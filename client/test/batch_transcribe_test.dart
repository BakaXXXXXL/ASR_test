import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

import 'package:asr_client/config.dart';
import 'package:asr_client/models/transcribe_task.dart';
import 'package:asr_client/services/asr_service.dart';
import 'package:asr_client/services/async_semaphore.dart';
import 'package:asr_client/services/audio_format.dart';
import 'package:asr_client/services/batch_export_helper.dart';
import 'package:asr_client/services/batch_transcribe_manager.dart';

/// 模拟 HTTP 请求适配器，用于控制网络并发和模拟响应
class MockBatchHttpClientAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) handler;

  MockBatchHttpClientAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

Future<File> _createMockWavFile(String name, {int pcmLength = 3200}) async {
  final tempDir = await Directory.systemTemp.createTemp('batch_test_');
  final file = File('${tempDir.path}/$name.wav');
  final header = buildWavHeader(pcmLength);
  final pcm = Uint8List(pcmLength);
  for (var i = 0; i < pcmLength; i += 2) {
    pcm[i] = ((i * 17) % 255);
    pcm[i + 1] = 0x20;
  }
  final raf = await file.open(mode: FileMode.write);
  await raf.writeFrom(header);
  await raf.writeFrom(pcm);
  await raf.close();
  return file;
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AsyncSemaphore 并发信号量单元测试', () {
    test('基本许可证获取与释放', () async {
      final sem = AsyncSemaphore(2);
      expect(sem.availablePermits, 2);
      expect(sem.queueLength, 0);

      await sem.acquire();
      expect(sem.availablePermits, 1);

      await sem.acquire();
      expect(sem.availablePermits, 0);

      sem.release();
      expect(sem.availablePermits, 1);

      sem.release();
      expect(sem.availablePermits, 2);
    });

    test('当许可证用尽时挂起，释放时唤醒等待者', () async {
      final sem = AsyncSemaphore(1);
      await sem.acquire();
      expect(sem.availablePermits, 0);

      var secondAcquired = false;
      unawaited(sem.acquire().then((_) {
        secondAcquired = true;
      }));

      // 尚未释放前，第二个任务应当在排队中
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(secondAcquired, isFalse);
      expect(sem.queueLength, 1);

      // 释放后，第二个任务被唤醒
      sem.release();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(secondAcquired, isTrue);
      expect(sem.availablePermits, 0);
      expect(sem.queueLength, 0);

      sem.release();
      expect(sem.availablePermits, 1);
    });

    test('run 保证异常时必定释放许可证', () async {
      final sem = AsyncSemaphore(1);
      try {
        await sem.run(() async {
          expect(sem.availablePermits, 0);
          throw Exception('test error');
        });
      } catch (_) {}

      expect(sem.availablePermits, 1);
    });

    test('多任务并发受控，最大并发数不超过 maxPermits', () async {
      const maxPermits = 3;
      final sem = AsyncSemaphore(maxPermits);
      var currentActive = 0;
      var peakActive = 0;

      final tasks = List.generate(10, (i) async {
        await sem.run(() async {
          currentActive++;
          if (currentActive > peakActive) {
            peakActive = currentActive;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
          currentActive--;
        });
      });

      await Future.wait(tasks);
      expect(peakActive, lessThanOrEqualTo(maxPermits));
      expect(sem.availablePermits, maxPermits);
    });
  });

  group('TranscribeTask 状态与模型测试', () {
    test('初始状态与属性计算', () {
      final task = TranscribeTask(
        id: '1',
        file: File('fake.wav'),
        fileName: 'fake.wav',
        fileSize: 1024 * 500, // 500 KB
        format: AudioFormat.wav,
      );

      expect(task.status, TaskStatus.idle);
      expect(task.progress, 0.0);
      expect(task.statusDisplay, '等待转写');
      expect(task.formattedSize, '500.0 KB');
    });

    test('转写中进度与分段计算', () {
      final task = TranscribeTask(
        id: '2',
        file: File('test.mp3'),
        fileName: 'test.mp3',
        fileSize: 1024 * 1024 * 5, // 5 MB
        format: AudioFormat.mp3,
        status: TaskStatus.transcribing,
        stage: AudioStage.segmentTranscribing,
        segDone: 3,
        segTotal: 6,
      );

      expect(task.progress, 0.5);
      expect(task.statusDisplay, '正在分段转写 3/6 段...');
      expect(task.formattedSize, '5.0 MB');
    });

    test('完成与失败状态', () {
      final task = TranscribeTask(
        id: '3',
        file: File('done.wav'),
        fileName: 'done.wav',
        fileSize: 100,
        format: AudioFormat.wav,
        status: TaskStatus.completed,
        resultText: '识别结果',
      );

      expect(task.progress, 1.0);
      expect(task.statusDisplay, '转写完成');
    });
  });

  group('BatchTranscribeManager 调度测试', () {
    late AppConfig config;

    setUp(() async {
      config = AppConfig();
      await config.load();
      await config.save(concurrency: 4);
    });

    test('添加合法与非法音频文件并正确嗅探', () async {
      final manager = BatchTranscribeManager(config: config);
      final wav = await _createMockWavFile('audio1');

      // 创建一个损坏的/不支持的伪造文件
      final tempDir = await Directory.systemTemp.createTemp('invalid_');
      final invalid = File('${tempDir.path}/corrupt.txt');
      await invalid.writeAsString('not an audio file');

      await manager.addFiles([wav, invalid]);

      expect(manager.totalCount, 2);
      expect(manager.tasks[0].format, AudioFormat.wav);
      expect(manager.tasks[0].status, TaskStatus.idle);

      expect(manager.tasks[1].format, isNull);
      expect(manager.tasks[1].status, TaskStatus.failed);
      expect(manager.tasks[1].errorMessage, unsupportedFormatMessage);

      manager.dispose();
    });

    test('启动任务并成功转写', () async {
      final mockDio = Dio(BaseOptions(baseUrl: config.baseUrl));
      mockDio.httpClientAdapter = MockBatchHttpClientAdapter((options) async {
        return ResponseBody.fromString(
          '{"choices":[{"message":{"content":"测试转写内容"}}]}',
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final asrService = AsrService(config, dio: mockDio);
      final manager =
          BatchTranscribeManager(config: config, asrService: asrService);

      final wav = await _createMockWavFile('success_audio');
      await manager.addFiles([wav]);

      final taskId = manager.tasks.first.id;
      await manager.startTask(taskId);

      expect(manager.tasks.first.status, TaskStatus.completed);
      expect(manager.tasks.first.resultText, '测试转写内容');
      expect(manager.completedCount, 1);

      manager.dispose();
    });

    test('一键全部开始与清空已完成', () async {
      final mockDio = Dio(BaseOptions(baseUrl: config.baseUrl));
      mockDio.httpClientAdapter = MockBatchHttpClientAdapter((options) async {
        return ResponseBody.fromString(
          '{"choices":[{"message":{"content":"并发结果"}}]}',
          200,
          headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
        );
      });

      final asrService = AsrService(config, dio: mockDio);
      final manager =
          BatchTranscribeManager(config: config, asrService: asrService);

      final f1 = await _createMockWavFile('file1');
      final f2 = await _createMockWavFile('file2');
      await manager.addFiles([f1, f2]);

      expect(manager.idleCount, 2);
      await manager.startAllPending();

      expect(manager.completedCount, 2);
      expect(manager.overallProgress, 1.0);

      // 清理已完成
      manager.clearCompleted();
      expect(manager.totalCount, 0);

      manager.dispose();
    });

    test('取消单个任务与批量取消', () async {
      final mockDio = Dio(BaseOptions(baseUrl: config.baseUrl));
      mockDio.httpClientAdapter = MockBatchHttpClientAdapter((options) async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return ResponseBody.fromString(
          '{"choices":[{"message":{"content":"延迟结果"}}]}',
          200,
          headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
        );
      });

      final asrService = AsrService(config, dio: mockDio);
      final manager =
          BatchTranscribeManager(config: config, asrService: asrService);

      final f1 = await _createMockWavFile('cancel_audio');
      await manager.addFiles([f1]);

      unawaited(manager.startTask(manager.tasks.first.id));
      await Future<void>.delayed(const Duration(milliseconds: 20));

      manager.cancelTask(manager.tasks.first.id);
      expect(manager.tasks.first.status, TaskStatus.cancelled);

      manager.dispose();
    });
  });
}

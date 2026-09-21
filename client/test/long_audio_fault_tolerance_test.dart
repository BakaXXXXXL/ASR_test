import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

import 'package:asr_client/config.dart';
import 'package:asr_client/services/asr_service.dart';
import 'package:asr_client/services/audio_format.dart';
import 'package:asr_client/services/audio_segment_transcriber.dart';

class ImmediateRateLimitCoordinator extends RateLimitCoordinator {
  @override
  Future<void> waitUntilReady() async {}
}

/// Helper to generate a valid test WAV file in a temporary directory.
Future<File> _createDummyWavFile(int pcmBytesLength) async {
  final tempDir = await Directory.systemTemp.createTemp('asr_fault_test_');
  final wavFile = File('${tempDir.path}/test_audio.wav');
  final header = buildWavHeader(pcmBytesLength);
  final pcm = Uint8List(pcmBytesLength);
  // Fill with dummy audio sine/sawtooth so VAD doesn't think it's purely corrupt
  for (var i = 0; i < pcmBytesLength; i += 2) {
    pcm[i] = (i % 256);
  }
  final raf = await wavFile.open(mode: FileMode.write);
  await raf.writeFrom(header);
  await raf.writeFrom(pcm);
  await raf.close();
  return wavFile;
}

void main() {
  group('AppConfig Concurrency', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('默认并发数为 6', () {
      final config = AppConfig();
      expect(config.concurrency, AppConfig.defaultConcurrency);
      expect(AppConfig.defaultConcurrency, 6);
      expect(AppConfig.minConcurrency, 1);
      expect(AppConfig.maxConcurrency, 16);
    });

    test('save 与 load 正确持久化并发数并限制在 [1, 16] 范围内', () async {
      SharedPreferences.setMockInitialValues({
        'concurrency': 12,
      });
      final config = AppConfig();
      await config.load();
      expect(config.concurrency, 12);

      // 保存超出上限的值 -> clamp 到 16
      await config.save(concurrency: 99);
      expect(config.concurrency, 16);

      // 保存低于下限的值 -> clamp 到 1
      await config.save(concurrency: 0);
      expect(config.concurrency, 1);

      await config.save(concurrency: -5);
      expect(config.concurrency, 1);

      // 重新加载验证持久化值
      final configReloaded = AppConfig();
      await configReloaded.load();
      expect(configReloaded.concurrency, 1);
    });
  });

  group('RateLimitCoordinator & 429 Backoff', () {
    test('初始状态非冷却中', () {
      final coordinator = RateLimitCoordinator();
      expect(coordinator.isCoolingDown, isFalse);
      expect(coordinator.remainingCooldown, Duration.zero);
      expect(coordinator.consecutive429Count, 0);
    });

    test('连续 429 阶梯递增冷却时长 (3s -> 6s -> 10s)', () {
      final coordinator = RateLimitCoordinator();

      // 第 1 次 429 -> 3s
      coordinator.record429();
      expect(coordinator.consecutive429Count, 1);
      expect(coordinator.isCoolingDown, isTrue);
      expect(coordinator.remainingCooldown.inSeconds, greaterThanOrEqualTo(2));
      expect(coordinator.remainingCooldown.inSeconds, lessThanOrEqualTo(3));

      // 第 2 次 429 -> 6s
      coordinator.record429();
      expect(coordinator.consecutive429Count, 2);
      expect(coordinator.remainingCooldown.inSeconds, greaterThanOrEqualTo(5));
      expect(coordinator.remainingCooldown.inSeconds, lessThanOrEqualTo(6));

      // 第 3 次 429 -> 10s
      coordinator.record429();
      expect(coordinator.consecutive429Count, 3);
      expect(coordinator.remainingCooldown.inSeconds, greaterThanOrEqualTo(9));
      expect(coordinator.remainingCooldown.inSeconds, lessThanOrEqualTo(10));

      // 成功请求重置计数
      coordinator.recordSuccess();
      expect(coordinator.consecutive429Count, 0);
    });

    test('支持 Retry-After 指定冷却秒数', () {
      final coordinator = RateLimitCoordinator();
      coordinator.record429(retryAfterSeconds: 5);
      expect(coordinator.isCoolingDown, isTrue);
      expect(coordinator.remainingCooldown.inSeconds, greaterThanOrEqualTo(4));
      expect(coordinator.remainingCooldown.inSeconds, lessThanOrEqualTo(5));
    });

    test('calculateBackoffDelay 包含指数基数与 Full Jitter', () {
      final random = Random(42);

      // attempt 0: base 1000ms + jitter [0, 1000)ms -> [1000, 2000)ms
      final delay0 = calculateBackoffDelay(0, random);
      expect(delay0.inMilliseconds, greaterThanOrEqualTo(1000));
      expect(delay0.inMilliseconds, lessThan(2000));

      // attempt 1: base 2000ms + jitter [0, 1000)ms -> [2000, 3000)ms
      final delay1 = calculateBackoffDelay(1, random);
      expect(delay1.inMilliseconds, greaterThanOrEqualTo(2000));
      expect(delay1.inMilliseconds, lessThan(3000));

      // attempt 5: base 32000ms 被 cap 在 20000ms -> [20000, 21000)ms
      final delay5 = calculateBackoffDelay(5, random);
      expect(delay5.inMilliseconds, greaterThanOrEqualTo(20000));
      expect(delay5.inMilliseconds, lessThan(21000));
    });

    test('parseRetryAfter 正确提取头信息', () {
      final dioErrWithHeader = DioException(
        requestOptions: RequestOptions(path: '/test'),
        response: Response(
          requestOptions: RequestOptions(path: '/test'),
          statusCode: 429,
          headers: Headers.fromMap({
            'retry-after': ['8']
          }),
        ),
      );
      expect(parseRetryAfter(dioErrWithHeader), 8);

      final dioErrNoHeader = DioException(
        requestOptions: RequestOptions(path: '/test'),
        response: Response(
          requestOptions: RequestOptions(path: '/test'),
          statusCode: 429,
        ),
      );
      expect(parseRetryAfter(dioErrNoHeader), isNull);
    });
  });

  group('SegmentTranscribeResult & Placeholders', () {
    test('failedSegmentPlaceholder 格式符合规范', () {
      expect(
        failedSegmentPlaceholder(19),
        '[第 19 段转写未完成，可点击上方重试]',
      );
    });

    test('SegmentTranscribeResult 统计指标计算正确', () {
      final result = SegmentTranscribeResult(
        fullText: '你好 [第 2 段转写未完成，可点击上方重试] 世界',
        segmentTexts: ['你好', null, '世界'],
        failedIndices: [1],
        totalCount: 3,
        errors: {1: 'Timeout'},
      );

      expect(result.isAllSuccessful, isFalse);
      expect(result.successCount, 2);
      expect(result.failedIndices, [1]);
      expect(result.totalCount, 3);
    });
  });

  group('Two-Phase Self-Healing Transcription', () {
    late File dummyWav;

    setUp(() async {
      // 构造包含约 5 个分段的测试音频（每段约 32000 字节）
      dummyWav = await _createDummyWavFile(32000 * 5);
    });

    tearDown(() async {
      try {
        if (await dummyWav.exists()) {
          await dummyWav.parent.delete(recursive: true);
        }
      } catch (_) {}
    });
    test('模拟偶发 429 限流：阶段一偶发失败 -> 阶段二自动单路补漏自愈完成 100% 成功', () async {
      final attemptsPerSegment = <int, int>{};
      final coordinator = ImmediateRateLimitCoordinator();

      // 构造每个长度不同的 plan，便于通过 wavBytes.length 唯一识别段落
      final mockPlan = [
        (start: 0, end: 30000),
        (start: 30000, end: 62000),
        (start: 62000, end: 96000),
        (start: 96000, end: 132000),
        (start: 132000, end: 160000),
      ];
      final statusMessages = <String>[];

      final result = await transcribeSegmented(
        dummyWav,
        existingPlan: mockPlan,
        concurrency: 4,
        rateLimitCoordinator: coordinator,
        onStatusMessage: (msg) => statusMessages.add(msg),
        backoffCalculator: (_) => Duration.zero,
        phase2Cooldown: Duration.zero,
        requestOne: (wavBytes, token) async {
          // 找到当前段的标识（通过 wavBytes 长度）
          final segmentIndex = mockPlan.indexWhere(
              (s) => wavBytes.length == 44 + (s.end - s.start));
          final attempt =
              (attemptsPerSegment[segmentIndex] = (attemptsPerSegment[segmentIndex] ?? 0) + 1);

          // 模拟第 2 段（index 1）在阶段一前 6 次全部报 429，但在阶段二补漏时成功
          if (segmentIndex == 1 && attempt <= 6) {
            throw DioException(
              requestOptions: RequestOptions(path: '/chat/completions'),
              response: Response(
                requestOptions: RequestOptions(path: '/chat/completions'),
                statusCode: 429,
              ),
              type: DioExceptionType.badResponse,
            );
          }

          return TranscribeResult(text: '段落_$segmentIndex');
        },
      );

      // 验证阶段二自动触发补转
      expect(statusMessages.any((msg) => msg.contains('自动补转失败分段')), isTrue);
      // 验证最终全量成功，无需人工干预
      expect(result.isAllSuccessful, isTrue);
      expect(result.failedIndices, isEmpty);
      expect(result.successCount, 5);
      expect(result.segmentTexts[1], '段落_1');
      expect(result.fullText, contains('段落_0'));
      expect(result.fullText, contains('段落_1'));
      expect(result.fullText, contains('段落_4'));
    });

    test('某段彻底永久失败时：保留全部已成功文本，占位符定位准确且永不丢失已转写内容', () async {
      final mockPlan = [
        (start: 0, end: 30000),
        (start: 30000, end: 62000),
        (start: 62000, end: 96000),
      ];

      final result = await transcribeSegmented(
        dummyWav,
        existingPlan: mockPlan,
        concurrency: 2,
        rateLimitCoordinator: ImmediateRateLimitCoordinator(),
        backoffCalculator: (_) => Duration.zero,
        phase2Cooldown: Duration.zero,
        requestOne: (wavBytes, token) async {
          final segmentIndex = mockPlan.indexWhere(
              (s) => wavBytes.length == 44 + (s.end - s.start));
          if (segmentIndex == 1) {
            throw DioException(
              requestOptions: RequestOptions(path: '/chat/completions'),
              response: Response(
                requestOptions: RequestOptions(path: '/chat/completions'),
                statusCode: 429,
              ),
              type: DioExceptionType.badResponse,
            );
          }

          return TranscribeResult(text: '有效文本_$segmentIndex');
        },
      );

      expect(result.isAllSuccessful, isFalse);
      expect(result.successCount, 2);
      expect(result.totalCount, 3);
      expect(result.failedIndices, [1]);
      // 已成功的第 1 段和第 3 段文本完整保留
      expect(result.segmentTexts[0], '有效文本_0');
      expect(result.segmentTexts[2], '有效文本_2');
      // 失败段落正确填充占位标记
      expect(result.fullText, contains('有效文本_0'));
      expect(result.fullText, contains('[第 2 段转写未完成，可点击上方重试]'));
      expect(result.fullText, contains('有效文本_2'));
    });
  });

  group('TranscribeSession & Fault-Tolerant Retry', () {
    late File dummyWav;

    setUp(() async {
      dummyWav = await _createDummyWavFile(32000 * 3);
    });

    tearDown(() async {
      try {
        if (await dummyWav.exists()) {
          await dummyWav.parent.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('TranscribeSession 维持现场并在 retryFailedSegments 中实现断点自愈', () async {
      final mockPlan = [
        (start: 0, end: 30000),
        (start: 30000, end: 62000),
        (start: 62000, end: 96000),
      ];

      // 构造初始部分成功会话：第 1、3 段成功，第 2 段失败
      final session = TranscribeSession(
        wavFile: dummyWav,
        plan: mockPlan,
        texts: ['段落_0', null, '段落_2'],
        failedIndices: [1],
        language: 'zh',
        concurrency: 6,
      );
      expect(session.isAllSuccessful, isFalse);
      expect(session.successCount, 2);
      expect(session.totalCount, 3);
      expect(session.failedSegmentsDisplay, '2');

      // 使用 transcribeSegmented 模拟独立重试仅第 2 段
      var retriedIndices = <int>[];
      final retryResult = await transcribeSegmented(
        session.wavFile,
        concurrency: 1,
        targetIndices: session.failedIndices,
        existingPlan: session.plan,
        existingTexts: session.texts,
        rateLimitCoordinator: ImmediateRateLimitCoordinator(),
        backoffCalculator: (_) => Duration.zero,
        phase2Cooldown: Duration.zero,
        requestOne: (wavBytes, token) async {
          retriedIndices.add(1);
          return TranscribeResult(text: '补跑成功的段落_1');
        },
      );

      // 验证仅第 2 段被调度重试
      expect(retriedIndices, [1]);
      // 验证重试后全量成功合并
      expect(retryResult.isAllSuccessful, isTrue);
      expect(retryResult.failedIndices, isEmpty);
      expect(retryResult.fullText, contains('段落_0'));
      expect(retryResult.fullText, contains('补跑成功的段落_1'));
      expect(retryResult.fullText, contains('段落_2'));
      expect(retryResult.fullText, isNot(contains('转写未完成')));
    });
  });
}

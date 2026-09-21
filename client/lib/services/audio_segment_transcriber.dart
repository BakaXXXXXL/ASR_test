import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'asr_service.dart';
import 'audio_format.dart';

/// 分段转写的并发数。默认 6，支持外部自定义（1~16）。
const int defaultSegmentConcurrency = 6;
const int segmentConcurrency = defaultSegmentConcurrency;

/// 阶段一每段最多尝试次数（1 次首发 + 5 次重试 = 6 次尝试）。
const int segmentMaxAttempts = 6;

/// 阶段二自动单路补漏每段最大尝试次数。
const int phase2SegmentMaxAttempts = 4;

/// 全局限流冷却协调器：当任意 Worker 收到 429 时进行全局协同退避，
/// 避免并发 Workers 同步撞墙。
class RateLimitCoordinator {
  DateTime? _cooldownUntil;
  int _consecutive429Count = 0;

  DateTime? get cooldownUntil => _cooldownUntil;
  int get consecutive429Count => _consecutive429Count;

  bool get isCoolingDown {
    final until = _cooldownUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  Duration get remainingCooldown {
    final until = _cooldownUntil;
    if (until == null) return Duration.zero;
    final diff = until.difference(DateTime.now());
    return diff > Duration.zero ? diff : Duration.zero;
  }

  Future<void> waitUntilReady() async {
    while (true) {
      final until = _cooldownUntil;
      if (until == null) break;
      final remaining = until.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      await Future.delayed(remaining);
    }
  }

  void record429({int? retryAfterSeconds, Duration? customCooldown}) {
    _consecutive429Count++;
    final Duration cooldownDuration;
    if (customCooldown != null) {
      cooldownDuration = customCooldown;
    } else if (retryAfterSeconds != null && retryAfterSeconds > 0) {
      cooldownDuration = Duration(seconds: retryAfterSeconds);
    } else {
      final seconds = switch (_consecutive429Count) {
        1 => 3,
        2 => 6,
        _ => 10,
      };
      cooldownDuration = Duration(seconds: seconds);
    }
    final target = DateTime.now().add(cooldownDuration);
    if (_cooldownUntil == null || target.isAfter(_cooldownUntil!)) {
      _cooldownUntil = target;
    }
  }

  void recordSuccess() {
    if (_consecutive429Count > 0) {
      _consecutive429Count = 0;
    }
  }

  void reset() {
    _cooldownUntil = null;
    _consecutive429Count = 0;
  }
}

/// 计算带 Full Jitter 的指数退避时长：
/// delay = min(20000ms, 1000ms * (1 << attempt)) + Random().nextInt(1000)ms
Duration calculateBackoffDelay(int attempt, [Random? random]) {
  final rnd = random ?? Random();
  final baseMs = min(20000, 1000 * (1 << attempt));
  final jitterMs = rnd.nextInt(1000);
  return Duration(milliseconds: baseMs + jitterMs);
}

/// 解析 Dio 响应头中的 Retry-After 秒数。
int? parseRetryAfter(DioException e) {
  final header = e.response?.headers.value('retry-after');
  if (header == null) return null;
  return int.tryParse(header.trim());
}

/// 分段转写结果数据模型。
class SegmentTranscribeResult {
  final String fullText;
  final List<String?> segmentTexts;
  final List<int> failedIndices; // 0-indexed
  final int totalCount;
  final Map<int, Object> errors;
  final List<AudioSegment> plan;

  SegmentTranscribeResult({
    required this.fullText,
    required this.segmentTexts,
    required this.failedIndices,
    required this.totalCount,
    required this.errors,
    this.plan = const [],
  });
  bool get isAllSuccessful => failedIndices.isEmpty;
  int get successCount => totalCount - failedIndices.length;
}

/// 失败分段占位标记。
String failedSegmentPlaceholder(int index1Based) =>
    '[第 $index1Based 段转写未完成，可点击上方重试]';

/// 把已归一化为 16kHz/单声道/16-bit 的 [wav16k] 切成 60 秒段并行转写，
/// 采用两阶段自愈执行（并发首轮 + 自动单路补漏 + 容灾组装），按段序合并文本返回。
///
/// [requestOne] 负责发一次识别请求（传入一段完整的 WAV 字节）。
/// 不会因为单段失败而取消全部任务并丢弃已完成文本。
Future<SegmentTranscribeResult> transcribeSegmented(
  File wav16k, {
  required Future<TranscribeResult> Function(
      Uint8List wavBytes, CancelToken token)
      requestOne,
  int concurrency = defaultSegmentConcurrency,
  void Function(int done, int total)? onProgress,
  void Function(String message)? onStatusMessage,
  RateLimitCoordinator? rateLimitCoordinator,
  List<AudioSegment>? existingPlan,
  List<String?>? existingTexts,
  List<int>? targetIndices,
  Duration Function(int attempt)? backoffCalculator,
  Duration phase2Cooldown = const Duration(seconds: 3),
}) async {
  final fileLength = await wav16k.length();
  final head =
      await _readRange(wav16k, 0, fileLength < 65536 ? fileLength : 65536);
  final data = findWavData(head);
  // 流式写入的 WAV declared size 可能为 0，此时以文件长度为准
  final declared = data.size == 0 ? fileLength - data.offset : data.size;
  final available = fileLength - data.offset;
  final pcmBytes = declared < available ? declared : available;
  if (pcmBytes <= 0) {
    throw const AudioInputException('WAV 文件中没有可识别的音频数据');
  }

  final plan = existingPlan ??
      await buildVadSegmentPlan(wav16k, data.offset, pcmBytes);
  final total = plan.length;
  if (total == 0) {
    return SegmentTranscribeResult(
      fullText: '',
      segmentTexts: const [],
      failedIndices: const [],
      totalCount: 0,
      errors: const {},
      plan: const [],
    );
  }

  final texts = List<String?>.from(
      existingTexts ?? List<String?>.filled(total, null),
      growable: false);
  final errors = <int, Object>{};
  final rateLimiter = rateLimitCoordinator ?? RateLimitCoordinator();
  final effectiveConcurrency = concurrency.clamp(1, 16);

  // 确定待处理的分段索引
  final List<int> queue;
  if (targetIndices != null) {
    queue = List<int>.from(targetIndices);
  } else {
    queue = [for (var i = 0; i < total; i++) if (texts[i] == null) i];
  }

  var doneCount = texts.where((t) => t != null).length;
  onProgress?.call(doneCount, total);

  var queueIndex = 0;

  // ----------------------------------------------------
  // 阶段一：并发主跑（捕获 429 协同限流退避，单段失败不取消全局）
  // ----------------------------------------------------
  Future<void> worker() async {
    while (true) {
      if (queueIndex >= queue.length) return;
      final idx = queue[queueIndex++];
      final segment = plan[idx];

      Object? lastError;
      for (var attempt = 0; attempt < segmentMaxAttempts; attempt++) {
        if (attempt > 0) {
          final delay = backoffCalculator != null
              ? backoffCalculator(attempt - 1)
              : calculateBackoffDelay(attempt - 1);
          if (delay > Duration.zero) {
            await Future.delayed(delay);
          }
        }
        await rateLimiter.waitUntilReady();

        try {
          final pcm = await _readRange(
              wav16k, data.offset + segment.start, segment.end - segment.start);
          final wavBytes = _wrapWav(pcm);
          final cancelToken = CancelToken();
          final result = await requestOne(wavBytes, cancelToken);
          texts[idx] = result.text;
          errors.remove(idx);
          rateLimiter.recordSuccess();
          doneCount++;
          onProgress?.call(doneCount, total);
          lastError = null;
          break;
        } on DioException catch (e) {
          if (CancelToken.isCancel(e)) return;
          lastError = e;
          if (e.response?.statusCode == 429) {
            rateLimiter.record429(retryAfterSeconds: parseRetryAfter(e));
          }
          if (!_isRetryable(e)) break;
        } catch (e) {
          lastError = e;
          break;
        }
      }

      if (lastError != null) {
        errors[idx] = lastError;
      }
    }
  }

  if (queue.isNotEmpty) {
    final workerCount = min(effectiveConcurrency, queue.length);
    await Future.wait(List.generate(workerCount, (_) => worker()));
  }

  // ----------------------------------------------------
  // 阶段二：自动单路补漏自愈（阶段一结束后，针对偶发失败段串行重试）
  // ----------------------------------------------------
  var failedIndices = [
    for (var i = 0; i < total; i++)
      if (texts[i] == null) i
  ];

  final hasRetryableFailure = failedIndices.any((i) {
    final err = errors[i];
    return err is DioException ? _isRetryable(err) : true;
  });

  if (failedIndices.isNotEmpty && hasRetryableFailure) {
    // 静默冷却，让服务端限流窗口恢复
    if (phase2Cooldown > Duration.zero) {
      await Future.delayed(phase2Cooldown);
    }

    onStatusMessage?.call('正在自动补转失败分段 (${failedIndices.length} 段)...');

    final rnd = Random();
    for (final idx in List<int>.from(failedIndices)) {
      final segment = plan[idx];
      Object? lastError;

      for (var attempt = 0; attempt < phase2SegmentMaxAttempts; attempt++) {
        if (attempt > 0) {
          final delay = backoffCalculator != null
              ? backoffCalculator(attempt - 1)
              : Duration(milliseconds: 2000 + rnd.nextInt(2000));
          if (delay > Duration.zero) {
            await Future.delayed(delay);
          }
        }
        await rateLimiter.waitUntilReady();

        try {
          final pcm = await _readRange(
              wav16k, data.offset + segment.start, segment.end - segment.start);
          final wavBytes = _wrapWav(pcm);
          final cancelToken = CancelToken();
          final result = await requestOne(wavBytes, cancelToken);
          texts[idx] = result.text;
          errors.remove(idx);
          rateLimiter.recordSuccess();
          doneCount++;
          onProgress?.call(doneCount, total);
          lastError = null;
          break;
        } on DioException catch (e) {
          if (CancelToken.isCancel(e)) break;
          lastError = e;
          if (e.response?.statusCode == 429) {
            rateLimiter.record429(retryAfterSeconds: parseRetryAfter(e));
          }
          if (!_isRetryable(e)) break;
        } catch (e) {
          lastError = e;
          break;
        }
      }

      if (lastError != null) {
        errors[idx] = lastError;
      }
    }

    failedIndices = [
      for (var i = 0; i < total; i++)
        if (texts[i] == null) i
    ];
  }

  // ----------------------------------------------------
  // 阶段三：组装与占位容灾（永不丢弃已成功的段落）
  // ----------------------------------------------------
  final assembledTexts = <String>[];
  for (var i = 0; i < total; i++) {
    final t = texts[i];
    if (t != null && t.isNotEmpty) {
      assembledTexts.add(t);
    } else if (t != null && t.isEmpty) {
      // 成功识别但为空音频段
      assembledTexts.add('');
    } else {
      assembledTexts.add(failedSegmentPlaceholder(i + 1));
    }
  }

  final fullText = mergeSegmentTexts(assembledTexts);

  return SegmentTranscribeResult(
    fullText: fullText,
    segmentTexts: texts,
    failedIndices: failedIndices,
    totalCount: total,
    errors: errors,
    plan: plan,
  );
}

Uint8List _wrapWav(Uint8List pcm) {
  final header = buildWavHeader(pcm.length);
  return Uint8List(header.length + pcm.length)
    ..setRange(0, header.length, header)
    ..setRange(header.length, header.length + pcm.length, pcm);
}

Future<Uint8List> _readRange(File file, int start, int length) async {
  final buffer = Uint8List(length);
  final raf = await file.open();
  try {
    await raf.setPosition(start);
    var read = 0;
    while (read < length) {
      final n = await raf.readInto(buffer, read, length);
      if (n <= 0) {
        throw const AudioInputException('读取音频分段时文件意外结束');
      }
      read += n;
    }
    return buffer;
  } finally {
    await raf.close();
  }
}

bool _isRetryable(DioException e) => switch (e.type) {
      DioExceptionType.badResponse => const {
          429,
          500,
          502,
          503,
          504,
        }.contains(e.response?.statusCode),
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.connectionError =>
        true,
      _ => false,
    };

/// 对文件中的 WAV PCM 数据应用 VAD 智能断句切片。
///
/// 仅在候选切片边界处按需读取 [vadMinSegmentSeconds] ~ [vadMaxSegmentSeconds] 字节块，
/// 不将全量音频载入内存。
Future<List<AudioSegment>> buildVadSegmentPlan(
  File wav16k,
  int dataOffset,
  int pcmBytes,
) async {
  if (pcmBytes <= 0) return const [];
  if (pcmBytes <= vadMaxSegmentBytes) {
    return [(start: 0, end: pcmBytes)];
  }

  final plan = <AudioSegment>[];
  final raf = await wav16k.open();
  try {
    var currentStart = 0;
    while (currentStart < pcmBytes) {
      final remaining = pcmBytes - currentStart;
      if (remaining <= vadMaxSegmentBytes) {
        plan.add((start: currentStart, end: pcmBytes));
        break;
      }

      final windowStart = currentStart + vadMinSegmentBytes;
      final windowEnd = currentStart + vadMaxSegmentBytes < pcmBytes
          ? currentStart + vadMaxSegmentBytes
          : pcmBytes;
      final windowLength = windowEnd - windowStart;

      if (windowLength <= vadFrameBytes) {
        final cut = currentStart + vadNominalSegmentBytes < pcmBytes
            ? currentStart + vadNominalSegmentBytes
            : pcmBytes;
        plan.add((start: currentStart, end: cut));
        currentStart = cut;
        continue;
      }

      await raf.setPosition(dataOffset + windowStart);
      final windowBytes = await raf.read(windowLength);

      final nominalOffset = vadNominalSegmentBytes - vadMinSegmentBytes;
      final relativeCut = findOptimalSplitOffset(
        windowBytes,
        targetOffset: nominalOffset < windowBytes.length
            ? nominalOffset
            : (windowBytes.length ~/ 2),
      );

      var actualCut = windowStart + relativeCut;
      if (actualCut <= currentStart) {
        actualCut = currentStart + vadNominalSegmentBytes;
      }
      if (actualCut > pcmBytes) {
        actualCut = pcmBytes;
      }

      plan.add((start: currentStart, end: actualCut));
      currentStart = actualCut;
    }
  } finally {
    await raf.close();
  }

  if (plan.length > maxSegmentCount) {
    throw AudioInputException(durationLimitMessage(
      Duration(seconds: pcmBytes ~/ wavBytesPerSecond),
      limit: maxSegmentedDuration,
    ));
  }
  return plan;
}

import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'asr_service.dart';
import 'audio_format.dart';

/// 分段转写的并发数。若 MiMo 侧限流明显可下调。
const int segmentConcurrency = 4;

/// 每段最多尝试次数（1 次首发 + 3 次重试）。
const int segmentMaxAttempts = 4;

/// 把已归一化为 16kHz/单声道/16-bit 的 [wav16k] 切成 60 秒段并行转写，
/// 按段序合并文本返回。
///
/// [requestOne] 负责发一次识别请求（传入一段完整的 WAV 字节）。
/// 每段失败最多尝试 [segmentMaxAttempts] 次（仅对 429/5xx/超时类错误
/// 指数退避）；任一段最终失败即取消其余段并抛 [AudioInputException]，
/// 不静默丢弃内容。
Future<String> transcribeSegmented(
  File wav16k, {
  required Future<TranscribeResult> Function(
      Uint8List wavBytes, CancelToken token)
      requestOne,
  void Function(int done, int total)? onProgress,
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
  final plan = await buildVadSegmentPlan(wav16k, data.offset, pcmBytes);
  final total = plan.length;

  final texts = List<String?>.filled(total, null);
  final cancelToken = CancelToken();
  var nextIndex = 0;
  var doneCount = 0;
  Object? fatal;

  Future<void> worker() async {
    while (true) {
      if (fatal != null) return;
      final i = nextIndex++;
      if (i >= total) return;
      final segment = plan[i];

      Object? lastError;
      for (var attempt = 0; attempt < segmentMaxAttempts; attempt++) {
        if (attempt > 0) {
          await Future.delayed(Duration(seconds: 1 << (attempt - 1)));
        }
        if (fatal != null) return;
        try {
          final pcm = await _readRange(
              wav16k, data.offset + segment.start, segment.end - segment.start);
          final wavBytes = _wrapWav(pcm);
          final result = await requestOne(wavBytes, cancelToken);
          texts[i] = result.text;
          doneCount++;
          onProgress?.call(doneCount, total);
          lastError = null;
          break;
        } on DioException catch (e) {
          if (CancelToken.isCancel(e)) return;
          lastError = e;
          if (!_isRetryable(e)) break;
        } catch (e) {
          lastError = e;
          break;
        }
      }

      if (lastError != null) {
        fatal =
            AudioInputException(segmentFailureMessage(i + 1, total, lastError));
        cancelToken.cancel();
        return;
      }
    }
  }

  await Future.wait(List.generate(segmentConcurrency, (_) => worker()));
  if (fatal != null) {
    throw fatal!;
  }
  return mergeSegmentTexts(texts.map((t) => t ?? '').toList());
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

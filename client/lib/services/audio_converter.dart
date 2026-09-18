import 'dart:io';

import 'package:audio_decoder/audio_decoder.dart';

import 'audio_format.dart';

/// 把 m4a 转成 MiMo ASR 可接受的 WAV（16 kHz / 单声道 / 16-bit PCM）。
///
/// 转码走系统原生解码器（Android MediaCodec / Windows Media Foundation），
/// 不需要打包 FFmpeg。
class AudioConverter {
  /// 转码 [src] 并返回临时 WAV 文件，调用方用完必须调用 [cleanup]。
  ///
  /// 时长超过 [maxDuration] 时直接报错，不会真的解码，
  /// 避免把超长音频展开成上百 MB 的 PCM。
  Future<File> toWav(File src,
      {Duration maxDuration = maxConvertibleDuration}) async {
    final Duration duration;
    try {
      duration = (await AudioDecoder.getAudioInfo(src.path)).duration;
    } catch (e) {
      throw AudioInputException(decodeFailureMessage(e));
    }

    if (duration > maxDuration) {
      throw AudioInputException(
          durationLimitMessage(duration, limit: maxDuration));
    }

    final dir = await Directory.systemTemp.createTemp('asr_m4a_');
    final output = File('${dir.path}${Platform.pathSeparator}converted.wav');
    try {
      await AudioDecoder.convertToWav(
        src.path,
        output.path,
        sampleRate: wavSampleRate,
        channels: wavChannels,
        bitDepth: wavBitDepth,
      );
      return output;
    } catch (e) {
      await cleanup(output);
      throw AudioInputException(decodeFailureMessage(e));
    }
  }

  /// 删除转码产生的临时文件及其目录。
  ///
  /// Windows 上文件可能仍被占用导致删除失败，此时静默忽略。
  Future<void> cleanup(File converted) async {
    try {
      final dir = converted.parent;
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // 临时目录最终由系统清理。
    }
  }
}

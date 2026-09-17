import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:asr_client/services/audio_format.dart';

/// 构造一个 12+ 字节的文件头，便于测试魔数识别。
Uint8List _head(String tag, {int offset = 0, int length = 16}) {
  final bytes = Uint8List(length);
  for (var i = 0; i < tag.length; i++) {
    bytes[offset + i] = tag.codeUnitAt(i);
  }
  return bytes;
}

void main() {
  group('detectAudioFormat', () {
    test('识别 RIFF/WAVE', () {
      final bytes = _head('RIFF');
      for (var i = 0; i < 4; i++) {
        bytes[8 + i] = 'WAVE'.codeUnitAt(i);
      }
      expect(detectAudioFormat(bytes), AudioFormat.wav);
    });

    test('识别 MP4 容器（m4a）', () {
      for (final brand in ['M4A ', 'isom', 'mp42']) {
        expect(
          detectAudioFormat(_head('ftyp$brand', offset: 4, length: 16)),
          AudioFormat.m4a,
          reason: 'major brand: $brand',
        );
      }
    });

    test('识别带 ID3 标签的 mp3', () {
      expect(detectAudioFormat(_head('ID3', length: 16)), AudioFormat.mp3);
    });

    test('识别裸 MPEG 帧同步字的 mp3', () {
      final bytes = Uint8List.fromList([0xFF, 0xFB, 0x90, 0x64, 0, 0, 0, 0]);
      expect(detectAudioFormat(bytes), AudioFormat.mp3);
    });

    test('无法识别时返回 null', () {
      expect(detectAudioFormat(Uint8List(0)), isNull);
      expect(detectAudioFormat(Uint8List.fromList([1, 2, 3])), isNull);
      expect(
        detectAudioFormat(
          Uint8List.fromList(List<int>.generate(64, (i) => (i * 7 + 1) % 251)),
        ),
        isNull,
      );
    });

    test('长度不足 12 字节的 wav/m4a 头不误判', () {
      expect(detectAudioFormat(_head('RIFF', length: 8)), isNull);
      expect(detectAudioFormat(_head('ftyp', offset: 4, length: 8)), isNull);
    });
  });

  group('MIME 映射', () {
    test('与 MiMo API 要求的 MIME 类型一致', () {
      expect(mimeTypeOf(AudioFormat.wav), 'audio/wav');
      expect(mimeTypeOf(AudioFormat.mp3), 'audio/mpeg');
      expect(mimeTypeOf(AudioFormat.m4a), 'audio/mp4');
    });

    test('只有 m4a 需要本地转码', () {
      expect(needsConversion(AudioFormat.wav), isFalse);
      expect(needsConversion(AudioFormat.mp3), isFalse);
      expect(needsConversion(AudioFormat.m4a), isTrue);
    });

    test('m4a 上传时用转码后的 wav MIME', () {
      expect(uploadFormatFor(AudioFormat.wav), AudioFormat.wav);
      expect(uploadFormatFor(AudioFormat.mp3), AudioFormat.mp3);
      expect(uploadFormatFor(AudioFormat.m4a), AudioFormat.wav);
      expect(
        mimeTypeOf(uploadFormatFor(AudioFormat.m4a)),
        'audio/wav',
      );
    });
  });

  group('Base64 体积上限', () {
    test('长度换算含补齐', () {
      expect(base64LengthFor(0), 0);
      expect(base64LengthFor(1), 4);
      expect(base64LengthFor(3), 4);
      expect(base64LengthFor(7_864_320), 10 * 1024 * 1024);
      expect(base64LengthFor(7_864_321), 10 * 1024 * 1024 + 4);
    });

    test('边界值', () {
      expect(maxRawBytes, 7_864_320);
      expect(fitsBase64Limit(maxRawBytes), isTrue);
      expect(fitsBase64Limit(maxRawBytes + 1), isFalse);
    });

    test('提示文案包含实际大小与上限', () {
      final message = sizeLimitMessage(10 * 1024 * 1024);
      expect(message, contains('13.3 MB'));
      expect(message, contains('10 MB'));
    });
  });

  group('m4a 时长上限', () {
    test('转码目标是 16kHz 单声道 16-bit', () {
      expect(wavSampleRate, 16000);
      expect(wavChannels, 1);
      expect(wavBitDepth, 16);
      expect(wavBytesPerSecond, 32000);
    });

    test('上限内的时长可以上传', () {
      expect(maxConvertibleDuration, const Duration(seconds: 240));
      expect(fitsBase64Limit(wavBytesFor(maxConvertibleDuration)), isTrue);
    });

    test('超出上限的时长会被拒绝', () {
      expect(fitsBase64Limit(wavBytesFor(const Duration(seconds: 246))), isFalse);
    });

    test('提示文案包含估算时长与上限', () {
      final message = durationLimitMessage(const Duration(seconds: 600));
      expect(message, contains('10.0 分钟'));
      expect(message, contains('4 分钟'));
    });
  });

  group('解码失败文案', () {
    test('包含原始错误与替代方案', () {
      final message = decodeFailureMessage(StateError('boom'));
      expect(message, contains('M4A 解码失败'));
      expect(message, contains('boom'));
      expect(message, contains('WAV / MP3'));
    });
  });

  group('音频输入异常', () {
    test('toString 直接返回可读文案', () {
      const e = AudioInputException(unsupportedFormatMessage);
      expect(e.toString(), '无法识别的音频格式，仅支持 WAV / MP3 / M4A');
    });
  });

  group('file_picker 白名单', () {
    test('只包含 wav/mp3/m4a', () {
      expect(pickedExtensions, ['wav', 'mp3', 'm4a']);
    });
  });
}

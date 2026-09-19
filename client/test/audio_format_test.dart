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
      expect(message, contains('10 分钟'));
      expect(message, contains('4 分钟'));
    });
  });

  group('解码失败文案', () {
    test('包含原始错误与替代方案', () {
      final message = decodeFailureMessage(StateError('boom'));
      expect(message, contains('音频解码失败'));
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

  group('分段计划', () {
    const segmentBytes = 60 * 32000; // 60 秒 × 32000 B/s

    test('每段 60 秒、最多 2 小时', () {
      expect(segmentSeconds, 60);
      expect(maxSegmentedDuration, const Duration(hours: 2));
    });

    test('整除时不产生尾段', () {
      final plan = buildSegmentPlan(2 * segmentBytes);
      expect(plan.length, 2);
      expect(plan[0], (start: 0, end: segmentBytes));
      expect(plan[1], (start: segmentBytes, end: 2 * segmentBytes));
    });

    test('尾段可以短于 60 秒', () {
      final plan = buildSegmentPlan(segmentBytes + 1000);
      expect(plan.length, 2);
      expect(plan[1].start, segmentBytes);
      expect(plan[1].end - plan[1].start, 1000);
    });

    test('空输入得到空计划', () {
      expect(buildSegmentPlan(0), isEmpty);
    });

    test('段与段之间连续无重叠', () {
      final plan = buildSegmentPlan(5 * segmentBytes + 123);
      for (var i = 1; i < plan.length; i++) {
        expect(plan[i].start, plan[i - 1].end);
      }
    });

    test('恰好 125 段允许，再多 1 字节抛超限', () {
      expect(
        buildSegmentPlan(maxSegmentCount * segmentBytes).length,
        maxSegmentCount,
      );
      expect(
        () => buildSegmentPlan(maxSegmentCount * segmentBytes + 1),
        throwsA(isA<AudioInputException>().having(
          (e) => e.toString(),
          'message',
          allOf(contains('超过上限 2 小时'), contains('请裁剪')),
        )),
      );
    });
  });

  group('WAV 头构造与解析', () {
    test('buildWavHeader 生成标准 44 字节头', () {
      final header = buildWavHeader(1000);
      final view = ByteData.sublistView(header);
      expect(header.length, 44);
      expect(String.fromCharCodes(header.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(header.sublist(8, 12)), 'WAVE');
      expect(String.fromCharCodes(header.sublist(12, 16)), 'fmt ');
      expect(String.fromCharCodes(header.sublist(36, 40)), 'data');
      expect(view.getUint32(4, Endian.little), 44 - 8 + 1000);
      expect(view.getUint16(20, Endian.little), 1); // PCM
      expect(view.getUint32(24, Endian.little), 16000);
      expect(view.getUint32(28, Endian.little), 32000);
      expect(view.getUint16(32, Endian.little), 2);
      expect(view.getUint16(34, Endian.little), 16);
      expect(view.getUint32(40, Endian.little), 1000);
    });

    test('findWavData 识别标准 44 字节头', () {
      final header = buildWavHeader(1000);
      expect(findWavData(header), (offset: 44, size: 1000));
    });

    test('findWavData 跳过扩展块（LIST）定位 data', () {
      final header = _wavWithChunks([
        ('LIST', 100),
        ('data', 55),
      ]);
      expect(findWavData(header), (offset: 12 + 24 + 8 + 100 + 8, size: 55));
    });

    test('findWavData 对奇数长度块处理对齐填充', () {
      final header = _wavWithChunks([
        ('LIST', 101), // 奇数 → 补 1 字节
        ('data', 55),
      ]);
      expect(findWavData(header), (offset: 12 + 24 + 8 + 102 + 8, size: 55));
    });

    test('非 RIFF 数据抛解析失败', () {
      expect(
        () => findWavData(Uint8List(64)),
        throwsA(isA<AudioInputException>()
            .having((e) => e.toString(), 'message', contains('WAV'))),
      );
    });

    test('缺少 data 块抛错误', () {
      final header = _wavWithChunks([('LIST', 8)]);
      expect(
        () => findWavData(header),
        throwsA(isA<AudioInputException>()
            .having((e) => e.toString(), 'message', contains('data'))),
      );
    });
  });

  group('分段结果合并', () {
    test('按序拼接并跳过空段', () {
      expect(mergeSegmentTexts(['第一 段', '', '  ', '第二段']),
          '第一 段\n第二段');
    });

    test('全为空时返回空字符串', () {
      expect(mergeSegmentTexts(['', '   ']), '');
    });

    test('单段不加换行', () {
      expect(mergeSegmentTexts(['你好\n']), '你好');
    });
  });

  group('分段失败文案', () {
    test('包含段号与原始错误', () {
      final message = segmentFailureMessage(3, 12, 'timeout');
      expect(message, contains('第 3/12 段'));
      expect(message, contains('timeout'));
    });
  });

  group('VAD 智能静音断句切片', () {
    test('小缓冲区安全回退并对齐', () {
      final small = Uint8List(100);
      final cut = findOptimalSplitOffset(small, targetOffset: 51);
      expect(cut % 2, 0);
      expect(cut, 50);
    });

    test('优先命中静音区间中心', () {
      // 15 秒搜索窗口（480,000 字节）
      const windowBytesCount = 15 * wavBytesPerSecond;
      final buffer = Uint8List(windowBytesCount);
      final view = ByteData.sublistView(buffer);

      // 默认填充大音量正弦/方波样本（幅值 4000）
      for (var i = 0; i < windowBytesCount; i += 2) {
        view.setInt16(i, (i % 8 < 4) ? 4000 : -4000, Endian.little);
      }

      // 在 [200,000, 220,000]（长约 625ms）人工挖出一个静音空洞（振幅 0）
      for (var i = 200000; i < 220000; i += 2) {
        view.setInt16(i, 0, Endian.little);
      }

      final cut = findOptimalSplitOffset(buffer, targetOffset: 320000);
      expect(cut % 2, 0);
      // 切分点必须精准落在静音区间 [200000, 220000] 内部
      expect(cut, greaterThanOrEqualTo(200000));
      expect(cut, lessThanOrEqualTo(220000));
    });

    test('多静音区间优先选择最靠近目标偏移行者', () {
      const windowBytesCount = 15 * wavBytesPerSecond;
      final buffer = Uint8List(windowBytesCount);
      final view = ByteData.sublistView(buffer);

      for (var i = 0; i < windowBytesCount; i += 2) {
        view.setInt16(i, 5000, Endian.little);
      }

      // 静音区间 1：远离目标 (60,000 ~ 70,000)
      for (var i = 60000; i < 70000; i += 2) {
        view.setInt16(i, 0, Endian.little);
      }

      // 静音区间 2：紧邻目标 320,000 (310,000 ~ 325,000)
      for (var i = 310000; i < 325000; i += 2) {
        view.setInt16(i, 0, Endian.little);
      }

      final cut = findOptimalSplitOffset(buffer, targetOffset: 320000);
      // 必须优先选取更靠近 320,000 的静音区间 2
      expect(cut, greaterThanOrEqualTo(310000));
      expect(cut, lessThanOrEqualTo(325000));
    });

    test('全段无明显静音时选取局部能量波谷', () {
      const windowBytesCount = 15 * wavBytesPerSecond;
      final buffer = Uint8List(windowBytesCount);
      final view = ByteData.sublistView(buffer);

      // 整体较高能量（幅值 3000）
      for (var i = 0; i < windowBytesCount; i += 2) {
        view.setInt16(i, 3000, Endian.little);
      }

      // 在 250,000 处存在一段局部较低能量（幅值 600，虽未达到静音阈值但为明显局部凹陷）
      for (var i = 245000; i < 255000; i += 2) {
        view.setInt16(i, 600, Endian.little);
      }

      final cut = findOptimalSplitOffset(buffer, targetOffset: 250000);
      expect(cut, closeTo(250000, 3200)); // 误差在 100ms 内
    });

    test('buildVadSegmentPlanFromBytes 规划连续无缝片段', () {
      // 构造 130 秒长度的音频（130 * 32000 字节）
      const totalSeconds = 130;
      final bytes = Uint8List(totalSeconds * wavBytesPerSecond);
      final plan = buildVadSegmentPlanFromBytes(bytes);

      expect(plan.length, greaterThanOrEqualTo(2));
      expect(plan.first.start, 0);
      expect(plan.last.end, bytes.length);

      for (var i = 1; i < plan.length; i++) {
        expect(plan[i].start, plan[i - 1].end);
        expect(plan[i].start % 2, 0);
        expect(plan[i].end % 2, 0);
      }
    });

    test('小于最大单段时无需切片', () {
      final shortBytes = Uint8List(30 * wavBytesPerSecond);
      final plan = buildVadSegmentPlanFromBytes(shortBytes);
      expect(plan.length, 1);
      expect(plan[0], (start: 0, end: shortBytes.length));
    });
  });
}

/// 构造带指定 chunk 序列的 WAV 头：fmt(16) + 各给定块，data 块内容省略。
Uint8List _wavWithChunks(List<(String tag, int size)> chunks) {
  var length = 12 + 24; // RIFF 头 + fmt chunk
  for (final (_, size) in chunks) {
    length += 8 + size + (size & 1);
  }
  final bytes = Uint8List(length);
  final view = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  bytes.setRange(8, 12, 'WAVE'.codeUnits);
  bytes.setRange(12, 16, 'fmt '.codeUnits);
  view.setUint32(16, 16, Endian.little);
  view.setUint32(4, length - 8, Endian.little);
  var pos = 12 + 24;
  for (final (tag, size) in chunks) {
    bytes.setRange(pos, pos + 4, tag.codeUnits);
    view.setUint32(pos + 4, size, Endian.little);
    pos += 8 + size + (size & 1);
  }
  return bytes;
}

import 'dart:typed_data';

/// 客户端支持的音频容器格式。
///
/// MiMo ASR 只接受 wav / mp3，m4a 会先在本地转码成 wav（见 [AudioConverter]）。
enum AudioFormat { wav, mp3, m4a }

/// `file_picker` 的扩展名白名单（真正的格式判定以文件头为准）。
const List<String> pickedExtensions = ['wav', 'mp3', 'm4a'];

/// MiMo ASR 的硬性限制：Base64 编码后的字符串不得超过 10 MB。
const int maxBase64Chars = 10 * 1024 * 1024;

/// m4a 的转码目标参数：16 kHz / 单声道 / 16-bit PCM，ASR 的常规输入规格。
const int wavSampleRate = 16000;
const int wavChannels = 1;
const int wavBitDepth = 16;

/// 上述转码规格的字节率：32000 B/s。
const int wavBytesPerSecond = wavSampleRate * wavChannels * (wavBitDepth ~/ 8);

/// WAV 文件头长度。
const int _wavHeaderBytes = 44;

/// 不加密情况下可上传的最大原始字节数：7_864_320 B（≈ 7.5 MB）。
const int maxRawBytes = maxBase64Chars ~/ 4 * 3;

/// m4a 转码后可上传的最长时长。
///
/// 按 [maxRawBytes] 计算理论上限约 245 秒，这里取 240 秒留出余量。
const int maxConvertibleSeconds = 240;

/// 转码后可单次上传的最长时长。
const Duration maxConvertibleDuration = Duration(seconds: maxConvertibleSeconds);

/// 分段转写：标准目标时长（秒）。
const int segmentSeconds = 60;

/// VAD 弹性切片搜索窗口（秒）：在 [50s, 65s] 之间寻找自然停顿
const int vadMinSegmentSeconds = 50;
const int vadNominalSegmentSeconds = 60;
const int vadMaxSegmentSeconds = 65;

/// VAD 对应的字节数
const int vadMinSegmentBytes = vadMinSegmentSeconds * wavBytesPerSecond;
const int vadNominalSegmentBytes = vadNominalSegmentSeconds * wavBytesPerSecond;
const int vadMaxSegmentBytes = vadMaxSegmentSeconds * wavBytesPerSecond;

/// VAD 采样帧长：20ms（16kHz 下为 320 个采样点，即 640 字节）
const int vadFrameSamples = 320;
const int vadFrameBytes = vadFrameSamples * 2;

/// VAD 帧步长：10ms（160 个采样点，320 字节）
const int vadFrameStepSamples = 160;
const int vadFrameStepBytes = vadFrameStepSamples * 2;

/// VAD 判定为静音的平均绝对振幅（MAV）阈值（16-bit PCM 范围 -32768 ~ 32767）
const int vadSilenceThreshold = 350;

/// 分段转写：最大段数（约等于 [maxSegmentedDuration] / [segmentSeconds] 再多留一点余量）。
const int maxSegmentCount = 145;

/// 分段转写支持的录音总时长上限：2 小时。
const Duration maxSegmentedDuration = Duration(hours: 2);

/// 无法识别文件头时的统一提示。
const String unsupportedFormatMessage = '无法识别的音频格式，仅支持 WAV / MP3 / M4A';

/// 输入本身不合法（格式 / 体积 / 时长 / 解码失败）时抛出，
/// [toString] 直接返回可读文案，UI 可以原样展示。
class AudioInputException implements Exception {
  final String message;

  const AudioInputException(this.message);

  @override
  String toString() => message;
}

/// 读取文件头判断真实格式，识别不了返回 null。
///
/// - wav：`RIFF....WAVE`
/// - m4a：偏移 4 起为 `ftyp`（MP4 容器）
/// - mp3：`ID3` 标签或 MPEG 帧同步字（0xFFEx / 0xFFFx）
AudioFormat? detectAudioFormat(Uint8List bytes) {
  if (bytes.length >= 12) {
    if (_asciiAt(bytes, 0, 'RIFF') && _asciiAt(bytes, 8, 'WAVE')) {
      return AudioFormat.wav;
    }
    if (_asciiAt(bytes, 4, 'ftyp')) {
      return AudioFormat.m4a;
    }
  }

  if (_asciiAt(bytes, 0, 'ID3')) {
    return AudioFormat.mp3;
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) {
    return AudioFormat.mp3;
  }

  return null;
}

/// 上传时使用的 data URL MIME 类型。
String mimeTypeOf(AudioFormat format) => switch (format) {
  AudioFormat.wav => 'audio/wav',
  AudioFormat.mp3 => 'audio/mpeg',
  AudioFormat.m4a => 'audio/mp4',
};

/// 是否需要在本地转码后才能上传（目前只有 m4a）。
bool needsConversion(AudioFormat format) => format == AudioFormat.m4a;

/// 实际上传给 API 的格式：m4a 先转码成 wav，因此上传时要用 wav。
AudioFormat uploadFormatFor(AudioFormat source) =>
    needsConversion(source) ? AudioFormat.wav : source;

/// Base64 编码后的字符数（含补齐）。
int base64LengthFor(int rawBytes) => 4 * ((rawBytes + 2) ~/ 3);

/// 原始字节数 Base64 后是否还在 10 MB 上限内。
bool fitsBase64Limit(int rawBytes) => base64LengthFor(rawBytes) <= maxBase64Chars;

/// 按转码规格估算得到的 WAV 文件大小（含文件头）。
int wavBytesFor(Duration duration) {
  final samples = (duration.inMilliseconds * wavSampleRate) ~/ 1000;
  return _wavHeaderBytes + samples * wavChannels * (wavBitDepth ~/ 8);
}

/// 一段分段计划：PCM 数据区内的字节区间 [start, end)。
typedef AudioSegment = ({int start, int end});

/// 把 PCM 字节数切成 [segmentSeconds] 秒的段，尾段可短。
///
/// 段数超过 [maxSegmentCount]（≈2 小时）时抛 [AudioInputException]。
List<AudioSegment> buildSegmentPlan(int pcmBytes) {
  final segmentBytes = segmentSeconds * wavBytesPerSecond;
  final plan = <AudioSegment>[];
  var offset = 0;
  while (offset < pcmBytes) {
    final end = offset + segmentBytes < pcmBytes ? offset + segmentBytes : pcmBytes;
    plan.add((start: offset, end: end));
    offset = end;
  }
  if (plan.length > maxSegmentCount) {
    throw AudioInputException(durationLimitMessage(
      Duration(seconds: pcmBytes ~/ wavBytesPerSecond),
      limit: maxSegmentedDuration,
    ));
  }
  return plan;
}

/// 在 [windowBytes]（16kHz 16-bit 单声道 PCM）中分析短时能量，返回最佳切断点的字节偏移。
///
/// [targetOffset] 为名义目标偏移（通常是对应 60s 处的字节偏移）。
/// 优先检索持续时间 ≥100ms 且 MAV ≤ [vadSilenceThreshold] 的静音区间中心；
/// 若没有明显静音，则选择局部能量平滑谷底，确保切片落在自然呼吸停顿处。
int findOptimalSplitOffset(Uint8List windowBytes, {int? targetOffset}) {
  if (windowBytes.length < vadFrameBytes) {
    final t = targetOffset ?? (windowBytes.length ~/ 2);
    return (t.clamp(0, windowBytes.length)) & ~1;
  }

  final target = (targetOffset ?? (windowBytes.length ~/ 2)).clamp(0, windowBytes.length);
  final view = ByteData.sublistView(windowBytes);
  final numFrames = (windowBytes.length - vadFrameBytes) ~/ vadFrameStepBytes + 1;
  if (numFrames <= 0) {
    return target & ~1;
  }

  // 1. 计算各帧的平均绝对幅度 MAV
  final frameMavs = Int32List(numFrames);
  for (var f = 0; f < numFrames; f++) {
    final frameByteOffset = f * vadFrameStepBytes;
    var sum = 0;
    for (var i = 0; i < vadFrameSamples; i++) {
      final sample = view.getInt16(frameByteOffset + i * 2, Endian.little);
      sum += sample.abs();
    }
    frameMavs[f] = sum ~/ vadFrameSamples;
  }

  // 2. 滑动窗口平滑（半径 7 帧，覆盖约 150ms 窗口）
  final smoothed = Int32List(numFrames);
  const radius = 7;
  var windowSum = 0;
  var count = 0;
  final initialEnd = radius < numFrames ? radius : numFrames - 1;
  for (var f = 0; f <= initialEnd; f++) {
    windowSum += frameMavs[f];
    count++;
  }
  for (var f = 0; f < numFrames; f++) {
    final right = f + radius;
    if (right < numFrames && right > initialEnd) {
      windowSum += frameMavs[right];
      count++;
    }
    final left = f - radius - 1;
    if (left >= 0) {
      windowSum -= frameMavs[left];
      count--;
    }
    smoothed[f] = count > 0 ? (windowSum ~/ count) : frameMavs[f];
  }

  // 3. 寻找连续静音区间（≥10 帧，即 ≥100ms）
  final silenceIntervals = <({int start, int end})>[];
  var inSilence = false;
  var silenceStart = 0;
  for (var f = 0; f < numFrames; f++) {
    if (smoothed[f] <= vadSilenceThreshold) {
      if (!inSilence) {
        inSilence = true;
        silenceStart = f;
      }
    } else {
      if (inSilence) {
        inSilence = false;
        if (f - silenceStart >= 10) {
          silenceIntervals.add((start: silenceStart, end: f - 1));
        }
      }
    }
  }
  if (inSilence && numFrames - silenceStart >= 10) {
    silenceIntervals.add((start: silenceStart, end: numFrames - 1));
  }

  // 4. 若有满足条件的静音区间，选取中心点最接近 target 的区间
  if (silenceIntervals.isNotEmpty) {
    var bestDiff = 0x7FFFFFFF;
    var bestOffset = target;
    for (final interval in silenceIntervals) {
      final centerFrame = (interval.start + interval.end) ~/ 2;
      final centerByte = centerFrame * vadFrameStepBytes + vadFrameBytes ~/ 2;
      final diff = (centerByte - target).abs();
      if (diff < bestDiff) {
        bestDiff = diff;
        bestOffset = centerByte;
      }
    }
    return (bestOffset.clamp(0, windowBytes.length)) & ~1;
  }

  // 5. 兜底策略：全段无明显静音时，寻找加权局部能量谷底
  var minScore = 0x7FFFFFFF;
  var bestFrame = numFrames ~/ 2;
  for (var f = 0; f < numFrames; f++) {
    final byteOffset = f * vadFrameStepBytes + vadFrameBytes ~/ 2;
    final distanceSec = (byteOffset - target).abs() / wavBytesPerSecond;
    final score = smoothed[f] + (distanceSec * 40).toInt();
    if (score < minScore) {
      minScore = score;
      bestFrame = f;
    }
  }

  final fallbackByte = bestFrame * vadFrameStepBytes + vadFrameBytes ~/ 2;
  return (fallbackByte.clamp(0, windowBytes.length)) & ~1;
}

/// 对内存中的 PCM 字节应用 VAD 智能断句切片计划（主要供单测和内存音频使用）。
List<AudioSegment> buildVadSegmentPlanFromBytes(Uint8List pcmBytes) {
  final totalBytes = pcmBytes.length;
  if (totalBytes <= 0) return const [];
  if (totalBytes <= vadMaxSegmentBytes) {
    return [(start: 0, end: totalBytes)];
  }

  final plan = <AudioSegment>[];
  var currentStart = 0;
  while (currentStart < totalBytes) {
    final remaining = totalBytes - currentStart;
    if (remaining <= vadMaxSegmentBytes) {
      plan.add((start: currentStart, end: totalBytes));
      break;
    }

    final windowStart = currentStart + vadMinSegmentBytes;
    final windowEnd = currentStart + vadMaxSegmentBytes < totalBytes
        ? currentStart + vadMaxSegmentBytes
        : totalBytes;
    final windowLength = windowEnd - windowStart;

    if (windowLength <= vadFrameBytes) {
      final cut = currentStart + vadNominalSegmentBytes < totalBytes
          ? currentStart + vadNominalSegmentBytes
          : totalBytes;
      plan.add((start: currentStart, end: cut));
      currentStart = cut;
      continue;
    }

    final windowBytes = pcmBytes.sublist(windowStart, windowEnd);
    final nominalOffset = vadNominalSegmentBytes - vadMinSegmentBytes;
    final relativeCut = findOptimalSplitOffset(
      windowBytes,
      targetOffset: nominalOffset < windowLength ? nominalOffset : (windowLength ~/ 2),
    );

    var actualCut = windowStart + relativeCut;
    if (actualCut <= currentStart) {
      actualCut = currentStart + vadNominalSegmentBytes;
    }
    if (actualCut > totalBytes) {
      actualCut = totalBytes;
    }

    plan.add((start: currentStart, end: actualCut));
    currentStart = actualCut;
  }

  if (plan.length > maxSegmentCount) {
    throw AudioInputException(durationLimitMessage(
      Duration(seconds: totalBytes ~/ wavBytesPerSecond),
      limit: maxSegmentedDuration,
    ));
  }
  return plan;
}

/// 构造 44 字节的 RIFF/WAVE 文件头（16kHz 单声道 16-bit）。
Uint8List buildWavHeader(int pcmLength) {
  final header = Uint8List(_wavHeaderBytes);
  final view = ByteData.sublistView(header);
  header.setRange(0, 4, 'RIFF'.codeUnits);
  view.setUint32(4, _wavHeaderBytes - 8 + pcmLength, Endian.little);
  header.setRange(8, 12, 'WAVE'.codeUnits);
  header.setRange(12, 16, 'fmt '.codeUnits);
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little); // PCM
  view.setUint16(22, wavChannels, Endian.little);
  view.setUint32(24, wavSampleRate, Endian.little);
  view.setUint32(28, wavBytesPerSecond, Endian.little);
  view.setUint16(32, wavChannels * (wavBitDepth ~/ 8), Endian.little);
  view.setUint16(34, wavBitDepth, Endian.little);
  header.setRange(36, 40, 'data'.codeUnits);
  view.setUint32(40, pcmLength, Endian.little);
  return header;
}

/// 解析 WAV 文件头，定位 PCM 数据区。
///
/// 文件头不一定是标准 44 字节（解码器可能写入 LIST/fact 等扩展块），
/// 因此逐 chunk 扫描找 `data`。入参为文件开头的一段字节（几 KB 足够）。
({int offset, int size}) findWavData(Uint8List headerBytes) {
  if (headerBytes.length < 12 ||
      !_asciiAt(headerBytes, 0, 'RIFF') ||
      !_asciiAt(headerBytes, 8, 'WAVE')) {
    throw const AudioInputException('WAV 文件头解析失败');
  }
  final view = ByteData.sublistView(headerBytes);
  var pos = 12;
  while (pos + 8 <= headerBytes.length) {
    final size = view.getUint32(pos + 4, Endian.little);
    if (_asciiAt(headerBytes, pos, 'data')) {
      return (offset: pos + 8, size: size);
    }
    // chunk 按偶数字节对齐（奇数长度会填充 1 字节）
    pos += 8 + size + (size & 1);
  }
  throw const AudioInputException('WAV 文件中未找到 data 块');
}

/// 清洗 ASR 识别结果文本，消除模型幻觉、特殊控制 Token 及无意义重复占位符。
///
/// 1. 过滤模型特殊标记：如 `<chinese>`, `<english>`, `<silence>`, `<music>`, `<|zh|>`, `[BLANK]` 等。
/// 2. 避免误伤数学符号：`<...>` 正则要求无空格，绝不影响 `r < R`、`a < b` 等不等式。
/// 3. 过滤极端重复循环（Repetition Hallucination）。
/// 4. 实质语音字符校验：剥离特殊标记后若无汉字/英文字母/数字（仅剩残留标点或空白），直接返回空字符串。
String cleanAsrText(String text) {
  if (text.isEmpty) return '';

  // 1. 过滤模型无空格的特殊 Token 与语言/副语言标签
  var cleaned = text.replaceAll(RegExp(r'<\|?[a-zA-Z][a-zA-Z0-9_\-]*\|?>'), '');

  // 匹配 ASR 方括号事件标签: [BLANK], [silence], [music], [applause], [laughter] 等
  cleaned = cleaned.replaceAll(
    RegExp(
      r'\[(BLANK|blank|silence|music|applause|laughter|whisper|cough|screaming|snort|pant|null)\]',
      caseSensitive: false,
    ),
    '',
  );

  // 匹配圆括号事件标签: (music), (applause), (silence), (laughter) 等
  cleaned = cleaned.replaceAll(
    RegExp(
      r'\((music|applause|silence|laughter|whisper|cough)\)',
      caseSensitive: false,
    ),
    '',
  );

  cleaned = cleaned.trim();
  if (cleaned.isEmpty) return '';

  // 2. 实质内容校验：若完全不包含汉字、字母或数字（例如仅剩剥除残留的标点符号 ，。！？ 等），判定为空
  if (!RegExp(r'[\u4e00-\u9fa5a-zA-Z0-9]').hasMatch(cleaned)) {
    return '';
  }

  // 3. 过滤极端重复循环 (Repetition Hallucination)
  // 空格拆分多词完全一致且重复 5 次以上（如 "啊 啊 啊 啊 啊"）
  final tokens = cleaned.split(RegExp(r'\s+'));
  if (tokens.length >= 5 && tokens.toSet().length == 1) {
    return '';
  }

  // 单个中文字符无空格连续重复 10 次以上（如 "啊啊啊啊啊啊啊啊啊啊"）
  if (cleaned.length >= 10 && cleaned.runes.toSet().length == 1) {
    return '';
  }

  return cleaned;
}

/// 检测一段 16kHz 16-bit 单声道 PCM 数据是否为完全无声/静音。
///
/// 若整段数据的最大绝对振幅低于 [maxThreshold]（默认 150，约等于满量程 0.45%），
/// 且平均绝对幅度（MAV）低于 [mavThreshold]（默认 35），判定为数字静音或无声段落。
bool isSilentAudio(
  Uint8List pcmBytes, {
  int maxThreshold = 150,
  int mavThreshold = 35,
}) {
  if (pcmBytes.isEmpty) return true;
  final numSamples = pcmBytes.length ~/ 2;
  if (numSamples == 0) return true;

  final view = ByteData.sublistView(pcmBytes);
  var maxAmp = 0;
  var sum = 0;
  for (var i = 0; i < numSamples; i++) {
    final sample = view.getInt16(i * 2, Endian.little).abs();
    if (sample > maxAmp) {
      maxAmp = sample;
    }
    sum += sample;
  }
  final mav = sum ~/ numSamples;
  return maxAmp < maxThreshold && mav < mavThreshold;
}

/// 按段序合并识别文本：清洗 ASR 标记与幻觉，去掉空白段，段间换行分隔。
String mergeSegmentTexts(List<String> texts) => texts
    .map((t) => cleanAsrText(t).trim())
    .where((t) => t.isNotEmpty)
    .join('\n');
/// 体积超限的提示文案。
String sizeLimitMessage(int rawBytes) {
  final mb = base64LengthFor(rawBytes) / (1024 * 1024);
  return '音频数据过大（Base64 后约 ${mb.toStringAsFixed(1)} MB，上限 10 MB），请裁剪或压缩后重试';
}

/// 时长超限的提示文案。
String durationLimitMessage(Duration duration,
    {Duration limit = maxConvertibleDuration}) {
  return '音频时长约 ${_durationText(duration)}，超过上限 ${_durationText(limit)}，请裁剪后重试';
}

/// 某一段重试后仍失败的提示文案（[index] 从 1 开始）。
String segmentFailureMessage(int index, int total, Object error) =>
    '第 $index/$total 段识别失败：$error';

String _durationText(Duration d) {
  if (d.inSeconds % 3600 == 0 && d.inHours > 0) return '${d.inHours} 小时';
  if (d.inSeconds % 60 == 0 && d.inMinutes > 0 && d.inMinutes < 60) {
    return '${d.inMinutes} 分钟';
  }
  return '${(d.inSeconds / 60).toStringAsFixed(1)} 分钟';
}

/// 解码失败的提示文案。
String decodeFailureMessage(Object error) =>
    '音频解码失败：$error。可先转换为标准 WAV / MP3 后重试';

bool _asciiAt(Uint8List bytes, int offset, String tag) {
  if (bytes.length < offset + tag.length) return false;
  for (var i = 0; i < tag.length; i++) {
    if (bytes[offset + i] != tag.codeUnitAt(i)) return false;
  }
  return true;
}

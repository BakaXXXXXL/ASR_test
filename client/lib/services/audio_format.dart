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

/// 分段转写：每段目标时长（秒）。
const int segmentSeconds = 60;

/// 分段转写：最大段数（约等于 [maxSegmentedDuration] / [segmentSeconds] 再多留一点余量）。
const int maxSegmentCount = 125;

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

/// 按段序合并识别文本：去掉空白段，段间换行分隔。
String mergeSegmentTexts(List<String> texts) => texts
    .map((t) => t.trim())
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

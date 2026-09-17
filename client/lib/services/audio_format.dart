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

/// 转码后可上传的最长时长。
const Duration maxConvertibleDuration = Duration(seconds: maxConvertibleSeconds);

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

/// 体积超限的提示文案。
String sizeLimitMessage(int rawBytes) {
  final mb = base64LengthFor(rawBytes) / (1024 * 1024);
  return '音频数据过大（Base64 后约 ${mb.toStringAsFixed(1)} MB，上限 10 MB），请裁剪或压缩后重试';
}

/// 时长超限的提示文案。
String durationLimitMessage(Duration duration) {
  final minutes = duration.inSeconds / 60;
  return '音频时长约 ${minutes.toStringAsFixed(1)} 分钟，超过上限'
      '（M4A 转 ${wavSampleRate ~/ 1000}kHz 单声道 WAV 后约 '
      '${maxConvertibleSeconds ~/ 60} 分钟以内），请裁剪后重试';
}

/// 解码失败的提示文案。
String decodeFailureMessage(Object error) =>
    'M4A 解码失败：$error。可先转换为 WAV / MP3 后重试';

bool _asciiAt(Uint8List bytes, int offset, String tag) {
  if (bytes.length < offset + tag.length) return false;
  for (var i = 0; i < tag.length; i++) {
    if (bytes[offset + i] != tag.codeUnitAt(i)) return false;
  }
  return true;
}

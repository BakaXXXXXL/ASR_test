import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../config.dart';
import 'audio_converter.dart';
import 'audio_format.dart';
import 'audio_segment_transcriber.dart';

/// 识别流程阶段，供 UI 展示进度文案。
enum AudioStage {
  /// 正在本地转码成 16kHz 单声道 WAV。
  converting,

  /// 正在上传并等待识别结果。
  uploading,

  /// 长录音正在分段并行转写（配合 [transcribe] 的 onProgress）。
  segmentTranscribing,
}

class TranscribeResult {
  final String text;
  final String? language;

  TranscribeResult({required this.text, this.language});

  factory TranscribeResult.fromJson(Map<String, dynamic> json) {
    final choices = json['choices'] as List<dynamic>?;
    String text = '';
    if (choices != null && choices.isNotEmpty) {
      final message = choices[0]['message'];
      if (message != null) {
        final content = message['content'];
        if (content is String) {
          text = content;
        } else if (content is List) {
          text = content
              .where((c) => c['type'] == 'text')
              .map((c) => c['text'])
              .join();
        }
      }
    }
    return TranscribeResult(text: text);
  }
}

class AsrService {
  final AppConfig config;
  final AudioConverter _converter = AudioConverter();
  late final Dio _dio;

  AsrService(this.config) {
    _dio = Dio(BaseOptions(
      baseUrl: config.baseUrl,
      connectTimeout: const Duration(seconds: 30),
      receiveTimeout: const Duration(minutes: 5),
      headers: {
        'Authorization': 'Bearer ${config.apiKey}',
        'Content-Type': 'application/json',
      },
    ));
  }

  /// 释放底层 HTTP 连接。重建服务前必须调用，否则旧 Dio 泄漏。
  void dispose() => _dio.close(force: true);

  /// 把 [file] 转成文字。
  ///
  /// 格式以文件头为准。单次可上传（Base64 后 ≤10 MB）的音频直接一个
  /// 请求识别；超出上限的长录音先归一化转码成 16kHz 单声道 WAV，
  /// 再切成 60 秒段并行转写（≤2 小时），按序合并结果。
  /// 格式无法识别、体积/时长超限、解码失败都会抛出
  /// [AudioInputException]（文案可直接展示）。
  Future<TranscribeResult> transcribe(
    File file, {
    String language = 'auto',
    void Function(AudioStage stage)? onStage,
    void Function(int done, int total)? onProgress,
  }) async {
    final fileSize = await file.length();
    final format = await _detectFormat(file);
    if (format == null) {
      throw const AudioInputException(unsupportedFormatMessage);
    }

    if (!needsConversion(format) && fitsBase64Limit(fileSize)) {
      final bytes = await file.readAsBytes();
      if (!fitsBase64Limit(bytes.length)) {
        throw AudioInputException(sizeLimitMessage(bytes.length));
      }
      return _post(bytes, uploadFormatFor(format), language, onStage: onStage);
    }

    onStage?.call(AudioStage.converting);
    final converted =
        await _converter.toWav(file, maxDuration: maxSegmentedDuration);
    try {
      final convertedSize = await converted.length();
      if (fitsBase64Limit(convertedSize)) {
        final bytes = await converted.readAsBytes();
        return await _post(bytes, AudioFormat.wav, language, onStage: onStage);
      }

      onStage?.call(AudioStage.segmentTranscribing);
      final text = await transcribeSegmented(
        converted,
        requestOne: (wavBytes, token) => _post(
          wavBytes,
          AudioFormat.wav,
          language,
          cancelToken: token,
        ),
        onProgress: onProgress,
      );
      return TranscribeResult(text: text);
    } finally {
      await _converter.cleanup(converted);
    }
  }

  Future<TranscribeResult> _post(
    Uint8List bytes,
    AudioFormat format,
    String language, {
    void Function(AudioStage stage)? onStage,
    CancelToken? cancelToken,
  }) async {
    final dataUrl =
        'data:${mimeTypeOf(format)};base64,${base64Encode(bytes)}';

    final body = {
      'model': 'mimo-v2.5-asr',
      'messages': [
        {
          'role': 'user',
          'content': [
            {
              'type': 'input_audio',
              'input_audio': {'data': dataUrl},
            }
          ],
        }
      ],
      'extra_body': {
        'asr_options': {'language': language}
      },
    };

    onStage?.call(AudioStage.uploading);
    final response = await _dio.post('/chat/completions',
        data: body, cancelToken: cancelToken);
    return TranscribeResult.fromJson(response.data);
  }

  /// 只读文件头识别真实格式（扩展名不可信，也不必把整个文件读进内存）。
  Future<AudioFormat?> _detectFormat(File file) async {
    try {
      final raf = await file.open();
      try {
        final length = await raf.length();
        final head = await raf.read(length < 12 ? length : 12);
        return detectAudioFormat(head);
      } finally {
        await raf.close();
      }
    } catch (_) {
      return null;
    }
  }
}

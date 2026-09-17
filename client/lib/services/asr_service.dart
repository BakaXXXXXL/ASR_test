import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../config.dart';
import 'audio_converter.dart';
import 'audio_format.dart';

/// 识别流程阶段，供 UI 展示进度文案。
enum AudioStage {
  /// m4a 正在本地转码成 WAV。
  converting,

  /// 正在上传并等待识别结果。
  uploading,
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

  /// 把 [file] 转成文字。
  ///
  /// 格式以文件头为准：wav / mp3 直接上传，m4a 先本地转码成
  /// 16 kHz 单声道 WAV 再上传。格式无法识别、体积或时长超限、
  /// 解码失败都会抛出 [AudioInputException]（文案可直接展示），
  /// 这些情况下不会发起网络请求。
  Future<TranscribeResult> transcribe(
    File file, {
    String language = 'auto',
    void Function(AudioStage stage)? onStage,
  }) async {
    var bytes = await file.readAsBytes();
    final format = detectAudioFormat(bytes);
    if (format == null) {
      throw const AudioInputException(unsupportedFormatMessage);
    }

    File? converted;
    if (needsConversion(format)) {
      onStage?.call(AudioStage.converting);
      converted = await _converter.toWav(file);
      bytes = await converted.readAsBytes();
    }

    try {
      if (!fitsBase64Limit(bytes.length)) {
        throw AudioInputException(sizeLimitMessage(bytes.length));
      }

      final dataUrl =
          'data:${mimeTypeOf(uploadFormatFor(format))};base64,${base64Encode(bytes)}';

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
      final response = await _dio.post('/chat/completions', data: body);
      return TranscribeResult.fromJson(response.data);
    } finally {
      if (converted != null) {
        await _converter.cleanup(converted);
      }
    }
  }
}

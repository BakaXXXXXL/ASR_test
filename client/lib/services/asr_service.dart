import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../config.dart';

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
              .where((c) => c['type' ] == 'text')
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

  Future<TranscribeResult> transcribe(
    File file, {
    String language = 'auto',
  }) async {
    final bytes = await file.readAsBytes();
    if (bytes.length > 10 * 1024 * 1024) {
      throw Exception('文件过大（Base64 编码后不能超过 10MB）');
    }

    final suffix = file.path.split('.').last.toLowerCase();
    String mimeType;
    if (suffix == 'wav') {
      mimeType = 'audio/wav';
    } else if (suffix == 'mp3') {
      mimeType = 'audio/mpeg';
    } else {
      throw Exception('仅支持 wav 和 mp3 格式');
    }

    final base64Audio = base64Encode(bytes);
    final dataUrl = 'data:$mimeType;base64,$base64Audio';

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

    final response = await _dio.post('/chat/completions', data: body);
    return TranscribeResult.fromJson(response.data);
  }
}

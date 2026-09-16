import 'dart:io';

import 'package:dio/dio.dart';

import '../config.dart';

class TranscribeResult {
  final String text;
  final double duration;
  final String? language;

  TranscribeResult({
    required this.text,
    required this.duration,
    this.language,
  });

  factory TranscribeResult.fromJson(Map<String, dynamic> json) {
    return TranscribeResult(
      text: json['text'] as String,
      duration: (json['duration'] as num).toDouble(),
      language: json['language'] as String?,
    );
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
    ));
  }

  Future<bool> checkHealth() async {
    try {
      final response = await _dio.get('/health');
      return response.statusCode == 200 &&
          response.data['model_loaded'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<TranscribeResult> transcribe(
    File file, {
    String language = 'auto',
  }) async {
    final fileName = file.path.split(Platform.pathSeparator).last;
    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(
        file.path,
        filename: fileName,
      ),
      'language': language,
    });

    final headers = <String, String>{};
    if (config.apiKey.isNotEmpty) {
      headers['X-API-Key'] = config.apiKey;
    }

    final response = await _dio.post(
      '/transcribe',
      data: formData,
      options: Options(headers: headers),
    );

    return TranscribeResult.fromJson(response.data);
  }
}

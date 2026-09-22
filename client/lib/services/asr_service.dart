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

/// 分段断点容灾会话，保持未完成分段的现场，允许一键重试失败段。
class TranscribeSession {
  final File wavFile;
  final List<AudioSegment> plan;
  final List<String?> texts;
  List<int> failedIndices;
  final String language;
  final int concurrency;
  final Map<int, Object> errors;

  TranscribeSession({
    required this.wavFile,
    required this.plan,
    required this.texts,
    required this.failedIndices,
    required this.language,
    required this.concurrency,
    Map<int, Object>? errors,
  }) : errors = errors ?? <int, Object>{};

  int get totalCount => plan.length;
  int get successCount => totalCount - failedIndices.length;
  bool get isAllSuccessful => failedIndices.isEmpty;
  String get failedSegmentsDisplay =>
      failedIndices.map((i) => (i + 1).toString()).join('、');
}

class TranscribeResult {
  final String text;
  final String? language;
  final bool isPartial;
  final List<int> failedIndices;
  final int totalSegments;
  final TranscribeSession? session;

  TranscribeResult({
    required this.text,
    this.language,
    this.isPartial = false,
    List<int>? failedIndices,
    int? totalSegments,
    this.session,
  })  : failedIndices = failedIndices ?? const [],
        totalSegments = totalSegments ?? (isPartial ? 1 : 1);

  int get successCount => totalSegments - failedIndices.length;
  String get failedSegmentsDisplay =>
      failedIndices.map((i) => (i + 1).toString()).join('、');

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
    return TranscribeResult(text: cleanAsrText(text));
  }
}

class AsrService {
  final AppConfig config;
  final AudioConverter _converter = AudioConverter();
  late final Dio _dio;
  TranscribeSession? _activeSession;

  TranscribeSession? get activeSession => _activeSession;

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

  /// 释放底层 HTTP 连接与未清理的会话临时文件。
  void dispose() {
    _dio.close(force: true);
    final session = _activeSession;
    _activeSession = null;
    if (session != null) {
      _converter.cleanup(session.wavFile);
    }
  }

  /// 清除当前活跃的容灾会话并删除临时 WAV 文件。
  Future<void> clearSession() async {
    final session = _activeSession;
    _activeSession = null;
    if (session != null) {
      await _converter.cleanup(session.wavFile);
    }
  }

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
    void Function(String message)? onStatusMessage,
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
    var keepConvertedFile = false;
    try {
      final convertedSize = await converted.length();
      if (fitsBase64Limit(convertedSize)) {
        final bytes = await converted.readAsBytes();
        return await _post(bytes, AudioFormat.wav, language, onStage: onStage);
      }

      onStage?.call(AudioStage.segmentTranscribing);
      final segResult = await transcribeSegmented(
        converted,
        concurrency: config.concurrency,
        requestOne: (wavBytes, token) => _post(
          wavBytes,
          AudioFormat.wav,
          language,
          cancelToken: token,
        ),
        onProgress: onProgress,
        onStatusMessage: onStatusMessage,
      );

      // 全部失败：不保留现场，抛出异常告知用户根本原因
      if (segResult.totalCount > 0 && segResult.successCount == 0) {
        final firstErr = segResult.errors.values.firstOrNull;
        if (firstErr is DioException) {
          throw firstErr;
        } else if (firstErr != null) {
          throw AudioInputException(firstErr.toString());
        } else {
          throw const AudioInputException('分段转写全部失败');
        }
      }

      // 全部成功：清理文件，置空会话
      if (segResult.isAllSuccessful) {
        await clearSession();
        return TranscribeResult(
          text: segResult.fullText,
          isPartial: false,
          totalSegments: segResult.totalCount,
        );
      }

      // 部分成功：保留临时文件，建立容灾会话
      keepConvertedFile = true;
      if (_activeSession != null &&
          _activeSession!.wavFile.path != converted.path) {
        await _converter.cleanup(_activeSession!.wavFile);
      }

      _activeSession = TranscribeSession(
        wavFile: converted,
        plan: segResult.plan,
        texts: segResult.segmentTexts,
        failedIndices: segResult.failedIndices,
        language: language,
        concurrency: config.concurrency,
        errors: segResult.errors,
      );

      return TranscribeResult(
        text: segResult.fullText,
        isPartial: true,
        failedIndices: segResult.failedIndices,
        totalSegments: segResult.totalCount,
        session: _activeSession,
      );
    } finally {
      if (!keepConvertedFile) {
        await _converter.cleanup(converted);
      }
    }
  }

  /// 对当前活跃会话中的失败分段进行独立重试。
  Future<TranscribeResult> retryFailedSegments({
    void Function(int done, int total)? onProgress,
    void Function(String message)? onStatusMessage,
  }) async {
    final session = _activeSession;
    if (session == null || session.isAllSuccessful) {
      throw StateError('没有可重试的分段转写会话');
    }

    final segResult = await transcribeSegmented(
      session.wavFile,
      concurrency: 1, // 单路串行以避免再次限流
      targetIndices: session.failedIndices,
      existingPlan: session.plan,
      existingTexts: session.texts,
      requestOne: (wavBytes, token) => _post(
        wavBytes,
        AudioFormat.wav,
        session.language,
        cancelToken: token,
      ),
      onProgress: onProgress,
      onStatusMessage: onStatusMessage,
    );

    session.failedIndices = segResult.failedIndices;
    session.errors
      ..clear()
      ..addAll(segResult.errors);
    for (var i = 0; i < segResult.totalCount; i++) {
      if (segResult.segmentTexts[i] != null) {
        session.texts[i] = segResult.segmentTexts[i];
      }
    }

    if (session.isAllSuccessful) {
      await _converter.cleanup(session.wavFile);
      _activeSession = null;
      return TranscribeResult(
        text: segResult.fullText,
        isPartial: false,
        totalSegments: segResult.totalCount,
      );
    } else {
      return TranscribeResult(
        text: segResult.fullText,
        isPartial: true,
        failedIndices: session.failedIndices,
        totalSegments: session.totalCount,
        session: session,
      );
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

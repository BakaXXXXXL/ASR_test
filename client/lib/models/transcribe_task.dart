import 'dart:io';

import 'package:dio/dio.dart';

import '../services/asr_service.dart';
import '../services/audio_format.dart';

/// 任务生命周期状态
enum TaskStatus {
  idle, // 已添加，等待开始
  converting, // 本地 16kHz WAV 转码中
  transcribing, // API 转写中（单请求或分段并发）
  retrying, // 正在重试失败分段
  completed, // 全部成功转写完成
  failed, // 失败
  cancelled, // 用户主动取消
}

/// 单个音频文件的转写任务实体
class TranscribeTask {
  final String id;
  final File file;
  final String fileName;
  final int fileSize;
  final AudioFormat? format;
  final String language;

  TaskStatus status;
  AudioStage? stage;
  String? statusMessage;
  int segDone;
  int segTotal;
  String resultText;
  TranscribeResult? lastResult;
  String? errorMessage;
  bool isExpanded;
  CancelToken? cancelToken;

  TranscribeTask({
    required this.id,
    required this.file,
    required this.fileName,
    required this.fileSize,
    required this.format,
    this.language = 'auto',
    this.status = TaskStatus.idle,
    this.stage,
    this.statusMessage,
    this.segDone = 0,
    this.segTotal = 0,
    this.resultText = '',
    this.lastResult,
    this.errorMessage,
    this.isExpanded = false,
    this.cancelToken,
  });

  /// 任务整体进度比例 (0.0 ~ 1.0)
  double get progress {
    if (status == TaskStatus.completed) return 1.0;
    if (status == TaskStatus.idle || status == TaskStatus.cancelled) return 0.0;
    if (stage == AudioStage.converting) return 0.08;
    if (segTotal > 0) {
      return (segDone / segTotal).clamp(0.0, 1.0);
    }
    return status == TaskStatus.transcribing ? 0.35 : 0.0;
  }

  /// 状态描述文案（供 UI 标签展示）
  String get statusDisplay {
    if (status == TaskStatus.retrying) {
      return statusMessage ??
          (segTotal > 0
              ? '正在补转失败分段 $segDone/$segTotal 段...'
              : '正在补转失败分段...');
    }
    if (status == TaskStatus.completed) {
      if (lastResult?.isPartial ?? false) {
        return '部分完成 (有未识别段落)';
      }
      return '转写完成';
    }
    if (status == TaskStatus.failed) {
      return '转写失败';
    }
    if (status == TaskStatus.cancelled) {
      return '已取消';
    }
    if (status == TaskStatus.idle) {
      return '等待转写';
    }

    if (statusMessage != null && statusMessage!.isNotEmpty) {
      return statusMessage!;
    }

    return switch (stage) {
      AudioStage.converting => '正在转换音频为 16kHz WAV...',
      AudioStage.segmentTranscribing => segTotal > 0
          ? '正在分段转写 $segDone/$segTotal 段...'
          : '正在分段转写...',
      _ => '正在上传识别...',
    };
  }

  /// 格式化文件大小展示
  String get formattedSize {
    if (fileSize < 1024) return '$fileSize B';
    if (fileSize < 1024 * 1024) {
      return '${(fileSize / 1024).toStringAsFixed(1)} KB';
    }
    return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

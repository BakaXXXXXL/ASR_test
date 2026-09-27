import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config.dart';
import '../models/transcribe_task.dart';
import 'asr_service.dart';
import 'audio_format.dart';
import 'audio_segment_transcriber.dart';

/// 批量转写任务调度管理器
///
/// 统一管理多音频文件的生命周期、状态流转与单任务独立并发调度。
class BatchTranscribeManager extends ChangeNotifier {
  final AppConfig config;
  final Dio? _customDio;
  late AsrService _asrService;

  final List<TranscribeTask> _tasks = [];
  final Map<String, AsrService> _taskServices = {};
  bool _isDisposed = false;

  BatchTranscribeManager({
    required this.config,
    AsrService? asrService,
    Dio? dio,
  }) : _customDio = dio ?? asrService?.dio {
    _asrService = asrService ?? _createService();
  }

  /// 为任务创建独立的 AsrService 实例
  ///
  /// 每个任务拥有专属独立的限流协调器与并发 Worker，多任务同时转写时互不挤占最高 16 路并发额度。
  AsrService _createService() {
    return AsrService(
      config,
      dio: _customDio,
      sharedRateLimiter: RateLimitCoordinator(),
    );
  }

  List<TranscribeTask> get tasks => List.unmodifiable(_tasks);

  int get totalCount => _tasks.length;
  int get completedCount =>
      _tasks.where((t) => t.status == TaskStatus.completed).length;
  int get failedCount =>
      _tasks.where((t) => t.status == TaskStatus.failed).length;
  int get runningCount => _tasks
      .where((t) =>
          t.status == TaskStatus.converting ||
          t.status == TaskStatus.transcribing ||
          t.status == TaskStatus.retrying)
      .length;
  int get idleCount =>
      _tasks.where((t) => t.status == TaskStatus.idle).length;

  bool get isProcessing => runningCount > 0;

  double get overallProgress {
    if (_tasks.isEmpty) return 0.0;
    var sum = 0.0;
    for (final task in _tasks) {
      sum += task.progress;
    }
    return (sum / _tasks.length).clamp(0.0, 1.0);
  }

  /// 动态更新配置（例如在设置中修改了并发数或 API Key）
  void updateConfig() {
    _asrService.dispose();
    _asrService = _createService();
    notifyListeners();
  }

  /// 添加一批音频文件到任务队列
  Future<void> addFiles(List<File> files) async {
    for (final file in files) {
      // 避免重复添加相同路径且未完成的文件
      final exists = _tasks.any((t) =>
          t.file.path == file.path && t.status != TaskStatus.completed);
      if (exists) continue;

      final name = file.uri.pathSegments.isNotEmpty
          ? file.uri.pathSegments.last
          : 'audio';
      final length = await file.length();
      final format = await _detectFormat(file);

      final task = TranscribeTask(
        id: '${DateTime.now().microsecondsSinceEpoch}_${_tasks.length}',
        file: file,
        fileName: name,
        fileSize: length,
        format: format,
        errorMessage: format == null ? unsupportedFormatMessage : null,
        status: format == null ? TaskStatus.failed : TaskStatus.idle,
      );
      _tasks.add(task);
    }
    notifyListeners();
  }

  /// 移除指定任务
  void removeTask(String id) {
    final idx = _tasks.indexWhere((t) => t.id == id);
    if (idx == -1) return;

    final task = _tasks[idx];
    if (task.status == TaskStatus.converting ||
        task.status == TaskStatus.transcribing ||
        task.status == TaskStatus.retrying) {
      cancelTask(id);
    }

    final service = _taskServices.remove(id);
    service?.dispose();

    _tasks.removeAt(idx);
    notifyListeners();
  }

  /// 清空已完成任务
  void clearCompleted() {
    final toRemove = _tasks.where((t) => t.status == TaskStatus.completed).map((t) => t.id).toList();
    for (final id in toRemove) {
      final service = _taskServices.remove(id);
      service?.dispose();
    }
    _tasks.removeWhere((t) => t.status == TaskStatus.completed);
    notifyListeners();
  }

  /// 清空全部任务
  void clearAll() {
    cancelAll();
    for (final service in _taskServices.values) {
      service.dispose();
    }
    _taskServices.clear();
    _tasks.clear();
    notifyListeners();
  }

  /// 切换任务折叠面板展开/收起
  void toggleExpand(String id) {
    final idx = _tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      _tasks[idx].isExpanded = !_tasks[idx].isExpanded;
      notifyListeners();
    }
  }

  /// 启动单个任务
  Future<void> startTask(String id) async {
    final idx = _tasks.indexWhere((t) => t.id == id);
    if (idx == -1) return;
    final task = _tasks[idx];

    if (task.format == null) {
      task.status = TaskStatus.failed;
      task.errorMessage = unsupportedFormatMessage;
      notifyListeners();
      return;
    }

    if (task.status == TaskStatus.converting ||
        task.status == TaskStatus.transcribing ||
        task.status == TaskStatus.retrying) {
      return; // 已经在运行中
    }

    task.status = TaskStatus.transcribing;
    task.errorMessage = null;
    task.resultText = '';
    task.lastResult = null;
    task.stage = null;
    task.statusMessage = null;
    task.segDone = 0;
    task.segTotal = 0;
    task.cancelToken = CancelToken();

    // 为每个任务分配专属 AsrService 实例，避免不同任务间 _activeSession 冲突
    _taskServices[id]?.dispose();
    final service = _createService();
    _taskServices[id] = service;

    notifyListeners();

    try {
      final res = await service.transcribe(
        task.file,
        language: task.language,
        cancelToken: task.cancelToken,
        onStage: (stage) {
          task.stage = stage;
          notifyListeners();
        },
        onProgress: (done, total) {
          task.segDone = done;
          task.segTotal = total;
          notifyListeners();
        },
        onStatusMessage: (msg) {
          task.statusMessage = msg;
          notifyListeners();
        },
      );

      task.resultText = res.text;
      task.lastResult = res;
      task.status = TaskStatus.completed;
      task.stage = null;
      task.statusMessage = null;
      notifyListeners();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        task.status = TaskStatus.cancelled;
        task.statusMessage = '已取消';
      } else {
        task.status = TaskStatus.failed;
        task.errorMessage = _extractDioError(e);
      }
      task.stage = null;
      notifyListeners();
    } catch (e) {
      task.status = TaskStatus.failed;
      task.errorMessage = e.toString();
      task.stage = null;
      notifyListeners();
    }
  }

  /// 重试单个任务中的失败分段
  Future<void> retryFailedSegments(String id) async {
    final idx = _tasks.indexWhere((t) => t.id == id);
    if (idx == -1) return;
    final task = _tasks[idx];

    final service = _taskServices[id];
    if (service == null ||
        task.lastResult == null ||
        !task.lastResult!.isPartial) {
      return;
    }

    task.status = TaskStatus.retrying;
    task.errorMessage = null;
    task.statusMessage = '正在自动补转失败分段...';
    task.segDone = 0;
    task.segTotal = task.lastResult!.failedIndices.length;
    task.cancelToken = CancelToken();
    notifyListeners();

    try {
      final res = await service.retryFailedSegments(
        cancelToken: task.cancelToken,
        onProgress: (done, total) {
          task.segDone = done;
          task.segTotal = total;
          notifyListeners();
        },
        onStatusMessage: (msg) {
          task.statusMessage = msg;
          notifyListeners();
        },
      );

      task.resultText = res.text;
      task.lastResult = res;
      task.status = TaskStatus.completed;
      task.statusMessage = null;
      notifyListeners();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        task.status = TaskStatus.cancelled;
      } else {
        task.status = TaskStatus.failed;
        task.errorMessage = '补转失败: ${_extractDioError(e)}';
      }
      notifyListeners();
    } catch (e) {
      task.status = TaskStatus.failed;
      task.errorMessage = '补转失败: $e';
      notifyListeners();
    }
  }

  /// 取消单个任务
  void cancelTask(String id) {
    final idx = _tasks.indexWhere((t) => t.id == id);
    if (idx == -1) return;
    final task = _tasks[idx];

    task.cancelToken?.cancel('用户取消');
    task.status = TaskStatus.cancelled;
    task.stage = null;
    task.statusMessage = '已取消';
    notifyListeners();
  }

  /// 一键启动所有等待中、失败或被取消的任务
  Future<void> startAllPending() async {
    final pending = _tasks.where((t) =>
        t.status == TaskStatus.idle ||
        t.status == TaskStatus.failed ||
        t.status == TaskStatus.cancelled).toList();

    if (pending.isEmpty) return;

    // 所有待启动任务并发发起（全局网络请求将由 _semaphore 严格限流调度）
    await Future.wait(pending.map((t) => startTask(t.id)));
  }

  /// 一键取消所有进行中的任务
  void cancelAll() {
    for (final task in _tasks) {
      if (task.status == TaskStatus.converting ||
          task.status == TaskStatus.transcribing ||
          task.status == TaskStatus.retrying) {
        task.cancelToken?.cancel('用户批量取消');
        task.status = TaskStatus.cancelled;
        task.stage = null;
        task.statusMessage = '已取消';
      }
    }
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_isDisposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    cancelAll();
    _asrService.dispose();
    for (final service in _taskServices.values) {
      service.dispose();
    }
    _taskServices.clear();
    super.dispose();
  }

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

  String _extractDioError(DioException e) {
    try {
      return e.response?.data?['error']?['message']?.toString() ??
          e.response?.data?['detail']?.toString() ??
          e.message ??
          '请求失败';
    } catch (_) {
      return e.message ?? '请求失败';
    }
  }
}

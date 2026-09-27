import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../../config.dart';
import '../../models/transcribe_task.dart';
import '../../services/audio_format.dart';
import '../../services/batch_export_helper.dart';
import '../../services/batch_transcribe_manager.dart';
import 'fluent_settings_dialog.dart';

class FluentHomeScreen extends StatefulWidget {
  final AppConfig config;

  const FluentHomeScreen({super.key, required this.config});

  @override
  State<FluentHomeScreen> createState() => _FluentHomeScreenState();
}

class _FluentHomeScreenState extends State<FluentHomeScreen> {
  late final BatchTranscribeManager _manager;

  @override
  void initState() {
    super.initState();
    _manager = BatchTranscribeManager(config: widget.config);
    _manager.addListener(_onManagerUpdate);
  }

  void _onManagerUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _manager.removeListener(_onManagerUpdate);
    _manager.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: pickedExtensions,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;

    final files = <File>[];
    for (final f in result.files) {
      if (f.path != null) {
        files.add(File(f.path!));
      }
    }
    if (files.isNotEmpty) {
      await _manager.addFiles(files);
    }
  }

  void _openSettings() {
    showFluentSettingsDialog(
      context,
      config: widget.config,
      onSaved: () {
        _manager.updateConfig();
        setState(() {});
      },
    );
  }

  void _copyTaskText(TranscribeTask task) {
    if (task.resultText.isEmpty) return;
    Clipboard.setData(ClipboardData(text: task.resultText));
    displayInfoBar(
      context,
      builder: (context, close) => InfoBar(
        title: const Text('已复制'),
        content: Text('已将 "${task.fileName}" 的识别结果复制到剪贴板'),
        severity: InfoBarSeverity.success,
        onClose: close,
      ),
    );
  }

  Future<void> _exportSingle(TranscribeTask task) async {
    try {
      final file = await BatchExportHelper.exportSingleTask(task);
      if (file != null && mounted) {
        displayInfoBar(
          context,
          builder: (context, close) => InfoBar(
            title: const Text('导出成功'),
            content: Text('已保存至: ${file.path}'),
            severity: InfoBarSeverity.success,
            onClose: close,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        displayInfoBar(
          context,
          builder: (context, close) => InfoBar(
            title: const Text('导出失败'),
            content: Text(e.toString()),
            severity: InfoBarSeverity.error,
            onClose: close,
          ),
        );
      }
    }
  }

  Future<void> _batchExportFiles() async {
    try {
      final res = await BatchExportHelper.exportCompletedToDirectory(_manager.tasks);
      if (res != null && mounted) {
        displayInfoBar(
          context,
          builder: (context, close) => InfoBar(
            title: const Text('批量导出成功'),
            content: Text('共导出 ${res.count} 个文件至: ${res.directory}'),
            severity: InfoBarSeverity.success,
            onClose: close,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        displayInfoBar(
          context,
          builder: (context, close) => InfoBar(
            title: const Text('批量导出失败'),
            content: Text(e.toString()),
            severity: InfoBarSeverity.error,
            onClose: close,
          ),
        );
      }
    }
  }

  Future<void> _batchExportMerged() async {
    try {
      final file = await BatchExportHelper.exportMergedToSingleFile(_manager.tasks);
      if (file != null && mounted) {
        displayInfoBar(
          context,
          builder: (context, close) => InfoBar(
            title: const Text('合并导出成功'),
            content: Text('已生成汇总文件: ${file.path}'),
            severity: InfoBarSeverity.success,
            onClose: close,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        displayInfoBar(
          context,
          builder: (context, close) => InfoBar(
            title: const Text('合并导出失败'),
            content: Text(e.toString()),
            severity: InfoBarSeverity.error,
            onClose: close,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);

    return ScaffoldPage(
      header: _buildHeader(theme),
      content: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildToolbar(theme),
            const SizedBox(height: 12),
            if (_manager.tasks.isNotEmpty) ...[
              _buildOverallProgressBar(theme),
              const SizedBox(height: 12),
            ],
            Expanded(
              child: _manager.tasks.isEmpty
                  ? _buildEmptyUploadArea(theme)
                  : _buildTaskCardList(theme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(FluentThemeData theme) {
    final hasKey = widget.config.isConfigured;

    return PageHeader(
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: theme.accentColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              FluentIcons.speech,
              color: theme.accentColor,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          const Text(
            'ASR 语音转文字',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 10),
          // 服务商徽章
          GestureDetector(
            onTap: _openSettings,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: theme.accentColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: theme.accentColor.withValues(alpha: 0.35),
                  width: 0.8,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    FluentIcons.server,
                    size: 11,
                    color: theme.accentColor,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    widget.config.badgeText,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: theme.accentColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Spacer(),
          // 设置按钮
          Tooltip(
            message: hasKey ? '服务商与并发设置' : '请先配置 API Key',
            child: Button(
              onPressed: _openSettings,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    FluentIcons.settings,
                    size: 14,
                    color: hasKey ? null : Colors.warningPrimaryColor,
                  ),
                  const SizedBox(width: 6),
                  Text(hasKey ? '设置' : '配置 Key'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(FluentThemeData theme) {
    final hasTasks = _manager.tasks.isNotEmpty;
    final hasCompleted = _manager.completedCount > 0;
    final canStart = _manager.tasks.any((t) =>
        t.status == TaskStatus.idle ||
        t.status == TaskStatus.failed ||
        t.status == TaskStatus.cancelled);
    final isProcessing = _manager.isProcessing;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.resources.surfaceStrokeColorDefault),
      ),
      child: Row(
        children: [
          FilledButton(
            onPressed: _pickFiles,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(FluentIcons.add, size: 13),
                SizedBox(width: 6),
                Text('添加音频 (支持多选)'),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Button(
            onPressed: canStart ? () => _manager.startAllPending() : null,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(FluentIcons.play, size: 12),
                SizedBox(width: 6),
                Text('全部开始'),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Button(
            onPressed: isProcessing ? () => _manager.cancelAll() : null,
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(FluentIcons.stop, size: 12),
                SizedBox(width: 6),
                Text('全部停止'),
              ],
            ),
          ),
          const Spacer(),
          if (hasCompleted) ...[
            DropDownButton(
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(FluentIcons.download, size: 12),
                  const SizedBox(width: 6),
                  Text('批量导出 (${_manager.completedCount})'),
                ],
              ),
              items: [
                MenuFlyoutItem(
                  leading: const Icon(FluentIcons.folder_horizontal, size: 14),
                  text: const Text('分别导出各文件 .txt'),
                  onPressed: _batchExportFiles,
                ),
                MenuFlyoutItem(
                  leading: const Icon(FluentIcons.page, size: 14),
                  text: const Text('合并为单个总 .txt'),
                  onPressed: _batchExportMerged,
                ),
              ],
            ),
            const SizedBox(width: 8),
          ],
          if (hasTasks)
            Button(
              onPressed: () => _manager.clearCompleted(),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(FluentIcons.clear, size: 12),
                  SizedBox(width: 6),
                  Text('清理已完成'),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildOverallProgressBar(FluentThemeData theme) {
    final total = _manager.totalCount;
    final done = _manager.completedCount;
    final running = _manager.runningCount;
    final percent = (total > 0 ? (done / total * 100) : 0).toStringAsFixed(0);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.resources.surfaceStrokeColorDefault),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '总进度: $done / $total 个文件完成 ($percent%)',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (running > 0) ...[
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: ProgressRing(strokeWidth: 2),
                ),
                const SizedBox(width: 6),
                Text(
                  '正在转写 $running 个任务 (每任务独立最高 ${widget.config.concurrency} 路并发)',
                  style: TextStyle(fontSize: 11, color: theme.accentColor),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          ProgressBar(value: _manager.overallProgress * 100),
        ],
      ),
    );
  }

  Widget _buildEmptyUploadArea(FluentThemeData theme) {
    return Center(
      child: GestureDetector(
        onTap: _pickFiles,
        child: Container(
          width: 520,
          padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 36),
          decoration: BoxDecoration(
            color: theme.cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.resources.surfaceStrokeColorDefault,
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: theme.accentColor.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  FluentIcons.cloud_upload,
                  size: 32,
                  color: theme.accentColor,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '点击添加或批量导入音频文件',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                '支持 WAV、MP3、M4A • 支持多文件同时排队并发 • 最长 2 小时智能切片',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.resources.textFillColorSecondary,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _pickFiles,
                child: const Text('选择音频文件'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTaskCardList(FluentThemeData theme) {
    return ListView.separated(
      itemCount: _manager.tasks.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final task = _manager.tasks[index];
        return _buildTaskCard(task, theme);
      },
    );
  }

  Widget _buildTaskCard(TranscribeTask task, FluentThemeData theme) {
    final isRunning = task.status == TaskStatus.converting ||
        task.status == TaskStatus.transcribing ||
        task.status == TaskStatus.retrying;
    final isCompleted = task.status == TaskStatus.completed;
    final isFailed = task.status == TaskStatus.failed;
    final hasPartial = task.lastResult?.isPartial ?? false;

    return Card(
      padding: const EdgeInsets.all(12),
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 头部行：图标、名称、大小、状态、快捷操作
          Row(
            children: [
              _buildFormatBadge(task.format, theme),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      task.fileName,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          task.formattedSize,
                          style: TextStyle(
                            fontSize: 11,
                            color: theme.resources.textFillColorSecondary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          task.statusDisplay,
                          style: TextStyle(
                            fontSize: 11,
                            color: isFailed
                                ? Colors.errorPrimaryColor
                                : (isRunning
                                    ? theme.accentColor
                                    : (isCompleted
                                        ? Colors.successPrimaryColor
                                        : theme.resources.textFillColorSecondary)),
                            fontWeight: isRunning ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (isRunning) ...[
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: ProgressRing(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(FluentIcons.stop, size: 14),
                  onPressed: () => _manager.cancelTask(task.id),
                ),
              ] else if (isFailed || task.status == TaskStatus.idle || task.status == TaskStatus.cancelled) ...[
                IconButton(
                  icon: Icon(
                    FluentIcons.play,
                    size: 14,
                    color: theme.accentColor,
                  ),
                  onPressed: () => _manager.startTask(task.id),
                ),
              ],
              if (isCompleted && hasPartial) ...[
                Tooltip(
                  message: '重试失败分段',
                  child: IconButton(
                    icon: const Icon(FluentIcons.refresh, size: 14),
                    onPressed: () => _manager.retryFailedSegments(task.id),
                  ),
                ),
              ],
              IconButton(
                icon: Icon(
                  task.isExpanded ? FluentIcons.chevron_up : FluentIcons.chevron_down,
                  size: 12,
                ),
                onPressed: () => _manager.toggleExpand(task.id),
              ),
              IconButton(
                icon: const Icon(FluentIcons.delete, size: 13),
                onPressed: () => _manager.removeTask(task.id),
              ),
            ],
          ),

          // 进度条（运行中或部分完成时展示）
          if (isRunning) ...[
            const SizedBox(height: 8),
            ProgressBar(value: task.progress * 100),
          ],

          // 折叠详情内容
          if (task.isExpanded) ...[
            const SizedBox(height: 10),
            const Divider(),
            const SizedBox(height: 6),
            if (task.errorMessage != null) ...[
              InfoBar(
                title: const Text('错误详情'),
                content: Text(task.errorMessage!),
                severity: InfoBarSeverity.error,
              ),
              const SizedBox(height: 8),
            ],
            if (task.resultText.isNotEmpty) ...[
              Row(
                children: [
                  Text(
                    '转写结果 (${task.resultText.length} 字符)',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const Spacer(),
                  Button(
                    onPressed: () => _copyTaskText(task),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.copy, size: 12),
                        SizedBox(width: 4),
                        Text('复制'),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Button(
                    onPressed: () => _exportSingle(task),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(FluentIcons.save, size: 12),
                        SizedBox(width: 4),
                        Text('导出 .txt'),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 180),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.resources.cardBackgroundFillColorSecondary,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: theme.resources.surfaceStrokeColorDefault),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    task.resultText,
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ),
              ),
            ] else if (!isFailed) ...[
              Text(
                '暂无转写结果',
                style: TextStyle(
                  fontSize: 12,
                  color: theme.resources.textFillColorSecondary,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildFormatBadge(AudioFormat? format, FluentThemeData theme) {
    final label = switch (format) {
      AudioFormat.wav => 'WAV',
      AudioFormat.mp3 => 'MP3',
      AudioFormat.m4a => 'M4A',
      _ => '未知',
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: theme.accentColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: theme.accentColor,
        ),
      ),
    );
  }
}

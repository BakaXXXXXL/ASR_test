import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config.dart';
import '../../models/transcribe_task.dart';
import '../../services/audio_format.dart';
import '../../services/batch_export_helper.dart';
import '../../services/batch_transcribe_manager.dart';

class MaterialHomeScreen extends StatefulWidget {
  final AppConfig config;

  const MaterialHomeScreen({super.key, required this.config});

  @override
  State<MaterialHomeScreen> createState() => _MaterialHomeScreenState();
}

class _MaterialHomeScreenState extends State<MaterialHomeScreen> {
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

  void _copyTaskText(TranscribeTask task) {
    if (task.resultText.isEmpty) return;
    Clipboard.setData(ClipboardData(text: task.resultText));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已复制 "${task.fileName}" 的识别结果'),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  Future<void> _exportSingle(TranscribeTask task) async {
    try {
      final file = await BatchExportHelper.exportSingleTask(task);
      if (file != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已保存至: ${file.path}'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('导出失败: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _batchExportFiles() async {
    try {
      final res = await BatchExportHelper.exportCompletedToDirectory(_manager.tasks);
      if (res != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已批量导出 ${res.count} 个文件至: ${res.directory}'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('批量导出失败: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _batchExportMerged() async {
    try {
      final file = await BatchExportHelper.exportMergedToSingleFile(_manager.tasks);
      if (file != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已保存汇总至: ${file.path}'),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('合并导出失败: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  void _showSettings() {
    String selectedProvider = widget.config.provider;
    AsrProtocol selectedProtocol = widget.config.protocol;
    final urlCtrl = TextEditingController(text: widget.config.baseUrl);
    final modelCtrl = TextEditingController(text: widget.config.model);
    final keyCtrl = TextEditingController(text: widget.config.apiKey);
    bool obscure = true;
    int concurrency = widget.config.concurrency;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final currentPreset = asrPresets.firstWhere(
            (p) => p.id == selectedProvider,
            orElse: () => asrPresets.firstWhere((p) => p.id == 'custom'),
          );

          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.tune, size: 22),
                SizedBox(width: 8),
                Text('ASR 服务商与设置'),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: selectedProvider,
                      decoration: const InputDecoration(
                        labelText: '服务商预设',
                        prefixIcon: Icon(Icons.cloud_outlined, size: 20),
                      ),
                      items: asrPresets
                          .map((p) => DropdownMenuItem(
                                value: p.id,
                                child: Text(p.name),
                              ))
                          .toList(),
                      onChanged: (val) {
                        if (val == null) return;
                        setDialogState(() {
                          selectedProvider = val;
                          final preset = asrPresets.firstWhere((p) => p.id == val);
                          if (preset.id != 'custom') {
                            urlCtrl.text = preset.defaultBaseUrl;
                            modelCtrl.text = preset.defaultModel;
                            selectedProtocol = preset.protocol;
                          }
                        });
                      },
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<AsrProtocol>(
                      initialValue: selectedProtocol,
                      decoration: const InputDecoration(
                        labelText: '接口协议规范',
                        prefixIcon: Icon(Icons.swap_horiz, size: 20),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: AsrProtocol.audioTranscriptions,
                          child: Text('OpenAI Whisper 规范 (/audio/transcriptions)'),
                        ),
                        DropdownMenuItem(
                          value: AsrProtocol.chatCompletions,
                          child: Text('OpenAI Chat 规范 (/chat/completions)'),
                        ),
                      ],
                      onChanged: (val) {
                        if (val != null) {
                          setDialogState(() => selectedProtocol = val);
                        }
                      },
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: urlCtrl,
                      decoration: const InputDecoration(
                        labelText: '接口地址 (Base URL)',
                        hintText: 'https://api.example.com/v1',
                        prefixIcon: Icon(Icons.link, size: 20),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: modelCtrl,
                      decoration: const InputDecoration(
                        labelText: '模型名称 (Model)',
                        hintText: '如 mimo-v2.5-asr',
                        prefixIcon: Icon(Icons.model_training, size: 20),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: keyCtrl,
                      obscureText: obscure,
                      decoration: InputDecoration(
                        labelText: 'API Key',
                        hintText: currentPreset.apiKeyHint,
                        prefixIcon: const Icon(Icons.key, size: 20),
                        suffixIcon: IconButton(
                          icon: Icon(
                            obscure ? Icons.visibility_off : Icons.visibility,
                            size: 20,
                          ),
                          onPressed: () =>
                              setDialogState(() => obscure = !obscure),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        const Icon(Icons.speed, size: 20),
                        const SizedBox(width: 8),
                        Text('单任务分段并发: $concurrency 路'),
                      ],
                    ),
                    Slider(
                      value: concurrency.toDouble(),
                      min: AppConfig.minConcurrency.toDouble(),
                      max: AppConfig.maxConcurrency.toDouble(),
                      divisions: AppConfig.maxConcurrency - AppConfig.minConcurrency,
                      label: '$concurrency 路',
                      onChanged: (val) {
                        setDialogState(() => concurrency = val.round());
                      },
                    ),
                    Text(
                      '每个任务独立享有此并发上限，多文件同时转写互不挤占 (最高 16 路)',
                      style: TextStyle(
                        fontSize: 11,
                        color: Theme.of(ctx).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () async {
                  await widget.config.save(
                    provider: selectedProvider,
                    protocol: selectedProtocol,
                    baseUrl: urlCtrl.text.trim(),
                    model: modelCtrl.text.trim(),
                    apiKey: keyCtrl.text.trim(),
                    concurrency: concurrency,
                  );
                  _manager.updateConfig();
                  if (ctx.mounted) Navigator.pop(ctx);
                  setState(() {});
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isProcessing = _manager.isProcessing;
    final canStart = _manager.tasks.any((t) =>
        t.status == TaskStatus.idle ||
        t.status == TaskStatus.failed ||
        t.status == TaskStatus.cancelled);
    final hasCompleted = _manager.completedCount > 0;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('ASR 语音转文字', style: TextStyle(fontSize: 18)),
            Text(
              widget.config.badgeText,
              style: TextStyle(
                fontSize: 11,
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          if (hasCompleted)
            PopupMenuButton<String>(
              icon: const Icon(Icons.download),
              tooltip: '批量导出',
              onSelected: (val) {
                if (val == 'separate') {
                  _batchExportFiles();
                } else if (val == 'merged') {
                  _batchExportMerged();
                }
              },
              itemBuilder: (ctx) => [
                const PopupMenuItem(
                  value: 'separate',
                  child: Row(
                    children: [
                      Icon(Icons.folder_outlined, size: 18),
                      SizedBox(width: 8),
                      Text('分别导出各文件 .txt'),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'merged',
                  child: Row(
                    children: [
                      Icon(Icons.description_outlined, size: 18),
                      SizedBox(width: 8),
                      Text('合并为单个总 .txt'),
                    ],
                  ),
                ),
              ],
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '设置',
            onPressed: _showSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_manager.tasks.isNotEmpty) _buildProgressBar(theme),
          Expanded(
            child: _manager.tasks.isEmpty
                ? _buildEmptyView(theme)
                : _buildTaskList(theme),
          ),
        ],
      ),
      bottomNavigationBar: _manager.tasks.isNotEmpty
          ? BottomAppBar(
              child: Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickFiles,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('添加'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: canStart ? () => _manager.startAllPending() : null,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('全部开始'),
                  ),
                  const Spacer(),
                  if (isProcessing)
                    IconButton.filledTonal(
                      icon: const Icon(Icons.stop),
                      tooltip: '全部停止',
                      onPressed: () => _manager.cancelAll(),
                    )
                  else if (hasCompleted)
                    IconButton(
                      icon: const Icon(Icons.cleaning_services_outlined),
                      tooltip: '清空已完成',
                      onPressed: () => _manager.clearCompleted(),
                    ),
                ],
              ),
            )
          : null,
      floatingActionButton: _manager.tasks.isEmpty
          ? FloatingActionButton.extended(
              onPressed: _pickFiles,
              icon: const Icon(Icons.audio_file),
              label: const Text('添加音频文件'),
            )
          : null,
    );
  }

  Widget _buildProgressBar(ThemeData theme) {
    final total = _manager.totalCount;
    final done = _manager.completedCount;
    final running = _manager.runningCount;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                '总进度: $done / $total 完成',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              if (running > 0)
                Text(
                  '正在转写 $running 个任务 (每任务独立 ${widget.config.concurrency} 并发)',
                  style: TextStyle(fontSize: 11, color: theme.colorScheme.primary),
                ),
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: _manager.overallProgress),
        ],
      ),
    );
  }

  Widget _buildEmptyView(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.queue_music,
              size: 72,
              color: theme.colorScheme.primary.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            const Text(
              '批量转写队列为空',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '点击右下角按钮添加一个或多个音频文件\n支持 WAV / MP3 / M4A 格式，最长 2 小时',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTaskList(ThemeData theme) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _manager.tasks.length,
      itemBuilder: (ctx, index) {
        final task = _manager.tasks[index];
        final isRunning = task.status == TaskStatus.converting ||
            task.status == TaskStatus.transcribing ||
            task.status == TaskStatus.retrying;
        final isCompleted = task.status == TaskStatus.completed;
        final isFailed = task.status == TaskStatus.failed;
        final hasPartial = task.lastResult?.isPartial ?? false;

        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            key: Key(task.id),
            initiallyExpanded: task.isExpanded,
            onExpansionChanged: (expanded) {
              task.isExpanded = expanded;
            },
            leading: CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Text(
                task.format?.name.toUpperCase() ?? '?',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
            ),
            title: Text(
              task.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 2),
                Text(
                  '${task.formattedSize} • ${task.statusDisplay}',
                  style: TextStyle(
                    fontSize: 12,
                    color: isFailed
                        ? theme.colorScheme.error
                        : (isRunning
                            ? theme.colorScheme.primary
                            : (isCompleted
                                ? Colors.green
                                : theme.colorScheme.onSurfaceVariant)),
                  ),
                ),
                if (isRunning) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: task.progress),
                ],
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isRunning)
                  IconButton(
                    icon: const Icon(Icons.stop),
                    onPressed: () => _manager.cancelTask(task.id),
                  )
                else if (isFailed || task.status == TaskStatus.idle || task.status == TaskStatus.cancelled)
                  IconButton(
                    icon: const Icon(Icons.play_arrow),
                    onPressed: () => _manager.startTask(task.id),
                  ),
                if (isCompleted && hasPartial)
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: '重试失败分段',
                    onPressed: () => _manager.retryFailedSegments(task.id),
                  ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => _manager.removeTask(task.id),
                ),
              ],
            ),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (task.errorMessage != null) ...[
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          task.errorMessage!,
                          style: TextStyle(
                            color: theme.colorScheme.onErrorContainer,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (task.resultText.isNotEmpty) ...[
                      Row(
                        children: [
                          Text(
                            '识别结果 (${task.resultText.length} 字)',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: () => _copyTaskText(task),
                            icon: const Icon(Icons.copy, size: 16),
                            label: const Text('复制'),
                          ),
                          TextButton.icon(
                            onPressed: () => _exportSingle(task),
                            icon: const Icon(Icons.save_alt, size: 16),
                            label: const Text('导出'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Container(
                        constraints: const BoxConstraints(maxHeight: 180),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: SingleChildScrollView(
                          child: SelectableText(
                            task.resultText,
                            style: const TextStyle(fontSize: 13, height: 1.5),
                          ),
                        ),
                      ),
                    ] else if (!isFailed) ...[
                      const Text(
                        '暂无转写结果',
                        style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';

import '../../config.dart';
import '../../services/asr_service.dart';
import '../../services/audio_format.dart';
import 'fluent_settings_dialog.dart';

class FluentHomeScreen extends StatefulWidget {
  final AppConfig config;

  const FluentHomeScreen({super.key, required this.config});

  @override
  State<FluentHomeScreen> createState() => _FluentHomeScreenState();
}

class _FluentHomeScreenState extends State<FluentHomeScreen> {
  File? _selectedFile;
  String _fileName = '';
  int _fileSize = 0;
  String _language = 'auto';
  String _result = '';
  bool _loading = false;
  String? _error;
  AudioFormat? _format;
  AudioStage? _stage;
  int _segDone = 0;
  int _segTotal = 0;

  String get _stageLabel {
    if (!_loading) return '开始识别';
    return switch (_stage) {
      AudioStage.converting => '正在转换音频为 16kHz WAV...',
      AudioStage.segmentTranscribing => _segTotal > 0
          ? '正在分段转写 $_segDone/$_segTotal 段...'
          : '正在分段转写...',
      _ => '正在上传并识别...',
    };
  }

  late AsrService _asr;

  @override
  void initState() {
    super.initState();
    _asr = AsrService(widget.config);
  }

  @override
  void dispose() {
    _asr.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: pickedExtensions,
    );
    if (result == null || result.files.single.path == null) return;

    final file = File(result.files.single.path!);
    final format = await _detectFormat(file);
    if (!mounted) return;

    setState(() {
      _selectedFile = file;
      _fileName = result.files.single.name;
      _fileSize = result.files.single.size;
      _format = format;
      _error = format == null ? unsupportedFormatMessage : null;
      _result = '';
      _stage = null;
    });
  }

  Future<AudioFormat?> _detectFormat(File file) async {
    final raf = await file.open();
    try {
      final length = await raf.length();
      final head = await raf.read(length < 12 ? length : 12);
      return detectAudioFormat(head);
    } catch (_) {
      return null;
    } finally {
      await raf.close();
    }
  }

  Future<void> _transcribe() async {
    if (_selectedFile == null) return;

    setState(() {
      _loading = true;
      _error = null;
      _result = '';
      _stage = null;
      _segDone = 0;
      _segTotal = 0;
    });

    try {
      final res = await _asr.transcribe(
        _selectedFile!,
        language: _language,
        onStage: (stage) {
          if (mounted) setState(() => _stage = stage);
        },
        onProgress: (done, total) {
          if (mounted && (done != _segDone || total != _segTotal)) {
            setState(() {
              _segDone = done;
              _segTotal = total;
            });
          }
        },
      );
      if (mounted) {
        setState(() {
          _result = res.text;
          _loading = false;
          _stage = null;
        });
      }
    } on DioException catch (e) {
      if (mounted) {
        String msg;
        try {
          msg = e.response?.data?['error']?['message']?.toString() ??
              e.response?.data?['detail']?.toString() ??
              e.message ??
              '请求失败';
        } catch (_) {
          msg = e.message ?? '请求失败';
        }
        setState(() {
          _error = msg;
          _loading = false;
          _stage = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
          _stage = null;
        });
      }
    }
  }

  void _copyResult() {
    if (_result.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: _result));
      displayInfoBar(
        context,
        builder: (context, close) => InfoBar(
          title: const Text('已复制'),
          content: const Text('识别文本已复制到剪贴板'),
          severity: InfoBarSeverity.success,
          onClose: close,
        ),
      );
    }
  }

  Future<void> _exportTxt() async {
    if (_result.isEmpty) return;
    final savedPath = await FilePicker.platform.saveFile(
      dialogTitle: '导出识别结果为 TXT',
      fileName: _exportFileName(),
      bytes: utf8.encode(_result),
    );
    if (!mounted) return;
    if (savedPath != null) {
      displayInfoBar(
        context,
        builder: (context, close) => InfoBar(
          title: const Text('导出成功'),
          content: Text('已成功导出至 $savedPath'),
          severity: InfoBarSeverity.success,
          onClose: close,
        ),
      );
    }
  }

  String _exportFileName() {
    final dot = _fileName.lastIndexOf('.');
    final base = dot > 0 ? _fileName.substring(0, dot) : 'transcript';
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final ts = '${now.year}${two(now.month)}${two(now.day)}'
        '_${two(now.hour)}${two(now.minute)}${two(now.second)}';
    return '${base}_$ts.txt';
  }

  void _openSettings() {
    showFluentSettingsDialog(
      context,
      config: widget.config,
      onSaved: () {
        _asr.dispose();
        _asr = AsrService(widget.config);
        setState(() {});
      },
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final hasKey = widget.config.apiKey.isNotEmpty;

    return ScaffoldPage.scrollable(
      header: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          border: Border(
            bottom: BorderSide(
              color: theme.resources.dividerStrokeColorDefault,
              width: 1.0,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(FluentIcons.mic_on, color: theme.accentColor, size: 24),
            const SizedBox(width: 10),
            Text(
              'ASR 语音转文字',
              style: theme.typography.title?.copyWith(
                fontWeight: FontWeight.w600,
                fontSize: 18,
              ),
            ),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.accentColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'MiMo-V2.5',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: theme.accentColor,
                ),
              ),
            ),
            const Spacer(),
            // Key status pill
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: hasKey
                    ? Colors.green.withValues(alpha: 0.12)
                    : Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: hasKey
                      ? Colors.green.withValues(alpha: 0.3)
                      : Colors.orange.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    hasKey ? FluentIcons.check_mark : FluentIcons.warning,
                    size: 12,
                    color: hasKey ? Colors.green : Colors.orange,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    hasKey ? '已就绪' : '未配置 Key',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: hasKey ? Colors.green : Colors.orange,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(FluentIcons.settings, size: 16),
              onPressed: _openSettings,
            ),
          ],
        ),
      ),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 16),

                // Audio File Selection Card
                HoverButton(
                  onPressed: _loading ? null : _pickFile,
                  builder: (context, states) {
                    final isHovered = states.isHovering;
                    return Card(
                      padding: const EdgeInsets.symmetric(
                          vertical: 32, horizontal: 24),
                      borderColor: _selectedFile != null
                          ? theme.accentColor.withValues(alpha: 0.5)
                          : isHovered
                              ? theme.accentColor.withValues(alpha: 0.3)
                              : null,
                      backgroundColor: _selectedFile != null
                          ? theme.accentColor.withValues(alpha: 0.05)
                          : null,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_selectedFile == null) ...[
                            Icon(
                              FluentIcons.cloud_upload,
                              size: 48,
                              color: theme.accentColor,
                            ),
                            const SizedBox(height: 14),
                            Text(
                              '点击选择音频文件',
                              style: theme.typography.subtitle?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '支持 WAV / MP3 / M4A 格式，超长录音自动分段转写（最长 2 小时）',
                              style: TextStyle(
                                fontSize: 12,
                                color: theme
                                    .resources.textFillColorSecondary,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ] else ...[
                            Icon(
                              FluentIcons.audio_file,
                              size: 40,
                              color: theme.accentColor,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _fileName,
                              style: theme.typography.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  _formatSize(_fileSize),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme
                                        .resources.textFillColorSecondary,
                                  ),
                                ),
                                if (_format != null) ...[
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: theme.accentColor
                                          .withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: Text(
                                      _format!.name.toUpperCase(),
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: theme.accentColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (_format == AudioFormat.m4a) ...[
                              const SizedBox(height: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
                                decoration: BoxDecoration(
                                  color: theme.resources
                                      .cardBackgroundFillColorDefault,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: theme
                                        .resources.dividerStrokeColorDefault,
                                  ),
                                ),
                                child: Text(
                                  '💡 M4A 将在本地转码为 16kHz WAV 后提交转写',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: theme
                                        .resources.textFillColorSecondary,
                                  ),
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            Button(
                              onPressed: _loading ? null : _pickFile,
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(FluentIcons.refresh, size: 12),
                                  SizedBox(width: 6),
                                  Text('更换文件'),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),

                const SizedBox(height: 16),

                // Controls: Language Selector & Transcribe Button
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      flex: 2,
                      child: InfoLabel(
                        label: '识别语言',
                        child: ComboBox<String>(
                          value: _language,
                          items: const [
                            ComboBoxItem(
                              value: 'auto',
                              child: Text('自动检测'),
                            ),
                            ComboBoxItem(
                              value: 'zh',
                              child: Text('中文 (Chinese)'),
                            ),
                            ComboBoxItem(
                              value: 'en',
                              child: Text('英语 (English)'),
                            ),
                          ],
                          onChanged: _loading
                              ? null
                              : (val) {
                                  if (val != null) {
                                    setState(() => _language = val);
                                  }
                                },
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      flex: 3,
                      child: SizedBox(
                        height: 36,
                        child: FilledButton(
                          onPressed: (_selectedFile != null &&
                                  !_loading &&
                                  hasKey &&
                                  _format != null)
                              ? _transcribe
                              : null,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (_loading) ...[
                                const ProgressRing(size: 16),
                                const SizedBox(width: 8),
                              ] else ...[
                                const Icon(FluentIcons.speech, size: 16),
                                const SizedBox(width: 8),
                              ],
                              Text(
                                _stageLabel,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),

                // Progress Indicator
                if (_loading) ...[
                  const SizedBox(height: 16),
                  Card(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              _stageLabel,
                              style: theme.typography.caption?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            if (_stage == AudioStage.segmentTranscribing &&
                                _segTotal > 0)
                              Text(
                                '${(_segDone / _segTotal * 100).toInt()}%',
                                style: theme.typography.caption?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: theme.accentColor,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ProgressBar(
                          value: (_stage == AudioStage.segmentTranscribing &&
                                  _segTotal > 0)
                              ? (_segDone / _segTotal * 100)
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],

                // Error Banner
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  InfoBar(
                    title: const Text('转写失败'),
                    content: Text(_error!),
                    severity: InfoBarSeverity.error,
                    isLong: true,
                    onClose: () => setState(() => _error = null),
                  ),
                ],

                // Result Card
                if (_result.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Card(
                    padding: EdgeInsets.zero,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            border: Border(
                              bottom: BorderSide(
                                color: theme
                                    .resources.dividerStrokeColorDefault,
                                width: 1.0,
                              ),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                FluentIcons.text_document,
                                size: 16,
                                color: theme.accentColor,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '转写结果',
                                style: theme.typography.bodyStrong,
                              ),
                              const Spacer(),
                              Tooltip(
                                message: '复制文本',
                                child: IconButton(
                                  icon: const Icon(FluentIcons.copy, size: 15),
                                  onPressed: _copyResult,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Tooltip(
                                message: '导出为 TXT 文件',
                                child: IconButton(
                                  icon: const Icon(FluentIcons.download,
                                      size: 15),
                                  onPressed: _exportTxt,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: SelectableText(
                            _result,
                            style: const TextStyle(
                              fontSize: 14,
                              height: 1.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

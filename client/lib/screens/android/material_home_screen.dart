import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config.dart';
import '../../services/asr_service.dart';
import '../../services/audio_format.dart';

class MaterialHomeScreen extends StatefulWidget {
  final AppConfig config;

  const MaterialHomeScreen({super.key, required this.config});

  @override
  State<MaterialHomeScreen> createState() => _MaterialHomeScreenState();
}

class _MaterialHomeScreenState extends State<MaterialHomeScreen> {
  File? _selectedFile;
  String _fileName = '';
  int _fileSize = 0;
  String _language = 'auto';
  String _result = '';
  bool _loading = false;
  bool _retrying = false;
  String? _error;
  AudioFormat? _format;
  AudioStage? _stage;
  String? _statusMessage;
  int _segDone = 0;
  int _segTotal = 0;
  TranscribeResult? _lastResult;

  String get _stageLabel {
    if (_retrying) {
      return _statusMessage ??
          (_segTotal > 0
              ? '正在补转失败分段 $_segDone/$_segTotal 段...'
              : '正在补转失败分段...');
    }
    if (!_loading) return '开始识别';
    if (_statusMessage != null) return _statusMessage!;
    return switch (_stage) {
      AudioStage.converting => '正在转换音频...',
      AudioStage.segmentTranscribing => _segTotal > 0
          ? '正在转写 $_segDone/$_segTotal 段...'
          : '正在分段转写...',
      _ => '正在识别...',
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

  /// 只读文件头识别真实格式（扩展名不可信）。
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
      _retrying = false;
      _error = null;
      _result = '';
      _lastResult = null;
      _stage = null;
      _statusMessage = null;
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
        onStatusMessage: (msg) {
          if (mounted) setState(() => _statusMessage = msg);
        },
      );
      if (mounted) {
        setState(() {
          _result = res.text;
          _lastResult = res;
          _loading = false;
          _stage = null;
          _statusMessage = null;
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

  Future<void> _retryFailedSegments() async {
    if (_retrying || _loading || _lastResult == null || !_lastResult!.isPartial) {
      return;
    }

    setState(() {
      _retrying = true;
      _error = null;
      _statusMessage = '正在自动补转失败分段...';
      _segDone = 0;
      _segTotal = _lastResult!.failedIndices.length;
    });

    try {
      final res = await _asr.retryFailedSegments(
        onProgress: (done, total) {
          if (mounted) {
            setState(() {
              _segDone = done;
              _segTotal = total;
            });
          }
        },
        onStatusMessage: (msg) {
          if (mounted) setState(() => _statusMessage = msg);
        },
      );

      if (mounted) {
        setState(() {
          _result = res.text;
          _lastResult = res;
          _retrying = false;
          _statusMessage = null;
        });

        if (!res.isPartial) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('所有失败分段已成功补转完成'),
              backgroundColor: Colors.green.shade700,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '补转失败: $e';
          _retrying = false;
          _statusMessage = null;
        });
      }
    }
  }

  void _copyResult() {
    if (_result.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: _result));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('已复制到剪贴板'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已导出到 $savedPath'),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
                Text('ASR 服务商与 API 设置'),
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
                          child: Text(
                              'OpenAI Whisper 规范 (/audio/transcriptions)'),
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
                        hintText: '例如: whisper-1 或 SenseVoiceSmall',
                        prefixIcon: Icon(Icons.model_training, size: 20),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: keyCtrl,
                      decoration: InputDecoration(
                        labelText: 'API Key',
                        hintText: currentPreset.apiKeyHint,
                        prefixIcon: const Icon(Icons.key, size: 20),
                        suffixIcon: IconButton(
                          icon: Icon(obscure
                              ? Icons.visibility_off
                              : Icons.visibility),
                          onPressed: () =>
                              setDialogState(() => obscure = !obscure),
                        ),
                      ),
                      obscureText: obscure,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '分段并发数',
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                        Text(
                          '$concurrency 路',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    Slider(
                      value: concurrency.toDouble(),
                      min: 1,
                      max: 16,
                      divisions: 15,
                      label: '$concurrency',
                      onChanged: (val) {
                        setDialogState(() => concurrency = val.round());
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        '推荐 4~8 路并发；过高易触发 API 429 限流',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.grey,
                              fontSize: 11,
                            ),
                      ),
                    ),
                    if (currentPreset.portalUrl != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        '官网控制台: ${currentPreset.portalUrl}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.grey,
                            ),
                      ),
                    ],
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
                  _asr.dispose();
                  _asr = AsrService(widget.config);
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

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isReady = widget.config.isConfigured;

    return Scaffold(
      body: Column(
        children: [
          // Top bar
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            decoration: BoxDecoration(
              color: cs.surface,
              border: Border(
                bottom:
                    BorderSide(color: cs.outlineVariant.withValues(alpha: 0.5)),
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Row(
                children: [
                  Icon(Icons.mic, color: cs.primary, size: 24),
                  const SizedBox(width: 10),
                  Text(
                    'ASR 语音转文字',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      widget.config.badgeText,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // API Key indicator
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: isReady
                          ? Colors.green.withValues(alpha: 0.1)
                          : cs.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isReady
                              ? Icons.check_circle_outline
                              : Icons.warning_amber,
                          size: 14,
                          color: isReady ? Colors.green.shade700 : cs.error,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isReady ? '已就绪' : '未配置服务',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: isReady ? Colors.green.shade700 : cs.error,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.settings, size: 20),
                    onPressed: _showSettings,
                    tooltip: 'API 设置',
                    style: IconButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Main content
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // File picker area
                      InkWell(
                        onTap: _loading ? null : _pickFile,
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              vertical: 36, horizontal: 20),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: _selectedFile != null
                                  ? cs.primary.withValues(alpha: 0.4)
                                  : cs.outlineVariant,
                              width: _selectedFile != null ? 2 : 1,
                            ),
                            color: _selectedFile != null
                                ? cs.primaryContainer.withValues(alpha: 0.15)
                                : cs.surfaceContainerLowest,
                          ),
                          child: Column(
                            children: [
                              if (_selectedFile == null) ...[
                                Icon(Icons.cloud_upload_outlined,
                                    size: 48,
                                    color: cs.onSurfaceVariant
                                        .withValues(alpha: 0.5)),
                                const SizedBox(height: 12),
                                Text(
                                  '点击或拖放音频文件',
                                  style: TextStyle(
                                    fontSize: 15,
                                    color: cs.onSurfaceVariant,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '支持 WAV / MP3 / M4A 格式',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: cs.onSurfaceVariant
                                        .withValues(alpha: 0.6),
                                  ),
                                ),
                              ] else ...[
                                Icon(Icons.audio_file,
                                    size: 40, color: cs.primary),
                                const SizedBox(height: 12),
                                Text(
                                  _fileName,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: cs.onSurface,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _formatSize(_fileSize),
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                                if (_format == AudioFormat.m4a) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    '将自动转换为 WAV（${wavSampleRate ~/ 1000}kHz 单声道），'
                                    '超长录音按 $segmentSeconds 秒分段并行转写，最长 2 小时',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: cs.onSurfaceVariant
                                          .withValues(alpha: 0.75),
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ],
                                const SizedBox(height: 8),
                                TextButton.icon(
                                  onPressed: _loading ? null : _pickFile,
                                  icon: const Icon(Icons.swap_horiz, size: 16),
                                  label: const Text('更换文件'),
                                  style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Language selector
                      DropdownButtonFormField<String>(
                        initialValue: _language,
                        decoration: const InputDecoration(
                          labelText: '识别语言',
                          prefixIcon: Icon(Icons.translate, size: 20),
                        ),
                        borderRadius: BorderRadius.circular(10),
                        items: const [
                          DropdownMenuItem(value: 'auto', child: Text('自动检测')),
                          DropdownMenuItem(value: 'zh', child: Text('中文')),
                          DropdownMenuItem(value: 'en', child: Text('English')),
                        ],
                        onChanged: _loading
                            ? null
                            : (v) => setState(() => _language = v ?? 'auto'),
                      ),
                      const SizedBox(height: 24),

                      // Transcribe button
                      SizedBox(
                        height: 48,
                        child: FilledButton.icon(
                          onPressed: (_selectedFile != null &&
                                  !_loading &&
                                  isReady &&
                                  _format != null)
                              ? _transcribe
                              : null,
                          icon: _loading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.auto_awesome, size: 20),
                          label: Text(
                            _stageLabel,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w500),
                          ),
                        ),
                      ),
                      // Linear Progress Bar during segmentation or retry
                      if ((_loading || _retrying) && _segTotal > 0) ...[
                        const SizedBox(height: 12),
                        LinearProgressIndicator(
                          value: _segDone / _segTotal,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ],

                      // Error
                      if (_error != null) ...[
                        const SizedBox(height: 20),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: cs.errorContainer,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.error_outline,
                                  color: cs.error, size: 20),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  _error!,
                                  style: TextStyle(
                                    color: cs.onErrorContainer,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      // Partial Success Banner
                      if (_lastResult != null &&
                          _lastResult!.isPartial &&
                          !_loading) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade50,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.amber.shade300),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.warning_amber_rounded,
                                      color: Colors.amber.shade900, size: 20),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      '转写完成（${_lastResult!.successCount}/${_lastResult!.totalSegments} 段成功）',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                        color: Colors.amber.shade900,
                                      ),
                                    ),
                                  ),
                                  if (_retrying)
                                    const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  else
                                    FilledButton.tonal(
                                      onPressed: _retryFailedSegments,
                                      style: FilledButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                      ),
                                      child: const Text('重试失败段'),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '第 ${_lastResult!.failedSegmentsDisplay} 段未转写成功，已为您保留全部成功内容。您可以点击右侧按钮重试失败段落。',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.amber.shade900,
                                  height: 1.4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      // Result
                      if (_result.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: cs.outlineVariant),
                            color: cs.surfaceContainerLowest,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 12, 8, 8),
                                child: Row(
                                  children: [
                                    Icon(Icons.text_snippet_outlined,
                                        size: 18, color: cs.primary),
                                    const SizedBox(width: 8),
                                    Text(
                                      '识别结果',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: 14,
                                        color: cs.onSurface,
                                      ),
                                    ),
                                    const Spacer(),
                                    IconButton(
                                      icon: const Icon(Icons.copy_rounded,
                                          size: 18),
                                      onPressed: _copyResult,
                                      tooltip: '复制',
                                      style: IconButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                      ),
                                    ),
                                    IconButton(
                                      icon:
                                          const Icon(Icons.download, size: 18),
                                      onPressed: _exportTxt,
                                      tooltip: '导出为 TXT',
                                      style: IconButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Divider(height: 1, color: cs.outlineVariant),
                              Padding(
                                padding: const EdgeInsets.all(16),
                                child: SelectableText(
                                  _result,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    height: 1.6,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

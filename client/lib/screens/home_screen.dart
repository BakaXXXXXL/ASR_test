import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../services/asr_service.dart';

class HomeScreen extends StatefulWidget {
  final AppConfig config;

  const HomeScreen({super.key, required this.config});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  File? _selectedFile;
  String _language = 'auto';
  String _result = '';
  bool _loading = false;
  String? _error;
  bool _modelReady = false;

  late AsrService _asr;

  @override
  void initState() {
    super.initState();
    _asr = AsrService(widget.config);
    _checkHealth();
  }

  Future<void> _checkHealth() async {
    final ready = await _asr.checkHealth();
    if (mounted) {
      setState(() => _modelReady = ready);
    }
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav', 'mp3', 'm4a', 'flac', 'ogg', 'aac', 'wma', 'webm'],
    );
    if (result != null && result.files.single.path != null) {
      setState(() {
        _selectedFile = File(result.files.single.path!);
        _error = null;
        _result = '';
      });
    }
  }

  Future<void> _transcribe() async {
    if (_selectedFile == null) return;

    setState(() {
      _loading = true;
      _error = null;
      _result = '';
    });

    try {
      final res = await _asr.transcribe(_selectedFile!, language: _language);
      if (mounted) {
        setState(() {
          _result = res.text;
          _loading = false;
        });
      }
    } on DioException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.response?.data?['detail']?.toString() ?? e.message;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _copyResult() {
    if (_result.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: _result));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制到剪贴板')),
      );
    }
  }

  void _showSettings() {
    final urlCtrl = TextEditingController(text: widget.config.baseUrl);
    final keyCtrl = TextEditingController(text: widget.config.apiKey);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('API 设置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                labelText: 'API 地址',
                hintText: 'http://localhost:8000',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: keyCtrl,
              decoration: const InputDecoration(
                labelText: 'API Key',
                hintText: '留空表示无需认证',
              ),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              await widget.config.save(
                baseUrl: urlCtrl.text.trim(),
                apiKey: keyCtrl.text.trim(),
              );
              _asr = AsrService(widget.config);
              if (ctx.mounted) Navigator.pop(ctx);
              _checkHealth();
            },
            child: const Text('保存'),
          ),
        ],
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('ASR 语音转文字'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettings,
            tooltip: 'API 设置',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status indicator
            Row(
              children: [
                Icon(
                  _modelReady ? Icons.check_circle : Icons.error_outline,
                  color: _modelReady ? Colors.green : Colors.orange,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  _modelReady ? '模型就绪' : '模型未就绪',
                  style: TextStyle(
                    color: _modelReady ? Colors.green : Colors.orange,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // File selection
            OutlinedButton.icon(
              onPressed: _loading ? null : _pickFile,
              icon: const Icon(Icons.audio_file),
              label: const Text('选择音频文件'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            if (_selectedFile != null) ...[
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _selectedFile!.path.split(Platform.pathSeparator).last,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '大小: ${_formatSize(_selectedFile!.lengthSync())}',
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),

            // Language selector
            DropdownButtonFormField<String>(
              value: _language,
              decoration: const InputDecoration(
                labelText: '语言',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'auto', child: Text('自动检测')),
                DropdownMenuItem(value: 'chinese', child: Text('中文')),
                DropdownMenuItem(value: 'english', child: Text('English')),
              ],
              onChanged: _loading
                  ? null
                  : (v) => setState(() => _language = v ?? 'auto'),
            ),
            const SizedBox(height: 24),

            // Transcribe button
            FilledButton.icon(
              onPressed: (_selectedFile != null && !_loading) ? _transcribe : null,
              icon: _loading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.transcribe),
              label: Text(_loading ? '识别中...' : '开始识别'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
            const SizedBox(height: 24),

            // Error display
            if (_error != null)
              Card(
                color: Colors.red[50],
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.error, color: Colors.red[700]),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(color: Colors.red[700]),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // Result display
            if (_result.isNotEmpty)
              Expanded(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              '识别结果',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.copy),
                              onPressed: _copyResult,
                              tooltip: '复制结果',
                            ),
                          ],
                        ),
                        const Divider(),
                        Expanded(
                          child: SingleChildScrollView(
                            child: SelectableText(_result),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

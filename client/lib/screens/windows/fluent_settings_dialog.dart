import 'package:fluent_ui/fluent_ui.dart';

import '../../config.dart';

Future<void> showFluentSettingsDialog(
  BuildContext context, {
  required AppConfig config,
  required VoidCallback onSaved,
}) async {
  String selectedProvider = config.provider;
  AsrProtocol selectedProtocol = config.protocol;
  final urlCtrl = TextEditingController(text: config.baseUrl);
  final modelCtrl = TextEditingController(text: config.model);
  final keyCtrl = TextEditingController(text: config.apiKey);
  bool obscure = true;
  int concurrency = config.concurrency;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        final currentPreset = asrPresets.firstWhere(
          (p) => p.id == selectedProvider,
          orElse: () => asrPresets.firstWhere((p) => p.id == 'custom'),
        );

        return ContentDialog(
          constraints: const BoxConstraints(maxWidth: 480),
          title: const Row(
            children: [
              Icon(FluentIcons.settings, size: 20),
              SizedBox(width: 8),
              Text('ASR 服务商与 API 设置'),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                InfoLabel(
                  label: '服务商预设',
                  child: ComboBox<String>(
                    isExpanded: true,
                    value: selectedProvider,
                    items: asrPresets
                        .map(
                          (p) => ComboBoxItem<String>(
                            value: p.id,
                            child: Text(p.name),
                          ),
                        )
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
                ),
                const SizedBox(height: 12),
                InfoLabel(
                  label: '接口协议规范',
                  child: ComboBox<AsrProtocol>(
                    isExpanded: true,
                    value: selectedProtocol,
                    items: const [
                      ComboBoxItem(
                        value: AsrProtocol.audioTranscriptions,
                        child: Text('OpenAI Whisper 规范 (/audio/transcriptions)'),
                      ),
                      ComboBoxItem(
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
                ),
                const SizedBox(height: 12),
                InfoLabel(
                  label: '接口地址 (Base URL)',
                  child: TextBox(
                    controller: urlCtrl,
                    placeholder: 'https://api.example.com/v1',
                  ),
                ),
                const SizedBox(height: 12),
                InfoLabel(
                  label: '模型名称 (Model)',
                  child: TextBox(
                    controller: modelCtrl,
                    placeholder: '例如: whisper-1 或 SenseVoiceSmall',
                  ),
                ),
                const SizedBox(height: 12),
                InfoLabel(
                  label: 'API Key',
                  child: TextBox(
                    controller: keyCtrl,
                    placeholder: currentPreset.apiKeyHint,
                    obscureText: obscure,
                    suffix: IconButton(
                      icon: Icon(
                        obscure ? FluentIcons.view : FluentIcons.hide,
                        size: 14,
                      ),
                      onPressed: () =>
                          setDialogState(() => obscure = !obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                InfoLabel(
                  label: '分段转写并发数 ($concurrency 路)',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Slider(
                        min: 1,
                        max: 16,
                        value: concurrency.toDouble(),
                        onChanged: (val) =>
                            setDialogState(() => concurrency = val.round()),
                      ),
                      Text(
                        '推荐 4~8 路并发；过高易触发 API 429 限流',
                        style: TextStyle(
                          fontSize: 11,
                          color: FluentTheme.of(ctx)
                              .resources
                              .textFillColorSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (currentPreset.portalUrl != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    '官网控制台: ${currentPreset.portalUrl}',
                    style: TextStyle(
                      fontSize: 12,
                      color:
                          FluentTheme.of(ctx).resources.textFillColorSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            Button(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                await config.save(
                  provider: selectedProvider,
                  protocol: selectedProtocol,
                  baseUrl: urlCtrl.text.trim(),
                  model: modelCtrl.text.trim(),
                  apiKey: keyCtrl.text.trim(),
                  concurrency: concurrency,
                );
                onSaved();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    ),
  );
}

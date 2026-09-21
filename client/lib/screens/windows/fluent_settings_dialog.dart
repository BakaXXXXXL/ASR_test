import 'package:fluent_ui/fluent_ui.dart';

import '../../config.dart';

Future<void> showFluentSettingsDialog(
  BuildContext context, {
  required AppConfig config,
  required VoidCallback onSaved,
}) async {
  final keyCtrl = TextEditingController(text: config.apiKey);
  bool obscure = true;
  int concurrency = config.concurrency;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => ContentDialog(
        title: const Row(
          children: [
            Icon(FluentIcons.settings, size: 20),
            SizedBox(width: 8),
            Text('API 设置'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InfoLabel(
              label: 'MiMo API Key',
              child: TextBox(
                controller: keyCtrl,
                placeholder: '从 platform.xiaomimimo.com 获取',
                obscureText: obscure,
                suffix: IconButton(
                  icon: Icon(
                    obscure ? FluentIcons.view : FluentIcons.hide,
                    size: 14,
                  ),
                  onPressed: () => setDialogState(() => obscure = !obscure),
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
                      color:
                          FluentTheme.of(ctx).resources.textFillColorSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '接口地址: ${config.baseUrl}',
              style: TextStyle(
                fontSize: 12,
                color: FluentTheme.of(ctx).resources.textFillColorSecondary,
              ),
            ),
          ],
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              await config.save(
                apiKey: keyCtrl.text.trim(),
                concurrency: concurrency,
              );
              onSaved();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
}

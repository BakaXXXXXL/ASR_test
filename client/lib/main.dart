import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'app_fluent.dart';
import 'app_material.dart';
import 'config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();
    const windowOptions = WindowOptions(
      size: Size(680, 780),
      minimumSize: Size(480, 640),
      center: true,
      title: 'ASR 语音转文字',
      titleBarStyle: TitleBarStyle.normal,
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  final config = AppConfig();
  await config.load();

  if (Platform.isWindows) {
    runApp(FluentAsrApp(config: config));
  } else {
    runApp(MaterialAsrApp(config: config));
  }
}

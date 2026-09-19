import 'dart:io';
import 'package:flutter/widgets.dart';

import '../config.dart';
import 'android/material_home_screen.dart';
import 'windows/fluent_home_screen.dart';

export 'android/material_home_screen.dart';
export 'windows/fluent_home_screen.dart';

/// 跨平台自适应 HomeScreen：Windows 平台使用 WinUI 3，其他平台使用 Material 3。
class HomeScreen extends StatelessWidget {
  final AppConfig config;

  const HomeScreen({super.key, required this.config});

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) {
      return FluentHomeScreen(config: config);
    }
    return MaterialHomeScreen(config: config);
  }
}

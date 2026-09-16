import 'package:flutter/material.dart';

import 'config.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final config = AppConfig();
  await config.load();

  runApp(AsrApp(config: config));
}

class AsrApp extends StatelessWidget {
  final AppConfig config;

  const AsrApp({super.key, required this.config});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ASR 语音转文字',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: HomeScreen(config: config),
    );
  }
}

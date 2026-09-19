import 'package:fluent_ui/fluent_ui.dart';

import 'config.dart';
import 'screens/windows/fluent_home_screen.dart';

class FluentAsrApp extends StatelessWidget {
  final AppConfig config;

  const FluentAsrApp({super.key, required this.config});

  @override
  Widget build(BuildContext context) {
    return FluentApp(
      title: 'ASR 语音转文字',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: FluentThemeData(
        accentColor: Colors.blue,
        brightness: Brightness.light,
        visualDensity: VisualDensity.standard,
      ),
      darkTheme: FluentThemeData(
        accentColor: Colors.blue,
        brightness: Brightness.dark,
        visualDensity: VisualDensity.standard,
      ),
      home: FluentHomeScreen(config: config),
    );
  }
}

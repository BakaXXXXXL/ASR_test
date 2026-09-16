import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  static const String defaultBaseUrl = 'http://localhost:8000';
  static const String defaultApiKey = '';

  String _baseUrl = defaultBaseUrl;
  String _apiKey = defaultApiKey;

  String get baseUrl => _baseUrl;
  String get apiKey => _apiKey;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString('api_base_url') ?? defaultBaseUrl;
    _apiKey = prefs.getString('api_key') ?? defaultApiKey;
  }

  Future<void> save({String? baseUrl, String? apiKey}) async {
    final prefs = await SharedPreferences.getInstance();
    if (baseUrl != null) {
      _baseUrl = baseUrl;
      await prefs.setString('api_base_url', baseUrl);
    }
    if (apiKey != null) {
      _apiKey = apiKey;
      await prefs.setString('api_key', apiKey);
    }
  }
}

import 'package:shared_preferences/shared_preferences.dart';

class AppConfig {
  static const String defaultBaseUrl = 'https://api.xiaomimimo.com/v1';
  static const String defaultApiKey = '';
  static const int defaultConcurrency = 6;
  static const int minConcurrency = 1;
  static const int maxConcurrency = 16;

  String _baseUrl = defaultBaseUrl;
  String _apiKey = defaultApiKey;
  int _concurrency = defaultConcurrency;

  String get baseUrl => _baseUrl;
  String get apiKey => _apiKey;
  int get concurrency => _concurrency;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString('api_base_url') ?? defaultBaseUrl;
    _apiKey = prefs.getString('api_key') ?? defaultApiKey;
    final savedConcurrency = prefs.getInt('concurrency') ?? defaultConcurrency;
    _concurrency = savedConcurrency.clamp(minConcurrency, maxConcurrency);
  }

  Future<void> save({String? baseUrl, String? apiKey, int? concurrency}) async {
    final prefs = await SharedPreferences.getInstance();
    if (baseUrl != null) {
      _baseUrl = baseUrl;
      await prefs.setString('api_base_url', baseUrl);
    }
    if (apiKey != null) {
      _apiKey = apiKey;
      await prefs.setString('api_key', apiKey);
    }
    if (concurrency != null) {
      _concurrency = concurrency.clamp(minConcurrency, maxConcurrency);
      await prefs.setInt('concurrency', _concurrency);
    }
  }
}

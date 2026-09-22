import 'package:shared_preferences/shared_preferences.dart';

/// ASR 请求协议规范
enum AsrProtocol {
  /// 标准 OpenAI Audio 规范: multipart/form-data POST /audio/transcriptions
  /// 适用: SiliconFlow (SenseVoice/Whisper), Groq, OpenAI, 本地 Faster-Whisper/LocalAI 等
  audioTranscriptions,

  /// OpenAI Chat 规范: application/json POST /chat/completions (带 input_audio)
  /// 适用: Xiaomi MiMo, Qwen-Audio 等
  chatCompletions,
}

/// 服务商预设配置项
class AsrPreset {
  final String id;
  final String name;
  final AsrProtocol protocol;
  final String defaultBaseUrl;
  final String defaultModel;
  final String apiKeyHint;
  final String? portalUrl;

  const AsrPreset({
    required this.id,
    required this.name,
    required this.protocol,
    required this.defaultBaseUrl,
    required this.defaultModel,
    required this.apiKeyHint,
    this.portalUrl,
  });
}

/// 内置服务商预设列表
const List<AsrPreset> asrPresets = [
  AsrPreset(
    id: 'mimo',
    name: '小米 MiMo (官方)',
    protocol: AsrProtocol.chatCompletions,
    defaultBaseUrl: 'https://api.xiaomimimo.com/v1',
    defaultModel: 'mimo-v2.5-asr',
    apiKeyHint: '从 platform.xiaomimimo.com 获取',
    portalUrl: 'https://platform.xiaomimimo.com',
  ),
  AsrPreset(
    id: 'siliconflow',
    name: '硅基流动 SiliconFlow',
    protocol: AsrProtocol.audioTranscriptions,
    defaultBaseUrl: 'https://api.siliconflow.cn/v1',
    defaultModel: 'FunAudioLLM/SenseVoiceSmall',
    apiKeyHint: '从 cloud.siliconflow.cn 获取',
    portalUrl: 'https://cloud.siliconflow.cn',
  ),
  AsrPreset(
    id: 'groq',
    name: 'Groq (海外极速)',
    protocol: AsrProtocol.audioTranscriptions,
    defaultBaseUrl: 'https://api.groq.com/openai/v1',
    defaultModel: 'whisper-large-v3',
    apiKeyHint: '从 console.groq.com 获取',
    portalUrl: 'https://console.groq.com',
  ),
  AsrPreset(
    id: 'openai',
    name: 'OpenAI (官方)',
    protocol: AsrProtocol.audioTranscriptions,
    defaultBaseUrl: 'https://api.openai.com/v1',
    defaultModel: 'whisper-1',
    apiKeyHint: '从 platform.openai.com 获取',
    portalUrl: 'https://platform.openai.com',
  ),
  AsrPreset(
    id: 'local',
    name: '本地 / 自建服务',
    protocol: AsrProtocol.audioTranscriptions,
    defaultBaseUrl: 'http://localhost:8000/v1',
    defaultModel: 'whisper-1',
    apiKeyHint: '本地服务无需 API Key（留空即可）',
    portalUrl: null,
  ),
  AsrPreset(
    id: 'custom',
    name: '自定义配置 (Custom)',
    protocol: AsrProtocol.audioTranscriptions,
    defaultBaseUrl: 'https://api.example.com/v1',
    defaultModel: 'whisper-1',
    apiKeyHint: '输入对应服务商的 API Key',
    portalUrl: null,
  ),
];

class AppConfig {
  static const String defaultProvider = 'mimo';
  static const AsrProtocol defaultProtocol = AsrProtocol.chatCompletions;
  static const String defaultBaseUrl = 'https://api.xiaomimimo.com/v1';
  static const String defaultModel = 'mimo-v2.5-asr';
  static const String defaultApiKey = '';
  static const int defaultConcurrency = 6;
  static const int minConcurrency = 1;
  static const int maxConcurrency = 16;

  String _provider = defaultProvider;
  AsrProtocol _protocol = defaultProtocol;
  String _baseUrl = defaultBaseUrl;
  String _model = defaultModel;
  String _apiKey = defaultApiKey;
  int _concurrency = defaultConcurrency;

  String get provider => _provider;
  AsrProtocol get protocol => _protocol;
  String get baseUrl => _baseUrl;
  String get model => _model;
  String get apiKey => _apiKey;
  int get concurrency => _concurrency;

  /// 是否已完成可用配置。本地自建服务无需 API Key 即可转写。
  bool get isConfigured =>
      apiKey.isNotEmpty ||
      provider == 'local' ||
      baseUrl.contains('localhost') ||
      baseUrl.contains('127.0.0.1');

  /// 当前预设定义（若未命中则返回 custom 预设）
  AsrPreset get currentPreset => asrPresets.firstWhere(
        (p) => p.id == _provider,
        orElse: () => asrPresets.firstWhere((p) => p.id == 'custom'),
      );

  /// 顶部徽章展示标题（如：MiMo · mimo-v2.5-asr 或 硅基流动 · SenseVoiceSmall）
  String get badgeText {
    final preset = currentPreset;
    final shortModel = _model.contains('/') ? _model.split('/').last : _model;
    if (preset.id == 'mimo') {
      return 'MiMo · $shortModel';
    } else if (preset.id == 'siliconflow') {
      return '硅基流动 · $shortModel';
    } else if (preset.id == 'groq') {
      return 'Groq · $shortModel';
    } else if (preset.id == 'openai') {
      return 'OpenAI · $shortModel';
    } else if (preset.id == 'local') {
      return '本地服务 · $shortModel';
    } else {
      return '自定义 · $shortModel';
    }
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString('api_base_url') ?? defaultBaseUrl;
    _apiKey = prefs.getString('api_key') ?? defaultApiKey;
    final savedConcurrency = prefs.getInt('concurrency') ?? defaultConcurrency;
    _concurrency = savedConcurrency.clamp(minConcurrency, maxConcurrency);

    final savedProvider = prefs.getString('asr_provider');
    if (savedProvider != null && savedProvider.isNotEmpty) {
      _provider = savedProvider;
    } else {
      // 向下兼容旧版本：通过已存 baseUrl 平滑推断
      if (_baseUrl.contains('xiaomimimo')) {
        _provider = 'mimo';
      } else if (_baseUrl.contains('siliconflow')) {
        _provider = 'siliconflow';
      } else if (_baseUrl.contains('groq')) {
        _provider = 'groq';
      } else if (_baseUrl.contains('openai.com')) {
        _provider = 'openai';
      } else if (_baseUrl.contains('localhost') ||
          _baseUrl.contains('127.0.0.1')) {
        _provider = 'local';
      } else {
        _provider = defaultProvider;
      }
    }

    final savedProtocolStr = prefs.getString('asr_protocol');
    if (savedProtocolStr != null && savedProtocolStr.isNotEmpty) {
      _protocol = AsrProtocol.values.firstWhere(
        (e) => e.name == savedProtocolStr,
        orElse: () => currentPreset.protocol,
      );
    } else {
      _protocol = currentPreset.protocol;
    }

    _model = prefs.getString('asr_model') ?? currentPreset.defaultModel;
  }

  Future<void> save({
    String? provider,
    AsrProtocol? protocol,
    String? baseUrl,
    String? model,
    String? apiKey,
    int? concurrency,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    if (provider != null) {
      _provider = provider;
      await prefs.setString('asr_provider', provider);
    }
    if (protocol != null) {
      _protocol = protocol;
      await prefs.setString('asr_protocol', protocol.name);
    }
    if (baseUrl != null) {
      _baseUrl = baseUrl;
      await prefs.setString('api_base_url', baseUrl);
    }
    if (model != null) {
      _model = model;
      await prefs.setString('asr_model', model);
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

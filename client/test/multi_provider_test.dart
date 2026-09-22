import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

import 'package:asr_client/config.dart';
import 'package:asr_client/services/asr_service.dart';
import 'package:asr_client/services/audio_format.dart';

/// Mock HttpClientAdapter 用于拦截 Dio 请求并验证请求内容
class MockHttpClientAdapter implements HttpClientAdapter {
  final Future<ResponseBody> Function(RequestOptions options) handler;

  MockHttpClientAdapter(this.handler);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

/// 创建临时测试 WAV 文件
Future<File> _createSmallTestWav() async {
  final tempDir = await Directory.systemTemp.createTemp('asr_provider_test_');
  final wavFile = File('${tempDir.path}/test.wav');
  // 构造包含 3200 字节（16kHz 16bit 单声道 0.1秒）的有效 WAV
  const pcmLength = 3200;
  final header = buildWavHeader(pcmLength);
  final pcm = Uint8List(pcmLength);
  for (var i = 0; i < pcmLength; i += 2) {
    // 写入有效人声音频数据，避免被数字静音或异常过滤拦截
    pcm[i] = ((i * 33) % 256);
    pcm[i + 1] = 0x10;
  }
  final raf = await wavFile.open(mode: FileMode.write);
  await raf.writeFrom(header);
  await raf.writeFrom(pcm);
  await raf.close();
  return wavFile;
}

void main() {
  group('AsrPreset & AppConfig Multi-Provider', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('内置预设清单包含 6 项且必填字段完整有效', () {
      expect(asrPresets.length, 6);
      final ids = asrPresets.map((p) => p.id).toList();
      expect(ids, containsAll([
        'mimo',
        'siliconflow',
        'groq',
        'openai',
        'local',
        'custom',
      ]));

      for (final p in asrPresets) {
        expect(p.id.isNotEmpty, isTrue);
        expect(p.name.isNotEmpty, isTrue);
        expect(p.defaultBaseUrl.isNotEmpty, isTrue);
        expect(p.defaultModel.isNotEmpty, isTrue);
        expect(p.apiKeyHint.isNotEmpty, isTrue);
      }

      final mimo = asrPresets.firstWhere((p) => p.id == 'mimo');
      expect(mimo.protocol, AsrProtocol.chatCompletions);
      expect(mimo.defaultModel, 'mimo-v2.5-asr');

      final sf = asrPresets.firstWhere((p) => p.id == 'siliconflow');
      expect(sf.protocol, AsrProtocol.audioTranscriptions);
      expect(sf.defaultModel, 'FunAudioLLM/SenseVoiceSmall');

      final groq = asrPresets.firstWhere((p) => p.id == 'groq');
      expect(groq.protocol, AsrProtocol.audioTranscriptions);
      expect(groq.defaultModel, 'whisper-large-v3');

      final openai = asrPresets.firstWhere((p) => p.id == 'openai');
      expect(openai.protocol, AsrProtocol.audioTranscriptions);
      expect(openai.defaultModel, 'whisper-1');

      final local = asrPresets.firstWhere((p) => p.id == 'local');
      expect(local.protocol, AsrProtocol.audioTranscriptions);
      expect(local.defaultBaseUrl, 'http://localhost:8000/v1');
    });

    test('AppConfig save 与 load 能够完整还原各服务商配置', () async {
      final config = AppConfig();
      await config.load();

      // 默认状态检查
      expect(config.provider, 'mimo');
      expect(config.protocol, AsrProtocol.chatCompletions);
      expect(config.model, 'mimo-v2.5-asr');
      expect(config.concurrency, 6);

      // 保存为 SiliconFlow 预设
      await config.save(
        provider: 'siliconflow',
        protocol: AsrProtocol.audioTranscriptions,
        baseUrl: 'https://api.siliconflow.cn/v1',
        model: 'FunAudioLLM/SenseVoiceSmall',
        apiKey: 'sk-test-siliconflow',
        concurrency: 8,
      );

      final config2 = AppConfig();
      await config2.load();
      expect(config2.provider, 'siliconflow');
      expect(config2.protocol, AsrProtocol.audioTranscriptions);
      expect(config2.baseUrl, 'https://api.siliconflow.cn/v1');
      expect(config2.model, 'FunAudioLLM/SenseVoiceSmall');
      expect(config2.apiKey, 'sk-test-siliconflow');
      expect(config2.concurrency, 8);
    });

    test('isConfigured 判定规则正确：本地自建服务无需 API Key 即可就绪', () async {
      final config = AppConfig();
      await config.load();
      expect(config.isConfigured, isFalse);

      // 云端服务商有 key 即就绪
      await config.save(apiKey: 'sk-mimo-key');
      expect(config.isConfigured, isTrue);

      // 本地服务无 key 依然就绪
      await config.save(
        provider: 'local',
        baseUrl: 'http://localhost:8000/v1',
        apiKey: '',
      );
      expect(config.isConfigured, isTrue);

      // 包含 127.0.0.1 的地址即使 provider 设为 custom 且无 key 也视为就绪
      await config.save(
        provider: 'custom',
        baseUrl: 'http://127.0.0.1:9000/v1',
        apiKey: '',
      );
      expect(config.isConfigured, isTrue);
    });

    test('旧版本配置平滑向下兼容：未记录 asr_provider 时根据 baseUrl 自动推断', () async {
      // 模拟旧版本 SharedPreferences 只有 api_base_url
      SharedPreferences.setMockInitialValues({
        'api_base_url': 'https://api.siliconflow.cn/v1',
        'api_key': 'legacy-sf-key',
      });

      final config = AppConfig();
      await config.load();
      expect(config.provider, 'siliconflow');
      expect(config.protocol, AsrProtocol.audioTranscriptions);
      expect(config.apiKey, 'legacy-sf-key');

      // 模拟旧版本 xiaomimimo
      SharedPreferences.setMockInitialValues({
        'api_base_url': 'https://api.xiaomimimo.com/v1',
        'api_key': 'legacy-mimo-key',
      });
      final configMimo = AppConfig();
      await configMimo.load();
      expect(configMimo.provider, 'mimo');
      expect(configMimo.protocol, AsrProtocol.chatCompletions);

      // 模拟旧版本 localhost
      SharedPreferences.setMockInitialValues({
        'api_base_url': 'http://localhost:8000/v1',
      });
      final configLocal = AppConfig();
      await configLocal.load();
      expect(configLocal.provider, 'local');
      expect(configLocal.protocol, AsrProtocol.audioTranscriptions);
    });

    test('badgeText 展示文本格式符合规范', () async {
      final config = AppConfig();
      await config.load();

      await config.save(provider: 'mimo', model: 'mimo-v2.5-asr');
      expect(config.badgeText, 'MiMo · mimo-v2.5-asr');

      await config.save(
        provider: 'siliconflow',
        model: 'FunAudioLLM/SenseVoiceSmall',
      );
      expect(config.badgeText, '硅基流动 · SenseVoiceSmall');

      await config.save(provider: 'groq', model: 'whisper-large-v3');
      expect(config.badgeText, 'Groq · whisper-large-v3');

      await config.save(provider: 'openai', model: 'whisper-1');
      expect(config.badgeText, 'OpenAI · whisper-1');

      await config.save(provider: 'local', model: 'whisper-1');
      expect(config.badgeText, '本地服务 · whisper-1');

      await config.save(provider: 'custom', model: 'my-custom-model');
      expect(config.badgeText, '自定义 · my-custom-model');
    });
  });

  group('AsrService.buildEndpoint URL 合成测试', () {
    test('正确拼接带与不带斜杠的 Base URL 和 Path', () {
      expect(
        AsrService.buildEndpoint('https://api.siliconflow.cn/v1', 'audio/transcriptions'),
        'https://api.siliconflow.cn/v1/audio/transcriptions',
      );
      expect(
        AsrService.buildEndpoint('https://api.siliconflow.cn/v1/', 'audio/transcriptions'),
        'https://api.siliconflow.cn/v1/audio/transcriptions',
      );
      expect(
        AsrService.buildEndpoint('https://api.siliconflow.cn/v1', '/audio/transcriptions'),
        'https://api.siliconflow.cn/v1/audio/transcriptions',
      );
      expect(
        AsrService.buildEndpoint('https://api.siliconflow.cn/v1/', '/audio/transcriptions'),
        'https://api.siliconflow.cn/v1/audio/transcriptions',
      );
      expect(
        AsrService.buildEndpoint('http://localhost:8000/v1', 'audio/transcriptions'),
        'http://localhost:8000/v1/audio/transcriptions',
      );
      expect(
        AsrService.buildEndpoint('https://api.groq.com/openai/v1', 'audio/transcriptions'),
        'https://api.groq.com/openai/v1/audio/transcriptions',
      );
      expect(
        AsrService.buildEndpoint('https://api.xiaomimimo.com/v1', 'chat/completions'),
        'https://api.xiaomimimo.com/v1/chat/completions',
      );
    });
  });

  group('TranscribeResult.fromJson 双格式响应解析测试', () {
    test('标准 OpenAI Whisper 格式 {"text": "..."}', () {
      final res = TranscribeResult.fromJson({'text': '这是标准转写文本'});
      expect(res.text, '这是标准转写文本');
    });

    test('OpenAI Whisper 格式带模型幻觉标记被正确过滤', () {
      final res = TranscribeResult.fromJson({
        'text': '<chinese>这是过滤标记后的干净文本<chinese>',
      });
      expect(res.text, '这是过滤标记后的干净文本');
    });

    test('OpenAI Chat Completions 格式 String content', () {
      final res = TranscribeResult.fromJson({
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': 'Chat 接口转写的文本内容',
            }
          }
        ]
      });
      expect(res.text, 'Chat 接口转写的文本内容');
    });

    test('OpenAI Chat Completions 格式 List tokens content', () {
      final res = TranscribeResult.fromJson({
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': '你好，'},
                {'type': 'text', 'text': '世界！'},
              ],
            }
          }
        ]
      });
      expect(res.text, '你好，世界！');
    });

    test('非 Map 或异常响应优雅退避', () {
      final res1 = TranscribeResult.fromJson('直接纯字符串返回');
      expect(res1.text, '直接纯字符串返回');

      final res2 = TranscribeResult.fromJson(null);
      expect(res2.text, '');
    });
  });

  group('Mock 网络请求协议分流验证', () {
    late File testWav;

    setUpAll(() async {
      testWav = await _createSmallTestWav();
    });

    tearDownAll(() async {
      if (await testWav.exists()) {
        await testWav.delete();
      }
    });

    test('audioTranscriptions 协议：发出 POST /audio/transcriptions 且为 FormData 格式', () async {
      final config = AppConfig();
      await config.save(
        provider: 'siliconflow',
        protocol: AsrProtocol.audioTranscriptions,
        baseUrl: 'https://api.siliconflow.cn/v1',
        model: 'FunAudioLLM/SenseVoiceSmall',
        apiKey: 'sk-sf-test-key',
      );

      late RequestOptions capturedOptions;

      final dio = Dio();
      dio.httpClientAdapter = MockHttpClientAdapter((options) async {
        capturedOptions = options;
        return ResponseBody.fromString(
          jsonEncode({'text': '硅基流动 SenseVoice 识别成功'}),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final service = AsrService(config, dio: dio);
      final result = await service.transcribe(testWav, language: 'zh');

      expect(result.text, '硅基流动 SenseVoice 识别成功');
      expect(
        capturedOptions.uri.toString(),
        'https://api.siliconflow.cn/v1/audio/transcriptions',
      );
      expect(capturedOptions.method, 'POST');
      expect(capturedOptions.headers['Authorization'], 'Bearer sk-sf-test-key');

      // 验证 FormData
      expect(capturedOptions.data, isA<FormData>());
      final formData = capturedOptions.data as FormData;
      final fields = Map.fromEntries(formData.fields);
      expect(fields['model'], 'FunAudioLLM/SenseVoiceSmall');
      expect(fields['response_format'], 'json');
      expect(fields['language'], 'zh');

      // 验证包含文件
      expect(formData.files.length, 1);
      final fileEntry = formData.files.first;
      expect(fileEntry.key, 'file');
      expect(fileEntry.value.filename, endsWith('.wav'));
    });

    test('chatCompletions 协议：发出 POST /chat/completions 且为 JSON 格式携带 input_audio', () async {
      final config = AppConfig();
      await config.save(
        provider: 'mimo',
        protocol: AsrProtocol.chatCompletions,
        baseUrl: 'https://api.xiaomimimo.com/v1',
        model: 'mimo-v2.5-asr',
        apiKey: 'sk-mimo-test-key',
      );

      late RequestOptions capturedOptions;

      final dio = Dio();
      dio.httpClientAdapter = MockHttpClientAdapter((options) async {
        capturedOptions = options;
        return ResponseBody.fromString(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '小米 MiMo 转写成功'}
              }
            ]
          }),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final service = AsrService(config, dio: dio);
      final result = await service.transcribe(testWav, language: 'zh');

      expect(result.text, '小米 MiMo 转写成功');
      expect(
        capturedOptions.uri.toString(),
        'https://api.xiaomimimo.com/v1/chat/completions',
      );
      expect(capturedOptions.method, 'POST');
      expect(capturedOptions.headers['Authorization'], 'Bearer sk-mimo-test-key');

      // 验证 JSON 请求体
      expect(capturedOptions.data, isA<Map<String, dynamic>>());
      final body = capturedOptions.data as Map<String, dynamic>;
      expect(body['model'], 'mimo-v2.5-asr');
      final messages = body['messages'] as List;
      final content = messages[0]['content'] as List;
      expect(content[0]['type'], 'input_audio');
      final audioData = content[0]['input_audio']['data'] as String;
      expect(audioData, startsWith('data:audio/wav;base64,'));
      expect(body['extra_body']['asr_options']['language'], 'zh');
    });

    test('local 协议（无 API Key）：不附加 Authorization 请求头', () async {
      final config = AppConfig();
      await config.save(
        provider: 'local',
        protocol: AsrProtocol.audioTranscriptions,
        baseUrl: 'http://localhost:8000/v1',
        model: 'whisper-1',
        apiKey: '',
      );

      late RequestOptions capturedOptions;

      final dio = Dio();
      dio.httpClientAdapter = MockHttpClientAdapter((options) async {
        capturedOptions = options;
        return ResponseBody.fromString(
          jsonEncode({'text': '本地自建服务识别成功'}),
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });

      final service = AsrService(config, dio: dio);
      final result = await service.transcribe(testWav);

      expect(result.text, '本地自建服务识别成功');
      expect(
        capturedOptions.uri.toString(),
        'http://localhost:8000/v1/audio/transcriptions',
      );
      expect(capturedOptions.headers.containsKey('Authorization'), isFalse);
    });
  });
}

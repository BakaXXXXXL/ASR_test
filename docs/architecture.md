# 架构设计文档

## 系统架构

```
┌─────────────────────────┐       HTTPS POST        ┌──────────────────────────┐
│     Flutter 客户端       │ ──────────────────────→  │   MiMo 官方 API          │
│    (Windows / Android)   │ ←──────────────────────  │   api.xiaomimimo.com     │
│                          │                          │                          │
│  ┌─────────────────┐    │  /v1/chat/completions    │  • MiMo-V2.5-ASR 模型    │
│  │   file_picker   │    │  Authorization: Bearer   │  • 自动语言检测            │
│  │  选择 wav/mp3/m4a│    │  Content-Type: JSON      │  • 流式/非流式返回         │
│  └─────────────────┘    │                          │                          │
│  ┌─────────────────┐    │  Request:                │                          │
│  │  audio_format   │    │  { model, messages:      │                          │
│  │  魔数识别格式     │    │    [{ role, content:     │                          │
│  └─────────────────┘    │      [{ input_audio }] }]│                          │
│  ┌─────────────────┐    │  }                       │                          │
│  │ audio_converter │    │                          │                          │
│  │ m4a → 16k wav   │    │  Response:               │                          │
│  └─────────────────┘    │  { choices: [{ message   │                          │
│  ┌─────────────────┐    │    : { content } }] }    │                          │
│  │   dio (HTTP)    │    │                          │                          │
│  │   Base64 编码    │    │                          │                          │
│  └─────────────────┘    │                          │                          │
│  ┌─────────────────┐    │                          │                          │
│  │   UI 界面       │    │                          │                          │
│  │   显示结果       │    │                          │                          │
│  │   可复制        │    │                          │                          │
│  └─────────────────┘    │                          │                          │
└─────────────────────────┘                          └──────────────────────────┘
```

**架构优势**：无需自建服务器，Flutter 客户端直接调用 MiMo 官方 API，部署简单、维护成本低。

## 数据流

```
用户选择音频文件 (wav/mp3/m4a) → file_picker 获取文件路径
       ↓
读取文件头 12 字节 → 魔数识别真实格式（RIFF/WAVE、ftyp、ID3/MPEG 同步字）
       ↓
  ┌─ wav / mp3：直接使用
  └─ m4a：audio_converter 取时长 → 校验 ≤ 240s → 转 16kHz 单声道 16-bit WAV
       ↓
校验 Base64 长度 ≤ 10MB（原始字节 ≤ 7,864,320 B），超限直接报错
       ↓
构造 data:audio/...;base64,... → 组装 OpenAI 兼容请求体 (chat/completions)
       ↓
POST 到 https://api.xiaomimimo.com/v1/chat/completions
Authorization: Bearer <API_KEY>
       ↓
解析响应 JSON → choices[0].message.content
       ↓
在界面显示识别结果（可复制），临时 WAV 立即清理
```

## 技术选型理由

### ASR 模型：MiMo-V2.5-ASR（官方 API）
- **选择理由**：小米官方提供云端 API，无需本地部署模型
- **优势**：支持中英双语、方言、歌词、噪声环境，OpenAI 兼容接口
- **限制**：官方仅声明 wav 和 mp3，Base64 编码后上限 10MB；m4a 由客户端先转码成 wav 再上传

### 音频转码：audio_decoder
- **选择理由**：MiMo API 不接受 m4a，需要在客户端把 m4a 转成 wav
- **优势**：MIT 许可、体积仅约 +500KB、调用系统原生解码器（Android MediaCodec / Windows Media Foundation），不需要打包 FFmpeg（后者会带来 GPL 约束与 ~20MB 体积）
- **限制**：要求 Flutter >= 3.38（Dart >= 3.10.8）；Windows 上依赖系统自带的 AAC 解码器

### 跨平台：Flutter
- **选择理由**：一套代码同时编译 Windows 和 Android
- **优势**：UI 一致性好、Hot Reload 开发效率高、Material Design 3

### HTTP 客户端：Dio
- **选择理由**：Flutter 生态中最成熟的 HTTP 库
- **优势**：支持拦截器、FormData、超时配置、取消请求

## 模块职责

| 模块 | 职责 |
|------|------|
| `main.dart` | Flutter 应用入口、主题配置、初始化 |
| `config.dart` | 配置管理（API Key）、shared_preferences 持久化 |
| `audio_format.dart` | 纯 Dart 策略层：文件头嗅探格式、MIME 映射、Base64 体积与 m4a 时长上限、错误文案 |
| `audio_converter.dart` | m4a → 16kHz 单声道 WAV 本地转码、时长预检、临时文件清理 |
| `asr_service.dart` | 编排识别流程（嗅探 → 转码 → 体积校验 → Base64 → POST）、响应解析、阶段回调 |
| `home_screen.dart` | 主界面 UI、文件选择与格式预检、阶段提示、结果展示 |

## 安全设计

- **API Key 存储**：使用 shared_preferences 本地存储，不明文展示（输入框 obscureText）
- **文件格式限制**：仅允许选择 wav/mp3/m4a，并以文件头魔数为准判定真实格式，无法识别的文件不会发起请求
- **文件大小限制**：客户端按 Base64 编码后 ≤ 10MB 校验（原始字节 ≤ 7,864,320 B）
- **m4a 时长限制**：转码后按 16kHz 单声道估算，超过 240 秒直接报错，不会解码
- **临时文件**：转码产物写入系统临时目录，请求结束（含异常）后立即删除
- **传输安全**：全程 HTTPS，API Key 通过 Authorization Header 传递

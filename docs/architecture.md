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
  ┌─ wav / mp3 且原始字节 ≤ 7,864,320 B：直接进入上传
  └─ 其余（m4a 或长录音）：audio_converter 取时长 → 校验 ≤ 2 小时
       → 统一转 16kHz 单声道 16-bit WAV（临时文件）
       ↓
  ┌─ 转码后 ≤ 10MB Base64 上限：单请求路径
  │    构造 data:audio/wav;base64,... → POST /chat/completions → 解析结果
  └─ 超长录音：分段路径（audio_segment_transcriber）
       解析 WAV data 块 → 按 60 秒切段（≤125 段，即约 2 小时）
       → 每段重拼 44 字节 WAV 头 → 4 并发上传识别
       → 429/5xx/超时按 1s/2s/4s 退避重试（每段最多 4 次尝试）
       → 任一段最终失败：取消其余段并报"第 x/N 段识别失败"
       → 全部成功后按段序换行拼接
       ↓
在界面显示识别结果（可复制、可导出 .txt），临时 WAV 立即清理
```

## 技术选型理由

### ASR 模型：MiMo-V2.5-ASR（官方 API）
- **选择理由**：小米官方提供云端 API，无需本地部署模型
- **优势**：支持中英双语、方言、歌词、噪声环境，OpenAI 兼容接口
- **限制**：官方仅声明 wav 和 mp3，Base64 编码后上限 10MB；m4a 由客户端先转码成 wav 再上传，长录音通过客户端分段并行请求绕过单次体积上限

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
| `audio_format.dart` | 纯 Dart 策略层：文件头嗅探格式、MIME 映射、Base64 体积上限、分段计划/WAV 头构造与解析、文本合并、错误文案 |
| `audio_converter.dart` | 音频 → 16kHz 单声道 WAV 本地转码、时长预检、临时文件清理 |
| `audio_segment_transcriber.dart` | 长录音分段：按 60s 切片、4 并发请求、退避重试、失败取消、按序合并 |
| `asr_service.dart` | 编排识别流程（嗅探 → 转码 → 单请求或分段 → POST）、响应解析、阶段/进度回调、Dio 释放 |
| `home_screen.dart` | 主界面 UI、文件选择与格式预检、阶段与 x/N 分段进度提示、结果展示 / 复制 / 导出 TXT |

## 安全设计

- **API Key 存储**：使用 shared_preferences 本地存储，不明文展示（输入框 obscureText）
- **文件格式限制**：仅允许选择 wav/mp3/m4a，并以文件头魔数为准判定真实格式，无法识别的文件不会发起请求
- **文件大小限制**：单次上传按 Base64 编码后 ≤ 10MB 校验（原始字节 ≤ 7,864,320 B）；超限长录音走分段路径
- **时长限制**：分段转写前按音频时长预检，超过 2 小时直接报错、不会解码；分段计划再兜底 ≤125 段
- **并发限制**：分段请求以 4 个 worker 并行，429/5xx/超时退避重试，避免瞬时压垮服务端
- **临时文件**：转码产物写入系统临时目录，请求结束（含异常）后立即删除
- **传输安全**：全程 HTTPS，API Key 通过 Authorization Header 传递

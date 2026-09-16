# 架构设计文档

## 系统架构

```
┌─────────────────────────┐       HTTPS POST        ┌──────────────────────────┐
│     Flutter 客户端       │ ──────────────────────→  │   MiMo 官方 API          │
│    (Windows / Android)   │ ←──────────────────────  │   api.xiaomimimo.com     │
│                          │                          │                          │
│  ┌─────────────────┐    │  /v1/chat/completions    │  • MiMo-V2.5-ASR 模型    │
│  │   file_picker   │    │  Authorization: Bearer   │  • 自动语言检测            │
│  │   选择 wav/mp3  │    │  Content-Type: JSON      │  • 流式/非流式返回         │
│  └─────────────────┘    │                          │                          │
│  ┌─────────────────┐    │  Request:                │                          │
│  │   dio (HTTP)    │    │  { model, messages:      │                          │
│  │   Base64 编码   │    │    [{ role, content:     │                          │
│  │   发送请求      │    │      [{ input_audio }] }]│                          │
│  └─────────────────┘    │  }                       │                          │
│  ┌─────────────────┐    │                          │                          │
│  │   UI 界面       │    │  Response:               │                          │
│  │   显示结果      │    │  { choices: [{ message   │                          │
│  │   可复制        │    │    : { content } }] }    │                          │
│  └─────────────────┘    │                          │                          │
└─────────────────────────┘                          └──────────────────────────┘
```

**架构优势**：无需自建服务器，Flutter 客户端直接调用 MiMo 官方 API，部署简单、维护成本低。

## 数据流

```
用户选择音频文件 (wav/mp3) → Flutter file_picker 获取文件路径
       ↓
读取文件字节 → Base64 编码 → 构造 data:audio/wav;base64,... 格式
       ↓
构造 OpenAI 兼容格式请求体 (chat/completions)
       ↓
POST 到 https://api.xiaomimimo.com/v1/chat/completions
Authorization: Bearer <API_KEY>
       ↓
解析响应 JSON → choices[0].message.content
       ↓
在界面显示识别结果（可复制）
```

## 技术选型理由

### ASR 模型：MiMo-V2.5-ASR（官方 API）
- **选择理由**：小米官方提供云端 API，无需本地部署模型
- **优势**：支持中英双语、方言、歌词、噪声环境，OpenAI 兼容接口
- **限制**：仅支持 wav 和 mp3 格式，Base64 编码后上限 10MB

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
| `asr_service.dart` | 封装 MiMo API 调用、Base64 编码、响应解析 |
| `home_screen.dart` | 主界面 UI、文件选择、结果展示、设置对话框 |

## 安全设计

- **API Key 存储**：使用 shared_preferences 本地存储，不明文展示（输入框 obscureText）
- **文件格式限制**：客户端仅允许选择 wav/mp3，与 API 要求一致
- **文件大小限制**：客户端检查 Base64 后不超过 10MB
- **传输安全**：全程 HTTPS，API Key 通过 Authorization Header 传递

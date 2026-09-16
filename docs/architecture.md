# 架构设计文档

## 系统架构

```
┌─────────────────────────┐         HTTP/REST          ┌──────────────────────────┐
│     Flutter 客户端       │ ─────────────────────────→ │    Python API Server     │
│    (Windows / Android)   │ ←───────────────────────── │     (FastAPI + GPU)      │
│                          │                            │                          │
│  ┌─────────────────┐    │   POST /transcribe         │  ┌────────────────────┐  │
│  │   file_picker   │    │   Content-Type:            │  │  MiMo-V2.5-ASR     │  │
│  │   选择音频文件   │    │   multipart/form-data      │  │  8B 参数模型        │  │
│  └─────────────────┘    │                            │  └────────────────────┘  │
│  ┌─────────────────┐    │   Headers:                 │  ┌────────────────────┐  │
│  │   dio (HTTP)    │    │   X-API-Key: <key>         │  │  MiMo-Audio-       │  │
│  │   发送请求      │    │                            │  │  Tokenizer          │  │
│  └─────────────────┘    │                            │  └────────────────────┘  │
│  ┌─────────────────┐    │   Response:                │                          │
│  │   UI 界面       │    │   { "text": "...",         │  ┌────────────────────┐  │
│  │   显示结果      │    │     "duration": 2.5 }      │  │  FastAPI + uvicorn │  │
│  └─────────────────┘    │                            │  │  Web 服务器         │  │
│                          │                            │  └────────────────────┘  │
└─────────────────────────┘                            └──────────────────────────┘
```

## 数据流

```
用户选择音频文件 → Flutter file_picker 获取文件路径
       ↓
点击"开始识别" → dio 发送 multipart POST 到 /transcribe
       ↓
FastAPI 接收文件 → 保存到临时目录
       ↓
调用 model.asr_sft(filePath) → MiMo-V2.5-ASR 推理
       ↓
返回 JSON { text, duration, language }
       ↓
Flutter 解析响应 → 在界面显示识别结果（可复制）
```

## 技术选型理由

### ASR 模型：MiMo-V2.5-ASR
- **选择理由**：小米开源的 SOTA ASR 模型，8B 参数
- **优势**：支持中文方言、中英混杂、歌词识别、噪声环境、多人对话
- **限制**：需要 GPU（CUDA >= 12.0），不能直接在移动设备运行
- **替代方案**：无（用户指定）

### API 框架：FastAPI
- **选择理由**：异步支持好、自带 OpenAPI 文档、类型安全
- **优势**：自动生成 /docs 接口文档、性能优异
- **替代方案**：Flask（更简单但无自动文档）、Django（过重）

### 跨平台：Flutter
- **选择理由**：一套代码同时编译 Windows 和 Android
- **优势**：UI 一致性好、Hot Reload 开发效率高、Material Design 3
- **替代方案**：React Native（Windows 支持弱）、原生双端（开发成本高）

### HTTP 客户端：Dio
- **选择理由**：Flutter 生态中最成熟的 HTTP 库
- **优势**：支持拦截器、FormData、超时配置、取消请求
- **替代方案**：http（更轻但功能少）

## 模块职责

### 服务端模块
| 模块 | 职责 |
|------|------|
| `main.py` | FastAPI 应用入口、路由定义、认证中间件 |
| 模型加载 | 初始化 MiMo-Audio-Tokenizer 和 MiMo-V2.5-ASR |
| 文件处理 | 接收上传音频、保存临时文件、处理后清理 |
| API 认证 | 验证 X-API-Key 请求头 |

### 客户端模块
| 模块 | 职责 |
|------|------|
| `main.dart` | Flutter 应用入口、主题配置、初始化 |
| `config.dart` | 配置管理（API 地址、Key）、持久化存储 |
| `asr_service.dart` | 封装 HTTP 请求、健康检查、转写调用 |
| `home_screen.dart` | 主界面 UI、文件选择、结果展示、设置对话框 |

## 安全设计

- **API Key 认证**：通过 `X-API-Key` 请求头传递，服务端校验
- **文件大小限制**：100MB 上限，防止滥用
- **临时文件清理**：处理完成后立即删除上传的音频文件
- **CORS 配置**：默认允许所有来源（生产环境应限制）
- **客户端密钥存储**：使用 shared_preferences 本地存储，不明文展示

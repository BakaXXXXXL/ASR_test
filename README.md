# ASR 语音转文字应用

基于小米 **MiMo-V2.5-ASR** 官方 API 的跨平台语音转文字客户端，支持 Windows 和 Android。

## 功能特性

- **多文件批量并发转写（多开队列）**：支持一次性导入复数个音频文件排队或并行识别，卡片式独立展示各文件进度、状态与转写文本
- **单任务独立并发（Per-Task Concurrency）**：多个音频文件同时转写时互不挤占切片并发额度，每个任务独立享有最高 16 路并发请求能力，各任务全速并行处理
- **折叠卡片流与双端质感**：Windows 端采用微软 WinUI 3 (Fluent Design) 原生卡片与 Acrylic 质感，Android 端采用 Material Design 3 界面；每个任务支持独立折叠展开、复制、单文件导出或一键批量导出
- **长录音智能分段转写**：超长录音自动转成 16kHz 单声道 WAV，基于 VAD 短时能量检测在自然停顿处智能切片（50s~65s），支持两阶段断点自愈（最长 2 小时）
- **多模型服务商架构**：支持 OpenAI Audio 规范与 Chat 规范，预设 MiMo、硅基流动、Groq、OpenAI、本地自建及自定义 API
- **结果导出**：支持一键复制，支持选择目录分别导出各文件的同名 `.txt` 或合并导出汇总文件

## 快速开始

### 1. 获取 API Key

访问 [MiMo 开放平台](https://platform.xiaomimimo.com) 注册并获取 API Key。

### 2. 下载发行版

从 [Releases](../../releases) 页面下载最新版本：
- **Windows**: `ASR-Client-Windows.zip` — 解压后运行 `asr_client.exe`
- **Android**: `app-release.apk` — 安装后打开

### 3. 源码构建

```bash
cd client/

# 环境要求：Flutter >= 3.38（Dart >= 3.10.8，audio_decoder 插件要求）
# 生成平台文件（首次）
flutter create . --platforms=windows,android

# 安装依赖
flutter pub get

# 运行 / 构建
flutter run -d windows
flutter run -d android
flutter build windows --release
flutter build apk --release
```

### 4. 使用

1. 打开应用，点击右上角齿轮图标配置 API Key 与全局并发度（1~16 路）
2. 点击"添加音频"或上传区域选择一个或多个 wav、mp3 或 m4a 文件
3. 点击"全部开始"或单个任务的开始按钮，每个任务将各自以最高 16 路独立并发全速转写
4. 界面卡片实时展示转码与分段进度（最长 2 小时录音自动智能切片与自愈）
5. 识别完成后可展开卡片复制单文本、单独导出，或点击"批量导出"选择目录一键保存所有文件的同名 `.txt`

## 项目结构

```
ASR_test/
├── .github/workflows/
│   └── build-release.yml    # CI/CD：自动构建 + GitHub Release
├── client/                  # Flutter 客户端
│   ├── lib/
│   │   ├── main.dart        # 入口（含桌面窗口管理）
│   │   ├── config.dart      # 配置管理与多服务商预设
│   │   ├── models/
│   │   │   └── transcribe_task.dart # 任务实体与生命周期模型
│   │   ├── services/
│   │   │   ├── asr_service.dart     # 双协议 ASR 调用与容灾重试编排
│   │   │   ├── async_semaphore.dart # 全局受控并发信号量
│   │   │   ├── batch_transcribe_manager.dart # 批量任务流调度管理器
│   │   │   ├── batch_export_helper.dart      # 单文件/批量/合并导出辅助类
│   │   │   ├── audio_format.dart    # 格式嗅探 / MIME / 上限与 VAD 策略
│   │   │   ├── audio_converter.dart # → 16kHz 单声道 WAV 本地转码
│   │   │   └── audio_segment_transcriber.dart # 长录音分段并行转写 + 协同限流退避
│   │   └── screens/
│   │       ├── home_screen.dart     # 自适应入口分流
│   │       ├── windows/fluent_home_screen.dart   # Windows WinUI 3 折叠卡片流
│   │       └── android/material_home_screen.dart # Android Material 3 卡片流
│   ├── test/
│   │   ├── audio_format_test.dart
│   │   ├── long_audio_fault_tolerance_test.dart
│   │   ├── multi_provider_test.dart
│   │   └── batch_transcribe_test.dart # 批量并发与调度单元测试
│   └── pubspec.yaml
├── docs/                    # 技术文档
│   ├── architecture.md
│   ├── api-reference.md
│   └── deployment.md
└── README.md
```

## 文档

- [架构设计](docs/architecture.md) — 系统架构、数据流、技术选型
- [API 接口文档](docs/api-reference.md) — MiMo 官方 API 接口说明
- [部署指南](docs/deployment.md) — 构建步骤和常见问题

## 技术栈

| 组件 | 技术 |
|------|------|
| ASR 服务 | MiMo-V2.5-ASR 官方 API |
| API 格式 | OpenAI 兼容 (chat/completions) |
| 跨平台客户端 | Flutter 3.x (Dart) |
| Windows WinUI 3 | fluent_ui (Fluent Design System) |
| HTTP 客户端 | Dio |
| 文件选择 | file_picker |
| 音频解码 | audio_decoder（系统原生解码器，无需 FFmpeg） |
| 桌面窗口 | window_manager |
| CI/CD | GitHub Actions |

## 许可证

MIT

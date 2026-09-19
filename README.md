# ASR 语音转文字应用

基于小米 **MiMo-V2.5-ASR** 官方 API 的跨平台语音转文字客户端，支持 Windows 和 Android。

## 功能特性

- 音频文件导入转文字（支持 wav / mp3 / m4a）
- 长录音分段转写：超长录音自动转成 16kHz 单声道 WAV，按 60 秒分段并行识别（最长 2 小时）
- 多语言支持（中文/英文/自动检测）
- Windows 桌面端 (.exe) + Android 移动端 (APK)
- Windows 端采用微软 WinUI 3 (Fluent Design) 原生质感界面，Android 端采用 Material Design 3 界面，均支持系统级明暗主题
- API Key 认证保护
- 识别结果一键复制或导出为 .txt 文件

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

1. 打开应用，点击右上角齿轮图标配置 API Key
2. 点击音频上传区域选择 wav、mp3 或 m4a 文件
3. 选择语言（推荐自动检测）
4. 点击"开始识别"等待结果（超过单次上传上限的长录音会自动分段并行转写，界面显示"正在转写 x/N 段"进度，最长 2 小时）
5. 识别完成后可一键复制或点击下载按钮导出为 .txt

## 项目结构

```
ASR_test/
├── .github/workflows/
│   └── build-release.yml    # CI/CD：自动构建 + GitHub Release
├── client/                  # Flutter 客户端
│   ├── lib/
│   │   ├── main.dart        # 入口（含桌面窗口管理）
│   │   ├── config.dart      # 配置管理
│   │   ├── services/
│   │   │   ├── asr_service.dart     # MiMo API 调用 + 识别流程编排
│   │   │   ├── audio_format.dart    # 格式嗅探 / MIME / 上限与分段策略（纯 Dart，可单测）
│   │   │   ├── audio_converter.dart # → 16kHz 单声道 WAV 本地转码（系统原生解码器）
│   │   │   └── audio_segment_transcriber.dart # 长录音 60s 分段并行转写 + 合并
│   │   └── screens/
│   │       └── home_screen.dart  # 主界面 UI
│   ├── test/
│   │   └── audio_format_test.dart # 格式与上限策略单元测试
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

# ASR 语音转文字应用

基于小米 **MiMo-V2.5-ASR** 官方 API 的跨平台语音转文字应用，支持 Windows 和 Android 双端。

## 功能特性

- 音频文件导入转文字（支持 wav / mp3）
- 多语言支持（中文/英文/自动检测）
- Windows 桌面端 + Android 移动端
- API Key 认证保护
- 识别结果一键复制

## 项目结构

```
ASR_test/
├── client/          # Flutter 客户端（Windows + Android）
├── docs/            # 技术文档
└── README.md
```

## 快速开始

### 1. 获取 API Key

访问 [MiMo 开放平台](https://platform.xiaomimimo.com) 注册并获取 API Key。

### 2. 构建客户端

```bash
cd client/

# 首次需要生成平台目录
flutter create . --platforms=windows,android

# 安装依赖
flutter pub get

# 构建 Windows
flutter build windows --release

# 构建 Android APK
flutter build apk --release
```

### 3. 使用

1. 打开应用，点击右上角齿轮图标配置 API Key
2. 点击"选择音频文件"选择 wav 或 mp3 文件
3. 选择语言（推荐自动检测）
4. 点击"开始识别"等待结果
5. 识别完成后点击复制按钮复制结果

## 文档

- [架构设计](docs/architecture.md) — 系统架构、数据流、技术选型
- [API 接口文档](docs/api-reference.md) — MiMo 官方 API 接口说明
- [部署指南](docs/deployment.md) — 构建步骤和常见问题

## 技术栈

| 组件 | 技术 |
|------|------|
| ASR 服务 | MiMo-V2.5-ASR 官方 API |
| API 格式 | OpenAI 兼容 (chat/completions) |
| 跨平台客户端 | Flutter (Dart) |
| HTTP 客户端 | Dio |
| 文件选择 | file_picker |

## 许可证

MIT

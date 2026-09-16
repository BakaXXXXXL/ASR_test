# ASR 语音转文字应用

基于小米 **MiMo-V2.5-ASR** 模型的跨平台语音转文字应用，支持 Windows 和 Android 双端。

## 功能特性

- 音频文件导入转文字（支持 wav/mp3/m4a/flac/ogg/aac/wma/webm）
- 多语言支持（中文/英文/自动检测）
- Windows 桌面端 + Android 移动端
- API Key 认证保护
- 识别结果一键复制

## 项目结构

```
ASR_test/
├── server/          # Python API 服务端（FastAPI + MiMo-V2.5-ASR）
├── client/          # Flutter 客户端（Windows + Android）
└── docs/            # 技术文档
```

## 快速开始

### 1. 部署服务端

**环境要求**：Linux + Python 3.12+ + CUDA >= 12.0 + GPU >= 16GB 显存

```bash
# 下载模型
pip install huggingface-hub
hf download XiaomiMiMo/MiMo-V2.5-ASR --local-dir ./models/MiMo-V2.5-ASR
hf download XiaomiMiMo/MiMo-Audio-Tokenizer --local-dir ./models/MiMo-Audio-Tokenizer

# 安装依赖
cd server/
pip install -r requirements.txt
pip install flash-attn==2.7.4.post1

# 配置
cp .env.example .env
# 编辑 .env 设置 MODEL_PATH 和 API_KEY

# 启动
python main.py
```

服务启动后访问 `http://localhost:8000/docs` 查看 API 文档。

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

1. 打开应用，点击右上角齿轮图标配置 API 地址和 Key
2. 点击"选择音频文件"选择要识别的音频
3. 选择语言（推荐自动检测）
4. 点击"开始识别"等待结果
5. 识别完成后点击复制按钮复制结果

## 文档

- [架构设计](docs/architecture.md) — 系统架构、数据流、技术选型
- [API 接口文档](docs/api-reference.md) — 接口格式、参数说明、调用示例
- [部署指南](docs/deployment.md) — 详细的部署步骤和常见问题

## 技术栈

| 组件 | 技术 |
|------|------|
| ASR 模型 | MiMo-V2.5-ASR（小米开源，8B 参数） |
| API 框架 | FastAPI + uvicorn |
| 跨平台客户端 | Flutter (Dart) |
| HTTP 客户端 | Dio |
| 文件选择 | file_picker |

## 许可证

MIT

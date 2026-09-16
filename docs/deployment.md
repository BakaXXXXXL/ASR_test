# 部署指南

## 一、服务端部署

### 1.1 环境要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Linux（推荐 Ubuntu 22.04+） |
| Python | 3.12+ |
| CUDA | >= 12.0 |
| GPU 显存 | >= 16GB（推荐 24GB+） |
| 内存 | >= 32GB |
| 磁盘 | >= 20GB（模型文件约 16GB） |

### 1.2 下载模型

```bash
pip install huggingface-hub

# 下载 ASR 模型
hf download XiaomiMiMo/MiMo-V2.5-ASR --local-dir ./models/MiMo-V2.5-ASR

# 下载 Audio Tokenizer
hf download XiaomiMiMo/MiMo-Audio-Tokenizer --local-dir ./models/MiMo-Audio-Tokenizer
```

### 1.3 安装依赖

```bash
cd server/
pip install -r requirements.txt
pip install flash-attn==2.7.4.post1
```

如果 flash-attn 编译太慢，可以下载预编译 wheel：
```bash
# 根据你的 CUDA 和 Python 版本选择对应的 wheel
# https://github.com/Dao-AILab/flash-attention/releases
pip install flash_attn-2.7.4.post1+cu12torch2.6cxx11abiFALSE-cp312-cp312-linux_x86_64.whl
```

### 1.4 配置环境变量

```bash
cp .env.example .env
# 编辑 .env 文件，设置 MODEL_PATH、API_KEY 等
```

### 1.5 启动服务

```bash
python main.py
```

或使用 uvicorn 直接启动：
```bash
uvicorn main:app --host 0.0.0.0 --port 8000
```

### 1.6 验证服务

```bash
# 健康检查
curl http://localhost:8000/health

# 测试转写
curl -X POST http://localhost:8000/transcribe \
  -H "X-API-Key: your-api-key" \
  -F "file=@test.wav" \
  -F "language=auto"
```

访问 `http://localhost:8000/docs` 查看交互式 API 文档。

---

## 二、客户端构建

### 2.1 环境要求

| 项目 | 要求 |
|------|------|
| Flutter SDK | >= 3.7.0 |
| Android Studio | 用于 Android 构建 |
| Visual Studio | 用于 Windows 构建（含 C++ 桌面开发） |

### 2.2 创建 Flutter 项目（首次）

如果 `client/` 目录中还没有 `android/` 和 `windows/` 平台目录：

```bash
cd client/
flutter create . --platforms=windows,android
```

这会生成 `android/` 和 `windows/` 目录及其平台配置文件。

### 2.3 安装依赖

```bash
cd client/
flutter pub get
```

### 2.4 构建 Windows

```bash
flutter build windows --release
```

输出位于 `client/build/windows/x64/runner/Release/`。

### 2.5 构建 Android APK

```bash
flutter build apk --release
```

输出位于 `client/build/app/outputs/flutter-apk/app-release.apk`。

### 2.6 配置 API 地址

应用启动后，点击右上角齿轮图标，在设置对话框中填入：
- **API 地址**：服务端地址，如 `http://192.168.1.100:8000`
- **API Key**：与服务端 `.env` 中配置的 API_KEY 一致

---

## 三、常见问题

### 模型加载失败
- 确认 CUDA 版本 >= 12.0：`nvcc --version`
- 确认 GPU 显存足够：`nvidia-smi`
- 确认模型文件完整下载

### Android 无法连接服务端
- 确保手机和服务器在同一局域网
- Android 默认不允许 HTTP 明文请求，需要配置 `android:usesCleartextTraffic="true"`
- 或使用 HTTPS

### Windows 构建失败
- 确认安装了 Visual Studio 及 C++ 桌面开发工作负载
- 运行 `flutter doctor` 检查环境

### 转写超时
- 检查音频文件大小，大文件耗时更长
- 默认超时 5 分钟，可在 `asr_service.dart` 中调整 `receiveTimeout`

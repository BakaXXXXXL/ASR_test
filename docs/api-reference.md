# API 接口文档

**Base URL**: `http://<server-host>:8000`

## 认证

所有需要认证的接口通过请求头传递 API Key：

```
X-API-Key: your-secret-api-key
```

如果服务端未配置 `API_KEY` 环境变量，则认证被禁用。

---

## 接口列表

### GET /health

健康检查接口，无需认证。

**请求**：
```http
GET /health HTTP/1.1
```

**响应** (200)：
```json
{
  "status": "ok",
  "model_loaded": true
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| status | string | 服务状态，固定为 `"ok"` |
| model_loaded | boolean | 模型是否已加载 |

---

### POST /transcribe

音频转文字接口，需要认证。

**请求**：
```http
POST /transcribe HTTP/1.1
Content-Type: multipart/form-data
X-API-Key: your-secret-api-key
```

**请求参数** (form-data)：

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| file | File | 是 | 音频文件 |
| language | string | 否 | 语言标签：`auto`（默认）/ `chinese` / `english` |

**支持的音频格式**：
`.wav`, `.mp3`, `.m4a`, `.flac`, `.ogg`, `.aac`, `.wma`, `.webm`

**文件大小限制**：100MB

**响应** (200)：
```json
{
  "text": "这是识别出来的文字内容。",
  "duration": 2.35,
  "language": "auto"
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| text | string | 识别出的文字 |
| duration | number | 识别耗时（秒） |
| language | string | 使用的语言标签 |

**错误响应**：

| 状态码 | 说明 |
|--------|------|
| 400 | 不支持的音频格式 / 文件过大 |
| 401 | API Key 无效 |
| 500 | 识别过程出错 |
| 503 | 模型未加载 |

**错误响应示例** (400)：
```json
{
  "detail": "Unsupported format: .txt. Supported: .aac, .flac, .m4a, .mp3, .ogg, .wma, .wav, .webm"
}
```

---

## 调用示例

### curl
```bash
curl -X POST http://localhost:8000/transcribe \
  -H "X-API-Key: your-secret-api-key" \
  -F "file=@/path/to/audio.wav" \
  -F "language=auto"
```

### Python
```python
import requests

resp = requests.post(
    "http://localhost:8000/transcribe",
    headers={"X-API-Key": "your-secret-api-key"},
    files={"file": open("audio.wav", "rb")},
    data={"language": "auto"},
)
print(resp.json()["text"])
```

### 自动文档

服务启动后访问 `http://localhost:8000/docs` 可查看 FastAPI 自动生成的交互式 API 文档（Swagger UI）。

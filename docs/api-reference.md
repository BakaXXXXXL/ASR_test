# API 接口文档

本应用直接调用小米 MiMo 官方 API，接口为 OpenAI 兼容格式。

**官方文档**: https://mimo.mi.com/docs/zh-CN/quick-start/usage-guide/audio/Speech-Recognition

**Base URL**: `https://api.xiaomimimo.com/v1`

## 认证

通过 Bearer Token 认证：

```
Authorization: Bearer <your-mimo-api-key>
```

API Key 在 https://platform.xiaomimimo.com/console 获取。

---

## POST /chat/completions

音频转文字接口。

### 请求体

```json
{
  "model": "mimo-v2.5-asr",
  "messages": [
    {
      "role": "user",
      "content": [
        {
          "type": "input_audio",
          "input_audio": {
            "data": "data:audio/wav;base64,<BASE64_ENCODED_AUDIO>"
          }
        }
      ]
    }
  ],
  "extra_body": {
    "asr_options": {
      "language": "zh"
    }
  }
}
```

### 参数说明

| 参数 | 类型 | 必填 | 说明 |
|------|------|------|------|
| model | string | 是 | 固定为 `mimo-v2.5-asr` |
| messages[].role | string | 是 | 固定为 `user` |
| messages[].content[].type | string | 是 | 固定为 `input_audio` |
| messages[].content[].input_audio.data | string | 是 | Data URL 格式的 Base64 音频 |
| extra_body.asr_options.language | string | 否 | `auto`（默认）/ `zh` / `en` |

### 音频格式要求

- 服务端仅接受 **wav** 和 **mp3** 格式
- 需转换为 Base64 编码，**Base64 字符串**大小上限 **10MB**（即原始字节 ≤ 7,864,320 B）
- Data URL 格式：
  - wav: `data:audio/wav;base64,<BASE64>`
  - mp3: `data:audio/mpeg;base64,<BASE64>`
- **m4a 不在服务端支持列表内**：客户端会先把 m4a 转成 16kHz 单声道 16-bit WAV（`data:audio/wav;base64,...`）再上传。按此规格估算，m4a 可直接识别的时长约 **4 分钟**（转码后 Base64 需 ≤ 10MB）
- 客户端额外做了一层本地校验：
  - 以文件头魔数判定真实格式（`RIFF....WAVE` → wav，`ID3` / MPEG 同步字 → mp3，偏移 4 起为 `ftyp` → m4a），无法识别直接报错
  - 转码前先读时长，超过 240 秒直接报错，不发请求

### 响应格式（非流式）

```json
{
  "choices": [
    {
      "message": {
        "content": "这是识别出来的文字内容。"
      }
    }
  ]
}
```

### 调用示例（Python）

```python
import os, base64
from openai import OpenAI

client = OpenAI(
    api_key=os.environ.get("MIMO_API_KEY"),
    base_url="https://api.xiaomimimo.com/v1"
)

with open("audio.wav", "rb") as f:
    audio_b64 = base64.b64encode(f.read()).decode()

completion = client.chat.completions.create(
    model="mimo-v2.5-asr",
    messages=[{
        "role": "user",
        "content": [{
            "type": "input_audio",
            "input_audio": {"data": f"data:audio/wav;base64,{audio_b64}"}
        }]
    }],
    extra_body={"asr_options": {"language": "zh"}}
)
print(completion.choices[0].message.content)
```

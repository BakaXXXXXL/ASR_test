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

- 仅支持 **wav** 和 **mp3** 格式
- 需转换为 Base64 编码，编码后大小上限 **10MB**
- Data URL 格式：
  - wav: `data:audio/wav;base64,<BASE64>`
  - mp3: `data:audio/mpeg;base64,<BASE64>`

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

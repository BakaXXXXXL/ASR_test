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
- **m4a 不在服务端支持列表内**：客户端会先把 m4a 转成 16kHz 单声道 16-bit WAV（`data:audio/wav;base64,...`）再上传
- 客户端额外做了一层本地校验：
  - 以文件头魔数判定真实格式（`RIFF....WAVE` → wav，`ID3` / MPEG 同步字 → mp3，偏移 4 起为 `ftyp` → m4a），无法识别直接报错
  - 音频时长超过 2 小时直接报错，不发请求

### 长录音分段转写（客户端行为）

服务端对单次请求没有分段能力，客户端在本地把长录音切开、并行请求再合并：

- 触发条件：转码/原始文件 Base64 后会超过 10MB（约等效 4 分钟 16kHz WAV）
- 分段：统一转成 16kHz 单声道 WAV 后按 **60 秒**切段，尾段可短；最多 **125 段**（≈2 小时）
- 并发：**4 个请求并行**；官方未声明 QPS/并发限制，若被限流可下调
- 重试：单段遇 429/5xx/超时按 1s、2s、4s 退避，最多 4 次尝试；仍失败则取消其余段并报"第 x/N 段识别失败"，不静默丢内容
- 合并：各段纯文本按段序以换行拼接（响应无时间戳信息，切点可能落在句中，属已知限制）

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

import os
import tempfile
import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# Global model instance
model = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global model
    model_path = os.getenv("MODEL_PATH", "./models/MiMo-V2.5-ASR")
    tokenizer_path = os.getenv("TOKENIZER_PATH", "./models/MiMo-Audio-Tokenizer")

    if Path(model_path).exists():
        try:
            from src.mimo_audio.mimo_audio import MimoAudio
            model = MimoAudio(
                model_path=model_path,
                tokenizer_path=tokenizer_path,
            )
            print(f"Model loaded from {model_path}")
        except Exception as e:
            print(f"Failed to load model: {e}")
    else:
        print(f"Model path not found: {model_path}")

    yield

    model = None


app = FastAPI(
    title="MiMo-V2.5-ASR API",
    description="Speech recognition API powered by MiMo-V2.5-ASR",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class TranscribeResponse(BaseModel):
    text: str
    duration: float
    language: str | None = None


class HealthResponse(BaseModel):
    status: str
    model_loaded: bool


SUPPORTED_FORMATS = {".wav", ".mp3", ".m4a", ".flac", ".ogg", ".aac", ".wma", ".webm"}
MAX_FILE_SIZE = 100 * 1024 * 1024  # 100MB


def verify_api_key(x_api_key: str | None = Header(None)) -> None:
    expected_key = os.getenv("API_KEY")
    if expected_key and x_api_key != expected_key:
        raise HTTPException(status_code=401, detail="Invalid API key")


@app.get("/health", response_model=HealthResponse)
async def health():
    return HealthResponse(
        status="ok",
        model_loaded=model is not None,
    )


@app.post("/transcribe", response_model=TranscribeResponse)
async def transcribe(
    file: UploadFile = File(...),
    language: str = Form(default="auto"),
    x_api_key: str | None = Header(None),
):
    verify_api_key(x_api_key)

    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    suffix = Path(file.filename or "").suffix.lower()
    if suffix not in SUPPORTED_FORMATS:
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported format: {suffix}. Supported: {', '.join(sorted(SUPPORTED_FORMATS))}",
        )

    content = await file.read()
    if len(content) > MAX_FILE_SIZE:
        raise HTTPException(status_code=400, detail="File too large (max 100MB)")

    audio_tag = None
    if language == "chinese":
        audio_tag = "<chinese>"
    elif language == "english":
        audio_tag = "<english>"

    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=suffix)
    try:
        tmp.write(content)
        tmp.close()

        start = time.time()
        kwargs = {}
        if audio_tag:
            kwargs["audio_tag"] = audio_tag
        text = model.asr_sft(tmp.name, **kwargs)
        duration = time.time() - start

        return TranscribeResponse(
            text=text,
            duration=round(duration, 2),
            language=language,
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Transcription failed: {str(e)}")
    finally:
        try:
            os.unlink(tmp.name)
        except OSError:
            pass


if __name__ == "__main__":
    import uvicorn

    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8000"))
    uvicorn.run(app, host=host, port=port)

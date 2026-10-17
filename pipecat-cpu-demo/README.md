# Pipecat CPU local demo

Local **CPU-only** cascade voice agent using [Pipecat](https://github.com/pipecat-ai/pipecat):

**SmallWebRTC** → Silero VAD → Whisper (tiny/base) → Ollama LLM → Kokoro TTS

No Daily account. No LiveKit. No GPU required (latency will be higher than cloud).

## Why SmallWebRTC instead of Daily?

| | SmallWebRTC (this demo) | Daily |
|--|-------------------------|-------|
| Account / API key | None | Daily account + API key |
| Media path | Browser ↔ your laptop (P2P) | Daily global SFU |
| Cost | $0 transport | External dependency |
| Fit | Local CPU POC | Production / multi-region |

Pipecat recommends SmallWebRTC for local/self-host development and Daily when you need managed global routing. This directory is a laptop demo, so we use SmallWebRTC only.

## Prerequisites

1. **Python 3.11+** and [`uv`](https://docs.astral.sh/uv/)
2. **[Ollama](https://ollama.com/)** running locally with a small model:

```bash
ollama serve
ollama pull llama3.2:1b
```

## Setup

```bash
cd pipecat-cpu-demo
cp .env.example .env
uv sync
```

## Run

```bash
uv run bot.py -t webrtc
```

Then open the prebuilt client:

**http://localhost:7860/client/**

Allow microphone access and talk to the bot. First run downloads Whisper + Kokoro model files.

## Notes

- This is a **cascade** pipeline, not native full duplex.
- Expect multi-second latency on CPU; that is expected.
- Keep the LiveKit agent in `../livekit-voice-agent` for Cloud / duplex experiments.

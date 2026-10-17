"""CPU-only local voice demo with Pipecat SmallWebRTC (no Daily).

Pipeline: SmallWebRTC -> Silero VAD -> Whisper (CPU) -> Ollama -> Kokoro TTS
"""

from __future__ import annotations

import os

from dotenv import load_dotenv
from loguru import logger

load_dotenv(override=True)

logger.info("Loading Silero VAD / pipeline imports...")

from pipecat.audio.vad.silero import SileroVADAnalyzer
from pipecat.frames.frames import LLMRunFrame
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import (
    LLMContextAggregatorPair,
    LLMUserAggregatorParams,
)
from pipecat.runner.types import RunnerArguments
from pipecat.runner.utils import create_transport
from pipecat.services.kokoro.tts import KokoroTTSService
from pipecat.services.ollama.llm import OLLamaLLMService
from pipecat.services.whisper.stt import Model, WhisperSTTService
from pipecat.transports.base_transport import BaseTransport, TransportParams

logger.info("Imports ready")

SYSTEM_INSTRUCTION = (
    "You are a concise local CPU voice demo assistant. "
    "Keep replies under two short sentences."
)


def _whisper_model() -> Model:
    name = os.getenv("WHISPER_MODEL", "tiny").strip().lower()
    mapping = {
        "tiny": Model.TINY,
        "base": Model.BASE,
        "small": Model.SMALL,
    }
    return mapping.get(name, Model.TINY)


async def run_bot(transport: BaseTransport, runner_args: RunnerArguments) -> None:
    logger.info("Starting CPU cascade bot")

    stt = WhisperSTTService(
        device="cpu",
        compute_type="int8",
        settings=WhisperSTTService.Settings(model=_whisper_model()),
    )

    llm = OLLamaLLMService(
        base_url=os.getenv("OLLAMA_BASE_URL", "http://localhost:11434/v1"),
        settings=OLLamaLLMService.Settings(
            model=os.getenv("OLLAMA_MODEL", "llama3.2:1b"),
            system_instruction=SYSTEM_INSTRUCTION,
        ),
    )

    tts = KokoroTTSService(
        settings=KokoroTTSService.Settings(
            voice="af_heart",
        ),
    )

    context = LLMContext()
    user_aggregator, assistant_aggregator = LLMContextAggregatorPair(
        context,
        user_params=LLMUserAggregatorParams(vad_analyzer=SileroVADAnalyzer()),
    )

    pipeline = Pipeline(
        [
            transport.input(),
            stt,
            user_aggregator,
            llm,
            tts,
            transport.output(),
            assistant_aggregator,
        ]
    )

    task = PipelineTask(
        pipeline,
        params=PipelineParams(
            enable_metrics=True,
            enable_usage_metrics=True,
        ),
    )

    @transport.event_handler("on_client_connected")
    async def on_client_connected(transport, client):
        logger.info("Client connected")
        context.add_message(
            {
                "role": "developer",
                "content": "Say hello briefly and say you are a local CPU Pipecat demo.",
            }
        )
        await task.queue_frames([LLMRunFrame()])

    @transport.event_handler("on_client_disconnected")
    async def on_client_disconnected(transport, client):
        logger.info("Client disconnected")
        await task.cancel()

    runner = PipelineRunner(handle_sigint=runner_args.handle_sigint)
    await runner.run(task)


async def bot(runner_args: RunnerArguments) -> None:
    """Pipecat runner entrypoint — SmallWebRTC only (no Daily)."""
    transport_params = {
        "webrtc": lambda: TransportParams(
            audio_in_enabled=True,
            audio_out_enabled=True,
        ),
    }
    transport = await create_transport(runner_args, transport_params)
    await run_bot(transport, runner_args)


if __name__ == "__main__":
    from pipecat.runner.run import main

    main()

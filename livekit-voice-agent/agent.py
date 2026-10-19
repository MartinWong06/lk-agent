import logging
import os
import time
from pathlib import Path
from typing import Any

import httpx
import yaml
from dotenv import load_dotenv
from livekit import agents
from livekit.agents import (
    Agent,
    AgentServer,
    AgentSession,
    AgentStateChangedEvent,
    JobContext,
    MetricsCollectedEvent,
    RunContext,
    ToolError,
    UserInputTranscribedEvent,
    function_tool,
    inference,
    metrics,
    room_io,
)
from livekit.agents.llm.mcp import MCPServerHTTP, MCPToolset
from livekit.plugins import noise_cancellation

load_dotenv()

logger = logging.getLogger("assistant")

DEFAULT_INSTRUCTIONS = (
    "You are an upbeat, slightly sarcastic voice AI for tech support. "
    "Help the caller fix issues without rambling, and keep replies under 3 sentences. "
    "You can look up the weather if asked. You can also answer questions about "
    "LiveKit by searching the documentation. When users ask about LiveKit "
    "features, APIs, or how to build something, use the docs search tools "
    "to find accurate information."
)


def load_agent_config() -> dict[str, Any]:
    """Load routine settings from AGENT_CONFIG YAML (no code redeploy for persona/voice)."""
    path = os.getenv("AGENT_CONFIG", "").strip()
    cfg: dict[str, Any] = {
        "agent_name": os.getenv("AGENT_NAME", "enterprise-voice"),
        "model": "openai/gpt-live-1",
        "voice": "marin",
        "instructions": DEFAULT_INSTRUCTIONS,
        "tools": {"weather": True, "livekit_docs_mcp": True},
    }
    if not path:
        return cfg
    p = Path(path)
    if not p.is_file():
        logger.warning("AGENT_CONFIG not found at %s — using defaults", path)
        return cfg
    data = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    if not isinstance(data, dict):
        logger.warning("AGENT_CONFIG invalid — using defaults")
        return cfg
    cfg.update({k: v for k, v in data.items() if v is not None})
    tools = cfg.get("tools") or {}
    if isinstance(tools, dict):
        cfg["tools"] = {
            "weather": bool(tools.get("weather", True)),
            "livekit_docs_mcp": bool(tools.get("livekit_docs_mcp", True)),
        }
    logger.info(
        "Loaded agent config from %s (name=%s model=%s voice=%s)",
        path,
        cfg.get("agent_name"),
        cfg.get("model"),
        cfg.get("voice"),
    )
    return cfg


AGENT_CFG = load_agent_config()


class Assistant(Agent):
    def __init__(self, config: dict[str, Any] | None = None) -> None:
        config = config or AGENT_CFG
        tools: list = []
        tool_flags = config.get("tools") or {}
        if tool_flags.get("livekit_docs_mcp", True):
            tools.append(
                MCPToolset(
                    id="livekit-docs",
                    mcp_server=MCPServerHTTP(url="https://docs.livekit.io/mcp"),
                )
            )

        super().__init__(
            instructions=str(config.get("instructions") or DEFAULT_INSTRUCTIONS),
            tools=tools,
        )
        self._weather_enabled = bool(tool_flags.get("weather", True))

    @function_tool()
    async def lookup_weather(
        self,
        context: RunContext,
        location: str,
    ) -> dict:
        """Look up current weather for a location.

        Args:
            location: City name or location to get weather for.
        """
        if not self._weather_enabled:
            raise ToolError("Weather tool is disabled in agent config")

        async with httpx.AsyncClient(timeout=10.0) as client:
            geo_response = await client.get(
                "https://geocoding-api.open-meteo.com/v1/search",
                params={"name": location, "count": 1},
            )
            geo_response.raise_for_status()
            geo_data = geo_response.json()

            if not geo_data.get("results"):
                raise ToolError(f"Could not find location: {location}")

            place = geo_data["results"][0]
            lat = place["latitude"]
            lon = place["longitude"]
            place_name = place["name"]

            weather_response = await client.get(
                "https://api.open-meteo.com/v1/forecast",
                params={
                    "latitude": lat,
                    "longitude": lon,
                    "current": "temperature_2m,weather_code",
                    "temperature_unit": "fahrenheit",
                },
            )
            weather_response.raise_for_status()
            weather = weather_response.json()

            return {
                "location": place_name,
                "temperature_f": weather["current"]["temperature_2m"],
                "conditions": weather["current"]["weather_code"],
            }

    async def on_enter(self) -> None:
        await self.session.generate_reply(
            instructions="Greet the user briefly and ask how you can help.",
        )


AGENT_NAME = str(AGENT_CFG.get("agent_name") or "enterprise-voice")
server = AgentServer()


@server.rtc_session(agent_name=AGENT_NAME)
async def entrypoint(ctx: JobContext):
    # Full-duplex speech-to-speech (GPT-Live): model owns turn-taking.
    model = str(AGENT_CFG.get("model") or "openai/gpt-live-1")
    voice = str(AGENT_CFG.get("voice") or "marin")
    session = AgentSession(
        llm=inference.DuplexModel(
            model=model,
            voice=voice,
        ),
    )

    usage_collector = metrics.UsageCollector()
    last_eou_metrics: metrics.EOUMetrics | None = None

    @session.on("metrics_collected")
    def _on_metrics_collected(ev: MetricsCollectedEvent) -> None:
        nonlocal last_eou_metrics
        if ev.metrics.type == "eou_metrics":
            last_eou_metrics = ev.metrics

        metrics.log_metrics(ev.metrics)
        usage_collector.collect(ev.metrics)

    @session.on("agent_state_changed")
    def _on_agent_state_changed(ev: AgentStateChangedEvent) -> None:
        if ev.new_state == "speaking" and last_eou_metrics:
            elapsed = time.time() - last_eou_metrics.timestamp
            logger.info("Time to first audio: %.3fs", elapsed)

    @session.on("user_input_transcribed")
    def _on_user_input(ev: UserInputTranscribedEvent) -> None:
        if ev.is_final:
            logger.info("user said: %s", ev.transcript)

    @session.on("error")
    def _on_error(ev) -> None:
        logger.error("session error: %s", ev.error)

    async def log_usage() -> None:
        summary = usage_collector.get_summary()
        logger.info("Usage summary: %s", summary)

    ctx.add_shutdown_callback(log_usage)

    await session.start(
        agent=Assistant(AGENT_CFG),
        room=ctx.room,
        room_options=room_io.RoomOptions(
            audio_input=room_io.AudioInputOptions(
                noise_cancellation=noise_cancellation.BVC(),
            ),
        ),
    )


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    logger.info("Starting worker agent_name=%s", AGENT_NAME)
    agents.cli.run_app(server)

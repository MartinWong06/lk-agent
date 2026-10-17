import logging
import time

import httpx
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


# Define your agent's behavior by extending the Agent class
class Assistant(Agent):
    def __init__(self) -> None:
        super().__init__(
            instructions=(
                "You are an upbeat, slightly sarcastic voice AI for tech support. "
                "Help the caller fix issues without rambling, and keep replies under 3 sentences. "
                "You can look up the weather if asked. You can also answer questions about "
                "LiveKit by searching the documentation. When users ask about LiveKit "
                "features, APIs, or how to build something, use the docs search tools "
                "to find accurate information."
            ),
            # LiveKit docs MCP — use MCPToolset (mcp_servers= on session is deprecated)
            tools=[
                MCPToolset(
                    id="livekit-docs",
                    mcp_server=MCPServerHTTP(url="https://docs.livekit.io/mcp"),
                ),
            ],
        )

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
        # Speak first so console/dev sessions are not silent after connect
        await self.session.generate_reply(
            instructions="Greet the user briefly and ask how you can help.",
        )


server = AgentServer()


# The entrypoint function runs when a participant joins the room
@server.rtc_session()
async def entrypoint(ctx: JobContext):
    # Full-duplex speech-to-speech (GPT-Live): skip cascaded STT → LLM → TTS.
    # The model listens and speaks at the same time and owns turn-taking.
    session = AgentSession(
        llm=inference.DuplexModel(
            model="openai/gpt-live-1",
            voice="marin",
        ),
    )

    # Aggregate data across all conversation turns
    usage_collector = metrics.UsageCollector()

    # Track End of Utterance timing when available (may be limited on duplex models)
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
        agent=Assistant(),
        room=ctx.room,
        room_options=room_io.RoomOptions(
            audio_input=room_io.AudioInputOptions(
                noise_cancellation=noise_cancellation.BVC(),
            ),
        ),
    )


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    agents.cli.run_app(server)

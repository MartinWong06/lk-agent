#!/usr/bin/env python3
"""Static validation of telephony stack artifacts (no Docker required)."""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
errors: list[str] = []


def need(path: Path, what: str) -> None:
    if not path.exists():
        errors.append(f"missing {what}: {path.relative_to(ROOT)}")


def main() -> int:
    need(ROOT / "docker-compose.yml", "compose file")
    need(ROOT / "config" / "agent.yaml", "agent config")
    need(ROOT / "kamailio" / "kamailio.cfg", "kamailio cfg")
    need(ROOT / "kamailio" / "dispatcher.list", "dispatcher list")
    need(ROOT / "asterisk" / "conf" / "pjsip.conf.template", "pjsip template")
    need(ROOT / "asterisk" / "conf" / "extensions.conf.template", "dialplan template")
    need(ROOT / "asterisk" / "conf" / "rtp.conf.template", "rtp template")
    need(ROOT / "softphone" / "index.html", "softphone UI")
    need(ROOT / "livekit" / "setup_sip.py", "SIP setup script")
    need(ROOT / "tests" / "softphone-e2e" / "run.mjs", "softphone media e2e test")

    compose = (ROOT / "docker-compose.yml").read_text(encoding="utf-8")
    coturn_block = compose.split("coturn:", 1)[1].split("\n  kamailio:", 1)[0] if "coturn:" in compose else ""
    if coturn_block and 'profiles: ["turn"]' not in coturn_block:
        errors.append("coturn must stay an opt-in profile (unreachable TURN delays every INVITE)")
    if "condition: service_started" in compose.split("softphone:", 1)[-1].split("\n  agent:", 1)[0]:
        errors.append("softphone must not depend on coturn")
    if "/dev/tcp/127.0.0.1/8080" not in compose:
        errors.append("kamailio healthcheck must probe the WS listener on :8080")

    pjsip = (ROOT / "asterisk" / "conf" / "pjsip.conf.template").read_text(encoding="utf-8")
    # UDP transport must not rewrite softphone SDP to WAN
    udp_block = pjsip.split("[transport-tcp]")[0]
    if "external_media_address=" in udp_block:
        errors.append("transport-udp must not set external_media_address (breaks softphone ICE)")
    if "allow=opus,ulaw,alaw" in pjsip:
        errors.append("softphone endpoints should prefer ulaw (no transcoding to the LiveKit leg)")

    rtp = (ROOT / "asterisk" / "conf" / "rtp.conf.template").read_text(encoding="utf-8")
    if "[ice_host_candidates]" not in rtp or "__ICE_HOST_CANDIDATES__" not in rtp:
        errors.append("rtp.conf.template must render [ice_host_candidates] (container IP → LAN IP)")
    for line in rtp.splitlines():
        if line.strip().startswith(("stunaddr", "turnaddr")):
            errors.append("rtp.conf must not set stunaddr/turnaddr together with ice_host_candidates")
    ast_ep = (ROOT / "asterisk" / "entrypoint.sh").read_text(encoding="utf-8")
    if "include_local_address" not in ast_ep:
        errors.append("ice_host_candidates needs include_local_address (else DTLS never starts)")

    kam_cfg = (ROOT / "kamailio" / "kamailio.cfg").read_text(encoding="utf-8")
    if "record_route()" not in kam_cfg:
        errors.append("kamailio.cfg must record_route() INVITEs (else ACK/BYE lost, call drops ~32s)")
    kam_df = (ROOT / "kamailio" / "Dockerfile").read_text(encoding="utf-8")
    if "netbase" not in kam_df:
        errors.append("kamailio image needs netbase (/etc/protocols) for TCP/WS listeners")

    nginx = (ROOT / "softphone" / "nginx.conf.template").read_text(encoding="utf-8")
    if "resolver 127.0.0.11" not in nginx:
        errors.append("nginx must re-resolve Kamailio via Docker DNS (stale IP → WSS 1006)")

    agent_yaml = ROOT / "config" / "agent.yaml"
    if agent_yaml.exists():
        text = agent_yaml.read_text(encoding="utf-8")
        for key in ("agent_name:", "model:", "voice:", "instructions:"):
            if key not in text:
                errors.append(f"agent.yaml missing {key}")

    dial = (ROOT / "asterisk" / "conf" / "extensions.conf.template").read_text(encoding="utf-8")
    if "livekit-sip" not in dial or "AI_EXTENSION" not in dial and "__AI_EXTENSION__" not in dial:
        errors.append("dialplan must Dial via livekit-sip and AI extension placeholder")

    cfg = ROOT / "softphone" / "config.json"
    if cfg.exists():
        try:
            data = json.loads(cfg.read_text(encoding="utf-8"))
            for k in ("wsServer", "domain", "authorizationUser", "aiExtension"):
                if k not in data:
                    errors.append(f"softphone config.json missing {k}")
        except json.JSONDecodeError as e:
            errors.append(f"softphone config.json invalid: {e}")

    agent_py = ROOT.parent / "livekit-voice-agent" / "agent.py"
    if agent_py.exists():
        src = agent_py.read_text(encoding="utf-8")
        if "agent_name=" not in src:
            errors.append("agent.py must set rtc_session(agent_name=...)")
        if "load_agent_config" not in src and "AGENT_CONFIG" not in src:
            errors.append("agent.py must load AGENT_CONFIG YAML")
        if "DuplexModel" not in src or "RealtimeModel" not in src:
            errors.append(
                "agent.py must support DuplexModel and RealtimeModel "
                "(select via agent.yaml model id)"
            )
        if "build_speech_llm" not in src:
            errors.append("agent.py must select speech LLM via build_speech_llm")
        if "BVCTelephony" not in src:
            errors.append("agent.py must use BVCTelephony for SIP callers (BVC can mute 8 kHz audio)")

    if errors:
        print("FAIL")
        for e in errors:
            print(f"  - {e}")
        return 1
    print("OK — telephony stack artifacts look consistent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

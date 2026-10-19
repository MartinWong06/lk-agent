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
    need(ROOT / "softphone" / "index.html", "softphone UI")
    need(ROOT / "livekit" / "setup_sip.py", "SIP setup script")

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
        if "DuplexModel" not in src:
            errors.append("agent.py must use DuplexModel for full duplex")

    if errors:
        print("FAIL")
        for e in errors:
            print(f"  - {e}")
        return 1
    print("OK — telephony stack artifacts look consistent")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

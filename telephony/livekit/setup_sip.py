#!/usr/bin/env python3
"""Create LiveKit inbound SIP trunk + explicit agent dispatch rule.

Run once after filling telephony/.env:

  cd telephony
  uv run --with livekit-api python livekit/setup_sip.py

Requires: LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET,
          LIVEKIT_SIP_USERNAME, LIVEKIT_SIP_PASSWORD, AGENT_NAME
"""

from __future__ import annotations

import asyncio
import os
import sys

from dotenv import load_dotenv


async def main() -> int:
    load_dotenv()
    url = os.environ.get("LIVEKIT_URL", "")
    key = os.environ.get("LIVEKIT_API_KEY", "")
    secret = os.environ.get("LIVEKIT_API_SECRET", "")
    agent_name = os.environ.get("AGENT_NAME", "enterprise-voice")
    sip_user = os.environ.get("LIVEKIT_SIP_USERNAME", "asterisk-trunk")
    sip_pass = os.environ.get("LIVEKIT_SIP_PASSWORD", "")
    ai_ext = os.environ.get("AI_EXTENSION", "1000")
    allow = os.environ.get("SIP_ALLOWED_ADDRESSES", "")  # comma-separated IPs

    if not (url and key and secret and sip_pass):
        print("Missing LIVEKIT_URL / API_KEY / API_SECRET / LIVEKIT_SIP_PASSWORD", file=sys.stderr)
        return 1

    from livekit import api

    lk = api.LiveKitAPI(url=url, api_key=key, api_secret=secret)

    allowed_addresses = [a.strip() for a in allow.split(",") if a.strip()] or None

    trunk = await lk.sip.create_sip_inbound_trunk(
        api.CreateSIPInboundTrunkRequest(
            trunk=api.SIPInboundTrunkInfo(
                name="asterisk-enterprise-voice",
                numbers=[ai_ext, f"+{ai_ext}"],
                allowed_addresses=allowed_addresses,
                auth_username=sip_user,
                auth_password=sip_pass,
            )
        )
    )
    print(f"inbound trunk id: {trunk.sip_trunk_id}")

    # Explicit dispatch (recommended for SIP) → named duplex agent workers
    rule = await lk.sip.create_sip_dispatch_rule(
        api.CreateSIPDispatchRuleRequest(
            rule=api.SIPDispatchRule(
                dispatch_rule_individual=api.SIPDispatchRuleIndividual(
                    room_prefix="call-",
                ),
            ),
            trunk_ids=[trunk.sip_trunk_id],
            name=f"dispatch-{agent_name}",
            room_config=api.RoomConfiguration(
                agents=[
                    api.RoomAgentDispatch(agent_name=agent_name),
                ]
            ),
        )
    )
    print(f"dispatch rule id: {rule.sip_dispatch_rule_id}")
    print(f"agent_name: {agent_name}")
    print("Done. Point Asterisk LIVEKIT_SIP_HOST at your project SIP host.")
    await lk.aclose()
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))

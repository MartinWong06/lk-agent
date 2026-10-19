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
    did = os.environ.get("LIVEKIT_DID", "+15555550100")
    allow = os.environ.get("SIP_ALLOWED_ADDRESSES", "")  # comma-separated IPs
    sip_host = os.environ.get("LIVEKIT_SIP_HOST", "")

    if not (url and key and secret):
        print("Missing LIVEKIT_URL / API_KEY / API_SECRET", file=sys.stderr)
        return 1
    if not sip_host:
        print(
            "Set LIVEKIT_SIP_HOST to <project_id_without_p_>.sip.livekit.cloud "
            "(from Cloud project settings / agent logs project_id).",
            file=sys.stderr,
        )
        return 1

    from livekit import api

    lk = api.LiveKitAPI(url=url, api_key=key, api_secret=secret)

    # IP allowlist is the reliable match for Asterisk/NAT (digest auth is optional).
    allowed_addresses = [a.strip() for a in allow.split(",") if a.strip()]

    trunk = await lk.sip.create_inbound_trunk(
        api.CreateSIPInboundTrunkRequest(
            trunk=api.SIPInboundTrunkInfo(
                name="asterisk-enterprise-voice",
                numbers=[did],
                allowed_addresses=allowed_addresses,
                auth_username=sip_user if sip_pass else "",
                auth_password=sip_pass,
            )
        )
    )
    print(f"inbound trunk id: {trunk.sip_trunk_id}")

    # Explicit dispatch (recommended for SIP) → named duplex agent workers
    rule = await lk.sip.create_dispatch_rule(
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
    print(f"DID: {did}")
    print(f"Asterisk should Dial PJSIP/{did}@livekit-sip → {sip_host}")
    await lk.aclose()
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))

# Enterprise voice (Kamailio + Asterisk + LiveKit duplex)

High-availability–oriented **reference stack** for a web softphone voice AI call path:

```text
Browser softphone (SIP.js)
    → Kamailio (SIP/WebSocket edge + dispatcher)
    → Asterisk (PJSIP dialplan)
    → LiveKit SIP
    → LiveKit Agents (full-duplex GPT-Live)
```

Pipecat is not used here. AI is **full duplex** via the existing LiveKit agent.

## Prerequisites

- Docker + Docker Compose
- LiveKit Cloud project (or self-hosted) with **SIP** enabled
- API key/secret and **SIP URI host from Project Settings** (Cloud dashboard)

### Critical: SIP host ≠ WebSocket subdomain

`LIVEKIT_SIP_HOST` is `<project_id without p_>.sip.livekit.cloud`.

Example: agent logs show `project_id:p_25v23ne9zzm` → `25v23ne9zzm.sip.livekit.cloud`.

The `wss://martin-….livekit.cloud` subdomain is **not** the SIP host. Wrong host →
`SIP/2.0 404 No trunk found` even when trunks exist via the API.

Also set `LIVEKIT_DID` to the exact trunk number (e.g. `+15555550100`). Softphone still
dials extension `1000`; Asterisk maps that to the DID.

## Quick start

```bash
cd telephony
cp .env.example .env
# Edit .env: LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET,
#           LIVEKIT_SIP_HOST, passwords

# Static artifact check (no Docker)
python3 scripts/validate_stack.py

# One-time: create inbound trunk + explicit agent dispatch
uv run --with livekit-api --with python-dotenv python livekit/setup_sip.py

# Softphone UI password/WS URL are rendered from .env at container start

docker compose up -d --build --scale agent=2
```

Open **http://localhost:8088/** → **Register** → dial **1000** (AI).

## Configuration (no code edits for routine changes)

| What | File / env |
|------|------------|
| Persona, voice, model, tools | [`config/agent.yaml`](config/agent.yaml) — remounted; restart agents |
| Softphone WS / user | [`softphone/config.json`](softphone/config.json) |
| SIP domain, passwords, LiveKit SIP host | `.env` |
| AI extension | `AI_EXTENSION` (default `1000`) + Asterisk dialplan template |
| Agent worker name (must match dispatch) | `AGENT_NAME` / `agent.yaml` → `enterprise-voice` |

After changing `agent.yaml`:

```bash
docker compose up -d --force-recreate --scale agent=2 agent
```

## Ports

| Port | Service |
|------|---------|
| 8088 | Softphone UI |
| 8080 | Kamailio SIP over WebSocket |
| 5060 | Kamailio SIP UDP/TCP |
| 10000–10100/udp | Asterisk RTP |

## HA layout

Compose is single-host but **shaped for HA**:

- **Kamailio** `dispatcher.list` — add more `sip:asterisk-N:5060` rows for extra Asterisk nodes
- **Agents** — scale workers sharing `agent_name=enterprise-voice` (`--scale agent=2` or more)
- **Production** — dual Kamailio behind VIP/DNS, shared registrar DB, multi-region LiveKit, autoscale agents

Optional profile `full-media` includes an rtpengine image for advanced WebRTC bridging; the default path uses Asterisk WebRTC/DTLS on the softphone endpoint.

## Call flow details

1. Softphone **REGISTER** over `ws://localhost:8080` to Kamailio (usrloc)
2. Softphone **INVITE** `sip:1000@voice.local` → Kamailio dispatches to Asterisk
3. Asterisk dialplan `Dial(PJSIP/1000@livekit-sip)` to LiveKit SIP host
4. LiveKit creates room `call-*` and dispatches agent **`enterprise-voice`**
5. Duplex GPT-Live answers in the room

## Troubleshooting

- Softphone cannot register: check Kamailio logs (`docker compose logs kamailio`) and `wsServer` / env-rendered `config.json`
- `404 No trunk found` from LiveKit: wrong `LIVEKIT_SIP_HOST` (see above) or trunk numbers / `allowed_addresses` mismatch
- Agent `Connection timeout` to LiveKit from Docker: agents use `network_mode: host` in compose for Cloud WSS
- Asterisk cannot reach LiveKit SIP through bridge NAT: try `docker-compose.host-asterisk.yml` (stop Kamailio first — port 5060 clash)
- Set `EXTERNAL_SIP_IP` to your current public egress IP (it can rotate on cloud VMs)
- One-way audio: open UDP 10000–10100; for remote browsers, set public IPs / TLS WSS and ICE carefully

## Verified on reference host

- Softphone UI healthy (`:8088`), config rendered from `.env`
- Kamailio healthy (`:5060`, WS `:8080`) when not using host-Asterisk overlay
- Asterisk → LiveKit SIP (`25v23ne9zzm.sip.livekit.cloud`): `100` / `180` / `200 OK`
- Duplex worker `enterprise-voice` received job, joined room `call-_1000_*`,
  linked `sip_1000`, ran `openai/gpt-live-1`
- `agent.yaml` drives persona/voice/model without code changes
- For Cloud SIP behind NAT, use:
  `docker compose -f docker-compose.yml -f docker-compose.host-asterisk.yml up -d asterisk`
  (stop Kamailio first — both want host `:5060`)

## Phase 2 (not in this compose)

- Carrier PSTN DID into Kamailio
- Multi-site Kamailio + shared location DB
- WSS + certificates for production softphones

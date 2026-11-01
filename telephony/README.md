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

# Bridge stack (signaling). Softphone audio on Docker Desktop needs a LAN IP — see below.
docker compose up -d --build --force-recreate --scale agent=1
docker compose ps
```

### Windows Docker Desktop softphone (recommended one-shot)

If Kamailio logs show `dispatch ... -> sip:host.docker.internal:5060`, you are on the
**host-asterisk overlay** and INVITEs will hang ~30s then Terminated. Reset with:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\bringup-windows.ps1
```

That script:
1. Writes `SOFTPHONE_PUBLIC_HOST` / `SOFTPHONE_MEDIA_IP` / `SOFTPHONE_WS_SERVER` to `.env`
2. Runs `docker compose down` **including** the host overlay
3. Starts **bridge** compose only (`ASTERISK_HOST=asterisk`)
4. Prints the LAN URL to open

Open **`https://<LAN_IP>:8443/`** (accept the self-signed cert warning) → allow mic → Register → Call AI.

- `http://localhost:8088/` → ICE fails in Docker Desktop  
- `http://<LAN>:8088/` → browser blocks `getUserMedia` (insecure context)  
- `https://<LAN>:8443/` → mic works; nginx terminates TLS and proxies WSS → Kamailio  

Expect Kamailio: `dispatch sip:1000@voice.local -> sip:asterisk:5060`  
Expect softphone: `INVITE progress/accepted` then `iceConnectionState=connected`.

If `ghcr.io` times out while building the agent, the script still starts softphone/Kamailio/Asterisk
and retries the agent from Docker Hub (`astral/uv`). You can also rebuild just the agent later:
`docker compose build agent && docker compose up -d --scale agent=1 agent`.

If softphone still crash-loops, confirm `docker compose ps` COMMAND contains
`/bin/sh -c` (not bare `/docker-entrypoint.sh`), then check
`docker compose logs softphone kamailio --tail 40`.

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
docker compose up -d --force-recreate --scale agent=1 agent
```

## Ports

| Port | Service |
|------|---------|
| 8088 | Softphone UI |
| 8080 | Kamailio SIP over WebSocket |
| 5060 | Kamailio SIP UDP/TCP |
| 10000–10050/udp | Asterisk RTP (softphone + LiveKit) |

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

- Softphone / Kamailio crash-loop with `exec ...entrypoint.sh: no such file or directory`
  or `Restarting (255)` while Asterisk is healthy: Windows CRLF broke the Linux shebang.
  Compose now launches via `tr -d '\\r' | /bin/sh` so a recreate is enough:
  `docker compose up -d --build --force-recreate --scale agent=1`
  Confirm `docker compose ps` COMMAND contains `/bin/sh -c` (not bare `/docker-entrypoint.sh`).
  Then `docker compose logs softphone kamailio --tail 40`.
- Softphone status **SIP.js failed to load**: UI needs `vendor/sip-0.21.2.min.js` (bundled in-repo).
  Do not use jsDelivr `dist/sip.min.js` for 0.21.x — that path 404s. Rebuild softphone after pull:
  `docker compose up -d --build --force-recreate softphone`, then hard-refresh the browser.
- Softphone log `audio attach error: ... sessionDescriptionHandler`: fixed by attaching media via
  `onSessionDescriptionHandler` / `track` events and blocking overlapping Call AI clicks.
  Recreate softphone + hard-refresh. Click **Call AI once**; use Hang up before redialing.
- Call **Established**, ICE briefly `connected`, then `disconnected` / `remote: muted=true`:
  softphone WebRTC never got RTP. On Docker Desktop, use the bundled **coturn** relay:
  1. `SOFTPHONE_MEDIA_IP` / `SOFTPHONE_PUBLIC_HOST` = LAN IP (not `127.0.0.1`)
  2. `docker compose up -d --build --force-recreate coturn asterisk softphone`
  3. Softphone log should show `ICE servers configured: 3` and later `ICE pair … relay`
  4. Asterisk boot log should show `turnaddr=coturn:3478` and **no** `external_media` on UDP
  5. Allow Windows Firewall UDP **3478**, **49160–49200**, **10000–10050**
  Do **not** use `docker-compose.host-asterisk.yml` on Docker Desktop Windows.
- Call **Establishing → Terminated (~30s)** with no Established: INVITE timed out (Kamailio↔Asterisk
  or Asterisk↔LiveKit). Prefer plain bridge compose on Docker Desktop Windows — avoid
  `host-asterisk` overlay there. Check `docker compose logs kamailio asterisk --tail 80`.
- Softphone **`INVITE rejected 488 Not Acceptable Here`**: Asterisk rejected WebRTC SDP.
  Recreate Asterisk after pulling. Check `docker compose logs asterisk --tail 100`.
- Softphone **`INVITE rejected 401`** / Asterisk `No matching endpoint found` for
  `sip:1001@voice.local` from Kamailio: INVITE is identified by Kamailio’s Docker IP via
  `from-kamailio` (trusted). Recreate Asterisk after pull; confirm log no longer shows
  “No matching endpoint found”.
- Softphone ICE **connected**, agent logs **`user said: Hello`**, but **no speaker audio** /
  `output_audio_tokens=0`: speech Inference never generated a reply. On the **Build** plan
  check Cloud **Billing → LiveKit Inference** credits (~$2.50/mo). Default model is
  turn-based `openai/gpt-realtime-2.1-mini` (`RealtimeModel`); only `openai/gpt-live-1`
  is full-duplex (`DuplexModel`). Agent logs should show `agent_state … -> speaking` and
  `on_enter: generate_reply completed` (or a clear decline / “no agent speaking state” error).
  Telephony `config/agent.yaml` disables MCP/weather by default while bringing up audio.
- Linux-only host Asterisk overlay: `docker-compose.host-asterisk.yml` (not for Desktop Windows).
- Softphone cannot register: check Kamailio logs (`docker compose logs kamailio`) and `wsServer` / env-rendered `config.json`
- `404 No trunk found` from LiveKit: wrong `LIVEKIT_SIP_HOST` (see above) or trunk numbers / `allowed_addresses` mismatch
- Agent `Connection timeout` to LiveKit from Docker: agents use `network_mode: host` in compose for Cloud WSS
- Set `EXTERNAL_SIP_IP` to your current public egress IP (it can rotate on cloud VMs)
- One-way audio: open UDP 10000–10050; for remote browsers, set public IPs / TLS WSS and ICE carefully
- `setup_sip.py` `Conflicting inbound SIP Trunks`: trunk already exists — skip the script or update
  the existing trunk in LiveKit Cloud (do not re-create the same DID)
- On Windows with `network_mode: host` agents, prefer `--scale agent=1` for the first call test

## Verified on reference host

- Softphone UI healthy (`:8088`), config rendered from `.env`
- Kamailio healthy (`:5060`, WS `:8080`) when not using host-Asterisk overlay
- Asterisk → LiveKit SIP (`25v23ne9zzm.sip.livekit.cloud`): `100` / `180` / `200 OK`
- Speech worker `enterprise-voice` received job, joined room `call-_1000_*`,
  linked `sip_1000`; model comes from `agent.yaml` (`openai/gpt-realtime-2.1-mini` default)
- `agent.yaml` drives persona/voice/model without code changes (`gpt-live-1` → DuplexModel)
- For Cloud SIP + local softphone audio on Docker Desktop, use bridge compose with
  `SOFTPHONE_MEDIA_IP`/`SOFTPHONE_PUBLIC_HOST` set to the LAN IP (see bringup-windows.ps1)

## Phase 2 (not in this compose)

- Carrier PSTN DID into Kamailio
- Multi-site Kamailio + shared location DB
- WSS + certificates for production softphones

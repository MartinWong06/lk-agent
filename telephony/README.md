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

## Automated media test

Headless Chrome (fake mic) in Docker registers `1001`, dials, and checks ICE, inbound RTP
packets and audio energy, and that the call survives past the old ~32 s drop:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\test-media.ps1   # 9196 echo + 1000 AI
```

```bash
sh scripts/test-media.sh            # add --echo-only to skip the LiveKit/AI call
```

- `9196` (Asterisk echo) isolates browser ↔ Kamailio ↔ Asterisk WebRTC. If this fails, the
  problem is local (LAN IP / firewall / Docker), not LiveKit.
- `1000` passes only when the agent greeting audio actually reaches the browser
  (Asterisk → LiveKit SIP → agent → Inference → back).

## Deploy to a Linux VPS

Requirements: Ubuntu/Debian (or any Linux) VPS with a public IPv4, Docker Engine and
Compose ≥ 2.24 (`curl -fsSL https://get.docker.com | sh`), 2 vCPU / 2 GB RAM is plenty.
Optional but recommended: a DNS A record (e.g. `voice.example.com`) pointing at the VPS,
so you get a real Let's Encrypt certificate instead of a browser warning.

```bash
git clone <this repo> && cd lk-agent/telephony
cp .env.example .env
# fill LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET, LIVEKIT_SIP_HOST
sudo sh scripts/vps-setup.sh --domain voice.example.com --email you@example.com
# (no domain yet?  sudo sh scripts/vps-setup.sh   → public IP + self-signed cert)
uv run --with livekit-api --with python-dotenv python livekit/setup_sip.py   # trunk allowlists the VPS IP
sh scripts/test-security.sh && sh scripts/test-media.sh
```

`vps-setup.sh` sets `PRODUCTION=1`, the public host/IPs, replaces every empty or
`change-me` secret in `.env` with a random one (and prints the logins), configures ufw,
starts the stack with [`docker-compose.prod.yml`](docker-compose.prod.yml) and issues the
certificate (renewed by the `certbot` container). Re-running it is safe: real values are kept.
If it regenerated `LIVEKIT_SIP_PASSWORD`, re-run `setup_sip.py` (it replaces its old trunk).

Open `https://voice.example.com/`, enter the page login (basic auth), then the SIP login,
Register, dial `9196` (echo) and `1000` (AI).

What is protected in production:

| Layer | Protection |
|-------|------------|
| Network | Only 80/tcp, 443/tcp and 20000–20050/udp published (Kamailio 5060/8080, Asterisk, agent stay on the Docker network); ufw denies the rest. Docker-published ports bypass ufw, which is why the overlay publishes so little. |
| Web | TLS (Let's Encrypt), HTTP→HTTPS, HSTS, CSP / frame / referrer headers, basic auth, per-IP rate limits on pages and the WSS handshake, no server version, no build files served. |
| SIP | Digest auth on REGISTER and every INVITE (auth user must equal From user), only INVITE/REGISTER as initial requests, no relaying to foreign domains, in-dialog requests only towards Asterisk, scanner UAs dropped, pike flood ban on direct SIP, WebSocket closed after 5 wrong passwords. |
| Credentials | SIP password not in `config.json` (users type it), containers refuse `change-me` / short passwords, `.env` mode 600, agent only receives `LIVEKIT_*`. |
| Cost | `MAX_AI_CALLS` concurrent AI calls (busy beyond that), `MAX_CALL_SECONDS` hard call limit, echo test capped at 120 s. |

More accounts: `SIP_USERS=alice:<long-random>,bob:<long-random>` in `.env`, then
`docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d kamailio`.
Logs are rotated (10 MB × 5 per container): `docker compose logs -f kamailio`.

Browsers on any network work without TURN as long as UDP 20000–20050 reaches the VPS
(Asterisk advertises the public IP). Only for callers behind UDP-blocking firewalls add
`SOFTPHONE_TURN=1` and `--profile turn` (and open 3478 + 49160–49169/udp).

### Behind Caddy / nginx (ports 80/443 already taken)

If the host already runs Caddy (or nginx) on 80/443 — e.g. CRM on `crm.suarify.my` —
layer [`docker-compose.caddy.yml`](docker-compose.caddy.yml) so the softphone binds only
`127.0.0.1:8443` and let Caddy terminate public TLS:

```bash
sudo sh scripts/vps-setup.sh --domain platformfe.suarify.my --email you@example.com --no-up
# Caddyfile: reverse_proxy https://127.0.0.1:8443 { transport http { tls_insecure_skip_verify } }
docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.caddy.yml up -d --build
```

Related settings that must stay aligned:

| Setting | Value behind Caddy | Why |
|---------|--------------------|-----|
| Softphone ports | `127.0.0.1:8443:443` only (caddy overlay) | Caddy owns public 80/443 |
| `SOFTPHONE_HTTPS_PORT` | **`443`** (do not set 8443) | Browser WS URL must be `wss://domain/ws`, not `:8443` |
| `SOFTPHONE_WS_SERVER` | empty | Entrypoint builds `wss://domain/ws` from the public host |
| `SOFTPHONE_PUBLIC_HOST` | your DNS name (e.g. `platformfe.suarify.my`) | Used for WS URL + preferred page URL |
| `SOFTPHONE_MEDIA_IP` / `EXTERNAL_SIP_IP` | VPS public IPv4 | Asterisk ICE / LiveKit SIP Contact |
| RTP | UDP **20000–20050** (compose + `rtp.conf`) | Must match; open in ufw **and** provider firewall |
| Certbot profile | skip | Caddy issues the public cert; softphone uses self-signed on loopback |

Do **not** change `SOFTPHONE_HTTPS_PORT` to `8443` when using this overlay — that would make
`config.json` advertise `wss://domain:8443/ws`, which is not reachable through Caddy.

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

Dev/LAN stack (`docker-compose.yml`). Production publishes only 80, 443 and RTP.

| Port | Service |
|------|---------|
| 8088 | Softphone UI |
| 8080 | Kamailio SIP over WebSocket |
| 5060 | Kamailio SIP UDP/TCP |
| 8443 | Softphone HTTPS UI + WSS → Kamailio |
| 20000–20050/udp | Asterisk RTP (softphone + LiveKit) |
| 3478, 49160–49169/udp | coturn (opt-in `turn` profile only) |

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
5. The speech model from `agent.yaml` answers in the room (`gpt-realtime-2.1-mini` by default)

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
  the browser never received RTP from Asterisk. Root causes (all fixed in this repo):
  1. Asterisk only advertised its container IP (`172.x`) as an ICE candidate, which a Windows
     browser cannot reach. `asterisk/entrypoint.sh` now renders `rtp.conf`
     `[ice_host_candidates] <container-ip> => SOFTPHONE_MEDIA_IP,include_local_address`
     so ICE uses the published UDP ports 20000–20050 on your LAN IP. (`include_local_address`
     is required — without it Asterisk never sends its own ICE checks and DTLS never starts.)
  2. Kamailio did not `record_route()`, so the browser's ACK/BYE never reached Asterisk and
     every call was torn down ~32 s after answer.
  Checklist: `SOFTPHONE_MEDIA_IP` = this PC's LAN IP (not vEthernet/WSL `172.x`, not
  `127.0.0.1`), open `https://<LAN>:8443/`, Windows Firewall allows UDP **20000–20050**
  (bringup script adds it when run as Administrator). TURN/coturn is **not** needed on a LAN;
  it is an opt-in profile (`SOFTPHONE_TURN=1 docker compose --profile turn up -d`).
- Softphone `WSS 1006` / INVITE `503`/`408`: Kamailio's WS listener or Asterisk was down.
  Kamailio now ships `netbase` (without `/etc/protocols` it logs `tcp_init(): could not get
  TCP protocol number`), its healthcheck probes `:8080`, Asterisk is only healthy once PJSIP
  loaded `from-kamailio`, and nginx re-resolves `kamailio` so recreating it no longer leaves
  WSS pointing at a dead IP. Run `scripts\doctor-windows.ps1`.
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
  SIP callers use `noise_cancellation.BVCTelephony()` (wideband `BVC()` can suppress 8 kHz
  phone audio so the model never hears a turn). `agent.py` is baked into the image —
  `bringup-windows.ps1` always rebuilds the agent so code changes are not silently ignored.
- Linux-only host Asterisk overlay: `docker-compose.host-asterisk.yml` (not for Desktop Windows).
- Softphone cannot register: check Kamailio logs (`docker compose logs kamailio`) and `wsServer` / env-rendered `config.json`
- `404 No trunk found` from LiveKit: wrong `LIVEKIT_SIP_HOST` (see above) or trunk numbers / `allowed_addresses` mismatch
- Agent `Connection timeout` to LiveKit from Docker: agents use `network_mode: host` in compose for Cloud WSS
- Set `EXTERNAL_SIP_IP` to your current public egress IP (it can rotate on cloud VMs)
- One-way audio: open UDP 20000–20050; for remote browsers, set public IPs / TLS WSS and ICE carefully
- `test-media` **echo passes** but the **AI call is silent** while agent logs show
  `user said: …` and `agent_state … -> speaking`: the agent's audio from LiveKit Cloud is not
  getting back through your router to Asterisk. Asterisk advertises `EXTERNAL_SIP_IP:20000-20050`
  to LiveKit — set `EXTERNAL_SIP_IP` to your *current* public IP and port-forward UDP
  20000–20050 (and disable "SIP ALG") on the router to this PC.
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

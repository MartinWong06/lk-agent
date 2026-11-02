// Headless softphone media test: Register → dial → measure ICE + inbound RTP audio.
//
// Env:
//   SOFTPHONE_URL   https://<LAN_IP>:8443/          (required)
//   DIAL            9196 (Asterisk echo) | 1000 (LiveKit AI)   default 9196
//   HOLD_SECONDS    how long to keep the call up    default 45
//   MIN_ENERGY      min inbound totalAudioEnergy to call it "audible"  default 0.01
import { chromium } from "playwright";

const url = process.env.SOFTPHONE_URL;
const dial = process.env.DIAL || "9196";
const holdSeconds = Number(process.env.HOLD_SECONDS || 45);
const minEnergy = Number(process.env.MIN_ENERGY || 0.01);

if (!url) {
  console.error("SOFTPHONE_URL is required (e.g. https://192.168.1.10:8443/)");
  process.exit(2);
}

const browser = await chromium.launch({
  args: [
    "--use-fake-ui-for-media-stream",
    "--use-fake-device-for-media-stream",
    "--autoplay-policy=no-user-gesture-required",
    "--ignore-certificate-errors",
  ],
});
const context = await browser.newContext({ ignoreHTTPSErrors: true });
const page = await context.newPage();

const consoleLines = [];
page.on("console", (m) => consoleLines.push(m.text()));

await page.addInitScript(() => {
  const Orig = window.RTCPeerConnection;
  window.__pcs = [];
  window.RTCPeerConnection = function (...args) {
    const pc = new Orig(...args);
    window.__pcs.push(pc);
    return pc;
  };
  window.RTCPeerConnection.prototype = Orig.prototype;
  Object.setPrototypeOf(window.RTCPeerConnection, Orig);
});

function hasLog(re) {
  return consoleLines.some((l) => re.test(l));
}

async function waitFor(re, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    if (hasLog(re)) return true;
    await page.waitForTimeout(250);
  }
  return false;
}

async function sample() {
  return page.evaluate(async () => {
    const pc = window.__pcs[window.__pcs.length - 1];
    if (!pc) return null;
    const out = {
      ice: pc.iceConnectionState,
      conn: pc.connectionState,
      inPackets: 0,
      inBytes: 0,
      inEnergy: 0,
      outPackets: 0,
      codec: null,
      pair: null,
    };
    const stats = await pc.getStats();
    const byId = {};
    stats.forEach((r) => (byId[r.id] = r));
    stats.forEach((r) => {
      if (r.type === "inbound-rtp" && r.kind === "audio") {
        out.inPackets = r.packetsReceived || 0;
        out.inBytes = r.bytesReceived || 0;
        out.inEnergy = r.totalAudioEnergy || 0;
        if (r.codecId && byId[r.codecId]) out.codec = byId[r.codecId].mimeType;
      }
      if (r.type === "outbound-rtp" && r.kind === "audio") out.outPackets = r.packetsSent || 0;
      if (r.type === "candidate-pair" && r.nominated && r.state === "succeeded") {
        const l = byId[r.localCandidateId];
        const rem = byId[r.remoteCandidateId];
        out.pair = `${l?.candidateType} ${l?.address}:${l?.port} -> ${rem?.candidateType} ${rem?.address}:${rem?.port}`;
      }
    });
    return out;
  });
}

const result = { url, dial, holdSeconds, pass: false, reasons: [], samples: [] };
try {
  await page.goto(url, { waitUntil: "load", timeout: 20000 });
  if (!(await waitFor(/config loaded/, 10000))) result.reasons.push("softphone config.json did not load");

  await page.click("#btn-register");
  if (!(await waitFor(/register state: Registered/, 15000))) {
    result.reasons.push("REGISTER failed (check Kamailio / WSS)");
    throw new Error("register");
  }

  await page.fill("#dest", dial);
  await page.click("#btn-call");
  if (!(await waitFor(/call state: Established/, 30000))) {
    result.reasons.push("call never Established (INVITE rejected/timed out)");
    throw new Error("invite");
  }
  const establishedAt = Date.now();

  for (let t = 0; t < holdSeconds; t += 3) {
    await page.waitForTimeout(3000);
    const s = await sample();
    if (s) result.samples.push({ t: Math.round((Date.now() - establishedAt) / 1000), ...s });
    if (hasLog(/call state: Terminated/)) break;
  }

  const last = result.samples[result.samples.length - 1] || {};
  const terminatedEarly = hasLog(/call state: Terminated/);
  const survived = result.samples.length ? last.t : 0;
  result.summary = {
    survivedSeconds: survived,
    terminatedEarly,
    finalIce: last.ice,
    inboundPackets: last.inPackets,
    inboundAudioEnergy: last.inEnergy,
    outboundPackets: last.outPackets,
    codec: last.codec,
    selectedPair: last.pair,
  };

  if (terminatedEarly) result.reasons.push(`call dropped after ~${survived}s (ACK/BYE routing or remote hangup)`);
  if (!["connected", "completed"].includes(last.ice)) result.reasons.push(`ICE ended ${last.ice}`);
  if (!(last.outPackets > 0)) result.reasons.push("no outbound RTP from browser");
  if (!(last.inPackets > 0)) result.reasons.push("no inbound RTP to browser (silent)");
  else if (!(last.inEnergy >= minEnergy)) result.reasons.push(`inbound RTP but near-silent energy=${last.inEnergy}`);

  result.pass = result.reasons.length === 0;
  try {
    await page.click("#btn-hangup", { timeout: 2000 });
    await page.waitForTimeout(1500);
  } catch (_) {}
} catch (e) {
  if (!result.reasons.length) result.reasons.push(String(e));
} finally {
  result.softphoneLog = consoleLines.filter((l) => /^\[\d\d:/.test(l)).slice(-60);
  console.log(JSON.stringify(result, null, 2));
  console.log(result.pass ? "RESULT: PASS" : `RESULT: FAIL — ${result.reasons.join("; ")}`);
  await browser.close();
  process.exit(result.pass ? 0 : 1);
}

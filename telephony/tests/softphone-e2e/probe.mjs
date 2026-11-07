// Small probes for the self-healing chaos test (scripts/chaos-test.sh).
//
// PROBE=invite  One authenticated INVITE to DIAL; prints the final SIP status and how
//               long it took (fast 503 vs. 30s hang shows dispatcher health probing).
// PROBE=watch   Registers through the real softphone UI, prints "PROBE READY", then
//               watches WATCH_SECONDS for the page to lose its WebSocket and register
//               again on its own (softphone auto-recovery).
//
// Env: SOFTPHONE_URL, SIP_USER, SIP_PASSWORD, BASIC_AUTH_USER/PASSWORD, DIAL (9196),
//      WATCH_SECONDS (90)
import { chromium } from "playwright";

const url = process.env.SOFTPHONE_URL;
const mode = process.env.PROBE || "invite";
const dial = process.env.DIAL || "9196";
const watchSeconds = Number(process.env.WATCH_SECONDS || 90);
const sipUser = process.env.SIP_USER || "";
const sipPassword = process.env.SIP_PASSWORD || "";
const basicUser = process.env.BASIC_AUTH_USER;

const browser = await chromium.launch({
  args: ["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", "--ignore-certificate-errors"],
});
const context = await browser.newContext({
  ignoreHTTPSErrors: true,
  ...(basicUser ? { httpCredentials: { username: basicUser, password: process.env.BASIC_AUTH_PASSWORD || "" } } : {}),
});
const page = await context.newPage();
const lines = [];
page.on("console", (m) => lines.push({ t: Date.now(), text: m.text() }));

function report(result) {
  console.log(`PROBE ${JSON.stringify(result)}`);
}

async function invite() {
  await page.goto(url, { waitUntil: "load", timeout: 20000 });
  await page.waitForFunction(() => !!window.SIP, null, { timeout: 10000 });
  const cfg = await (await page.request.get(new URL("config.json", url).href)).json();
  return page.evaluate(
    async ({ cfg, sipUser, sipPassword, dial }) => {
      const SIP = window.SIP;
      const ua = new SIP.UserAgent({
        uri: SIP.UserAgent.makeURI(`sip:${sipUser}@${cfg.domain}`),
        transportOptions: { server: cfg.wsServer },
        authorizationUsername: sipUser,
        authorizationPassword: sipPassword,
        logBuiltinEnabled: false,
      });
      await ua.start();
      const inv = new SIP.Inviter(ua, SIP.UserAgent.makeURI(`sip:${dial}@${cfg.domain}`), {
        sessionDescriptionHandlerOptions: { constraints: { audio: true, video: false }, iceGatheringTimeout: 500 },
      });
      const start = Date.now();
      const status = await new Promise((resolve) => {
        const t = setTimeout(() => resolve("timeout"), 45000);
        const done = (v) => {
          clearTimeout(t);
          resolve(v);
        };
        inv
          .invite({
            requestDelegate: {
              onAccept: (r) => done(r.message.statusCode),
              onReject: (r) => done(r.message.statusCode),
            },
          })
          .catch((e) => done(`error:${e.message || e}`));
      });
      const ms = Date.now() - start;
      try {
        if (inv.state === "Established") await inv.bye();
      } catch (_) {}
      try {
        await ua.stop();
      } catch (_) {}
      return { mode: "invite", dial, status, ms };
    },
    { cfg, sipUser, sipPassword, dial }
  );
}

async function watch() {
  await page.goto(url, { waitUntil: "load", timeout: 20000 });
  if (await page.isVisible("#login")) {
    if (sipUser) await page.fill("#sip-user", sipUser);
    await page.fill("#sip-password", sipPassword);
  }
  await page.click("#btn-register");
  const end0 = Date.now() + 15000;
  while (Date.now() < end0 && !lines.some((l) => /register state: Registered/.test(l.text))) {
    await page.waitForTimeout(200);
  }
  if (!lines.some((l) => /register state: Registered/.test(l.text))) {
    return { mode: "watch", pass: false, reason: "initial REGISTER failed" };
  }
  const readyAt = Date.now();
  console.log("PROBE READY");

  let lostAt = null;
  let recoveredAt = null;
  const end = readyAt + watchSeconds * 1000;
  while (Date.now() < end) {
    await page.waitForTimeout(250);
    const after = lines.filter((l) => l.t > readyAt);
    const lost = after.find((l) => /transport: disconnected|transport state: Disconnected/i.test(l.text));
    if (lost) {
      lostAt = lost.t;
      const back = after.find(
        (l) =>
          l.t > lostAt &&
          (/register state: Registered/.test(l.text) || /SELFHEAL re-registered/.test(l.text))
      );
      if (back) {
        recoveredAt = back.t;
        break;
      }
    }
  }
  const status = await page.textContent("#status").catch(() => null);
  return {
    mode: "watch",
    pass: !!(lostAt && recoveredAt),
    disconnected: !!lostAt,
    recovered: !!recoveredAt,
    recoverySeconds: lostAt && recoveredAt ? Math.round((recoveredAt - lostAt) / 100) / 10 : null,
    finalStatus: status,
    log: lines.filter((l) => l.t > readyAt && /^\[\d\d:/.test(l.text)).map((l) => l.text).slice(-15),
  };
}

let result;
try {
  result = mode === "watch" ? await watch() : await invite();
} catch (e) {
  result = { mode, pass: false, error: String(e) };
}
report(result);
await browser.close();
process.exit(0);

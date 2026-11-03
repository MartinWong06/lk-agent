// Security checks against a running stack (uses the softphone page's SIP.js in Chrome).
//
// Env:
//   SOFTPHONE_URL      https://<host>/                       (required)
//   SIP_USER / SIP_PASSWORD   a valid account (positive control)  (required)
//   BASIC_AUTH_USER / BASIC_AUTH_PASSWORD   if the UI is behind basic auth
//   EXPECT_PRODUCTION  1 → also require: no password in config.json, basic auth enforced
import https from "node:https";
import { chromium } from "playwright";

const url = process.env.SOFTPHONE_URL;
const sipUser = process.env.SIP_USER;
const sipPassword = process.env.SIP_PASSWORD;
const basicUser = process.env.BASIC_AUTH_USER;
const basicPassword = process.env.BASIC_AUTH_PASSWORD || "";
const expectProduction = process.env.EXPECT_PRODUCTION === "1";

if (!url || !sipUser || !sipPassword) {
  console.error("SOFTPHONE_URL, SIP_USER and SIP_PASSWORD are required");
  process.exit(2);
}

const checks = [];
function check(name, ok, detail) {
  checks.push({ name, ok: !!ok, detail });
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail !== undefined ? `  (${detail})` : ""}`);
}

function httpStatus(path, auth) {
  return new Promise((resolve) => {
    const u = new URL(path, url);
    const req = https.request(
      u,
      {
        method: "GET",
        rejectUnauthorized: false,
        headers: auth ? { Authorization: "Basic " + Buffer.from(auth).toString("base64") } : {},
        timeout: 8000,
      },
      (res) => {
        let body = "";
        res.on("data", (d) => (body += d));
        res.on("end", () => resolve({ status: res.statusCode, body, headers: res.headers }));
      }
    );
    req.on("error", (e) => resolve({ status: `error:${e.code || e.message}`, body: "" }));
    req.on("timeout", () => req.destroy(new Error("timeout")));
    req.end();
  });
}

const creds = basicUser ? `${basicUser}:${basicPassword}` : null;

// --- HTTP layer ---
const cfgRes = await httpStatus("config.json", creds);
let cfg = null;
try {
  cfg = JSON.parse(cfgRes.body);
} catch (_) {}
check("config.json reachable with valid credentials", cfgRes.status === 200 && cfg, cfgRes.status);
if (expectProduction) {
  check("config.json does not contain the SIP password", cfg && !cfg.password, cfg && typeof cfg.password);
  check("config.json does not enable SIP trace", cfg && cfg.traceSip === false);
  const page = await httpStatus("", creds);
  check("HSTS header present", !!(page.headers || {})["strict-transport-security"]);
  check("CSP header present", !!(page.headers || {})["content-security-policy"]);
}
if (basicUser) {
  const anon = await httpStatus("", null);
  check("UI requires basic auth", anon.status === 401, anon.status);
  const anonCfg = await httpStatus("config.json", null);
  check("config.json requires basic auth", anonCfg.status === 401, anonCfg.status);
} else if (expectProduction) {
  check("UI requires basic auth (SOFTPHONE_BASIC_AUTH_USER set)", false, "not configured");
}
for (const leak of ["nginx.conf.template", "docker-entrypoint.sh", "Dockerfile"]) {
  const r = await httpStatus(leak, creds);
  check(`build file /${leak} not served`, r.status === 404, r.status);
}

// --- SIP layer (through the real WSS endpoint) ---
const browser = await chromium.launch({
  args: [
    "--use-fake-ui-for-media-stream",
    "--use-fake-device-for-media-stream",
    "--ignore-certificate-errors",
  ],
});
const context = await browser.newContext({
  ignoreHTTPSErrors: true,
  ...(basicUser ? { httpCredentials: { username: basicUser, password: basicPassword } } : {}),
});
const page = await context.newPage();
await page.goto(url, { waitUntil: "load", timeout: 20000 });
await page.waitForFunction(() => !!window.SIP, null, { timeout: 10000 });

const sip = await page.evaluate(
  async ({ cfg, sipUser, sipPassword }) => {
    const SIP = window.SIP;
    const out = {};
    const wait = (ms) => new Promise((r) => setTimeout(r, ms));

    function makeUA(user, pass) {
      const opts = {
        uri: SIP.UserAgent.makeURI(`sip:${user}@${cfg.domain}`),
        transportOptions: { server: cfg.wsServer },
        logBuiltinEnabled: false,
        reconnectionAttempts: 0,
      };
      if (pass !== null) {
        opts.authorizationUsername = user;
        opts.authorizationPassword = pass;
      }
      return new SIP.UserAgent(opts);
    }

    function outcome(start) {
      return new Promise((resolve) => {
        const t = setTimeout(() => resolve("timeout"), 10000);
        const done = (v) => {
          clearTimeout(t);
          resolve(v);
        };
        start({
          onAccept: (r) => done(r.message.statusCode),
          onReject: (r) => done(r.message.statusCode),
        }).catch((e) => done(`error:${e.message || e}`));
      });
    }

    async function register(user, pass) {
      const ua = makeUA(user, pass);
      await ua.start();
      const reg = new SIP.Registerer(ua);
      const code = await outcome((d) => reg.register({ requestDelegate: d }));
      try {
        await ua.stop();
      } catch (_) {}
      return code;
    }

    async function invite(user, pass, target) {
      const ua = makeUA(user, pass);
      await ua.start();
      const inv = new SIP.Inviter(ua, SIP.UserAgent.makeURI(target), {
        sessionDescriptionHandlerOptions: { constraints: { audio: true, video: false }, iceGatheringTimeout: 500 },
      });
      const code = await outcome((d) => inv.invite({ requestDelegate: d }));
      try {
        if (inv.state === "Established") await inv.bye();
        else await inv.cancel();
      } catch (_) {}
      await wait(300);
      try {
        await ua.stop();
      } catch (_) {}
      return code;
    }

    out.validRegister = await register(sipUser, sipPassword);
    out.wrongPassword = await register(sipUser, sipPassword + "-wrong");
    out.unknownUser = await register("9999", "whatever-password");
    out.inviteNoCredentials = await invite(sipUser, null, `sip:9196@${cfg.domain}`);
    out.inviteWrongPassword = await invite(sipUser, "nope-nope-nope", `sip:9196@${cfg.domain}`);
    out.inviteForeignDomain = await invite(sipUser, sipPassword, "sip:9196@relay-test.example.com");
    out.inviteValid = await invite(sipUser, sipPassword, `sip:9196@${cfg.domain}`);

    // Brute force: repeated wrong passwords on one WebSocket must get it closed.
    const ua = makeUA(sipUser, sipPassword + "-brute");
    let disconnected = false;
    ua.transport.stateChange.addListener((s) => {
      if (s === "Disconnected") disconnected = true;
    });
    await ua.start();
    let attempts = 0;
    for (; attempts < 8 && !disconnected; attempts++) {
      const reg = new SIP.Registerer(ua);
      await outcome((d) => reg.register({ requestDelegate: d }));
      await wait(200);
    }
    out.bruteForce = { disconnected, attempts };
    try {
      await ua.stop();
    } catch (_) {}
    return out;
  },
  { cfg, sipUser, sipPassword }
);

check("valid account can REGISTER", sip.validRegister === 200, sip.validRegister);
check("wrong password REGISTER rejected", [401, 403].includes(sip.wrongPassword), sip.wrongPassword);
check("unknown user REGISTER rejected", sip.unknownUser === 403, sip.unknownUser);
check("INVITE without credentials rejected", [401, 403, 407].includes(sip.inviteNoCredentials), sip.inviteNoCredentials);
check("INVITE with wrong password rejected", [401, 403, 407].includes(sip.inviteWrongPassword), sip.inviteWrongPassword);
check("INVITE to foreign domain refused (no open relay)", sip.inviteForeignDomain === 403, sip.inviteForeignDomain);
check("authenticated INVITE to 9196 answered", sip.inviteValid === 200, sip.inviteValid);
check(
  "WebSocket closed after repeated wrong passwords",
  sip.bruteForce.disconnected,
  `attempts=${sip.bruteForce.attempts}`
);

await browser.close();
const failed = checks.filter((c) => !c.ok);
console.log(failed.length ? `RESULT: FAIL — ${failed.length} check(s) failed` : "RESULT: PASS");
process.exit(failed.length ? 1 : 0);

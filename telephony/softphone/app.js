/* Minimal SIP.js softphone — config driven via config.json */
(function () {
  const logEl = document.getElementById("log");
  const statusEl = document.getElementById("status");
  const destEl = document.getElementById("dest");
  const remoteAudio = document.getElementById("remote-audio");

  const btnReg = document.getElementById("btn-register");
  const btnUnreg = document.getElementById("btn-unregister");
  const btnCall = document.getElementById("btn-call");
  const btnHangup = document.getElementById("btn-hangup");

  let config = null;
  let userAgent = null;
  let registerer = null;
  let session = null;

  function log(msg) {
    const line = `[${new Date().toISOString().slice(11, 19)}] ${msg}`;
    logEl.textContent = `${line}\n${logEl.textContent}`.slice(0, 8000);
    console.log(line);
  }

  function setStatus(text, ok) {
    statusEl.textContent = text;
    statusEl.classList.toggle("ok", !!ok);
  }

  function setRegistered(on) {
    btnReg.disabled = on;
    btnUnreg.disabled = !on;
    btnCall.disabled = !on;
  }

  async function loadConfig() {
    const res = await fetch("./config.json", { cache: "no-store" });
    config = await res.json();
    destEl.value = config.aiExtension || "1000";
    setStatus(`Ready — ${config.authorizationUser}@${config.domain}`, false);
    log(`config loaded ws=${config.wsServer}`);
  }

  async function register() {
    if (!window.SIP) {
      setStatus("SIP.js failed to load", false);
      return;
    }
    const { UserAgent, Registerer, Inviter } = SIP;

    const uri = UserAgent.makeURI(`sip:${config.authorizationUser}@${config.domain}`);
    if (!uri) {
      setStatus("Invalid SIP URI", false);
      return;
    }

    userAgent = new UserAgent({
      uri,
      transportOptions: { server: config.wsServer },
      authorizationUsername: config.authorizationUser,
      authorizationPassword: config.password,
      displayName: config.displayName || config.authorizationUser,
      sessionDescriptionHandlerFactoryOptions: {
        constraints: { audio: true, video: false },
      },
      logBuiltinEnabled: !!config.traceSip,
    });

    userAgent.delegate = {
      onInvite(invitation) {
        log("incoming invite (ignored in demo)");
        invitation.reject();
      },
    };

    await userAgent.start();
    registerer = new Registerer(userAgent);
    registerer.stateChange.addListener((state) => {
      log(`register state: ${state}`);
      if (state === "Registered") {
        setRegistered(true);
        setStatus("Registered", true);
      }
      if (state === "Unregistered") {
        setRegistered(false);
        setStatus("Unregistered", false);
      }
    });
    await registerer.register();
    window._Inviter = Inviter;
  }

  async function unregister() {
    if (registerer) await registerer.unregister();
    if (userAgent) await userAgent.stop();
    userAgent = null;
    registerer = null;
    setRegistered(false);
    setStatus("Unregistered", false);
  }

  async function call() {
    if (!userAgent || !window._Inviter) return;
    const dest = destEl.value.trim();
    const target = SIP.UserAgent.makeURI(`sip:${dest}@${config.domain}`);
    if (!target) {
      setStatus("Bad destination", false);
      return;
    }

    session = new window._Inviter(userAgent, target, {
      sessionDescriptionHandlerOptions: {
        constraints: { audio: true, video: false },
      },
    });

    session.stateChange.addListener((state) => {
      log(`call state: ${state}`);
      btnHangup.disabled = state === "Terminated";
      if (state === "Established") {
        setStatus(`In call with ${dest}`, true);
        try {
          const pc = session.sessionDescriptionHandler.peerConnection;
          const receivers = pc.getReceivers();
          const stream = new MediaStream();
          receivers.forEach((r) => {
            if (r.track) stream.addTrack(r.track);
          });
          remoteAudio.srcObject = stream;
        } catch (e) {
          log(`audio attach error: ${e}`);
        }
      }
      if (state === "Terminated") {
        setStatus("Registered", true);
        session = null;
      }
    });

    btnHangup.disabled = false;
    await session.invite();
    log(`INVITE ${dest}`);
  }

  async function hangup() {
    if (!session) return;
    try {
      await session.bye();
    } catch (_) {
      try { session.cancel(); } catch (__) {}
    }
    session = null;
    btnHangup.disabled = true;
  }

  btnReg.addEventListener("click", () => register().catch((e) => {
    log(String(e));
    setStatus(`Register failed: ${e.message || e}`, false);
  }));
  btnUnreg.addEventListener("click", () => unregister().catch((e) => log(String(e))));
  btnCall.addEventListener("click", () => call().catch((e) => log(String(e))));
  btnHangup.addEventListener("click", () => hangup().catch((e) => log(String(e))));

  loadConfig().catch((e) => {
    setStatus(`Config error: ${e}`, false);
  });
})();

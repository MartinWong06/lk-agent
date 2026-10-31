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
  let callInFlight = false;
  let registered = false;
  let boundPeerConnection = null;

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
    registered = on;
    btnReg.disabled = on;
    btnUnreg.disabled = !on;
    btnCall.disabled = !on || callInFlight;
  }

  function setInCall(on) {
    callInFlight = on;
    btnCall.disabled = on || !registered;
    btnHangup.disabled = !on;
  }

  function bindRemoteStream(stream, label) {
    if (!stream || !stream.getTracks().length) return;
    // Avoid srcObject churn — re-assigning mid-play() causes:
    // "The play() request was interrupted by a new load request."
    if (remoteAudio.srcObject === stream) return;
    const prev = remoteAudio.srcObject;
    if (prev && prev.getAudioTracks && prev.getAudioTracks()[0] === stream.getAudioTracks()[0]) {
      return;
    }
    remoteAudio.srcObject = stream;
    remoteAudio.muted = false;
    remoteAudio.volume = 1;
    const p = remoteAudio.play();
    if (p && typeof p.then === "function") {
      p.catch((e) => {
        const msg = e && e.message ? e.message : String(e);
        // Benign when a later bind supersedes an in-flight play()
        if (/interrupted by a new load/i.test(msg)) return;
        log(`audio play blocked: ${msg}`);
      });
    }
    log(`remote audio attached (${label}) tracks=${stream.getAudioTracks().length}`);
  }

  function attachRemoteAudio(sdh, label) {
    if (!sdh || !sdh.peerConnection) {
      log(`audio attach skipped (${label}): no peerConnection`);
      return;
    }
    const pc = sdh.peerConnection;

    // Wire ontrack once per PeerConnection
    if (boundPeerConnection !== pc) {
      boundPeerConnection = pc;
      pc.addEventListener("track", (ev) => {
        if (ev.streams && ev.streams[0]) {
          bindRemoteStream(ev.streams[0], "track");
          return;
        }
        if (ev.track) bindRemoteStream(new MediaStream([ev.track]), "track");
      });
    }

    try {
      const stream = new MediaStream();
      pc.getReceivers().forEach((r) => {
        if (r.track) stream.addTrack(r.track);
      });
      if (stream.getTracks().length) bindRemoteStream(stream, label);
    } catch (e) {
      log(`audio receivers error: ${e}`);
    }
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
      setStatus("SIP.js failed to load (check /vendor/sip-0.21.2.min.js)", false);
      log("window.SIP missing — softphone vendor bundle did not load");
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
    if (session) {
      try {
        await hangup();
      } catch (_) {}
    }
    if (registerer) await registerer.unregister();
    if (userAgent) await userAgent.stop();
    userAgent = null;
    registerer = null;
    setRegistered(false);
    setStatus("Unregistered", false);
  }

  async function call() {
    if (!userAgent || !window._Inviter) return;
    if (callInFlight || session) {
      log("call already in progress — hang up first");
      return;
    }

    const dest = destEl.value.trim();
    const target = SIP.UserAgent.makeURI(`sip:${dest}@${config.domain}`);
    if (!target) {
      setStatus("Bad destination", false);
      return;
    }

    const thisSession = new window._Inviter(userAgent, target, {
      sessionDescriptionHandlerOptions: {
        constraints: { audio: true, video: false },
      },
    });
    session = thisSession;
    setInCall(true);

    // Attach media as soon as the SDH exists (avoids Established race / null SDH)
    thisSession.delegate = {
      onSessionDescriptionHandler(sdh) {
        log("sessionDescriptionHandler ready");
        attachRemoteAudio(sdh, "sdh");
      },
    };

    thisSession.stateChange.addListener((state) => {
      // Always use thisSession — never the shared `session` var (Terminated race)
      log(`call state: ${state}`);
      if (state === "Established") {
        setStatus(`In call with ${dest}`, true);
        const sdh = thisSession.sessionDescriptionHandler;
        if (sdh) attachRemoteAudio(sdh, "established");
        else log("Established but SDH not ready yet — waiting for delegate");
      }
      if (state === "Terminated") {
        if (session === thisSession) {
          session = null;
          boundPeerConnection = null;
          setInCall(false);
          setStatus("Registered", true);
          remoteAudio.srcObject = null;
        }
      }
    });

    try {
      log(`INVITE ${dest}`);
      await thisSession.invite();
    } catch (e) {
      log(`INVITE failed: ${e.message || e}`);
      if (session === thisSession) {
        session = null;
        setInCall(false);
      }
      throw e;
    }
  }

  async function hangup() {
    const s = session;
    if (!s) return;
    try {
      await s.bye();
    } catch (_) {
      try {
        s.cancel();
      } catch (__) {}
    }
    if (session === s) {
      session = null;
      boundPeerConnection = null;
      setInCall(false);
      remoteAudio.srcObject = null;
    }
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

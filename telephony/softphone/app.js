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
  const loginEl = document.getElementById("login");
  const userEl = document.getElementById("sip-user");
  const passwordEl = document.getElementById("sip-password");

  let config = null;
  let userAgent = null;
  let registerer = null;
  let session = null;
  let callInFlight = false;
  let registered = false;
  let boundPeerConnection = null;
  // Self-healing: reconnect after WSS/Kamailio blips (not after wrong-password).
  let wantRegistered = false;
  let reconnectTimer = null;
  let reconnectAttempt = 0;
  let reconnecting = false;
  let authRejected = false;
  let disconnectAt = null;
  let sipCredentials = null;

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

  function logMediaState(pc, label) {
    try {
      const senders = pc.getSenders().filter((s) => s.track);
      const receivers = pc.getReceivers().filter((r) => r.track);
      log(
        `media(${label}) ice=${pc.iceConnectionState} conn=${pc.connectionState} ` +
          `micTracks=${senders.length} remoteTracks=${receivers.length}`
      );
      senders.forEach((s) => {
        const t = s.track;
        log(`  mic: enabled=${t.enabled} muted=${t.muted} ready=${t.readyState} label=${t.label || "?"}`);
      });
      receivers.forEach((r) => {
        const t = r.track;
        log(`  remote: enabled=${t.enabled} muted=${t.muted} ready=${t.readyState}`);
      });
    } catch (e) {
      log(`media state error: ${e}`);
    }
  }

  function logIceStats(pc) {
    if (!pc || !pc.getStats) return;
    pc.getStats()
      .then((stats) => {
        const byId = {};
        stats.forEach((r) => {
          byId[r.id] = r;
        });
        stats.forEach((r) => {
          if (r.type === "candidate-pair" && (r.state === "succeeded" || r.nominated)) {
            const loc = byId[r.localCandidateId];
            const rem = byId[r.remoteCandidateId];
            const ldesc = loc
              ? `${loc.candidateType}/${loc.protocol} ${loc.address || loc.ip}:${loc.port}`
              : r.localCandidateId;
            const rdesc = rem
              ? `${rem.candidateType}/${rem.protocol} ${rem.address || rem.ip}:${rem.port}`
              : r.remoteCandidateId;
            log(`ICE pair ${r.state}: local=${ldesc} remote=${rdesc}`);
          }
        });
      })
      .catch((e) => log(`getStats error: ${e}`));
  }

  function logRemoteSdp(sdh) {
    try {
      const pc = sdh && sdh.peerConnection;
      const sdp = pc && pc.remoteDescription && pc.remoteDescription.sdp;
      if (!sdp) return;
      const lines = sdp
        .split(/\r?\n/)
        .filter((l) => /^(c=|a=candidate:|a=ice-|a=fingerprint|m=audio)/i.test(l));
      log(`remote SDP media lines:\n${lines.slice(0, 24).join("\n")}`);
    } catch (e) {
      log(`remote SDP log error: ${e}`);
    }
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
        if (ev.track) {
          ev.track.addEventListener("unmute", () => {
            log(`remote track unmuted (RTP flowing) id=${ev.track.id}`);
            logMediaState(pc, "unmute");
          });
          ev.track.addEventListener("mute", () => {
            log(`remote track muted (no RTP) id=${ev.track.id}`);
          });
        }
        if (ev.streams && ev.streams[0]) {
          bindRemoteStream(ev.streams[0], "track");
          return;
        }
        if (ev.track) bindRemoteStream(new MediaStream([ev.track]), "track");
      });
      pc.addEventListener("iceconnectionstatechange", () => {
        log(`iceConnectionState=${pc.iceConnectionState}`);
        if (pc.iceConnectionState === "connected" || pc.iceConnectionState === "completed") {
          logIceStats(pc);
          logRemoteSdp(sdh);
        }
        if (pc.iceConnectionState === "failed" || pc.iceConnectionState === "disconnected") {
          logIceStats(pc);
          log(
            `ICE ${pc.iceConnectionState} — check SOFTPHONE_MEDIA_IP=<this PC's LAN IP> ` +
              "(Asterisk logs 'ice_host_candidates'), open https://<LAN>:8443/, and allow " +
              "UDP 20000-20050 in Windows Firewall. Run scripts/doctor-windows.ps1"
          );
        }
        logMediaState(pc, "ice");
      });
      pc.addEventListener("connectionstatechange", () => {
        log(`pc.connectionState=${pc.connectionState}`);
      });
    }

    try {
      const stream = new MediaStream();
      pc.getReceivers().forEach((r) => {
        if (r.track) stream.addTrack(r.track);
      });
      if (stream.getTracks().length) bindRemoteStream(stream, label);
      logMediaState(pc, label);
    } catch (e) {
      log(`audio receivers error: ${e}`);
    }
  }

  async function ensureMicrophone() {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      const hint = (config && config.preferredPageUrl) || "https://<LAN_IP>:8443/";
      throw new Error(
        `getUserMedia blocked on insecure HTTP LAN — open ${hint} ` +
          "(accept the self-signed cert warning), not http://..."
      );
    }
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: false });
    const track = stream.getAudioTracks()[0];
    if (!track) throw new Error("No microphone track returned");
    log(`mic granted: ${track.label || "default"} enabled=${track.enabled}`);
    // Keep the permission warm; SIP.js will open its own track for the call.
    track.stop();
    return true;
  }

  function pageHostIsLoopback() {
    const h = (window.location.hostname || "").toLowerCase();
    return h === "localhost" || h === "127.0.0.1" || h === "[::1]";
  }

  async function loadConfig() {
    const res = await fetch("./config.json", { cache: "no-store" });
    config = await res.json();
    destEl.value = config.aiExtension || "1000";
    userEl.value = config.authorizationUser || "";
    // Production does not ship the SIP password in config.json — ask for it.
    loginEl.hidden = !!config.password;
    setStatus(
      config.password
        ? `Ready — ${config.authorizationUser}@${config.domain}`
        : "Enter your SIP user and password, then Register",
      false
    );
    log(`config loaded ws=${config.wsServer}`);
    const preferred = config.preferredPageUrl ||
      (config.preferredPageHost ? `https://${config.preferredPageHost}:8443/` : "");
    if (preferred && pageHostIsLoopback()) {
      log(`WARNING: open ${preferred} (HTTPS LAN) — localhost ICE fails in Docker Desktop`);
      setStatus(`Open ${preferred} for mic+audio`, false);
    } else if (pageHostIsLoopback()) {
      log(
        "WARNING: set SOFTPHONE_PUBLIC_HOST to your LAN IP and open https://<LAN_IP>:8443/ " +
          "(see scripts/bringup-windows.ps1)"
      );
    } else if (window.location.protocol === "http:" && config.httpsEnabled) {
      log(`WARNING: use HTTPS for mic access: ${preferred || "https://<LAN>:8443/"}`);
      setStatus(`Use HTTPS: ${preferred || "https://<LAN>:8443/"}`, false);
    }
  }

  function clearReconnect() {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    reconnectAttempt = 0;
    reconnecting = false;
    disconnectAt = null;
  }

  function scheduleReconnect(reason) {
    if (!wantRegistered || authRejected || reconnectTimer) return;
    reconnectAttempt += 1;
    const delay = Math.min(30000, 1000 * Math.pow(2, Math.min(reconnectAttempt - 1, 5)));
    reconnecting = true;
    setRegistered(false);
    setStatus(`Reconnecting… (attempt ${reconnectAttempt})`, false);
    log(`transport: disconnected (${reason}) — retry in ${delay}ms`);
    reconnectTimer = setTimeout(() => {
      reconnectTimer = null;
      reconnectNow().catch((e) => {
        log(`reconnect failed: ${e.message || e}`);
        scheduleReconnect("retry-failed");
      });
    }, delay);
  }

  async function reconnectNow() {
    if (!wantRegistered || authRejected || !sipCredentials) return;
    log(`reconnect attempt ${reconnectAttempt}`);
    try {
      if (registerer) {
        try {
          await registerer.unregister();
        } catch (_) {}
      }
      if (userAgent) {
        try {
          await userAgent.stop();
        } catch (_) {}
      }
      userAgent = null;
      registerer = null;
      await startUserAgent(sipCredentials.user, sipCredentials.password, { skipMic: true });
    } catch (e) {
      throw e;
    }
  }

  async function startUserAgent(sipUser, sipPassword, opts) {
    const { UserAgent, Registerer, Inviter } = SIP;
    const uri = UserAgent.makeURI(`sip:${sipUser}@${config.domain}`);
    if (!uri) {
      setStatus("Invalid SIP URI", false);
      return;
    }

    const iceServers = Array.isArray(config.iceServers) ? config.iceServers : [];
    if (!opts || !opts.skipMic) {
      log(`ICE servers configured: ${iceServers.length} (0 = direct LAN media via Asterisk ICE host mapping)`);
    }

    userAgent = new UserAgent({
      uri,
      transportOptions: {
        server: config.wsServer,
        // We own reconnect + re-REGISTER (SIP.js built-in reconnect alone is not enough).
        reconnectionAttempts: 0,
      },
      authorizationUsername: sipUser,
      authorizationPassword: sipPassword,
      displayName: config.displayName || sipUser,
      sessionDescriptionHandlerFactoryOptions: {
        constraints: { audio: true, video: false },
        peerConnectionConfiguration: { iceServers },
      },
      logBuiltinEnabled: !!config.traceSip,
    });

    userAgent.delegate = {
      onInvite(invitation) {
        log("incoming invite (ignored in demo)");
        invitation.reject();
      },
    };

    userAgent.transport.stateChange.addListener((state) => {
      log(`transport state: ${state}`);
      if (state === "Disconnected" && wantRegistered && !authRejected) {
        if (!disconnectAt) disconnectAt = Date.now();
        scheduleReconnect("wss");
      }
      if (state === "Connected" && reconnecting) {
        log("transport: connected");
      }
    });

    await userAgent.start();
    registerer = new Registerer(userAgent);
    registerer.stateChange.addListener((state) => {
      log(`register state: ${state}`);
      if (state === "Registered") {
        if (disconnectAt) {
          const sec = Math.round((Date.now() - disconnectAt) / 100) / 10;
          log(`SELFHEAL re-registered in ${sec}s after disconnect`);
        }
        clearReconnect();
        setRegistered(true);
        setStatus("Registered", true);
      }
      if (state === "Unregistered" && wantRegistered && !authRejected && !reconnecting) {
        setRegistered(false);
      }
    });
    await registerer.register({
      requestDelegate: {
        onReject(response) {
          const code = response.message.statusCode;
          log(`REGISTER rejected ${code} ${response.message.reasonPhrase}`);
          if (code === 401 || code === 403) {
            authRejected = true;
            wantRegistered = false;
            clearReconnect();
            setStatus("Wrong SIP user or password", false);
          } else {
            setStatus(`Register failed (${code})`, false);
            scheduleReconnect(`register-${code}`);
          }
        },
      },
    });
    window._Inviter = Inviter;
  }

  async function register() {
    if (!window.SIP) {
      setStatus("SIP.js failed to load (check /vendor/sip-0.21.2.min.js)", false);
      log("window.SIP missing — softphone vendor bundle did not load");
      return;
    }

    const sipUser = config.password ? config.authorizationUser : userEl.value.trim();
    const sipPassword = config.password || passwordEl.value;
    if (!sipUser || !sipPassword) {
      setStatus("SIP user and password are required", false);
      return;
    }

    authRejected = false;
    wantRegistered = true;
    sipCredentials = { user: sipUser, password: sipPassword };
    clearReconnect();

    try {
      await ensureMicrophone();
    } catch (e) {
      log(`mic preflight failed: ${e.message || e}`);
      setStatus(`Microphone required: ${e.message || e}`, false);
      wantRegistered = false;
      throw e;
    }

    await startUserAgent(sipUser, sipPassword, { skipMic: false });
  }

  async function unregister() {
    wantRegistered = false;
    clearReconnect();
    if (session) {
      try {
        await hangup();
      } catch (_) {}
    }
    if (registerer) {
      try {
        await registerer.unregister();
      } catch (_) {}
    }
    if (userAgent) {
      try {
        await userAgent.stop();
      } catch (_) {}
    }
    userAgent = null;
    registerer = null;
    sipCredentials = null;
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

    const iceServers = Array.isArray(config.iceServers) ? config.iceServers : [];
    const thisSession = new window._Inviter(userAgent, target, {
      sessionDescriptionHandlerOptions: {
        constraints: { audio: true, video: false },
        peerConnectionConfiguration: { iceServers },
        iceGatheringTimeout: iceServers.length ? 2000 : 500,
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
      await thisSession.invite({
        requestDelegate: {
          onAccept: (resp) => log(`INVITE accepted ${resp.message.statusCode}`),
          onProgress: (resp) => log(`INVITE progress ${resp.message.statusCode}`),
          onRedirect: (resp) => log(`INVITE redirect ${resp.message.statusCode}`),
          onReject: (resp) => {
            const m = resp.message;
            log(`INVITE rejected ${m.statusCode} ${m.reasonPhrase || ""}`);
          },
        },
      });
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

  window.addEventListener("online", () => {
    if (wantRegistered && !authRejected) {
      log("browser online — scheduling reconnect");
      scheduleReconnect("online");
    }
  });
  document.addEventListener("visibilitychange", () => {
    if (
      document.visibilityState === "visible" &&
      wantRegistered &&
      !authRejected &&
      (!userAgent || !userAgent.transport || userAgent.transport.state === "Disconnected")
    ) {
      log("tab visible with dead transport — scheduling reconnect");
      scheduleReconnect("visible");
    }
  });

  loadConfig().catch((e) => {
    setStatus(`Config error: ${e}`, false);
  });
})();

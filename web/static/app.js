(() => {
  // ─── State ──────────────────────────────────────────────────────────────────
  let editingShare = null; // null = add mode, string = edit mode

  // ─── Elements ───────────────────────────────────────────────────────────────
  const loginView     = document.getElementById("login-view");
  const dashView      = document.getElementById("dashboard-view");
  const loginForm     = document.getElementById("login-form");
  const loginError    = document.getElementById("login-error");
  const sharesGrid    = document.getElementById("shares-grid");
  const emptyMsg      = document.getElementById("empty-msg");
  const addBtn        = document.getElementById("add-btn");
  const logoutBtn     = document.getElementById("logout-btn");
  const modalOverlay  = document.getElementById("modal-overlay");
  const modalTitle    = document.getElementById("modal-title");
  const shareForm     = document.getElementById("share-form");
  const modalError    = document.getElementById("modal-error");
  const modalCancel   = document.getElementById("modal-cancel");
  const nameGroup     = document.getElementById("name-group");
  const fName         = document.getElementById("f-name");
  const fS3Other      = document.getElementById("f-s3-other");
  const fR2Fields     = document.getElementById("f-r2-fields");
  const fS3Fields     = document.getElementById("f-s3-fields");
  const fAccount      = document.getElementById("f-account");
  const fEu           = document.getElementById("f-eu");
  const fEndpoint     = document.getElementById("f-endpoint");
  const fKey          = document.getElementById("f-key");
  const fSecret       = document.getElementById("f-secret");
  const fSambaUser    = document.getElementById("f-samba-user");
  const fSambaPw      = document.getElementById("f-samba-pw");
  const modalSubmit   = document.getElementById("modal-submit");

  // ─── API helpers ────────────────────────────────────────────────────────────
  async function api(method, path, body) {
    const opts = {
      method,
      headers: { "Content-Type": "application/json" },
      credentials: "same-origin",
    };
    if (body !== undefined) opts.body = JSON.stringify(body);
    const res = await fetch(path, opts);
    const json = await res.json().catch(() => ({}));
    if (!res.ok) {
      const err = new Error(json.error || `HTTP ${res.status}`);
      err.status = res.status;
      throw err;
    }
    return json;
  }

  // ─── Login ──────────────────────────────────────────────────────────────────
  const loginSubmit = loginForm.querySelector("button[type=submit]");

  loginForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    loginError.hidden = true;
    loginSubmit.disabled = true;
    loginSubmit.textContent = "Signing in…";
    try {
      await api("POST", "/login", {
        username: document.getElementById("login-user").value,
        password: document.getElementById("login-pass").value,
      });
      showDashboard();
    } catch (err) {
      loginError.textContent = err.message;
      loginError.hidden = false;
      loginSubmit.disabled = false;
      loginSubmit.textContent = "Sign in";
    }
  });

  logoutBtn.addEventListener("click", async () => {
    await fetch("/logout", { credentials: "same-origin" });
    showLogin();
  });

  function showLogin(reason) {
    stopStats();
    dashView.hidden = true;
    loginView.hidden = false;
    loginSubmit.disabled = false;
    loginSubmit.textContent = "Sign in";
    document.getElementById("login-user").value = "";
    document.getElementById("login-pass").value = "";
    if (reason) {
      loginError.textContent = reason;
      loginError.hidden = false;
    }
  }

  function showDashboard() {
    loginView.hidden = true;
    dashView.hidden = false;
    loadShares();
    startStats();
    checkVersion();
  }

  // ─── Version check + update ─────────────────────────────────────────────────
  const versionBadge  = document.getElementById("version-badge");
  const updateBtn     = document.getElementById("update-btn");
  const updateOverlay = document.getElementById("update-overlay");
  const updateMsg     = document.getElementById("update-msg");

  async function checkVersion() {
    versionBadge.hidden = true;
    updateBtn.hidden    = true;
    try {
      const v = await api("GET", "/api/version");
      if (v.update_available) {
        versionBadge.textContent = `v${v.installed || "?"}  →  v${v.latest}`;
        versionBadge.className   = "version-badge version-badge--update";
        updateBtn.hidden         = false;
      } else if (v.installed && v.installed !== "unknown") {
        versionBadge.textContent = `v${v.installed}`;
        versionBadge.className   = "version-badge version-badge--ok";
      }
      versionBadge.hidden = false;
    } catch (_) { /* no version info — stay hidden */ }
  }

  updateBtn.addEventListener("click", async () => {
    updateOverlay.hidden = false;
    updateMsg.textContent = "Starting update…";
    try {
      await api("POST", "/api/update");
    } catch (_) { /* service restarts — connection drops, that's expected */ }

    updateMsg.textContent = "Restarting service — reconnecting…";

    // Poll until the service is back up, then reload
    const poll = async () => {
      try {
        const res = await fetch("/", { cache: "no-store" });
        if (res.ok) { location.reload(); return; }
      } catch (_) {}
      setTimeout(poll, 1500);
    };
    setTimeout(poll, 4000);
  });

  // ─── Shares list ────────────────────────────────────────────────────────────
  async function loadShares() {
    try {
      const shares = await api("GET", "/api/shares");
      renderShares(shares);
    } catch (err) {
      if (err.status === 401) { showLogin("Session expired — please log in again."); return; }
      sharesGrid.innerHTML = `<p class="error-msg">Failed to load shares: ${err.message}</p>`;
    }
  }

  function renderShares(shares) {
    sharesGrid.innerHTML = "";
    emptyMsg.hidden = shares.length > 0;
    shares.forEach((s) => {
      const card = document.createElement("div");
      card.className = "share-card";
      card.innerHTML = `
        <div class="share-card__header">
          <span class="share-name">${esc(s.name)}</span>
          <span class="badge ${s.mounted ? "badge--mounted" : "badge--unmounted"}">
            ${s.mounted ? "mounted" : "unmounted"}
          </span>
        </div>
        <div class="share-card__body">
          <span class="share-detail">Samba user: <strong>${esc(s.samba_user)}</strong></span>
          <span class="share-detail">SMB path: <code>\\\\${window.location.hostname}\\${esc(s.name)}</code></span>
        </div>
        <div class="share-card__actions">
          <button class="btn-secondary btn-edit" data-name="${esc(s.name)}">Edit</button>
          <button class="btn-ghost btn-clean" data-name="${esc(s.name)}">Clean cache</button>
          <button class="btn-danger btn-delete" data-name="${esc(s.name)}">Delete</button>
        </div>`;
      sharesGrid.appendChild(card);
    });

    sharesGrid.querySelectorAll(".btn-edit").forEach((btn) =>
      btn.addEventListener("click", () => openEditModal(btn.dataset.name))
    );
    sharesGrid.querySelectorAll(".btn-clean").forEach((btn) =>
      btn.addEventListener("click", () => confirmCleanCache(btn.dataset.name))
    );
    sharesGrid.querySelectorAll(".btn-delete").forEach((btn) =>
      btn.addEventListener("click", () => confirmDelete(btn.dataset.name))
    );
  }

  // ─── Modal ──────────────────────────────────────────────────────────────────
  addBtn.addEventListener("click", openAddModal);
  modalCancel.addEventListener("click", closeModal);
  modalOverlay.addEventListener("click", (e) => {
    if (e.target === modalOverlay) closeModal();
  });

  function setProviderMode(isS3Other) {
    fS3Other.checked      = isS3Other;
    fR2Fields.hidden      = isS3Other;
    fS3Fields.hidden      = !isS3Other;
    fAccount.required     = !isS3Other;
    fEndpoint.required    = isS3Other;
  }

  fS3Other.addEventListener("change", () => setProviderMode(fS3Other.checked));

  function openAddModal() {
    editingShare = null;
    modalTitle.textContent = "Add Share";
    shareForm.reset();
    fEu.checked = true;
    fSambaUser.value = "";
    nameGroup.hidden = false;
    fName.required = true;
    fKey.required = true;
    fSecret.required = true;
    fSambaPw.required = true;
    setProviderMode(false);
    setModalError(null);
    modalOverlay.hidden = false;
    fName.focus();
  }

  async function openEditModal(name) {
    editingShare = name;
    modalTitle.textContent = `Edit — ${name}`;
    setModalError(null);
    modalSubmit.disabled = true;
    modalSubmit.textContent = "Loading…";
    modalOverlay.hidden = false;
    nameGroup.hidden = true;
    fName.required = false;
    fKey.required = false;
    fSecret.required = false;
    fSambaPw.required = false;

    try {
      const s = await api("GET", `/api/shares/${encodeURIComponent(name)}`);
      setProviderMode(!s.is_r2);
      fAccount.value     = s.account_id;
      fEu.checked        = s.eu_jurisdiction;
      fEndpoint.value    = s.endpoint_url;
      fKey.value         = s.access_key_id;
      fSecret.value      = s.secret_access_key;
      fSambaUser.value   = s.samba_user;
      fSambaPw.value     = "";
    } catch (err) {
      setModalError(err.message);
    } finally {
      modalSubmit.disabled = false;
      modalSubmit.textContent = "Save";
    }
  }

  function closeModal() {
    modalOverlay.hidden = true;
    editingShare = null;
  }

  shareForm.addEventListener("submit", async (e) => {
    e.preventDefault();
    setModalError(null);
    modalSubmit.disabled = true;
    modalSubmit.textContent = "Saving…";

    const isS3Other = fS3Other.checked;
    const body = {
      ...(isS3Other
        ? { endpoint_url: fEndpoint.value.trim() }
        : { account_id: fAccount.value.trim(), eu: fEu.checked }),
      access_key_id:      fKey.value.trim(),
      secret_access_key:  fSecret.value.trim(),
      samba_user:         fSambaUser.value.trim(),
      samba_password:     fSambaPw.value,
    };

    try {
      if (editingShare) {
        await api("PUT", `/api/shares/${encodeURIComponent(editingShare)}`, body);
      } else {
        await api("POST", "/api/shares", { name: fName.value.trim(), ...body });
      }
      closeModal();
      loadShares();
    } catch (err) {
      setModalError(err.message);
    } finally {
      modalSubmit.disabled = false;
      modalSubmit.textContent = "Save";
    }
  });

  function setModalError(msg) {
    modalError.hidden = !msg;
    modalError.textContent = msg || "";
  }

  // ─── Delete ─────────────────────────────────────────────────────────────────
  async function confirmDelete(name) {
    if (!confirm(`Delete share "${name}" and unmount the R2 bucket?\n\nThis cannot be undone.`)) return;
    try {
      await api("DELETE", `/api/shares/${encodeURIComponent(name)}`);
      loadShares();
    } catch (err) {
      alert(`Failed to delete share: ${err.message}`);
    }
  }

  // ─── Clean cache modal ──────────────────────────────────────────────────────
  function fmtMb(bytes) {
    if (bytes < 1048576) return `${(bytes / 1024).toFixed(0)} KB`;
    if (bytes < 1073741824) return `${(bytes / 1048576).toFixed(0)} MB`;
    return `${(bytes / 1073741824).toFixed(2)} GB`;
  }

  const ccOverlay    = document.getElementById("clean-cache-overlay");
  const ccName       = document.getElementById("cc-name");
  const ccLoading    = document.getElementById("cc-loading");
  const ccResult     = document.getElementById("cc-result");
  const ccStaleRow   = document.getElementById("cc-stale-row");
  const ccStaleLabel = document.getElementById("cc-stale-label");
  const ccDirtyRow   = document.getElementById("cc-dirty-row");
  const ccDirtyLabel = document.getElementById("cc-dirty-label");
  const ccDesc       = document.getElementById("cc-desc");
  const ccError      = document.getElementById("cc-error");
  const ccCancel     = document.getElementById("cc-cancel");
  const ccCleanStale = document.getElementById("cc-clean-stale");
  const ccCleanAll   = document.getElementById("cc-clean-all");

  ccCancel.addEventListener("click", () => { ccOverlay.hidden = true; });
  ccOverlay.addEventListener("click", (e) => { if (e.target === ccOverlay) ccOverlay.hidden = true; });

  async function confirmCleanCache(shareName) {
    ccName.textContent    = shareName;
    ccLoading.hidden      = false;
    ccResult.hidden       = true;
    ccError.hidden        = true;
    ccCleanStale.hidden   = true;
    ccCleanAll.hidden     = true;
    ccOverlay.hidden      = false;

    let status;
    try {
      status = await api("GET", `/api/shares/${encodeURIComponent(shareName)}/cache-status`);
    } catch (err) {
      ccLoading.hidden = true;
      ccError.textContent = err.message;
      ccError.hidden = false;
      return;
    }

    ccLoading.hidden = true;
    ccResult.hidden  = false;

    const { stale_bytes, dirty_bytes, stale_count, dirty_count } = status;

    if (stale_bytes === 0 && dirty_bytes === 0) {
      ccDesc.textContent = "Cache is already empty — nothing to clean.";
      return;
    }

    ccStaleRow.hidden = stale_bytes === 0;
    if (stale_bytes > 0) {
      ccStaleLabel.textContent =
        `${fmtMb(stale_bytes)} — ${stale_count} file${stale_count !== 1 ? "s" : ""} already on R2`;
    }

    ccDirtyRow.hidden = dirty_bytes === 0;
    if (dirty_bytes > 0) {
      ccDirtyLabel.textContent =
        `${fmtMb(dirty_bytes)} — ${dirty_count} file${dirty_count !== 1 ? "s" : ""} not yet uploaded`;
    }

    if (stale_bytes > 0 && dirty_bytes > 0) {
      ccDesc.textContent =
        "Remove uploaded files only, or remove everything including pending uploads " +
        "(backup client will need to re-send those files).";
      ccCleanStale.textContent = `Remove uploaded (${fmtMb(stale_bytes)})`;
      ccCleanStale.hidden = false;
      ccCleanAll.textContent  = "Remove all";
      ccCleanAll.hidden = false;
    } else if (stale_bytes > 0) {
      ccDesc.textContent = "All cached data is already on R2 and safe to remove.";
      ccCleanStale.textContent = `Remove ${fmtMb(stale_bytes)}`;
      ccCleanStale.hidden = false;
    } else {
      ccDesc.textContent =
        "All cached data is still pending upload. Removing it will require the backup client to re-send.";
      ccCleanAll.textContent = `Remove ${fmtMb(dirty_bytes)}`;
      ccCleanAll.hidden = false;
    }

    async function doClean(stale_only) {
      ccOverlay.hidden = true;
      try {
        await api("POST", `/api/shares/${encodeURIComponent(shareName)}/clean-cache`, { stale_only });
        loadShares();
      } catch (err) {
        ccError.textContent = err.message;
        ccError.hidden = false;
        ccOverlay.hidden = false;
      }
    }

    ccCleanStale.onclick = () => doClean(true);
    ccCleanAll.onclick   = () => doClean(false);
  }

  // ─── Stats ──────────────────────────────────────────────────────────────────
  const HISTORY = 60;
  const statsHistory = { tx: [], rx: [] };
  let prevNet = null;
  let statsTimer = null;

  function fmtSpeed(b) {
    if (b < 1024) return b.toFixed(0) + " B/s";
    if (b < 1048576) return (b / 1024).toFixed(1) + " KB/s";
    return (b / 1048576).toFixed(2) + " MB/s";
  }

  function fmtTotal(b) {
    if (b < 1073741824) return (b / 1048576).toFixed(0) + " MB";
    return (b / 1073741824).toFixed(2) + " GB";
  }

  function drawSparkline(id, data, maxVal) {
    const el = document.getElementById(id);
    if (!el || data.length < 2) { el && el.setAttribute("points", ""); return; }
    const w = 300, h = 60, pad = 4;
    const mx = maxVal || 1;
    const pts = data.map((v, i) => {
      const x = pad + (i / (HISTORY - 1)) * (w - pad * 2);
      const y = h - pad - (v / mx) * (h - pad * 2);
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    }).join(" ");
    el.setAttribute("points", pts);
  }

  async function pollStats() {
    try {
      const s = await api("GET", "/api/stats");

      if (prevNet) {
        const dt = Math.max(s.timestamp - prevNet.ts, 0.1);
        const txRate = (s.network.tx_bytes - prevNet.tx) / dt;
        const rxRate = (s.network.rx_bytes - prevNet.rx) / dt;

        statsHistory.tx.push(Math.max(txRate, 0));
        statsHistory.rx.push(Math.max(rxRate, 0));
        if (statsHistory.tx.length > HISTORY) statsHistory.tx.shift();
        if (statsHistory.rx.length > HISTORY) statsHistory.rx.shift();

        document.getElementById("tx-speed").textContent = fmtSpeed(txRate);
        document.getElementById("rx-speed").textContent = fmtSpeed(rxRate);

        const maxRate = Math.max(...statsHistory.tx, ...statsHistory.rx, 1);
        drawSparkline("tx-line", statsHistory.tx, maxRate);
        drawSparkline("rx-line", statsHistory.rx, maxRate);
      }

      prevNet = { tx: s.network.tx_bytes, rx: s.network.rx_bytes, ts: s.timestamp };
      document.getElementById("tx-total").textContent = fmtTotal(s.network.tx_bytes);
      document.getElementById("rx-total").textContent = fmtTotal(s.network.rx_bytes);

      const mem = s.memory;
      document.getElementById("mem-label").textContent =
        `${mem.used_mb} / ${mem.total_mb} MB (${mem.pct}%)`;
      const memBar = document.getElementById("mem-bar");
      memBar.style.width = `${mem.pct}%`;
      memBar.className = "bar" + (mem.pct > 85 ? " bar--warn" : "");

      document.getElementById("load-label").textContent = s.load_1.toFixed(2);

      document.getElementById("cache-rows").innerHTML = s.shares.map((sh) => `
        <div class="cache-row">
          <span class="cache-name">${esc(sh.name)}</span>
          <span class="badge ${sh.mounted ? "badge--mounted" : "badge--unmounted"}">
            ${sh.mounted ? "mounted" : "unmounted"}
          </span>
          <span class="cache-size">${(sh.cache_bytes / 1048576).toFixed(0)} MB cached</span>
        </div>`).join("");

      const wdSection = document.getElementById("watchdog-section");
      const wdRows    = document.getElementById("watchdog-rows");
      const wdCount   = document.getElementById("watchdog-count");
      const log = s.watchdog_log || [];
      if (log.length === 0) {
        wdSection.hidden = true;
      } else {
        wdSection.hidden = false;
        wdCount.textContent = `${log.length} event${log.length !== 1 ? "s" : ""}`;
        wdRows.innerHTML = [...log].reverse().map((line) => {
          const cls = line.includes("remount failed") ? "wd-fail"
                    : line.includes("remounted:")     ? "wd-ok"
                    : "wd-warn";
          return `<div class="watchdog-row ${cls}">${esc(line)}</div>`;
        }).join("");
      }
    } catch (e) {
      if (e.status === 401) { showLogin("Session expired — please log in again."); }
    }
  }

  function startStats() {
    prevNet = null;
    statsHistory.tx.length = 0;
    statsHistory.rx.length = 0;
    pollStats();
    statsTimer = setInterval(pollStats, 3000);
  }

  function stopStats() {
    clearInterval(statsTimer);
    statsTimer = null;
  }

  // ─── Utils ──────────────────────────────────────────────────────────────────
  function esc(str) {
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  // ─── Settings ───────────────────────────────────────────────────────────────
  const settingsOverlay = document.getElementById("settings-overlay");
  const settingsCancel  = document.getElementById("settings-cancel");
  const settingsSave    = document.getElementById("settings-save");
  const settingsError   = document.getElementById("settings-error");
  const sVfsCacheGb     = document.getElementById("s-vfs-cache-gb");
  const sTransfers      = document.getElementById("s-transfers");
  const sCheckers       = document.getElementById("s-checkers");
  const sBufferMb       = document.getElementById("s-buffer-mb");
  const sWriteBackS     = document.getElementById("s-write-back-s");
  const sSnmpEnabled    = document.getElementById("s-snmp-enabled");
  const sSnmpCommunity  = document.getElementById("s-snmp-community");
  const sSnmpAllowed    = document.getElementById("s-snmp-allowed");
  const snmpFields      = document.getElementById("snmp-fields");
  const cfgBackupBtn      = document.getElementById("cfg-backup-btn");
  const cfgRestoreBtn     = document.getElementById("cfg-restore-btn");
  const cfgBucketRow      = document.getElementById("cfg-bucket-row");
  const cfgBucketSelect   = document.getElementById("cfg-bucket-select");
  const cfgBucketSaveBtn  = document.getElementById("cfg-bucket-save-btn");

  document.getElementById("settings-btn").addEventListener("click", openSettings);
  settingsCancel.addEventListener("click", closeSettings);
  settingsOverlay.addEventListener("click", (e) => { if (e.target === settingsOverlay) closeSettings(); });

  sSnmpEnabled.addEventListener("change", () => {
    snmpFields.style.opacity = sSnmpEnabled.checked ? "1" : "0.4";
    snmpFields.querySelectorAll("input").forEach((i) => (i.disabled = !sSnmpEnabled.checked));
  });

  async function openSettings() {
    settingsError.hidden = true;
    settingsSave.disabled = true;
    settingsSave.textContent = "Loading…";
    settingsOverlay.hidden = false;
    try {
      const cfg = await api("GET", "/api/settings");
      sVfsCacheGb.value          = cfg.vfs_cache_gb;
      sTransfers.value           = cfg.transfers;
      sCheckers.value            = cfg.checkers;
      sBufferMb.value            = cfg.buffer_mb;
      sWriteBackS.value          = cfg.write_back_s;
      sSnmpEnabled.checked       = cfg.snmp_enabled;
      sSnmpCommunity.value       = cfg.snmp_community;
      sSnmpAllowed.value         = cfg.snmp_allowed;
      snmpFields.style.opacity   = cfg.snmp_enabled ? "1" : "0.4";
      snmpFields.querySelectorAll("input").forEach((i) => (i.disabled = !cfg.snmp_enabled));
    } catch (err) {
      settingsError.textContent = err.message;
      settingsError.hidden = false;
    } finally {
      settingsSave.disabled = false;
      settingsSave.textContent = "Save";
    }
    // Populate bucket select (best-effort, non-blocking)
    try {
      const shares = await api("GET", "/api/shares");
      cfgBucketSelect.innerHTML = shares.length
        ? shares.map((s) => `<option value="${esc(s.name)}">${esc(s.name)}</option>`).join("")
        : `<option value="" disabled>No shares configured</option>`;
      cfgBucketRow.hidden    = shares.length === 0;
      cfgBucketSaveBtn.disabled = shares.length === 0;
    } catch (_) {
      cfgBucketRow.hidden = true;
    }
  }

  function closeSettings() {
    settingsOverlay.hidden = true;
  }

  settingsSave.addEventListener("click", async () => {
    settingsError.hidden = true;
    settingsSave.disabled = true;
    settingsSave.textContent = "Saving…";
    try {
      await api("POST", "/api/settings", {
        vfs_cache_gb:   parseInt(sVfsCacheGb.value,  10) || 70,
        transfers:      parseInt(sTransfers.value,    10) || 2,
        checkers:       parseInt(sCheckers.value,     10) || 2,
        buffer_mb:      parseInt(sBufferMb.value,     10) || 64,
        write_back_s:   parseInt(sWriteBackS.value,   10) || 5,
        snmp_enabled:   sSnmpEnabled.checked,
        snmp_community: sSnmpCommunity.value.trim(),
        snmp_allowed:   sSnmpAllowed.value.trim(),
      });
      closeSettings();
    } catch (err) {
      settingsError.textContent = err.message;
      settingsError.hidden = false;
    } finally {
      settingsSave.disabled = false;
      settingsSave.textContent = "Save";
    }
  });

  // ─── Config backup / restore ────────────────────────────────────────────────
  cfgBackupBtn.addEventListener("click", () => {
    window.location = "/api/config-backup";
  });

  cfgBucketSaveBtn.addEventListener("click", async () => {
    const bucket = cfgBucketSelect.value;
    if (!bucket) return;
    cfgBucketSaveBtn.disabled = true;
    cfgBucketSaveBtn.textContent = "Saving…";
    settingsError.hidden = true;
    try {
      const r = await api("POST", "/api/config-backup-to-bucket", { bucket });
      settingsError.style.color = "var(--success)";
      settingsError.textContent = `Saved as ${r.filename} in bucket "${bucket}"`;
      settingsError.hidden = false;
      setTimeout(() => {
        settingsError.hidden = true;
        settingsError.style.color = "";
      }, 4000);
    } catch (err) {
      settingsError.style.color = "";
      settingsError.textContent = "Save failed: " + err.message;
      settingsError.hidden = false;
    } finally {
      cfgBucketSaveBtn.disabled = false;
      cfgBucketSaveBtn.textContent = "☁ Save to bucket";
    }
  });

  cfgRestoreBtn.addEventListener("click", () => {
    const inp = document.createElement("input");
    inp.type = "file";
    inp.accept = ".json,application/json";
    inp.onchange = async () => {
      if (!inp.files.length) return;
      let parsed;
      try {
        parsed = JSON.parse(await inp.files[0].text());
      } catch {
        settingsError.textContent = "Invalid JSON file";
        settingsError.hidden = false;
        return;
      }
      settingsError.hidden = true;
      cfgRestoreBtn.disabled = true;
      cfgBackupBtn.disabled  = true;
      settingsSave.disabled  = true;
      try {
        await api("POST", "/api/config-restore", parsed);
      } catch (err) {
        settingsError.textContent = "Restore failed: " + err.message;
        settingsError.hidden = false;
        cfgRestoreBtn.disabled = false;
        cfgBackupBtn.disabled  = false;
        settingsSave.disabled  = false;
        return;
      }
      closeSettings();
      updateOverlay.hidden  = false;
      updateMsg.textContent = "Config restored — reconnecting…";
      const poll = async () => {
        try {
          const res = await fetch("/", { cache: "no-store" });
          if (res.ok) { location.reload(); return; }
        } catch (_) {}
        setTimeout(poll, 1500);
      };
      setTimeout(poll, 2000);
    };
    inp.click();
  });

  // ─── Init ───────────────────────────────────────────────────────────────────
  // Try to load shares — if 401, stay on login page
  api("GET", "/api/shares")
    .then((shares) => { showDashboard(); renderShares(shares); })
    .catch(() => { /* stay on login */ });
})();

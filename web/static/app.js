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
  const fAccount      = document.getElementById("f-account");
  const fEu           = document.getElementById("f-eu");
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

  function showLogin() {
    dashView.hidden = true;
    loginView.hidden = false;
    document.getElementById("login-user").value = "";
    document.getElementById("login-pass").value = "";
  }

  function showDashboard() {
    loginView.hidden = true;
    dashView.hidden = false;
    loadShares();
  }

  // ─── Shares list ────────────────────────────────────────────────────────────
  async function loadShares() {
    try {
      const shares = await api("GET", "/api/shares");
      renderShares(shares);
    } catch (err) {
      if (err.status === 401) { showLogin(); return; }
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
          <span class="share-detail">SMB path: <code>\\\\&lt;IP&gt;\\${esc(s.name)}</code></span>
        </div>
        <div class="share-card__actions">
          <button class="btn-secondary btn-edit" data-name="${esc(s.name)}">Edit</button>
          <button class="btn-danger btn-delete" data-name="${esc(s.name)}">Delete</button>
        </div>`;
      sharesGrid.appendChild(card);
    });

    sharesGrid.querySelectorAll(".btn-edit").forEach((btn) =>
      btn.addEventListener("click", () => openEditModal(btn.dataset.name))
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

  function openAddModal() {
    editingShare = null;
    modalTitle.textContent = "Add Share";
    shareForm.reset();
    fEu.checked = true;
    fSambaUser.value = "veeambackup";
    nameGroup.hidden = false;
    fName.required = true;
    fKey.required = true;
    fSecret.required = true;
    fSambaPw.required = true;
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
      fAccount.value     = s.account_id;
      fEu.checked        = s.eu_jurisdiction;
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

    const body = {
      account_id:         fAccount.value.trim(),
      eu:                 fEu.checked,
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

  // ─── Utils ──────────────────────────────────────────────────────────────────
  function esc(str) {
    return String(str)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  // ─── Init ───────────────────────────────────────────────────────────────────
  // Try to load shares — if 401, stay on login page
  api("GET", "/api/shares")
    .then((shares) => { showDashboard(); renderShares(shares); })
    .catch(() => { /* stay on login */ });
})();

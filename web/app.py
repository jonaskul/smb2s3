import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import time
from functools import wraps

from flask import Flask, jsonify, request, send_from_directory, session

app = Flask(__name__, static_folder="static")

ADMIN_CONF       = "/etc/smb2s3/admin.conf"
SMB_CONF         = "/etc/samba/smb.conf"
RCLONE_BIN       = "/usr/bin/rclone"
RCLONE_CONF_PFX  = "/etc/rclone-"   # {name}.conf
MOUNT_PREFIX     = "/mnt/r2-"
CACHE_PREFIX     = "/var/cache/rclone/"

NAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,62}$")


# ─── Config ───────────────────────────────────────────────────────────────────

def _load_conf():
    cfg = {}
    try:
        with open(ADMIN_CONF) as f:
            for line in f:
                k, _, v = line.strip().partition("=")
                if k:
                    cfg[k] = v
    except FileNotFoundError:
        pass
    if "session_secret" not in cfg:
        cfg["session_secret"] = secrets.token_hex(32)
        with open(ADMIN_CONF, "a") as f:
            f.write(f"session_secret={cfg['session_secret']}\n")
    return cfg


def _save_conf_keys(updates: dict):
    cfg = _load_conf()
    cfg.update(updates)
    with open(ADMIN_CONF, "w") as f:
        for k, v in cfg.items():
            f.write(f"{k}={v}\n")
    os.chmod(ADMIN_CONF, 0o600)


_cfg = _load_conf()
app.secret_key = _cfg["session_secret"]
app.config["SESSION_COOKIE_SAMESITE"] = "Strict"
app.config["SESSION_COOKIE_HTTPONLY"] = True


# ─── rclone mount services ────────────────────────────────────────────────────

def _service_name(name: str) -> str:
    return f"smb2s3-mount-{name}.service"


def _write_mount_service(name: str):
    cfg          = _load_conf()
    cache_gb     = int(cfg.get("vfs_cache_gb",  "70"))
    transfers    = int(cfg.get("transfers",      "2"))
    buffer_mb    = int(cfg.get("buffer_mb",      "64"))
    write_back_s = int(cfg.get("write_back_s",   "5"))
    checkers     = int(cfg.get("checkers",       "2"))
    conf  = f"{RCLONE_CONF_PFX}{name}.conf"
    mount = f"{MOUNT_PREFIX}{name}"
    cache = f"{CACHE_PREFIX}{name}"
    content = (
        f"[Unit]\n"
        f"Description=rclone R2 mount — {name}\n"
        f"After=network-online.target\n"
        f"Wants=network-online.target\n"
        f"\n"
        f"[Service]\n"
        f"Type=simple\n"
        f"ExecStart={RCLONE_BIN} mount {name}:{name} {mount}"
        f" --config {conf}"
        f" --vfs-cache-mode writes"
        f" --cache-dir {cache}"
        f" --vfs-cache-max-size {cache_gb}G"
        f" --vfs-write-back {write_back_s}s"
        f" --buffer-size {buffer_mb}M"
        f" --transfers {transfers}"
        f" --checkers {checkers}"
        f" --dir-cache-time 5m"
        f" --poll-interval 30s"
        f" --allow-other"
        f" --umask 022"
        f" --log-level INFO\n"
        f"ExecStop=fusermount3 -uz {mount}\n"
        f"Restart=on-failure\n"
        f"RestartSec=30\n"
        f"\n"
        f"[Install]\n"
        f"WantedBy=multi-user.target\n"
    )
    path = f"/etc/systemd/system/{_service_name(name)}"
    with open(path, "w") as f:
        f.write(content)
    os.chmod(path, 0o644)


def _ensure_rclone_services():
    sections = _parse_smb_conf()
    written = False
    for name in sections:
        try:
            _write_mount_service(name)
            written = True
        except Exception:
            pass
    if written:
        subprocess.run(["systemctl", "daemon-reload"], check=False)
    for name in sections:
        svc = _service_name(name)
        subprocess.run(["systemctl", "enable", "--now", svc], check=False)

# ─── Watchdog ─────────────────────────────────────────────────────────────────

WATCHDOG_SCRIPT  = "/usr/local/bin/smb2s3-watchdog"
WATCHDOG_SERVICE = "/etc/systemd/system/smb2s3-watchdog.service"
WATCHDOG_TIMER   = "/etc/systemd/system/smb2s3-watchdog.timer"


def _ensure_watchdog():
    script = """\
#!/usr/bin/env bash
set -euo pipefail
for svc_path in /etc/systemd/system/smb2s3-mount-*.service; do
    [[ -f "$svc_path" ]] || continue
    svc="${svc_path##*/}"
    name="${svc#smb2s3-mount-}"; name="${name%.service}"
    mp="/mnt/r2-${name}"
    grep -q " ${mp} " /proc/mounts && continue
    logger -t smb2s3-watchdog "unmounted: ${mp} — restarting service"
    if systemctl restart "${svc}" 2>/dev/null; then
        sleep 10
        if grep -q " ${mp} " /proc/mounts; then
            logger -t smb2s3-watchdog "remounted: ${mp}"
        else
            logger -t smb2s3-watchdog "remount failed: ${mp}"
        fi
    else
        logger -t smb2s3-watchdog "remount failed: ${mp}"
    fi
done
"""
    service = """\
[Unit]
Description=smb2s3 mount watchdog
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/smb2s3-watchdog
"""
    timer = """\
[Unit]
Description=smb2s3 mount watchdog timer

[Timer]
OnBootSec=60
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
"""
    try:
        changed = False
        for path, content, mode in [
            (WATCHDOG_SCRIPT,  script,  0o755),
            (WATCHDOG_SERVICE, service, 0o644),
            (WATCHDOG_TIMER,   timer,   0o644),
        ]:
            existing = open(path).read() if os.path.exists(path) else ""
            if existing != content:
                with open(path, "w") as f:
                    f.write(content)
                os.chmod(path, mode)
                changed = True
        if changed:
            subprocess.run(["systemctl", "daemon-reload"], check=False)
            subprocess.run(["systemctl", "enable", "--now", "smb2s3-watchdog.timer"], check=False)
    except Exception:
        pass

# ─── Auth ─────────────────────────────────────────────────────────────────────

def require_login(f):
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not session.get("logged_in"):
            return jsonify({"error": "Unauthorized"}), 401
        return f(*args, **kwargs)
    return wrapper


def _verify_password(password: str) -> bool:
    cfg = _load_conf()
    try:
        salt = bytes.fromhex(cfg["salt"])
        expected = cfg["hash"]
    except (KeyError, ValueError):
        return False
    h = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 260000).hex()
    return secrets.compare_digest(h, expected)


@app.route("/login", methods=["POST"])
def login():
    data = request.get_json(silent=True) or {}
    cfg = _load_conf()
    if data.get("username") == cfg.get("username") and _verify_password(data.get("password", "")):
        session["logged_in"] = True
        return jsonify({"ok": True})
    return jsonify({"error": "Invalid credentials"}), 401


@app.route("/logout")
def logout():
    session.clear()
    return jsonify({"ok": True})


# ─── Static ───────────────────────────────────────────────────────────────────

@app.route("/")
@app.route("/index.html")
def index():
    return send_from_directory(app.static_folder, "index.html")


# ─── Helpers ──────────────────────────────────────────────────────────────────

def _validate_name(name: str):
    if not NAME_RE.match(name):
        return jsonify({"error": f"Invalid share name: {name!r}"}), 400
    return None


def _run(*cmd, input=None, check=True):
    result = subprocess.run(cmd, capture_output=True, text=True, input=input)
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result


def _parse_smb_conf():
    sections = {}
    current = None
    try:
        with open(SMB_CONF) as f:
            for line in f:
                line = line.strip()
                if line.startswith("[") and line.endswith("]"):
                    current = line[1:-1].strip()
                    if current.lower() != "global":
                        sections[current] = {}
                elif current and current.lower() != "global" and "=" in line:
                    k, _, v = line.partition("=")
                    sections[current][k.strip().lower()] = v.strip()
    except FileNotFoundError:
        pass
    return sections


def _is_mounted(name: str) -> bool:
    mount_path = f"{MOUNT_PREFIX}{name}"
    try:
        with open("/proc/mounts") as f:
            return any(mount_path in line for line in f)
    except FileNotFoundError:
        return False


def _r2_url(account_id: str, eu: bool) -> str:
    region = "eu." if eu else ""
    return f"https://{account_id}.{region}r2.cloudflarestorage.com"


def _write_rclone_conf(name: str, account_id: str, access_key_id: str,
                       secret: str, eu: bool):
    endpoint = _r2_url(account_id, eu)
    content = (
        f"[{name}]\n"
        f"type = s3\n"
        f"provider = Cloudflare\n"
        f"access_key_id = {access_key_id}\n"
        f"secret_access_key = {secret}\n"
        f"endpoint = {endpoint}\n"
    )
    path = f"{RCLONE_CONF_PFX}{name}.conf"
    with open(path, "w") as f:
        f.write(content)
    os.chmod(path, 0o600)


def _parse_rclone_conf(name: str) -> dict:
    path = f"{RCLONE_CONF_PFX}{name}.conf"
    cfg = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("[") or line.startswith("#"):
                    continue
                k, _, v = line.partition("=")
                cfg[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    endpoint = cfg.get("endpoint", "")
    eu = ".eu.r2." in endpoint
    m = re.search(r"https://([^.]+)\.", endpoint)
    account_id = m.group(1) if m else ""
    return {
        "account_id":        account_id,
        "eu_jurisdiction":   eu,
        "access_key_id":     cfg.get("access_key_id", ""),
        "secret_access_key": cfg.get("secret_access_key", ""),
    }


def _smb_conf_has_share(name: str) -> bool:
    return f"[{name}]" in open(SMB_CONF).read() if os.path.exists(SMB_CONF) else False


def _smb_conf_append_share(name: str, samba_user: str):
    mount = f"{MOUNT_PREFIX}{name}"
    block = (
        f"\n[{name}]\n"
        f"   path = {mount}\n"
        f"   browseable = yes\n"
        f"   read only = no\n"
        f"   guest ok = no\n"
        f"   valid users = {samba_user}\n"
        f"   create mask = 0644\n"
        f"   directory mask = 0755\n"
        f"   force user = root\n"
    )
    with open(SMB_CONF, "a") as f:
        f.write(block)


def _smb_conf_remove_share(name: str):
    with open(SMB_CONF) as f:
        lines = f.readlines()
    out, skip = [], False
    for line in lines:
        s = line.strip()
        if s == f"[{name}]":
            skip = True
            continue
        if skip and s.startswith("[") and s.endswith("]"):
            skip = False
        if not skip:
            out.append(line)
    with open(SMB_CONF, "w") as f:
        f.writelines(out)


def _smb_conf_update_user(name: str, new_user: str):
    with open(SMB_CONF) as f:
        lines = f.readlines()
    in_section, out = False, []
    for line in lines:
        s = line.strip()
        if s == f"[{name}]":
            in_section = True
        elif in_section and s.startswith("["):
            in_section = False
        if in_section and s.lower().startswith("valid users"):
            line = f"   valid users = {new_user}\n"
        out.append(line)
    with open(SMB_CONF, "w") as f:
        f.writelines(out)


def _ensure_samba_user(username: str, password: str):
    r = _run("id", "-u", username, check=False)
    if r.returncode != 0:
        _run("useradd", "-M", "-s", "/sbin/nologin", username)
    _run("smbpasswd", "-a", "-s", username, input=f"{password}\n{password}\n")


def _unmount(name: str):
    mount = f"{MOUNT_PREFIX}{name}"
    r = _run("fusermount3", "-uz", mount, check=False)
    if r.returncode != 0:
        _run("umount", "-l", mount, check=False)


# ─── API: stats ───────────────────────────────────────────────────────────────

def _net_stats():
    try:
        with open("/proc/net/dev") as f:
            for line in f:
                if "eth0" in line:
                    fields = line.split(":")[1].split()
                    return {"rx_bytes": int(fields[0]), "tx_bytes": int(fields[8])}
    except Exception:
        pass
    return {"rx_bytes": 0, "tx_bytes": 0}


def _mem_stats():
    try:
        data = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, _, v = line.partition(":")
                data[k.strip()] = int(v.split()[0])
        total = data.get("MemTotal", 0)
        avail = data.get("MemAvailable", 0)
        used  = total - avail
        return {
            "total_mb": round(total / 1024),
            "used_mb":  round(used  / 1024),
            "pct":      round(used / total * 100) if total else 0,
        }
    except Exception:
        return {"total_mb": 0, "used_mb": 0, "pct": 0}


@app.route("/api/stats")
@require_login
def get_stats():
    sections = _parse_smb_conf()
    shares = []
    for name in sections:
        cache_bytes = 0
        try:
            r = _run("du", "-sb", f"{CACHE_PREFIX}{name}", check=False)
            if r.returncode == 0:
                cache_bytes = int(r.stdout.split()[0])
        except Exception:
            pass
        shares.append({
            "name":        name,
            "mounted":     _is_mounted(name),
            "cache_bytes": cache_bytes,
        })

    load = 0.0
    try:
        with open("/proc/loadavg") as f:
            load = float(f.read().split()[0])
    except Exception:
        pass

    watchdog_log = []
    try:
        r = subprocess.run(
            ["journalctl", "-t", "smb2s3-watchdog", "-n", "20",
             "--no-pager", "--output=short-iso"],
            capture_output=True, text=True, timeout=5,
        )
        watchdog_log = [l for l in r.stdout.splitlines() if l and not l.startswith("--")]
    except Exception:
        pass

    return jsonify({
        "timestamp":    time.time(),
        "network":      _net_stats(),
        "memory":       _mem_stats(),
        "load_1":       load,
        "shares":       shares,
        "watchdog_log": watchdog_log,
    })


# ─── API: shares ──────────────────────────────────────────────────────────────

@app.route("/api/shares")
@require_login
def list_shares():
    sections = _parse_smb_conf()
    return jsonify([
        {"name": name, "samba_user": attrs.get("valid users", ""), "mounted": _is_mounted(name)}
        for name, attrs in sections.items()
    ])


@app.route("/api/shares/<name>")
@require_login
def get_share(name):
    err = _validate_name(name)
    if err:
        return err
    sections = _parse_smb_conf()
    if name not in sections:
        return jsonify({"error": "Share not found"}), 404
    creds = _parse_rclone_conf(name)
    return jsonify({
        "name":       name,
        "samba_user": sections[name].get("valid users", ""),
        **creds,
    })


@app.route("/api/shares", methods=["POST"])
@require_login
def create_share():
    data          = request.get_json(silent=True) or {}
    name          = data.get("name", "")
    err           = _validate_name(name)
    if err:
        return err
    if _smb_conf_has_share(name):
        return jsonify({"error": f"Share '{name}' already exists"}), 409

    account_id    = data.get("account_id", "").strip()
    eu            = bool(data.get("eu", True))
    access_key_id = data.get("access_key_id", "").strip()
    secret        = data.get("secret_access_key", "").strip()
    samba_user    = re.sub(r"[^a-zA-Z0-9_.-]", "", data.get("samba_user", "")) or "backupuser"
    samba_password= data.get("samba_password", "")

    if not all([account_id, access_key_id, secret, samba_password]):
        return jsonify({"error": "Missing required fields"}), 400

    try:
        _write_rclone_conf(name, account_id, access_key_id, secret, eu)
        os.makedirs(f"{MOUNT_PREFIX}{name}", exist_ok=True)
        os.makedirs(f"{CACHE_PREFIX}{name}", exist_ok=True)
        _write_mount_service(name)
        _run("systemctl", "daemon-reload")
        _run("systemctl", "enable", "--now", _service_name(name))
        _smb_conf_append_share(name, samba_user)
        _ensure_samba_user(samba_user, samba_password)
        _run("systemctl", "reload", "smbd")
    except RuntimeError as e:
        return jsonify({"error": str(e)}), 500

    return jsonify({"ok": True}), 201


@app.route("/api/shares/<name>", methods=["PUT"])
@require_login
def update_share(name):
    err = _validate_name(name)
    if err:
        return err
    sections = _parse_smb_conf()
    if name not in sections:
        return jsonify({"error": "Share not found"}), 404

    data          = request.get_json(silent=True) or {}
    account_id    = data.get("account_id", "").strip()
    eu            = bool(data.get("eu", True))
    access_key_id = data.get("access_key_id", "").strip()
    secret        = data.get("secret_access_key", "").strip()
    samba_user    = re.sub(r"[^a-zA-Z0-9_.-]", "", data.get("samba_user", "")) \
                    or sections[name].get("valid users", "backupuser")
    samba_password= data.get("samba_password", "")

    try:
        creds_changed = access_key_id and secret
        if creds_changed or account_id:
            current = _parse_rclone_conf(name)
            _write_rclone_conf(
                name,
                account_id    or current["account_id"],
                access_key_id or current["access_key_id"],
                secret        or current["secret_access_key"],
                eu,
            )
            _unmount(name)
            _run("systemctl", "restart", _service_name(name))

        old_user = sections[name].get("valid users", "")
        if samba_user and samba_user != old_user:
            _smb_conf_update_user(name, samba_user)
        if samba_password:
            _ensure_samba_user(samba_user or old_user, samba_password)
        _run("systemctl", "reload", "smbd")
    except RuntimeError as e:
        return jsonify({"error": str(e)}), 500

    return jsonify({"ok": True})


def _iter_vfsmeta(name: str):
    """Yield (meta_path, data_path) for every .vfsmeta file in the cache.

    rclone co-locates metadata next to the data file inside vfs/:
      vfs/some/path/file.ext          <- data
      vfs/some/path/file.ext.vfsmeta  <- metadata
    """
    cache_dir = os.path.join(CACHE_PREFIX, name)
    for root, _, files in os.walk(cache_dir):
        for fname in files:
            if fname.endswith(".vfsmeta"):
                meta_path = os.path.join(root, fname)
                data_path = meta_path[: -len(".vfsmeta")]
                yield meta_path, data_path


def _scan_cache(name: str) -> dict:
    """Inspect VFS cache metadata to find stale (uploaded) vs dirty (pending) files."""
    stale_bytes = dirty_bytes = stale_count = dirty_count = 0
    for meta_path, data_path in _iter_vfsmeta(name):
        try:
            with open(meta_path) as f:
                meta = json.load(f)
            dirty = meta.get("Dirty", False)
            size = os.path.getsize(data_path) if os.path.exists(data_path) else 0
            if dirty:
                dirty_bytes += size
                dirty_count += 1
            else:
                stale_bytes += size
                stale_count += 1
        except Exception:
            pass
    return {
        "stale_bytes":  stale_bytes,
        "dirty_bytes":  dirty_bytes,
        "stale_count":  stale_count,
        "dirty_count":  dirty_count,
    }


def _clean_stale_files(name: str):
    """Delete cached files whose metadata shows Dirty=false (already uploaded)."""
    for meta_path, data_path in _iter_vfsmeta(name):
        try:
            with open(meta_path) as f:
                meta = json.load(f)
            if not meta.get("Dirty", False):
                try:
                    os.unlink(data_path)
                except FileNotFoundError:
                    pass
                os.unlink(meta_path)
        except Exception:
            pass


@app.route("/api/shares/<name>/cache-status")
@require_login
def cache_status(name):
    err = _validate_name(name)
    if err:
        return err
    if name not in _parse_smb_conf():
        return jsonify({"error": "Share not found"}), 404
    return jsonify(_scan_cache(name))


@app.route("/api/shares/<name>/clean-cache", methods=["POST"])
@require_login
def clean_cache(name):
    err = _validate_name(name)
    if err:
        return err
    if name not in _parse_smb_conf():
        return jsonify({"error": "Share not found"}), 404

    data       = request.get_json(silent=True) or {}
    stale_only = bool(data.get("stale_only", False))
    cache_dir  = f"{CACHE_PREFIX}{name}"
    svc        = _service_name(name)
    try:
        _run("systemctl", "stop", svc, check=False)
        _unmount(name)
        if stale_only:
            _clean_stale_files(name)
        else:
            shutil.rmtree(cache_dir, ignore_errors=True)
            os.makedirs(cache_dir, exist_ok=True)
        _run("systemctl", "start", svc, check=False)
    except RuntimeError as e:
        return jsonify({"error": str(e)}), 500

    return jsonify({"ok": True})


@app.route("/api/shares/<name>", methods=["DELETE"])
@require_login
def delete_share(name):
    err = _validate_name(name)
    if err:
        return err
    sections = _parse_smb_conf()
    if name not in sections:
        return jsonify({"error": "Share not found"}), 404

    try:
        svc = _service_name(name)
        _run("systemctl", "disable", "--now", svc, check=False)
        svc_path = f"/etc/systemd/system/{svc}"
        try:
            os.unlink(svc_path)
        except FileNotFoundError:
            pass
        _unmount(name)
        _smb_conf_remove_share(name)
        try:
            os.unlink(f"{RCLONE_CONF_PFX}{name}.conf")
        except FileNotFoundError:
            pass
        shutil.rmtree(f"{MOUNT_PREFIX}{name}", ignore_errors=True)
        shutil.rmtree(f"{CACHE_PREFIX}{name}", ignore_errors=True)
        _run("systemctl", "daemon-reload")
        _run("systemctl", "reload", "smbd")
    except RuntimeError as e:
        return jsonify({"error": str(e)}), 500

    return jsonify({"ok": True})


# ─── API: settings ────────────────────────────────────────────────────────────

SNMP_CONF = "/etc/snmp/snmpd.conf"


def _apply_snmp(enabled: bool, community: str, allowed: str):
    if enabled:
        _run("apt-get", "install", "-y", "-qq", "snmpd")
        source = f" {allowed}" if allowed else ""
        conf = (
            "agentAddress udp:161\n"
            f"rocommunity {community}{source}\n"
            "sysLocation LXC r2-smb\n"
            "sysContact root@localhost\n"
        )
        with open(SNMP_CONF, "w") as f:
            f.write(conf)
        _run("systemctl", "enable", "snmpd")
        _run("systemctl", "restart", "snmpd")
    else:
        _run("systemctl", "disable", "--now", "snmpd", check=False)


@app.route("/api/settings")
@require_login
def get_settings():
    cfg = _load_conf()
    return jsonify({
        "snmp_enabled":   cfg.get("snmp_enabled", "false") == "true",
        "snmp_community": cfg.get("snmp_community", "public"),
        "snmp_allowed":   cfg.get("snmp_allowed", ""),
        "vfs_cache_gb":   int(cfg.get("vfs_cache_gb",  "70")),
        "transfers":      int(cfg.get("transfers",      "2")),
        "buffer_mb":      int(cfg.get("buffer_mb",      "64")),
        "write_back_s":   int(cfg.get("write_back_s",   "5")),
        "checkers":       int(cfg.get("checkers",       "2")),
    })


@app.route("/api/settings", methods=["POST"])
@require_login
def save_settings():
    data          = request.get_json(silent=True) or {}
    snmp_enabled  = bool(data.get("snmp_enabled", False))
    community     = re.sub(r"[^a-zA-Z0-9_-]", "", data.get("snmp_community", "public")) or "public"
    allowed       = re.sub(r"[^a-zA-Z0-9._:/\-]", "", data.get("snmp_allowed", "").strip())
    vfs_cache_gb  = max(1, int(data.get("vfs_cache_gb", 70)))
    transfers     = max(1, min(16,   int(data.get("transfers",    2))))
    buffer_mb     = max(8, min(1024, int(data.get("buffer_mb",   64))))
    write_back_s  = max(1, min(60,   int(data.get("write_back_s", 5))))
    checkers      = max(1, min(16,   int(data.get("checkers",     2))))

    try:
        _apply_snmp(snmp_enabled, community, allowed)
        _save_conf_keys({
            "snmp_enabled":   "true" if snmp_enabled else "false",
            "snmp_community": community,
            "snmp_allowed":   allowed,
            "vfs_cache_gb":   str(vfs_cache_gb),
            "transfers":      str(transfers),
            "buffer_mb":      str(buffer_mb),
            "write_back_s":   str(write_back_s),
            "checkers":       str(checkers),
        })
        # Regenerate and restart all mount services with new cache size
        sections = _parse_smb_conf()
        if sections:
            for name in sections:
                _write_mount_service(name)
            _run("systemctl", "daemon-reload")
            for name in sections:
                _run("systemctl", "restart", _service_name(name), check=False)
    except RuntimeError as e:
        return jsonify({"error": str(e)}), 500

    return jsonify({"ok": True})


_ensure_rclone_services()
_ensure_watchdog()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)

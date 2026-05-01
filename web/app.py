import hashlib
import os
import re
import secrets
import shutil
import subprocess
import time
from functools import wraps

from flask import Flask, jsonify, request, send_from_directory, session

app = Flask(__name__, static_folder="static")

ADMIN_CONF = "/etc/smb2s3/admin.conf"
SMB_CONF = "/etc/samba/smb.conf"
FSTAB = "/etc/fstab"
CRED_PREFIX = "/etc/r2-credentials-"
MOUNT_PREFIX = "/mnt/r2-"
CACHE_PREFIX = "/var/cache/s3fs/"

S3FS_OPTS = (
    "passwd_file={cred},url={url},use_path_request_style,"
    "allow_other,umask=0022,uid=0,gid=0,"
    "use_cache={cache},parallel_count=8,multipart_size=64,ensure_diskfree=2048"
)

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


def _ensure_mount_service():
    path = "/etc/systemd/system/smb2s3-mount.service"
    content = """\
[Unit]
Description=Mount smb2s3 R2 shares
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/mount -a -t fuse.s3fs
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
"""
    try:
        existing = open(path).read() if os.path.exists(path) else ""
        if existing != content:
            with open(path, "w") as f:
                f.write(content)
            subprocess.run(["systemctl", "daemon-reload"], check=False)
            subprocess.run(["systemctl", "enable", "--now", "smb2s3-mount.service"], check=False)
    except Exception:
        pass

_ensure_mount_service()


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
    result = subprocess.run(
        cmd, capture_output=True, text=True, input=input
    )
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result


def _parse_smb_conf():
    """Return {section_name: {key: value}} for all non-global sections."""
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
            return any(
                "s3fs" in line and mount_path in line
                for line in f
            )
    except FileNotFoundError:
        return False


def _fstab_line(name: str, url: str) -> str:
    cred = f"{CRED_PREFIX}{name}"
    cache = f"{CACHE_PREFIX}{name}"
    mount = f"{MOUNT_PREFIX}{name}"
    opts = S3FS_OPTS.format(cred=cred, url=url, cache=cache)
    return f"s3fs#{name} {mount} fuse _netdev,nofail,{opts} 0 0\n"


def _r2_url(account_id: str, eu: bool) -> str:
    region = "eu." if eu else ""
    return f"https://{account_id}.{region}r2.cloudflarestorage.com"


def _parse_fstab_url(name: str):
    """Return (account_id, eu_jurisdiction) from the fstab entry for name."""
    try:
        with open(FSTAB) as f:
            for line in f:
                if line.startswith(f"s3fs#{name} "):
                    m = re.search(r"url=https://([^.]+)\.((?:eu\.)?r2\.cloudflarestorage\.com)", line)
                    if m:
                        return m.group(1), "eu." in m.group(2)
    except FileNotFoundError:
        pass
    return None, False


def _rewrite_fstab_without(name: str):
    with open(FSTAB) as f:
        lines = f.readlines()
    with open(FSTAB, "w") as f:
        for line in lines:
            if not line.startswith(f"s3fs#{name} "):
                f.write(line)


def _rewrite_fstab_replace(name: str, new_line: str):
    with open(FSTAB) as f:
        lines = f.readlines()
    replaced = False
    with open(FSTAB, "w") as f:
        for line in lines:
            if line.startswith(f"s3fs#{name} "):
                f.write(new_line)
                replaced = True
            else:
                f.write(line)
    if not replaced:
        with open(FSTAB, "a") as f:
            f.write(new_line)


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
    out = []
    skip = False
    for line in lines:
        stripped = line.strip()
        if stripped == f"[{name}]":
            skip = True
            continue
        if skip and stripped.startswith("[") and stripped.endswith("]"):
            skip = False
        if not skip:
            out.append(line)
    with open(SMB_CONF, "w") as f:
        f.writelines(out)


def _smb_conf_update_user(name: str, new_user: str):
    with open(SMB_CONF) as f:
        lines = f.readlines()
    in_section = False
    out = []
    for line in lines:
        stripped = line.strip()
        if stripped == f"[{name}]":
            in_section = True
        elif in_section and stripped.startswith("["):
            in_section = False
        if in_section and stripped.lower().startswith("valid users"):
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
    r = _run("fusermount", "-u", mount, check=False)
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
        cache_path = f"{CACHE_PREFIX}{name}"
        cache_bytes = 0
        try:
            result = _run("du", "-sb", cache_path, check=False)
            if result.returncode == 0:
                cache_bytes = int(result.stdout.split()[0])
        except Exception:
            pass
        shares.append({
            "name": name,
            "mounted": _is_mounted(name),
            "cache_bytes": cache_bytes,
        })

    load = 0.0
    try:
        with open("/proc/loadavg") as f:
            load = float(f.read().split()[0])
    except Exception:
        pass

    return jsonify({
        "timestamp": time.time(),
        "network": _net_stats(),
        "memory": _mem_stats(),
        "load_1": load,
        "shares": shares,
    })


# ─── API: shares ──────────────────────────────────────────────────────────────

@app.route("/api/shares")
@require_login
def list_shares():
    sections = _parse_smb_conf()
    result = []
    for name, attrs in sections.items():
        result.append({
            "name": name,
            "samba_user": attrs.get("valid users", ""),
            "mounted": _is_mounted(name),
        })
    return jsonify(result)


@app.route("/api/shares/<name>")
@require_login
def get_share(name):
    err = _validate_name(name)
    if err:
        return err

    sections = _parse_smb_conf()
    if name not in sections:
        return jsonify({"error": "Share not found"}), 404

    cred_file = f"{CRED_PREFIX}{name}"
    try:
        cred = open(cred_file).read().strip()
        access_key_id, _, secret = cred.partition(":")
    except FileNotFoundError:
        access_key_id = secret = ""

    account_id, eu = _parse_fstab_url(name)
    return jsonify({
        "name": name,
        "samba_user": sections[name].get("valid users", ""),
        "access_key_id": access_key_id,
        "secret_access_key": secret,
        "account_id": account_id or "",
        "eu_jurisdiction": eu,
    })


@app.route("/api/shares", methods=["POST"])
@require_login
def create_share():
    data = request.get_json(silent=True) or {}
    name = data.get("name", "")

    err = _validate_name(name)
    if err:
        return err
    if _smb_conf_has_share(name):
        return jsonify({"error": f"Share '{name}' already exists"}), 409

    account_id = data.get("account_id", "").strip()
    eu = bool(data.get("eu", True))
    access_key_id = data.get("access_key_id", "").strip()
    secret = data.get("secret_access_key", "").strip()
    samba_user = re.sub(r"[^a-zA-Z0-9_.-]", "", data.get("samba_user", "")) or "backupuser"
    samba_password = data.get("samba_password", "")

    if not all([account_id, access_key_id, secret, samba_password]):
        return jsonify({"error": "Missing required fields"}), 400

    try:
        cred_file = f"{CRED_PREFIX}{name}"
        with open(cred_file, "w") as f:
            f.write(f"{access_key_id}:{secret}\n")
        os.chmod(cred_file, 0o600)

        os.makedirs(f"{MOUNT_PREFIX}{name}", exist_ok=True)
        os.makedirs(f"{CACHE_PREFIX}{name}", exist_ok=True)

        url = _r2_url(account_id, eu)
        _rewrite_fstab_replace(name, _fstab_line(name, url))

        _run("systemctl", "daemon-reload")
        _run("mount", f"{MOUNT_PREFIX}{name}")

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

    data = request.get_json(silent=True) or {}
    account_id = data.get("account_id", "").strip()
    eu = bool(data.get("eu", True))
    access_key_id = data.get("access_key_id", "").strip()
    secret = data.get("secret_access_key", "").strip()
    samba_user = re.sub(r"[^a-zA-Z0-9_.-]", "", data.get("samba_user", "")) or sections[name].get("valid users", "backupuser")
    samba_password = data.get("samba_password", "")

    try:
        if access_key_id and secret:
            cred_file = f"{CRED_PREFIX}{name}"
            with open(cred_file, "w") as f:
                f.write(f"{access_key_id}:{secret}\n")
            os.chmod(cred_file, 0o600)

        if account_id:
            url = _r2_url(account_id, eu)
            _rewrite_fstab_replace(name, _fstab_line(name, url))
            _run("systemctl", "daemon-reload")
            _unmount(name)
            _run("mount", f"{MOUNT_PREFIX}{name}")

        old_user = sections[name].get("valid users", "")
        if samba_user and samba_user != old_user:
            _smb_conf_update_user(name, samba_user)

        if samba_password:
            _ensure_samba_user(samba_user or old_user, samba_password)

        _run("systemctl", "reload", "smbd")
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
        _unmount(name)
        _rewrite_fstab_without(name)
        _smb_conf_remove_share(name)

        cred_file = f"{CRED_PREFIX}{name}"
        try:
            os.unlink(cred_file)
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
    })


@app.route("/api/settings", methods=["POST"])
@require_login
def save_settings():
    data = request.get_json(silent=True) or {}
    snmp_enabled  = bool(data.get("snmp_enabled", False))
    community     = re.sub(r"[^a-zA-Z0-9_-]", "", data.get("snmp_community", "public")) or "public"
    allowed       = re.sub(r"[^a-zA-Z0-9._:/\-]", "", data.get("snmp_allowed", "").strip())

    try:
        _apply_snmp(snmp_enabled, community, allowed)
        _save_conf_keys({
            "snmp_enabled":   "true" if snmp_enabled else "false",
            "snmp_community": community,
            "snmp_allowed":   allowed,
        })
    except RuntimeError as e:
        return jsonify({"error": str(e)}), 500

    return jsonify({"ok": True})


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)

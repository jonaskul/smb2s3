#!/usr/bin/env bash
# setup-lxc-r2-smb.sh
# Creates a Debian 13 LXC on Proxmox with s3fs + Samba + web management UI.
# R2 buckets and SMB shares are configured through the web UI after setup.
# Run on the Proxmox host as root.
SCRIPT_VERSION="2026-05-01 14:00 CEST"
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*" >&2; }
step()  { echo -e "${CYAN}[STEP]${NC}  $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
ask()   { echo -e "${BOLD}$*${NC}"; }

# ─── Requirements ─────────────────────────────────────────────────────────────

require_root() {
    [[ $EUID -eq 0 ]] || error "Script must be run as root."
}

require_proxmox() {
    command -v pct   &>/dev/null || error "pct not found — run this on a Proxmox host."
    command -v pveam &>/dev/null || error "pveam not found — is this a Proxmox node?"
    command -v pvesm &>/dev/null || error "pvesm not found — is this a Proxmox node?"
}

# ─── Auto-detection ───────────────────────────────────────────────────────────

auto_detect() {
    step "Detecting Proxmox environment..."

    VMID=$(pvesh get /cluster/nextid 2>/dev/null | tr -d '[:space:]') || VMID=200
    info "Next available VMID: $VMID"

    ROOTFS_STORAGE=$(pvesm status --content rootdir 2>/dev/null \
        | awk 'NR>1 && $3=="active" {print $1; exit}')
    [[ -z "$ROOTFS_STORAGE" ]] && ROOTFS_STORAGE="local-lvm"
    info "Container storage: $ROOTFS_STORAGE"

    TEMPLATE_STORAGE=$(pvesm status --content vztmpl 2>/dev/null \
        | awk 'NR>1 && $3=="active" {print $1; exit}')
    [[ -z "$TEMPLATE_STORAGE" ]] && TEMPLATE_STORAGE="local"
    info "Template storage: $TEMPLATE_STORAGE"

    BRIDGE=$(ip -o link show type bridge 2>/dev/null \
        | awk -F': ' '{print $2}' | grep -m1 'vmbr' || true)
    [[ -z "$BRIDGE" ]] && BRIDGE="vmbr0"
    info "Network bridge: $BRIDGE"

    CT_HOSTNAME="r2-smb"
    DISK_GB=8
    MEMORY_MB=512
    CORES=1
    CT_DNS="1.1.1.1"
    WEB_ADMIN_USER="admin"
}

# ─── Interactive wizard ───────────────────────────────────────────────────────

run_wizard() {
    exec < /dev/tty

    echo
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║         Wizard: Cloudflare R2 → SMB Gateway              ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo

    # ── Network ──
    echo -e "${CYAN}── Network ─────────────────────────────────────────────────${NC}"
    ask "Network mode — DHCP or static? [dhcp/static, default: dhcp]:"
    read -r _net_mode
    if [[ "${_net_mode,,}" == "static" ]]; then
        ask "IP address with prefix length (e.g. 192.168.1.100/24):"
        read -r CT_IP
        ask "Gateway (e.g. 192.168.1.1):"
        read -r CT_GW
    else
        CT_IP="dhcp"
        CT_GW=""
    fi
    echo

    # ── Web UI ──
    echo -e "${CYAN}── Web UI ──────────────────────────────────────────────────${NC}"
    ask "Web UI admin username [${WEB_ADMIN_USER}]:"
    read -r _input
    _sanitized="${_input//[^a-zA-Z0-9_.-]/}"
    WEB_ADMIN_USER="${_sanitized:-admin}"
    ask "Web UI admin password:"
    read -r WEB_ADMIN_PASSWORD
    echo

    validate_wizard_input
    confirm_summary
}

validate_wizard_input() {
    local missing=()
    if [[ "${CT_IP:-}" != "dhcp" ]]; then
        [[ -z "${CT_IP:-}" ]] && missing+=("IP address")
        [[ -z "${CT_GW:-}" ]] && missing+=("Gateway")
    fi
    [[ -z "${WEB_ADMIN_PASSWORD:-}" ]] && missing+=("Web UI admin password")
    [[ ${#missing[@]} -gt 0 ]] && error "Missing required values: ${missing[*]}"

    if pct status "$VMID" &>/dev/null; then
        error "CT $VMID already exists. Restart the script — a new VMID will be suggested."
    fi
}

confirm_summary() {
    echo -e "${BOLD}── Summary ─────────────────────────────────────────────────${NC}"
    printf "  %-24s %s\n" "VMID:"         "$VMID"
    printf "  %-24s %s\n" "Hostname:"     "$CT_HOSTNAME"
    printf "  %-24s %s\n" "Storage:"      "$ROOTFS_STORAGE (${DISK_GB}GB)"
    printf "  %-24s %s\n" "Bridge:"       "$BRIDGE"
    if [[ "$CT_IP" == "dhcp" ]]; then
        printf "  %-24s %s\n" "IP:"       "DHCP (assigned at boot)"
    else
        printf "  %-24s %s\n" "IP:"       "$CT_IP"
        printf "  %-24s %s\n" "Gateway:"  "$CT_GW"
    fi
    printf "  %-24s %s\n" "Web UI user:"  "$WEB_ADMIN_USER"
    printf "  %-24s %s\n" "Web UI URL:"   "http://<CT-IP>:8080"
    echo
    ask "Does this look correct? Continue? [y/N]"
    read -r _confirm
    [[ "${_confirm,,}" =~ ^y ]] || { echo "Aborted."; exit 0; }
    echo
}

# ─── Template ─────────────────────────────────────────────────────────────────

get_template() {
    step "Looking for Debian 13 template..."
    pveam update -q 2>/dev/null || warn "pveam update failed, continuing with local cache."

    local tmpl
    tmpl=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null \
        | awk '/debian-13-standard/ {print $1; exit}')

    if [[ -n "$tmpl" ]]; then
        info "Found template: $tmpl"
        echo "$tmpl"
        return
    fi

    local avail
    avail=$(pveam available --section system 2>/dev/null \
        | awk '/debian-13-standard/ {print $2; exit}')
    [[ -z "$avail" ]] && error "No debian-13-standard template found. Check internet access on the Proxmox node."

    info "Downloading template: $avail"
    pveam download "$TEMPLATE_STORAGE" "$avail" >&2
    echo "${TEMPLATE_STORAGE}:vztmpl/${avail}"
}

# ─── Create container ─────────────────────────────────────────────────────────

create_container() {
    local template_path="$1"
    step "Creating LXC $VMID ($CT_HOSTNAME)..."

    local net0="name=eth0,bridge=${BRIDGE},ip=${CT_IP}"
    [[ -n "$CT_GW" ]] && net0+=",gw=${CT_GW}"

    pct create "$VMID" "$template_path" \
        --hostname   "$CT_HOSTNAME" \
        --memory     "$MEMORY_MB" \
        --cores      "$CORES" \
        --rootfs     "${ROOTFS_STORAGE}:${DISK_GB}" \
        --net0       "$net0" \
        --nameserver "$CT_DNS" \
        --unprivileged 0 \
        --features   "fuse=1" \
        --onboot     1 \
        --start      0

    local conf="/etc/pve/lxc/${VMID}.conf"
    grep -q "^lxc.apparmor.profile" "$conf" || \
        echo "lxc.apparmor.profile: unconfined" >> "$conf"
    sed -i '/^lxc.cap.drop/d' "$conf" 2>/dev/null || true

    info "Container $VMID created."
}

start_and_wait() {
    step "Starting container $VMID..."
    pct start "$VMID"
    info "Waiting for container to be ready..."
    local retries=20
    while (( retries-- > 0 )); do
        if pct exec "$VMID" -- true &>/dev/null; then
            info "Container is responding."
            return
        fi
        sleep 2
    done
    error "Container did not respond within timeout."
}

# ─── Configuration inside container ──────────────────────────────────────────

exec_ct() { pct exec "$VMID" -- bash -c "$1"; }

wait_for_dns() {
    step "Waiting for DNS resolution..."
    local retries=15
    while (( retries-- > 0 )); do
        if pct exec "$VMID" -- getent hosts deb.debian.org &>/dev/null; then
            info "DNS is working."
            return
        fi
        sleep 3
    done
    error "DNS did not become available within timeout."
}

install_packages() {
    step "Installing packages (s3fs, samba, python3-flask)..."
    exec_ct "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq s3fs samba samba-common-bin curl fuse python3-flask"
}

configure_samba() {
    step "Writing base Samba config..."
    pct exec "$VMID" -- bash -c "cat > /etc/samba/smb.conf" <<'EOF'
[global]
   workgroup = WORKGROUP
   server string = R2 SMB Gateway
   security = user
   usershare max shares = 0
   log file = /var/log/samba/log.%m
   max log size = 50
   socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072
   read raw = yes
   write raw = yes
   max xmit = 65535
   dead time = 15
   getwd cache = yes
EOF
    exec_ct "grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || echo 'user_allow_other' >> /etc/fuse.conf"
    exec_ct "systemctl enable smbd nmbd && systemctl restart smbd nmbd"
    info "Samba configured."
}

setup_autologin() {
    step "Configuring root auto-login on console..."
    exec_ct "mkdir -p /etc/systemd/system/container-getty@1.service.d"
    pct exec "$VMID" -- bash -c "cat > /etc/systemd/system/container-getty@1.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I linux
EOF
    exec_ct "systemctl daemon-reload"
}

setup_web_ui() {
    step "Setting up web management UI..."

    exec_ct "mkdir -p /opt/smb2s3/static /etc/smb2s3"

    local raw_base="https://raw.githubusercontent.com/jonaskul/smb2s3/main/web"
    exec_ct "curl -fsSL '${raw_base}/app.py'            -o /opt/smb2s3/app.py"
    exec_ct "curl -fsSL '${raw_base}/static/index.html' -o /opt/smb2s3/static/index.html"
    exec_ct "curl -fsSL '${raw_base}/static/app.js'     -o /opt/smb2s3/static/app.js"
    exec_ct "curl -fsSL '${raw_base}/static/style.css'  -o /opt/smb2s3/static/style.css"

    # Base64-encode password to safely pass it into pct exec python3 -c
    local pw_b64
    pw_b64=$(printf '%s' "$WEB_ADMIN_PASSWORD" | base64 -w0)
    local user_safe="${WEB_ADMIN_USER//[^a-zA-Z0-9_.-]/}"
    pct exec "$VMID" -- python3 -c "
import hashlib, os, base64, secrets
pw = base64.b64decode('${pw_b64}').decode()
salt = os.urandom(16).hex()
h = hashlib.pbkdf2_hmac('sha256', pw.encode(), bytes.fromhex(salt), 260000).hex()
secret = secrets.token_hex(32)
with open('/etc/smb2s3/admin.conf', 'w') as f:
    f.write(f'username=${user_safe}\nsalt={salt}\nhash={h}\nsession_secret={secret}\n')
os.chmod('/etc/smb2s3/admin.conf', 0o600)
"

    pct exec "$VMID" -- bash -c "cat > /etc/systemd/system/smb2s3-web.service" <<'EOF'
[Unit]
Description=smb2s3 web management UI
After=network.target smbd.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/smb2s3/app.py
WorkingDirectory=/opt/smb2s3
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    pct exec "$VMID" -- bash -c "cat > /usr/local/bin/smb2s3-update" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
RAW=https://raw.githubusercontent.com/jonaskul/smb2s3/main/web
curl -fsSL ${RAW}/app.py            -o /opt/smb2s3/app.py
curl -fsSL ${RAW}/static/index.html -o /opt/smb2s3/static/index.html
curl -fsSL ${RAW}/static/app.js     -o /opt/smb2s3/static/app.js
curl -fsSL ${RAW}/static/style.css  -o /opt/smb2s3/static/style.css
systemctl restart smb2s3-web
echo "smb2s3 updated."
EOF
    exec_ct "chmod +x /usr/local/bin/smb2s3-update"

    exec_ct "systemctl daemon-reload && systemctl enable --now smb2s3-web"
    info "Web UI started on port 8080."
}

# ─── Summary ──────────────────────────────────────────────────────────────────

print_summary() {
    local lxc_ip
    if [[ "$CT_IP" == "dhcp" ]]; then
        lxc_ip=$(pct exec "$VMID" -- hostname -I 2>/dev/null | awk '{print $1}')
        [[ -z "$lxc_ip" ]] && lxc_ip="<check: pct exec $VMID -- hostname -I>"
    else
        lxc_ip="${CT_IP%%/*}"
    fi

    echo
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Setup complete!                                         ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    printf "${GREEN}║${NC}  CT ID:       %-41s${GREEN}║${NC}\n" "$VMID ($CT_HOSTNAME)"
    printf "${GREEN}║${NC}  IP:          %-41s${GREEN}║${NC}\n" "$lxc_ip"
    printf "${GREEN}║${NC}  Web UI:      %-41s${GREEN}║${NC}\n" "http://${lxc_ip}:8080"
    printf "${GREEN}║${NC}  Web login:   %-41s${GREEN}║${NC}\n" "${WEB_ADMIN_USER} / ${WEB_ADMIN_PASSWORD}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  Open the web UI to add your first R2 share.             ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    require_root
    require_proxmox
    auto_detect
    run_wizard

    local template_path
    template_path=$(get_template)

    create_container "$template_path"
    start_and_wait
    wait_for_dns
    install_packages
    configure_samba
    setup_autologin
    setup_web_ui
    print_summary
}

main

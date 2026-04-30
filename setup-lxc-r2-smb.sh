#!/usr/bin/env bash
# setup-lxc-r2-smb.sh
# Oppretter Debian 12 LXC på Proxmox og setter opp s3fs + Samba mot Cloudflare R2.
# Kjøres på PROXMOX-HOSTEN som root.
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEG]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
ask()   { echo -e "${BOLD}$*${NC}"; }

# ─── Krav ─────────────────────────────────────────────────────────────────────

require_root() {
    [[ $EUID -eq 0 ]] || error "Scriptet må kjøres som root."
}

require_proxmox() {
    command -v pct   &>/dev/null || error "pct ikke funnet — scriptet må kjøres på Proxmox-hosten."
    command -v pveam &>/dev/null || error "pveam ikke funnet — er dette en Proxmox-node?"
    command -v pvesm &>/dev/null || error "pvesm ikke funnet — er dette en Proxmox-node?"
}

# ─── Auto-deteksjon ───────────────────────────────────────────────────────────

auto_detect() {
    step "Detekterer Proxmox-miljø..."

    VMID=$(pvesh get /cluster/nextid 2>/dev/null | tr -d '[:space:]') || VMID=200
    info "Neste ledige VMID: $VMID"

    ROOTFS_STORAGE=$(pvesm status --content rootdir 2>/dev/null \
        | awk 'NR>1 && $3=="active" {print $1; exit}')
    [[ -z "$ROOTFS_STORAGE" ]] && ROOTFS_STORAGE="local-lvm"
    info "Container-lagring: $ROOTFS_STORAGE"

    TEMPLATE_STORAGE=$(pvesm status --content vztmpl 2>/dev/null \
        | awk 'NR>1 && $3=="active" {print $1; exit}')
    [[ -z "$TEMPLATE_STORAGE" ]] && TEMPLATE_STORAGE="local"
    info "Template-lagring: $TEMPLATE_STORAGE"

    BRIDGE=$(ip -o link show type bridge 2>/dev/null \
        | awk -F': ' '{print $2}' | grep -m1 'vmbr' || true)
    [[ -z "$BRIDGE" ]] && BRIDGE="vmbr0"
    info "Nettverksbridge: $BRIDGE"

    # Faste standardverdier
    CT_HOSTNAME="r2-smb"
    DISK_GB=8
    MEMORY_MB=512
    CORES=1
    CT_DNS="1.1.1.1"
    R2_BUCKET="veeam-backup"
    SAMBA_USER="veeambackup"
    MOUNT_POINT="/mnt/r2-veeam"
    CACHE_DIR="/var/cache/s3fs"
}

# ─── Interaktiv veiviser ──────────────────────────────────────────────────────

run_wizard() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║         Veiviser: Cloudflare R2 → SMB Gateway            ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo

    # ── Nettverk ──
    echo -e "${CYAN}── Nettverk ────────────────────────────────────────────────${NC}"
    ask "LXC IP-adresse med prefixlengde (f.eks. 192.168.1.100/24):"
    read -r CT_IP
    ask "Gateway (f.eks. 192.168.1.1):"
    read -r CT_GW
    echo

    # ── Cloudflare R2 ──
    echo -e "${CYAN}── Cloudflare R2 ───────────────────────────────────────────${NC}"
    ask "R2 Access Key ID:"
    read -r R2_ACCESS_KEY_ID
    ask "R2 Secret Access Key:"
    read -rsp "" R2_SECRET_ACCESS_KEY; echo
    ask "R2 Account ID (kun ID-en, ikke URL):"
    read -r R2_ACCOUNT_ID
    ask "R2 Bucket-navn [${R2_BUCKET}]:"
    read -r _input; R2_BUCKET="${_input:-$R2_BUCKET}"
    echo

    # ── Samba ──
    echo -e "${CYAN}── Samba ───────────────────────────────────────────────────${NC}"
    ask "Samba-brukernavn [${SAMBA_USER}]:"
    read -r _input; SAMBA_USER="${_input:-$SAMBA_USER}"
    ask "Samba-passord:"
    read -rsp "" SAMBA_PASSWORD; echo
    echo

    validate_wizard_input
    confirm_summary
}

validate_wizard_input() {
    local missing=()
    [[ -z "${CT_IP:-}"               ]] && missing+=("IP-adresse")
    [[ -z "${CT_GW:-}"               ]] && missing+=("Gateway")
    [[ -z "${R2_ACCESS_KEY_ID:-}"    ]] && missing+=("R2 Access Key ID")
    [[ -z "${R2_SECRET_ACCESS_KEY:-}" ]] && missing+=("R2 Secret Access Key")
    [[ -z "${R2_ACCOUNT_ID:-}"       ]] && missing+=("R2 Account ID")
    [[ -z "${SAMBA_PASSWORD:-}"      ]] && missing+=("Samba-passord")
    [[ ${#missing[@]} -gt 0 ]] && error "Mangler påkrevde verdier: ${missing[*]}"

    pct status "$VMID" &>/dev/null && \
        error "CT $VMID finnes allerede. Restart scriptet — et nytt VMID vil bli foreslått."
}

confirm_summary() {
    local lxc_ip="${CT_IP%%/*}"
    echo -e "${BOLD}── Oppsummering ────────────────────────────────────────────${NC}"
    printf "  %-22s %s\n" "VMID:"           "$VMID"
    printf "  %-22s %s\n" "Hostname:"       "$CT_HOSTNAME"
    printf "  %-22s %s\n" "Lagring:"        "$ROOTFS_STORAGE (${DISK_GB}GB)"
    printf "  %-22s %s\n" "Bridge:"         "$BRIDGE"
    printf "  %-22s %s\n" "IP:"             "$CT_IP"
    printf "  %-22s %s\n" "Gateway:"        "$CT_GW"
    printf "  %-22s %s\n" "R2 Bucket:"      "$R2_BUCKET"
    printf "  %-22s %s\n" "R2 Account ID:"  "$R2_ACCOUNT_ID"
    printf "  %-22s %s\n" "Samba-bruker:"   "$SAMBA_USER"
    printf "  %-22s %s\n" "SMB-share:"      "\\\\${lxc_ip}\\${R2_BUCKET}"
    echo
    ask "Ser dette riktig ut? Fortsett? [j/N]"
    read -r _confirm
    [[ "${_confirm,,}" =~ ^j ]] || { echo "Avbrutt."; exit 0; }
    echo
}

# ─── Template ─────────────────────────────────────────────────────────────────

get_template() {
    step "Leter etter Debian 12-template..."
    pveam update -q 2>/dev/null || warn "pveam update feilet, fortsetter med lokal cache."

    local tmpl
    tmpl=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null \
        | awk '/debian-12-standard/ {print $1; exit}')

    if [[ -n "$tmpl" ]]; then
        info "Fant template: $tmpl"
        echo "$tmpl"
        return
    fi

    local avail
    avail=$(pveam available --section system 2>/dev/null \
        | awk '/debian-12-standard/ {print $2; exit}')
    [[ -z "$avail" ]] && error "Fant ingen debian-12-standard template. Sjekk internettilgang fra Proxmox-noden."

    info "Laster ned template: $avail"
    pveam download "$TEMPLATE_STORAGE" "$avail"
    echo "${TEMPLATE_STORAGE}:vztmpl/${avail}"
}

# ─── Opprett container ────────────────────────────────────────────────────────

create_container() {
    local template_path="$1"
    step "Oppretter LXC $VMID ($CT_HOSTNAME)..."

    pct create "$VMID" "$template_path" \
        --hostname   "$CT_HOSTNAME" \
        --memory     "$MEMORY_MB" \
        --cores      "$CORES" \
        --rootfs     "${ROOTFS_STORAGE}:${DISK_GB}" \
        --net0       "name=eth0,bridge=${BRIDGE},ip=${CT_IP},gw=${CT_GW}" \
        --nameserver "$CT_DNS" \
        --unprivileged 0 \
        --features   "fuse=1,mounts=fuse" \
        --onboot     1 \
        --start      0

    local conf="/etc/pve/lxc/${VMID}.conf"
    grep -q "^lxc.apparmor.profile" "$conf" || \
        echo "lxc.apparmor.profile: unconfined" >> "$conf"
    sed -i '/^lxc.cap.drop/d' "$conf" 2>/dev/null || true

    info "Container $VMID opprettet."
}

start_and_wait() {
    step "Starter container $VMID..."
    pct start "$VMID"
    info "Venter på at containeren er klar..."
    local retries=20
    while (( retries-- > 0 )); do
        pct exec "$VMID" -- true &>/dev/null && { info "Container svarer."; return; }
        sleep 2
    done
    error "Containeren svarte ikke innen timeout."
}

# ─── Konfigurasjon inni containeren ──────────────────────────────────────────

exec_ct() { pct exec "$VMID" -- bash -c "$1"; }

install_packages() {
    step "Installerer pakker (s3fs, samba, fuse)..."
    exec_ct "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq s3fs samba samba-common-bin curl fuse"
}

setup_credentials() {
    step "Lagrer R2-credentials..."
    exec_ct "printf '%s:%s\n' '${R2_ACCESS_KEY_ID}' '${R2_SECRET_ACCESS_KEY}' > /etc/r2-credentials && chmod 600 /etc/r2-credentials"
}

setup_mount() {
    step "Konfigurerer s3fs-montering..."
    local r2_url="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
    local fstab_opts="passwd_file=/etc/r2-credentials,url=${r2_url},use_path_request_style"
    fstab_opts+=",allow_other,umask=0022,uid=0,gid=0"
    fstab_opts+=",use_cache=${CACHE_DIR},parallel_count=8,multipart_size=64,ensure_diskfree=2048"

    exec_ct "mkdir -p '${MOUNT_POINT}' '${CACHE_DIR}'"
    exec_ct "grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || echo 'user_allow_other' >> /etc/fuse.conf"
    exec_ct "grep -qF 's3fs#${R2_BUCKET}' /etc/fstab || \
        echo 's3fs#${R2_BUCKET} ${MOUNT_POINT} fuse _netdev,${fstab_opts} 0 0' >> /etc/fstab"

    info "Tester montering av R2-bucket..."
    exec_ct "mount '${MOUNT_POINT}'" \
        || error "s3fs-montering feilet. Sjekk R2_ACCOUNT_ID, nøkler og at bucketen finnes."
    info "Montering OK."
}

configure_samba() {
    step "Konfigurerer Samba..."
    pct exec "$VMID" -- bash -c "cat > /etc/samba/smb.conf" <<EOF
[global]
   workgroup = WORKGROUP
   server string = R2 SMB Gateway
   security = user
   map to guest = bad user
   log file = /var/log/samba/log.%m
   max log size = 50
   socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=131072 SO_SNDBUF=131072
   read raw = yes
   write raw = yes
   max xmit = 65535
   dead time = 15
   getwd cache = yes

[${R2_BUCKET}]
   path = ${MOUNT_POINT}
   browseable = yes
   read only = no
   guest ok = no
   valid users = ${SAMBA_USER}
   create mask = 0644
   directory mask = 0755
   force user = root
EOF
    info "smb.conf skrevet."
}

setup_samba_user() {
    step "Oppretter Samba-bruker '${SAMBA_USER}'..."
    exec_ct "id -u '${SAMBA_USER}' &>/dev/null || useradd -M -s /sbin/nologin '${SAMBA_USER}'"
    exec_ct "printf '%s\n%s\n' '${SAMBA_PASSWORD}' '${SAMBA_PASSWORD}' | smbpasswd -a -s '${SAMBA_USER}'"
}

start_services() {
    step "Starter Samba-tjenester..."
    exec_ct "systemctl enable smbd nmbd && systemctl restart smbd nmbd"
}

# ─── Sammendrag ───────────────────────────────────────────────────────────────

print_summary() {
    local lxc_ip="${CT_IP%%/*}"
    echo
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Oppsett fullført!                                       ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    printf "${GREEN}║${NC}  CT ID:       %-41s${GREEN}║${NC}\n" "$VMID ($CT_HOSTNAME)"
    printf "${GREEN}║${NC}  IP:          %-41s${GREEN}║${NC}\n" "$lxc_ip"
    printf "${GREEN}║${NC}  SMB-share:   %-41s${GREEN}║${NC}\n" "\\\\${lxc_ip}\\${R2_BUCKET}"
    printf "${GREEN}║${NC}  Bruker:      %-41s${GREEN}║${NC}\n" "$SAMBA_USER"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  Legg til i Veeam:                                       ║${NC}"
    echo -e "${GREEN}║  Backup Infrastructure → Backup Repositories →           ║${NC}"
    echo -e "${GREEN}║  Add Repository → Network attached storage → SMB share   ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo
    echo "Test fra Windows PowerShell:"
    echo "  net use \\\\${lxc_ip}\\${R2_BUCKET} /user:${SAMBA_USER} ${SAMBA_PASSWORD}"
    echo "  dir \\\\${lxc_ip}\\${R2_BUCKET}"
}

# ─── Hovedflyt ────────────────────────────────────────────────────────────────

main() {
    require_root
    require_proxmox
    auto_detect
    run_wizard

    local template_path
    template_path=$(get_template)

    create_container "$template_path"
    start_and_wait
    install_packages
    setup_credentials
    setup_mount
    configure_samba
    setup_samba_user
    start_services
    print_summary
}

main

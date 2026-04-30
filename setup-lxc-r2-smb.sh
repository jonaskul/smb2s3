#!/usr/bin/env bash
# setup-lxc-r2-smb.sh
# Oppretter Debian 12 LXC på Proxmox og setter opp s3fs + Samba mot Cloudflare R2.
# Kjøres på PROXMOX-HOSTEN som root.
set -euo pipefail

# ─── Konfigurasjon — fyll inn disse før du kjører ────────────────────────────

# Container
VMID=200                     # CT ID — sjekk at den er ledig (pvesh get /cluster/resources)
CT_HOSTNAME="r2-smb"
ROOTFS_STORAGE="local-lvm"   # Lagring for container-disk (local-lvm, local, zfs-pool, osv.)
TEMPLATE_STORAGE="local"     # Lagring for CT-templates
DISK_GB=8
MEMORY_MB=512
CORES=1
BRIDGE="vmbr0"
CT_IP="192.168.1.100/24"     # Statisk IP for LXCen
CT_GW="192.168.1.1"          # Gateway
CT_DNS="1.1.1.1"

# Cloudflare R2
R2_ACCESS_KEY_ID=""
R2_SECRET_ACCESS_KEY=""
R2_ACCOUNT_ID=""             # Bare konto-ID (f.eks. abc123def456)
R2_BUCKET="veeam-backup"

# Samba
SAMBA_USER="veeambackup"
SAMBA_PASSWORD=""            # La stå tom for interaktiv prompt

# Intern stier i containeren
MOUNT_POINT="/mnt/r2-veeam"
CACHE_DIR="/var/cache/s3fs"

# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
step()  { echo -e "${CYAN}[STEG]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ─── Proxmox-host: forutsetninger ────────────────────────────────────────────

require_root() {
    [[ $EUID -eq 0 ]] || error "Scriptet må kjøres som root."
}

require_proxmox() {
    command -v pct &>/dev/null || error "pct ikke funnet — scriptet må kjøres på Proxmox-hosten."
    command -v pveam &>/dev/null || error "pveam ikke funnet — er dette en Proxmox-node?"
}

validate_config() {
    local missing=()
    [[ -z "$R2_ACCESS_KEY_ID" ]]     && missing+=("R2_ACCESS_KEY_ID")
    [[ -z "$R2_SECRET_ACCESS_KEY" ]] && missing+=("R2_SECRET_ACCESS_KEY")
    [[ -z "$R2_ACCOUNT_ID" ]]        && missing+=("R2_ACCOUNT_ID")
    [[ -z "$SAMBA_PASSWORD" ]]       && missing+=("SAMBA_PASSWORD")
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Følgende variabler mangler i konfigurasjonen: ${missing[*]}"
    fi
    pct status "$VMID" &>/dev/null && error "CT $VMID finnes allerede. Velg et annet VMID."
}

# ─── Finn eller last ned Debian 12-template ───────────────────────────────────

get_template() {
    step "Leter etter Debian 12-template..."
    pveam update -q 2>/dev/null || warn "pveam update feilet, fortsetter med lokal cache."

    # Sjekk om en debian-12-standard template allerede er lastet ned
    local tmpl
    tmpl=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null \
        | awk '/debian-12-standard/ {print $1; exit}')

    if [[ -n "$tmpl" ]]; then
        info "Fant template: $tmpl"
        echo "$tmpl"
        return
    fi

    # Finn siste tilgjengelige debian-12-standard fra online-katalogen
    local avail
    avail=$(pveam available --section system 2>/dev/null \
        | awk '/debian-12-standard/ {print $2; exit}')

    [[ -z "$avail" ]] && error "Fant ingen debian-12-standard template. Sjekk internettilgang fra Proxmox-noden."

    info "Laster ned template: $avail"
    pveam download "$TEMPLATE_STORAGE" "$avail"
    echo "${TEMPLATE_STORAGE}:vztmpl/${avail}"
}

# ─── Opprett LXC-container ───────────────────────────────────────────────────

create_container() {
    local template_path="$1"
    step "Oppretter LXC $VMID ($CT_HOSTNAME)..."

    pct create "$VMID" "$template_path" \
        --hostname  "$CT_HOSTNAME" \
        --memory    "$MEMORY_MB" \
        --cores     "$CORES" \
        --rootfs    "${ROOTFS_STORAGE}:${DISK_GB}" \
        --net0      "name=eth0,bridge=${BRIDGE},ip=${CT_IP},gw=${CT_GW}" \
        --nameserver "$CT_DNS" \
        --unprivileged 0 \
        --features  "fuse=1,mounts=fuse" \
        --onboot    1 \
        --start     0

    # Tillat FUSE og nesting i container-config
    local conf="/etc/pve/lxc/${VMID}.conf"
    grep -q "^lxc.apparmor.profile" "$conf" || \
        echo "lxc.apparmor.profile: unconfined" >> "$conf"
    grep -q "^lxc.cap.drop" "$conf" && \
        sed -i '/^lxc.cap.drop/d' "$conf"

    info "Container $VMID opprettet."
}

start_and_wait() {
    step "Starter container $VMID..."
    pct start "$VMID"

    info "Venter på at containeren er klar..."
    local retries=20
    while (( retries-- > 0 )); do
        if pct exec "$VMID" -- true &>/dev/null 2>&1; then
            info "Container svarer."
            return
        fi
        sleep 2
    done
    error "Containeren svarte ikke innen timeout."
}

# ─── Installer og konfigurer inni containeren ────────────────────────────────

exec_ct() {
    pct exec "$VMID" -- bash -c "$1"
}

install_packages() {
    step "Installerer pakker i container..."
    exec_ct "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq s3fs samba samba-common-bin curl fuse"
}

setup_credentials() {
    step "Lagrer R2-credentials i container..."
    exec_ct "echo '${R2_ACCESS_KEY_ID}:${R2_SECRET_ACCESS_KEY}' > /etc/r2-credentials && chmod 600 /etc/r2-credentials"
}

setup_mount() {
    step "Konfigurerer s3fs-montering..."
    local r2_url="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

    exec_ct "mkdir -p '${MOUNT_POINT}' '${CACHE_DIR}'"

    # Aktiver allow_other i fuse.conf
    exec_ct "grep -q '^user_allow_other' /etc/fuse.conf || echo 'user_allow_other' >> /etc/fuse.conf"

    # Legg til fstab-oppføring
    local fstab_line="s3fs#${R2_BUCKET} ${MOUNT_POINT} fuse _netdev,passwd_file=/etc/r2-credentials,url=${r2_url},use_path_request_style,allow_other,umask=0022,uid=0,gid=0,use_cache=${CACHE_DIR},parallel_count=8,multipart_size=64,ensure_diskfree=2048 0 0"
    exec_ct "grep -qF 's3fs#${R2_BUCKET}' /etc/fstab || echo '${fstab_line}' >> /etc/fstab"

    info "Tester montering av R2-bucket..."
    exec_ct "mount '${MOUNT_POINT}'" || error "s3fs-montering feilet. Sjekk R2_ACCOUNT_ID, nøkler og at bucketen finnes."
    info "Montering OK."
}

configure_samba() {
    step "Konfigurerer Samba..."
    pct exec "$VMID" -- bash -c "cat > /etc/samba/smb.conf <<'SMBEOF'
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
SMBEOF"
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
    local lxc_ip="${CT_IP%%/*}"   # Fjern prefixlengde
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
    validate_config

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

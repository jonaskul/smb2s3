#!/usr/bin/env bash
# setup-lxc-r2-smb.sh
# Setter opp s3fs + Samba på Debian 12 LXC for Cloudflare R2 → Veeam SMB-repository.
# Kjøres inne i LXC-containeren som root.
set -euo pipefail

# ─── Konfigurasjon — fyll inn disse før du kjører ────────────────────────────
R2_ACCESS_KEY_ID=""
R2_SECRET_ACCESS_KEY=""
R2_ACCOUNT_ID=""        # f.eks. abc123def456 (uten .r2.cloudflarestorage.com)
R2_BUCKET="veeam-backup"
SAMBA_USER="veeambackup"
SAMBA_PASSWORD=""       # Sett passord her, eller la stå tom for interaktiv prompt
CACHE_DIR="/var/cache/s3fs"
MOUNT_POINT="/mnt/r2-veeam"
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

require_root() {
    [[ $EUID -eq 0 ]] || error "Scriptet må kjøres som root."
}

validate_config() {
    local missing=()
    [[ -z "$R2_ACCESS_KEY_ID" ]]     && missing+=("R2_ACCESS_KEY_ID")
    [[ -z "$R2_SECRET_ACCESS_KEY" ]] && missing+=("R2_SECRET_ACCESS_KEY")
    [[ -z "$R2_ACCOUNT_ID" ]]        && missing+=("R2_ACCOUNT_ID")
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Følgende variabler mangler: ${missing[*]}"
    fi
}

install_packages() {
    info "Installerer pakker..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        s3fs samba samba-common-bin curl fuse
}

setup_credentials() {
    info "Lagrer R2-credentials..."
    echo "${R2_ACCESS_KEY_ID}:${R2_SECRET_ACCESS_KEY}" > /etc/r2-credentials
    chmod 600 /etc/r2-credentials
}

setup_mount() {
    info "Oppretter mountpoints..."
    mkdir -p "$MOUNT_POINT" "$CACHE_DIR"

    local r2_url="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
    local fstab_entry="s3fs#${R2_BUCKET} ${MOUNT_POINT} fuse _netdev,passwd_file=/etc/r2-credentials,url=${r2_url},use_path_request_style,allow_other,umask=0022,uid=0,gid=0,use_cache=${CACHE_DIR},parallel_count=8,multipart_size=64,ensure_diskfree=2048 0 0"

    if grep -qF "s3fs#${R2_BUCKET}" /etc/fstab; then
        warn "fstab-oppføring finnes allerede, hopper over."
    else
        info "Legger til fstab-oppføring..."
        echo "$fstab_entry" >> /etc/fstab
    fi

    # Aktiver allow_other i fuse
    if ! grep -q "^user_allow_other" /etc/fuse.conf 2>/dev/null; then
        echo "user_allow_other" >> /etc/fuse.conf
    fi

    info "Monterer ${R2_BUCKET} → ${MOUNT_POINT}..."
    mount "$MOUNT_POINT" || error "Montering feilet. Sjekk R2-credentials og konto-ID."
    info "Montering OK. Innhold:"
    ls "$MOUNT_POINT" || true
}

configure_samba() {
    info "Konfigurerer Samba..."
    local smb_conf="/etc/samba/smb.conf"

    # Skriv [global]-seksjon
    cat > "$smb_conf" <<EOF
[global]
   workgroup = WORKGROUP
   server string = R2 SMB Gateway
   security = user
   map to guest = bad user
   log file = /var/log/samba/log.%m
   max log size = 50
   # Forbedret ytelse for store filer (Veeam VBK)
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
    info "Oppretter systembruker '${SAMBA_USER}'..."
    if ! id -u "$SAMBA_USER" &>/dev/null; then
        useradd -M -s /sbin/nologin "$SAMBA_USER"
    else
        warn "Bruker '${SAMBA_USER}' finnes allerede."
    fi

    info "Setter Samba-passord for '${SAMBA_USER}'..."
    if [[ -n "$SAMBA_PASSWORD" ]]; then
        printf '%s\n%s\n' "$SAMBA_PASSWORD" "$SAMBA_PASSWORD" | smbpasswd -a -s "$SAMBA_USER"
    else
        smbpasswd -a "$SAMBA_USER"
    fi
}

start_services() {
    info "Starter og aktiverer smbd/nmbd..."
    systemctl enable smbd nmbd
    systemctl restart smbd nmbd
}

verify() {
    info "Verifiserer Samba-lister..."
    smbclient -L localhost -U "${SAMBA_USER}%${SAMBA_PASSWORD:-<passord>}" -N 2>/dev/null || \
        warn "smbclient-test feilet. Verifiser manuelt med: smbclient -L localhost -U ${SAMBA_USER}"

    local lxc_ip
    lxc_ip=$(hostname -I | awk '{print $1}')
    echo
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Oppsett fullført!                                       ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  SMB-share:   \\\\\\\\${lxc_ip}\\\\${R2_BUCKET}${NC}"
    echo -e "${GREEN}║  Bruker:      ${SAMBA_USER}${NC}"
    echo -e "${GREEN}║                                                          ║${NC}"
    echo -e "${GREEN}║  Legg til i Veeam:                                       ║${NC}"
    echo -e "${GREEN}║  Backup Infrastructure → Backup Repositories →           ║${NC}"
    echo -e "${GREEN}║  Add Repository → Network attached storage → SMB share   ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo
    echo "Test fra Windows PowerShell:"
    echo "  net use \\\\${lxc_ip}\\${R2_BUCKET} /user:${SAMBA_USER} <passord>"
    echo "  dir \\\\${lxc_ip}\\${R2_BUCKET}"
}

main() {
    require_root
    validate_config
    install_packages
    setup_credentials
    setup_mount
    configure_samba
    setup_samba_user
    start_services
    verify
}

main

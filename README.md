# smb2s3

Creates a Debian 13 LXC on Proxmox that mounts Cloudflare R2 buckets via s3fs and exposes them as SMB shares.

## What the script does

1. Auto-detects the Proxmox environment (VMID, storage, bridge)
2. Runs a minimal wizard — network mode and web UI credentials only
3. Downloads the Debian 13 template if not already present locally
4. Creates and starts a privileged LXC with FUSE support
5. Installs s3fs, Samba, and Python/Flask inside the container
6. Sets up a web management UI (port 8080) for adding and managing R2 shares
7. Configures root auto-login on the container console
8. Prints the web UI URL and login credentials

R2 buckets and SMB shares are configured through the web UI after setup.

## Requirements

- Proxmox node with internet access (for template download and apt packages)
- Cloudflare R2 bucket with API token (Access Key ID + Secret Access Key + Account ID)
- Network access between the SMB client and the LXC

## Usage

Run the script on the **Proxmox host** as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jonaskul/smb2s3/main/setup-lxc-r2-smb.sh)
```

The wizard will prompt for:

| Prompt | Example |
|---|---|
| Network mode | `dhcp` (default) or `static` |
| IP + gateway | Static mode only |
| Web UI admin username | `admin` (default) |
| Web UI admin password | |

A confirmation summary is shown before anything is created.

## Web management UI

After setup, a browser-based UI is available at `http://<CT-IP>:8080`. Log in with the credentials set during the wizard.

### Shares

- View all configured SMB shares and their mount status
- Add new R2 shares — each with its own bucket, credentials, and Samba user
- Edit existing shares (update credentials, account ID, or Samba password)
- Delete shares (unmounts, removes from fstab and smb.conf)

### Stats

A live stats panel is always visible on the dashboard:

- **Network graph** — TX/RX throughput over the last ~3 minutes (updates every 3 seconds)
- **System card** — memory usage bar and CPU load average
- **Per-share cache** — mount status and local cache size for each share

### Settings

The ⚙ Settings button in the top bar provides:

- **SNMP monitoring** — enable/disable `snmpd` with configurable community string and allowed host/CIDR. Compatible with the Zabbix **Linux by SNMP** template.

## Updating the web UI

Run this inside the container as root to pull the latest version from GitHub:

```bash
smb2s3-update
```

## Cloudflare R2 API token requirements

The token must have **Object Read & Write** permission scoped to the specific bucket. EU jurisdiction must match the actual bucket location — a standard bucket will not respond on the EU endpoint and vice versa.

## Connecting an SMB client

1. Open the web UI and add a share — note the share name and Samba credentials you set
2. Connect using the UNC path `\\<CT-IP>\<share-name>` with the Samba username and password set in the web UI

## Notes

- The container is created as **privileged** — required for FUSE mounts
- `force user = root` in the Samba config is necessary because the s3fs mount is owned by root
- Each share uses a separate credential file `/etc/r2-credentials-{name}` and mount point `/mnt/r2-{name}`
- The container auto-logs in as root on the Proxmox **Console** tab (the Shell button always gives root directly and does not need autologin)

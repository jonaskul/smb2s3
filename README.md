# smb2s3

Creates a Debian 13 LXC on Proxmox that mounts S3-compatible buckets via rclone and exposes them as SMB shares. Optimised for Cloudflare R2, but works with AWS S3, Wasabi, MinIO, and any other S3-compatible provider.

## Requirements

- Proxmox node with internet access
- An S3-compatible bucket with an access key (Access Key ID + Secret Access Key). For Cloudflare R2 you also need an Account ID.
- Network access between the SMB client and the LXC

## Setup

Run on the **Proxmox host** as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jonaskul/smb2s3/main/setup-lxc-r2-smb.sh)
```

The wizard prompts for:

| Prompt | Default |
|---|---|
| Container storage | auto-detected |
| Disk size (GB) | 120 |
| Network mode | dhcp |
| IP + gateway | static mode only |
| Web UI username | admin |
| Web UI password | |

A confirmation summary is shown before anything is created. The script prints the web UI URL and credentials when done.

## Web UI

Available at `http://<CT-IP>:8080` after setup.

### Shares

- View all configured SMB shares and their mount status
- **Add** shares from Cloudflare R2 or any S3-compatible provider (AWS S3, Wasabi, MinIO, etc.)
- **Edit** existing shares — update credentials, endpoint, or Samba password
- **Delete** shares — stops the rclone service, removes from smb.conf, cleans up cache
- **Clean cache** — free local disk space after uploads complete (see below)

Each share gets its own rclone config, systemd service, mount point, and VFS cache directory.

### Dashboard stats

Live stats panel, updated every 3 seconds:

- **Network** — TX/RX throughput sparkline over the last ~3 minutes, cumulative totals
- **System** — memory usage bar and CPU load average
- **Per-share cache** — mount status and local VFS cache size for each share
- **Watchdog log** — recent mount events (unmounts detected, remount attempts and results)

### Cache cleanup

Each share card has a **Clean cache** button. It reads rclone's internal metadata to distinguish files already uploaded from files still pending upload, then shows a breakdown before taking any action.

- **Remove uploaded** — deletes only already-uploaded files; pending uploads are untouched
- **Remove all** — deletes everything including pending uploads (backup client must re-send)

Rclone also evicts uploaded files automatically after ~1 hour. The button is useful when you need the space back immediately.

### Settings — Performance tab

- **VFS cache size** — maximum local disk space per share used to buffer writes before upload. Changing this restarts all active mounts.
- **rclone performance** — tune CPU and memory usage. All values restart active mounts when saved:
  - *Transfers* — concurrent upload streams (default: 2)
  - *Checkers* — concurrent checksum operations (default: 2)
  - *Buffer per transfer* — in-memory buffer in MB per stream (default: 64 MB)
  - *Write-back delay* — seconds after last write before upload starts (default: 5 s)

### Settings — Monitoring tab

- **SNMP** — enable `snmpd` on UDP port 161 (SNMPv2c). Compatible with LibreNMS and Zabbix (**Linux by SNMP** template). Includes extensions:

| Extension | Data |
|---|---|
| `distro` | OS name and version |
| `includeAllDisks` | Disk usage for all mount points |
| `proc smbd` | Samba process count (alerts if 0) |
| `proc python3` | Web UI process count (alerts if 0) |
| `osupdate` | Number of pending apt upgrades |

### Settings — Admin tab

- **Change password** — update the web UI admin password
- **Disable login** — remove the login requirement entirely. Useful on isolated networks where port 8080 is not exposed to untrusted clients.
- **Config backup / restore** — export all share definitions, credentials, and settings to a JSON file. Can also save the backup directly to a configured bucket. All data lives in the bucket — a config backup is all that is needed for disaster recovery.

### Version and updates

The topbar shows the installed version. When a newer version is available on GitHub, an **↑ Update** button appears. Clicking it shows a changelog of what's new, then asks for confirmation before running the update. The page reloads automatically when the service is back up.

To update from the terminal:

```bash
smb2s3-update
```

## Disk sizing

Each share buffers writes locally before uploading (rclone VFS cache mode `writes`). The entire file being written must fit on the container disk.

| Workload | Recommended disk |
|---|---|
| Testing / small files | 20 GB |
| Backups up to ~65 GB per file | 120 GB |
| Backups up to ~200 GB per file | 300+ GB |

Expand the container disk in Proxmox, then update the VFS cache size in Settings. A safe rule of thumb: keep the VFS cache at 70–80% of the disk to leave room for the OS and rclone metadata.

If the container causes high load on the Proxmox node:

```bash
pct set <VMID> -cpulimit 2
```

Reduce *Transfers* and *Buffer per transfer* in Settings to lower CPU and memory usage further.

## Cloudflare R2

The API token needs **Object Read & Write** permission scoped to the bucket. EU jurisdiction must match the actual bucket location.

## Other S3-compatible providers

When adding a share, check **Other S3-compatible provider** and enter the endpoint URL. Examples:

| Provider | Endpoint |
|---|---|
| AWS S3 | `https://s3.amazonaws.com` |
| Wasabi (EU) | `https://s3.eu-central-2.wasabisys.com` |
| MinIO (self-hosted) | `http://192.168.1.50:9000` |

## Connecting an SMB client

1. Add a share in the web UI — note the share name and Samba credentials
2. Connect with the UNC path `\\<CT-IP>\<share-name>` using the Samba username and password

## Notes

- The container runs as **privileged** — required for FUSE mounts
- `force user = root` in the Samba config is required because the rclone mount is owned by root
- A watchdog timer runs every 60 seconds and automatically remounts any dropped share

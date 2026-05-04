# smb2s3

Creates a Debian 13 LXC on Proxmox that mounts S3-compatible buckets via rclone and exposes them as SMB shares. Optimised for Cloudflare R2, but works with AWS S3, Wasabi, MinIO, and any other S3-compatible provider.

## What the script does

1. Auto-detects the Proxmox environment (VMID, storage, bridge)
2. Runs a minimal wizard — storage, disk size, network mode and web UI credentials
3. Downloads the Debian 13 template if not already present locally
4. Creates and starts a privileged LXC with FUSE support
5. Installs rclone, Samba, and Python/Flask inside the container
6. Sets up a web management UI (port 8080) for adding and managing R2 shares
7. Configures root auto-login on the container console
8. Prints the web UI URL and login credentials

R2 buckets and SMB shares are configured through the web UI after setup.

## Requirements

- Proxmox node with internet access (for template download and apt packages)
- An S3-compatible bucket with an access key (Access Key ID + Secret Access Key). For Cloudflare R2 you also need an Account ID.
- Network access between the SMB client and the LXC

## Usage

Run the script on the **Proxmox host** as root:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/jonaskul/smb2s3/main/setup-lxc-r2-smb.sh)
```

The wizard will prompt for:

| Prompt | Example |
|---|---|
| Container storage | `local-lvm` (auto-detected) |
| Disk size (GB) | `120` (default) |
| Network mode | `dhcp` (default) or `static` |
| IP + gateway | Static mode only |
| Web UI admin username | `admin` (default) |
| Web UI admin password | |

A confirmation summary is shown before anything is created.

## Web management UI

After setup, a browser-based UI is available at `http://<CT-IP>:8080`. Log in with the credentials set during the wizard.

### Shares

- View all configured SMB shares and their mount status
- Add shares from **Cloudflare R2** or any **S3-compatible provider** (AWS S3, Wasabi, MinIO, etc.) — each with its own bucket, credentials, and Samba user
- Edit existing shares (update credentials, endpoint, or Samba password)
- Delete shares (stops the rclone service, removes from smb.conf, cleans up cache)
- **Clean cache** — free local disk space after uploads complete (see below)

### Stats

A live stats panel is always visible on the dashboard (updates every 3 seconds):

- **Network graph** — TX/RX throughput over the last ~3 minutes
- **System card** — memory usage bar and CPU load average
- **Per-share cache** — mount status and local VFS cache size for each share
- **Watchdog log** — recent mount events (unmounts detected, remount attempts and results)

### Cache cleanup

Each share card has a **Clean cache** button. It reads rclone's internal metadata (`vfsMeta/`) to distinguish files already uploaded to R2 from files still pending upload, then shows a modal with the breakdown before taking any action.

- **Remove uploaded** — deletes only already-uploaded files; pending uploads are untouched
- **Remove all** — deletes everything including pending uploads (backup client must re-send those files)

Rclone also evicts uploaded files automatically after ~1 hour (`--vfs-cache-max-age` default). The button is useful when you need the space back immediately.

### Settings

The ⚙ Settings button in the top bar opens a modal with three tabs.

#### Performance tab

- **VFS cache size** — maximum local disk space per share used to buffer writes before upload. Changing this restarts all active mounts.
- **rclone performance** — tune CPU and memory usage during transfers. All values restart active mounts when saved:
  - *Transfers* — concurrent upload streams (default: 2)
  - *Checkers* — concurrent checksum operations (default: 2)
  - *Buffer per transfer* — in-memory buffer in MB per stream (default: 64 MB)
  - *Write-back delay* — seconds after last write before upload starts (default: 5 s)

#### Monitoring tab

- **SNMP monitoring** — enable/disable `snmpd` on UDP port 161 (SNMPv2c). Includes extensions for LibreNMS and Zabbix:

| Extension | Data |
|---|---|
| `distro` | OS name and version |
| `includeAllDisks` | Disk usage for all mount points |
| `proc smbd` | Samba process count (alerts if 0) |
| `proc python3` | Web UI process count (alerts if 0) |
| `osupdate` | Number of pending apt upgrades |

#### Admin tab

- **Change password** — update the web UI admin password (requires the current password).
- **Disable login** — remove the login requirement entirely. Anyone with network access to port 8080 can manage shares without a password. Useful on isolated home networks.
- **Config backup / restore** — export all share definitions, credentials, and settings to a JSON file. Use it to restore the container after a reinstall. All data lives in the bucket — a config backup is all that is needed for disaster recovery. You can also save the backup directly to a configured bucket.

### Version and updates

The topbar shows the installed version. If a newer version is available on GitHub, an **↑ Update** button appears. Clicking it opens a changelog showing what's new since the installed version, with a confirmation step before the update runs. The page reloads automatically when the service is back up.

To update from the terminal instead:

```bash
smb2s3-update
```

## Disk sizing

Each share buffers writes to local disk before uploading to R2 (rclone VFS cache mode `writes`). This means the entire file being written must fit on the container disk.

| Workload | Recommended disk |
|---|---|
| Testing / small files | 20 GB |
| Backups up to ~65 GB per file (default) | 120 GB |
| Backups up to ~200 GB per file | 300+ GB |

Expand the container disk in Proxmox, then update the VFS cache size in Settings accordingly. A safe rule of thumb: keep the VFS cache at 70–80% of the disk to leave room for the OS and rclone metadata.

If the container causes high load on the Proxmox node, cap its CPU usage from the host:

```bash
pct set <VMID> -cpulimit 2
```

Reduce *Transfers* and *Buffer per transfer* in Settings to lower CPU and memory usage further.

## Cloudflare R2 API token requirements

The token must have **Object Read & Write** permission scoped to the specific bucket. EU jurisdiction must match the actual bucket location — a standard bucket will not respond on the EU endpoint and vice versa.

## Other S3-compatible providers

When adding a share, check **Other S3-compatible provider** and enter the endpoint URL instead of the R2 account ID. Examples:

| Provider | Endpoint |
|---|---|
| AWS S3 | `https://s3.amazonaws.com` |
| Wasabi (EU) | `https://s3.eu-central-2.wasabisys.com` |
| MinIO (self-hosted) | `http://192.168.1.50:9000` |

## Connecting an SMB client

1. Open the web UI and add a share — note the share name and Samba credentials you set
2. Connect using the UNC path `\\<CT-IP>\<share-name>` with the Samba username and password set in the web UI

## Notes

- The container is created as **privileged** — required for FUSE mounts
- `force user = root` in the Samba config is necessary because the rclone mount is owned by root
- Each share gets its own rclone config (`/etc/rclone-{name}.conf`), systemd service (`smb2s3-mount-{name}.service`), mount point (`/mnt/r2-{name}`), and VFS cache directory (`/var/cache/rclone/{name}`)
- A watchdog timer runs every 60 seconds and automatically restarts any share that has dropped its mount
- The container auto-logs in as root on the Proxmox **Console** tab (the Shell button always gives root directly and does not need autologin)

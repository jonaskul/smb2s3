# smb2s3

Creates a Debian 13 LXC on Proxmox that mounts a Cloudflare R2 bucket via s3fs and exposes it as an SMB share. Primarily intended for use as a Veeam Backup & Replication repository.

## What the script does

1. Auto-detects the Proxmox environment (VMID, storage, bridge)
2. Runs an interactive wizard for R2 credentials, network settings, and Samba password
3. Downloads the Debian 13 template if not already present locally
4. Creates and starts a privileged LXC with FUSE support
5. Installs and configures s3fs + Samba inside the container
6. Prints the finished SMB path and a PowerShell test command

## Requirements

- Proxmox node with internet access (for template download and apt packages)
- Cloudflare R2 bucket with API token (Access Key ID + Secret Access Key + Account ID)
- Network access between the Veeam server and the LXC

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
| R2 Access Key ID | From the Cloudflare dashboard |
| R2 Secret Access Key | From the Cloudflare dashboard |
| R2 Account ID | ID only, not the full URL |
| EU jurisdiction | `Y` (default) or `n` |
| R2 Bucket name | Must match the exact name in Cloudflare R2 |
| Samba username | `veeambackup` (default) |
| Samba password | |

A confirmation summary is shown before anything is created.

## Cloudflare R2 API token requirements

The token must have **Object Read & Write** permission scoped to the specific bucket. EU jurisdiction must match the actual bucket location — a standard bucket will not respond on the EU endpoint and vice versa.

## Adding to Veeam

1. **Backup Infrastructure → Backup Repositories → Add Repository**
2. Select **Network attached storage → SMB share**
3. UNC path: `\\<CT-IP>\<bucket-name>`
4. Credentials: the username and password set in the wizard

## Notes

- The container is created as **privileged** — required for FUSE mounts
- `force user = root` in the Samba config is necessary because the s3fs mount is owned by root
- Do not configure lifecycle rules on the R2 bucket — Veeam manages deletion of backup files itself
- The container auto-logs in as root on the console (Proxmox Shell button)

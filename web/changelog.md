## 2026-05-03g
- Dashboard reuses cache-size readings for 30 s instead of scanning the cache every 3 s
- Fresh installs now get the favicon

## 2026-05-03f
- Deleting a share can no longer remove bucket contents if the unmount fails
- Mount status no longer shows a share as mounted when a similarly named one is
- Updates download everything before installing, so a failed download leaves the old version intact

## 2026-05-03e
- Settings no longer restart active mounts unless a performance value changed
- Invalid performance values return a clear error instead of failing the save
- Escape server error text rendered in the shares list

## 2026-05-03d
- Add Share modal: field hints, live SMB path preview, labelled section divider
- Clarify Cloudflare R2 as default provider with examples for AWS S3, Wasabi, MinIO

## 2026-05-03c
- Changelog shown before updating
- Change password in Settings → Admin tab
- Disable login requirement in Settings → Admin tab
- Settings reorganised into Performance / Monitoring / Admin tabs

## 2026-05-03b
- Generic S3 support — add shares on AWS S3, Wasabi, MinIO, etc.
- Save config backup directly to a configured bucket from Settings

## 2026-05-03a
- Config backup: option to save directly to a configured bucket

## 2026-05-03
- Config backup / restore — export/import all shares, credentials and settings as JSON

## 2026-05-02f
- Clean cache: smart detection of stale (uploaded) vs dirty (pending) files
- Custom clean cache modal replaces native browser confirm dialog
- Network graph (TX/RX sparklines), memory bar, per-share cache stats on dashboard
- Watchdog log in dashboard
- One-click update from topbar when a newer version is available
- Version badge in topbar
- SVG favicon
- LibreNMS and Zabbix SNMP extensions (distro, disk, processes, pending updates)
- Fix self-update script race condition

## 2026-05-02a
- rclone performance settings in web UI (transfers, checkers, buffer, write-back delay)
- SNMP monitoring (SNMPv2c, LibreNMS compatible)

## 2026-05-01
- Initial release — Cloudflare R2 → SMB via rclone VFS cache

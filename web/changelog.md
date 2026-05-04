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

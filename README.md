# smb2s3

Setter opp en Debian 13 LXC på Proxmox som monterer en Cloudflare R2-bucket via s3fs og deler den ut som et SMB-share. Primært ment for bruk som Veeam Backup & Replication-repository.

## Hva scriptet gjør

1. Auto-detekterer Proxmox-miljøet (VMID, lagring, bridge)
2. Kjører en interaktiv veiviser for R2-nøkler, nettverk og Samba-passord
3. Laster ned Debian 13-template om den ikke finnes lokalt
4. Oppretter og starter en privilegert LXC med FUSE-støtte
5. Installerer og konfigurerer s3fs + Samba inni containeren
6. Skriver ut ferdig SMB-path og PowerShell-testkommando

## Krav

- Proxmox-node med tilgang til internett (for template-nedlasting)
- Cloudflare R2-bucket med API-token (Access Key ID + Secret Access Key + Account ID)
- Nettverkstilgang mellom Veeam-server og LXCen

## Bruk

Kjør scriptet på **Proxmox-hosten** som root:

```bash
bash setup-lxc-r2-smb.sh
```

Scriptet vil spørre om:

| Spørsmål | Eksempel |
|---|---|
| Nettverksmodus | `dhcp` (default) eller `statisk` |
| IP + gateway | Kun ved statisk |
| R2 Access Key ID | Fra Cloudflare-dashbordet |
| R2 Secret Access Key | Fra Cloudflare-dashbordet |
| R2 Account ID | Kun ID-en, ikke URL |
| R2 Bucket-navn | `veeam-backup` (default) |
| Samba-brukernavn | `veeambackup` (default) |
| Samba-passord | Valgfritt |

En oppsummeringsskjerm vises før noe opprettes.

## Legg til i Veeam

1. **Backup Infrastructure → Backup Repositories → Add Repository**
2. Velg **Network attached storage → SMB share**
3. UNC-path: `\\<CT-IP>\veeam-backup`
4. Credentials: brukernavn og passord satt i veiviseren

## Merk

- Containeren opprettes som **privilegert** — påkrevd for FUSE-montering
- `force user = root` i Samba-konfigen er nødvendig fordi s3fs-monteringen eies av root
- Ikke sett opp lifecycle-regler i R2-bucketen — Veeam håndterer sletting av backup-filer selv

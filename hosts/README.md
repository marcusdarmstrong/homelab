# Host settings

A host's configuration is layered from these files, later ones winning:

| File | In git | Holds |
|---|---|---|
| `config/sdcard.env` | yes | write-saving settings, only if the host has `HOST_STORAGE=sdcard` |
| `hosts/common.env` | yes | settings every host shares |
| `hosts/<name>.env` | yes | this host's settings |
| `.env` on the host | **no** | `HOST_NAME` plus the secrets, assembled by `scripts/push-env.sh` from your `hosts/secrets.env` and `hosts/<name>.secrets.env` |

Settings deploy by commit, like code. Secrets are documented in
[`secrets.env.example`](secrets.env.example) and go out with
`scripts/push-env.sh <name>`. The repo is public, so CI refuses a committed
settings file with a secret-looking key (`*_SECRET`, `*_PASSWORD`, `*_TOKEN`,
`*_KEY`, `*_HASH`, `*_EMAIL`).

## Settings

| Setting | Default | |
|---|---|---|
| `COMPOSE_PROFILES` | none | What runs here, comma-separated: `sso`, `observability`, `dns`, `unifi`, `smart` (see the README). CI checks `sso` and `observability` are each on exactly one host, and `unifi` on at most one per site. |
| `SITE` | required | `home` or `basecamp`; labels this host's metrics and logs. |
| `BASE_DOMAIN` | required | This host's own name, `<host>.HOMELAB_DOMAIN`. Its pages live under it (`pihole.luna.…`). |
| `HOMELAB_DOMAIN` | required | The zone for everything; services that run once live at `<service>.HOMELAB_DOMAIN`. |
| `TZ` | `UTC` | |
| `HOST_SSH` | `<name>.local` | How `provision.sh` and `push-env.sh` reach the host. |
| `HOST_STORAGE` | `ssd` | `ssd` (an NVMe drive) or `sdcard`; see the README's SD-card section. With `ssd`, `provision.sh` moves a host that booted from its SD card onto the NVMe. |
| `HOST_DNS` | `"1.1.1.1 1.0.0.1"` | The Pi's own resolvers. Deliberately not Pi-hole, so the host can always pull images and sync git. |
| `OS_UPGRADE_TIME` | `04:00` | When OS auto-updates run. |
| `OS_REBOOT_TIME` | `04:30` | When the Pi reboots, if an update needs it. |
| `OS_AUTO_REBOOT` | `true` | `false` to reboot by hand, both for OS updates and for settings that need a reboot. |
| `DOCKER_SUBNET` | `172.30.0.0/24` | The project network; change only if it collides. |
| `DOCKER_LOG_DRIVER` | `local` | `journald` on SD cards (`config/sdcard.env`). |
| `ACME_DNS_PROVIDER` | `cloudflare` | Any [lego DNS provider](https://go-acme.github.io/lego/dns/), with its variables added to Traefik. |
| `ACME_CA_SERVER`, `ACME_STORAGE` | production | While testing, `https://acme-staging-v02.api.letsencrypt.org/directory` and `acme-staging.json`; delete both to switch to production. |
| `TRAEFIK_LOG_LEVEL` | `INFO` | |
| `TS_EXTRA_ARGS` | `--advertise-tags=tag:homelab` | Extra `tailscale up` flags. |
| `PIHOLE_UPSTREAMS` | `1.1.1.1;1.0.0.1` | Pi-hole's upstream resolvers. |
| `PIHOLE_DNSMASQ_LINES` | none | Semicolon-separated dnsmasq lines, if ever needed. |
| `PIHOLE_DB_INTERVAL` | `60` | Seconds between query-stat flushes; `600` on SD cards. |
| `UNIFI_URL` | none | The site's UniFi console, for `unifi` (e.g. `https://192.168.1.1`). |
| `PROM_RETENTION`, `LOKI_RETENTION` | `30d` | |
| `LOKI_WAL_ENABLED` | `true` | `false` on SD cards. |
| `GRAFANA_ALERT_STATE_SAVE_INTERVAL` | `1m` | `5m` on SD cards. |
| `NTFY_UPSTREAM_BASE_URL` | `https://ntfy.sh` | Relay for waking iOS devices; empty to skip it (Android is unaffected). |
| `BACKUP_CRON` | `0 30 3 * * *` | When backup sidecars snapshot, as 6-field cron (with seconds) in `TZ`. |
| `RESTIC_S3_REGION` | `auto` | Region for the backup buckets (`auto` is right for R2). |

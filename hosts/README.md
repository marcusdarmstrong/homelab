# Host settings

A host's configuration is layered from these files, later ones winning:

| File | In git | Holds |
|---|---|---|
| `config/sdcard.env` | yes | write-saving settings, only if the host has `HOST_STORAGE=sdcard` |
| `config/common.env` | yes | settings every host shares |
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
| `HOMELAB_DOMAIN` | required | The zone for everything: each host's pages live under `<host>.HOMELAB_DOMAIN` (`pihole.luna.…`), and services that run once at `<service>.HOMELAB_DOMAIN`. |
| `TZ` | `UTC` | |
| `HOST_STORAGE` | `ssd` | `ssd` (an NVMe drive) or `sdcard`; see the README's SD-card section. With `ssd`, `provision.sh` moves a host that booted from its SD card onto the NVMe. |
| `HOST_DNS` | `"1.1.1.1 1.0.0.1"` | The Pi's own resolvers. Deliberately not Pi-hole, so the host can always pull images and sync git. |
| `POE_FAN_TEMPS` | firmware's `40,45,50,55` | The four temperatures (°C) at which a PoE HAT's fan steps up a speed (12%, 25%, 50%, full). Changing it reboots the host. |
| `POE_FAN_HYST` | `2` | How far (°C) below each of those the Pi must cool before the fan steps back down. |
| `DOCKER_SUBNET` | `172.30.0.0/24` | The project network; change only if it collides. |
| `DOCKER_LOG_DRIVER` | `local` | `journald` on SD cards (`config/sdcard.env`). |
| `ACME_CA_SERVER`, `ACME_STORAGE` | production | While testing, `https://acme-staging-v02.api.letsencrypt.org/directory` and `acme-staging.json`; delete both to switch to production. |
| `PIHOLE_UPSTREAMS` | `1.1.1.1;1.0.0.1` | Pi-hole's upstream resolvers. |
| `PIHOLE_DB_INTERVAL` | `60` | Seconds between query-stat flushes; `600` on SD cards. |
| `UNIFI_URL` | none | The site's UniFi console, for `unifi` (e.g. `https://192.168.1.1`). |
| `PROM_RETENTION`, `LOKI_RETENTION` | `30d` | |
| `LOKI_WAL_ENABLED` | `true` | `false` on SD cards. |
| `GRAFANA_ALERT_STATE_SAVE_INTERVAL` | `1m` | `5m` on SD cards. |
| `NTFY_UPSTREAM_BASE_URL` | `https://ntfy.sh` | Relay for waking iOS devices; empty to skip it (Android is unaffected). |

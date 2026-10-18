# homelab

Docker Compose config for my Raspberry Pis, deployed GitOps-style: push to
`main` and every host converges within about a minute.

| Host      | Hardware    | Site  | `COMPOSE_PROFILES` (suggested)                         |
|-----------|-------------|-------|--------------------------------------------------------|
| primary   | Pi 4        | home  | `dns,tailscale,backup`                                 |
| secondary | Pi 5 + NVMe | cabin | `dns,observability,tailscale,backup,unifi,smart`       |

## How it works

The repo is one Compose project (`compose.yaml` includes `stacks/*/compose.yaml`).
Every host runs the same code. A host's gitignored `.env` is its entire
configuration, including which **profiles** it runs. **Sites are
independent:** no service talks to another site.

| Profile         | Services                                         |
|-----------------|--------------------------------------------------|
| _(always)_      | Traefik, Docker API proxy, Pocket ID, tinyauth   |
| `dns`           | Pi-hole                                          |
| `observability` | Prometheus, Loki, Grafana, Alloy, ntfy           |
| `tailscale`     | Tailscale (remote access, LAN subnet route)      |
| `backup`        | restic snapshots of the Docker volumes           |
| `unifi`         | UnPoller (UniFi metrics)                         |
| `smart`         | smartctl_exporter (NVMe/disk health)             |

- **Deploys**: `scripts/sync.sh` runs every minute from a systemd timer. It
  hard-resets to `origin/main` and runs `scripts/apply.sh` whenever the commit
  or `.env` differs from the last successful apply. Services whose profile was
  turned off are stopped. A failed apply retries on the next tick and raises
  the "Deploy failing" alert. Deploys are pull-based, so nothing has to accept
  inbound connections.
- **Image updates**: images are pinned to exact tags. Renovate opens a PR for
  each release once it's 14 days old, and merging the PR deploys it. Patch
  releases automerge once CI passes (see `renovate.json5`).
- **HTTPS**: Traefik issues a wildcard Let's Encrypt cert for `*.BASE_DOMAIN`
  through the DNS-01 challenge (Cloudflare by default), so services don't need
  to be internet-exposed. Renewal is automatic, and an alert fires if it falls
  behind.
- **SSO, no passwords**: Pocket ID is a passkey-only OIDC provider, so
  1Password, Bitwarden, iCloud Keychain or a hardware key all work. Grafana
  logs in through it directly. Everything else (Traefik, Pi-hole, Prometheus,
  Alloy) sits behind tinyauth's `sso@docker` forward-auth middleware. No app
  has a password of its own.
- **Observability**: Alloy collects host, container, Traefik and labelled
  service metrics, WAN probes, Docker logs and the systemd journal. It pushes
  them to the site's own Prometheus and Loki. Add metrics for any container
  with a `homelab.metrics.port` label.
- **Alerting**: Grafana alert rules (`provisioning/alerting/`) notify through
  the site's ntfy server: disk, memory, temperature, scrape targets, deploys,
  backups, cert expiry, WAN, SMART and OS updates.
- **OS updates**: unattended-upgrades applies everything from the Debian,
  Raspberry Pi and Docker repos daily, and reboots in a set window when a
  kernel or firmware update needs it.

## External setup

Everything outside the Pis, in the order you need it. Per-site items are done
once for each site, which keeps the sites independent.

**Once**

1. **GitHub.** This repo. Once CI has run:
   - Protect `main` and require the `validate` check, since a merge deploys
     within a minute.
   - Install the [Renovate](https://github.com/apps/renovate) app on the repo
     for image-update PRs.
2. **Cloudflare DNS.** A domain in a Cloudflare zone, with a subdomain per site
   (e.g. `home.example.com`, `cabin.example.com`). No DNS records are needed;
   Traefik only creates temporary TXT records for the DNS-01 challenge.
   - Prefer a dedicated domain for the homelab. Cloudflare can't scope a token
     to a subdomain, so each Pi holds a token that can edit the whole zone. A
     cheap separate domain keeps your main domain's email and website out of
     reach.
   - Protect the Cloudflare account with a passkey or hardware key: it holds
     both certificate issuance and the backups (below).
3. **Tailscale.** One tailnet; the free plan is plenty. In the access-control
   policy, add the tag and let it approve each site's LAN route:

   ```jsonc
   "tagOwners": { "tag:homelab": ["autogroup:admin"] },
   "autoApprovers": {
     "routes": {
       "192.168.1.0/24":  ["tag:homelab"],  // home
       "192.168.20.0/24": ["tag:homelab"],  // cabin
     },
   },
   ```

   Give every site a **distinct LAN subnet**: two sites advertising the same
   range collide. UniFi defaults new sites to `192.168.1.0/24`, so change the
   second site before anything depends on it.

**Per site**

4. **Cloudflare API token** with *Zone → DNS → Edit* on that zone →
   `CF_DNS_API_TOKEN`.
5. **Cloudflare R2 bucket** for backups, e.g. `homelab-home`. R2 is
   S3-compatible, has no egress fees (restores are free), and these backups
   fit easily in the free tier. Create an R2 API token with *Object Read &
   Write* scoped to that bucket only, so a compromised Pi can't touch another
   site's backups. Then:
   - `RESTIC_REPOSITORY=s3:https://<account-id>.r2.cloudflarestorage.com/homelab-home`
   - `RESTIC_S3_ACCESS_KEY_ID` / `RESTIC_S3_SECRET_ACCESS_KEY` from the token
6. **Tailscale OAuth client** (*Settings → OAuth clients*, scope *Auth Keys:
   write*, tag `tag:homelab`). Use the secret as
   `TS_AUTHKEY=tskey-client-…?ephemeral=false&preauthorized=true`. Without
   `ephemeral=false`, OAuth-issued nodes are ephemeral and vanish from the
   tailnet whenever the Pi goes offline. Then add a split-DNS nameserver
   (*DNS → Add nameserver → Custom*): `BASE_DOMAIN` → the site's `HOST_IP`.
7. **UniFi**, on the site's console:
   - a DHCP reservation for the Pi (`HOST_IP`)
   - DHCP DNS: the Pi first, plus a second resolver so the network survives a
     Pi reboot
   - for the `unifi` profile, a local API key (*Settings → Control Plane →
     Integrations*) → `UNIFI_API_KEY`
8. **Password manager.** Store the site's whole `.env`, above all
   `RESTIC_PASSWORD` and `POCKET_ID_ENCRYPTION_KEY`. It's the one part of the
   system that isn't in git, and a restore is impossible or useless without
   it.

**After the host is up**

9. **ntfy app** on each phone (see [Alerts on your phone](#alerts-on-your-phone)).
   No account needed.
10. Optional: an **external dead-man's switch** such as healthchecks.io. Alerts
    run on the Pi they describe, so only an outside check can notice a site
    that's fully down or offline. Not wired in yet.

Let's Encrypt needs no setup; Traefik registers automatically.

## Setting up a host

Each host's config lives in your checkout as `hosts/<name>.env`, which is
gitignored. That file is the **source of truth** for the host:
`scripts/provision.sh <name>` pushes it to the host, and anything edited
directly on the host is overwritten by the next push. Back these files up to
your password manager; they're the one part of the system that isn't in git.

1. Flash 64-bit Raspberry Pi OS Lite. On the Pi 5, boot from the NVMe. Make
   sure you can `ssh` to it (by default as `<name>.local`; set `HOST_SSH`
   otherwise).
2. Create `hosts/<name>.env` from [`.env.example`](.env.example), using
   `scripts/gen-secrets.sh` for the generated values. Leave the OIDC client
   fields empty for now.
3. Run `scripts/provision.sh <name>`. On a new host it copies
   `bootstrap.sh` over, which installs Docker, clones this repo over HTTPS
   and enables the deploy timer; then it runs the first deploy and shows the
   result. sudo may ask for your password. Reboot if it asks (memory cgroup).
4. Set up SSO (below) right away, add the client IDs and secrets to
   `hosts/<name>.env`, and run `scripts/provision.sh <name>` again.

`provision.sh` validates the file first (no placeholders, and the compose
config must resolve with it), prints which keys changed without printing any
values, and reports the deploy's outcome. For a private repo, set
`HOMELAB_REPO` to an SSH URL: bootstrap then prints a deploy key on the first
run and stops; add it under *Settings → Deploy keys* (read-only) and re-run.

`bootstrap.sh` is idempotent, and re-running it is how changes to it get
applied. It:

- installs Docker from Docker's apt repo, with log rotation and `live-restore`
- enables the memory cgroup and IPv4 forwarding
- enables OS auto-updates with reboots (see below)
- sets the hostname and the Pi's own DNS from `HOST_NAME` and `HOST_DNS`
- clones the repo to `/opt/homelab`, installs `.env`, and enables the timer

The Pi resolves through fixed upstreams rather than its own Pi-hole, so it can
still pull images and sync git while Pi-hole restarts. Containers that need
`*.BASE_DOMAIN` names reach them through Traefik network aliases, not host DNS.

While you get things working, set `ACME_CA_SERVER` to Let's Encrypt staging
and `ACME_STORAGE=acme-staging.json` (both in `.env.example`), then delete both
lines. Let's Encrypt rate-limits failed production attempts, and the separate
storage file means the switch to production gets a fresh, trusted cert.

### Single sign-on (once per site)

Passkeys are bound to the site's domain, so each site has its own Pocket ID
users.

1. Right after the first deploy, open `https://id.BASE_DOMAIN/setup` and
   register the admin passkey. Do this promptly: until someone does, anyone on
   the LAN could claim the admin account.
2. Create an `admins` group. Add users for yourself and your partner, and send
   them their one-time login link to enroll a passkey from their own password
   manager.
3. Create two OIDC clients. Both are **confidential** (not public): tinyauth
   and Grafana run server-side and hold a client secret. Restrict both to the
   `admins` group.

   | Client   | Callback URL                                           | PKCE | `.env` keys              |
   |----------|--------------------------------------------------------|------|--------------------------|
   | tinyauth | `https://auth.BASE_DOMAIN/api/oauth/callback/pocketid` | off  | `TINYAUTH_OIDC_CLIENT_*` |
   | grafana  | `https://grafana.BASE_DOMAIN/login/generic_oauth`      | on   | `GRAFANA_OIDC_CLIENT_*`  |

   Grafana is configured to send PKCE. tinyauth sends it too, so PKCE on its
   client should also work, but only "off" has been tested.
4. Copy each client's ID and secret (Pocket ID shows the secret once) into
   `hosts/<name>.env` and run `scripts/provision.sh <name>`. Members of
   `admins` get the Grafana Admin role; anyone else who logs in gets Viewer.

### Alerts on your phone

Install the ntfy app, add the server `https://ntfy.BASE_DOMAIN`, and subscribe
to `homelab-alerts`. Reading needs no credentials. Only Grafana's token can
publish, and the server is reachable only on the LAN or over Tailscale.

Alerts are evaluated on the same Pi they describe, so a host that's
completely down or offline can't page you. For that, add an external
dead-man's switch (e.g. healthchecks.io) if you want it.

### OS updates

Upgrades run daily at `OS_UPGRADE_TIME` (default 04:00, after the 03:30
backup). That covers Debian (including security and point-release updates),
the Raspberry Pi repo (kernel, firmware, bootloader) and Docker. When an update
needs a reboot, the Pi reboots at `OS_REBOOT_TIME` (default 04:30); set
`OS_AUTO_REBOOT=false` to do it by hand. A reboot means a minute or two
without DNS from that Pi. Docker engine upgrades don't stop containers
(`live-restore`).

"OS auto-update failed" and "Reboot pending" (more than 2 days) alerts cover
the failure cases. These are host-level settings applied by `bootstrap.sh`, which
`scripts/provision.sh` runs on every push.
Logs: `journalctl -u apt-daily-upgrade`.

### Tailscale

Accounts and keys are covered in [External setup](#external-setup). On the
host: set `TS_AUTHKEY`, set `TS_ROUTES` to the site's LAN, and enable the
`tailscale` profile. The key is only used for the first login; the node then
stays logged in through its state volume.

### Backups and restore

Nightly at 03:30 by default, to the site's R2 bucket (see [External
setup](#external-setup)); any restic repository works. Everything in the
Docker volumes is backed up except Prometheus/Loki data, Pi-hole's query
history and caches. To rebuild a dead
host: bootstrap it with the same `.env`, let the first deploy finish, then
`sudo /opt/homelab/scripts/restore.sh`. Pass volume names (e.g.
`pocket-id-data`) to restore only those.

SQLite databases are copied live. That's fine for these low-write apps, but
check what you restored. Running `restic check` occasionally is worthwhile.

### Migrating the existing Pi 4 Pi-hole

1. In the old Pi-hole: *Settings → Teleporter → Export*.
2. Free port 53: `sudo systemctl disable --now pihole-FTL` for a native
   install, or `docker compose down` in its directory for a container.
   Clients using that Pi for DNS lose resolution until the new Pi-hole is up.
3. Bootstrap the host as above, then import the Teleporter archive, either
   at `https://pihole.BASE_DOMAIN` or on the host:

   ```sh
   docker cp pi-hole_*_teleporter_*.zip homelab-pihole-1:/tmp/import.zip
   docker exec homelab-pihole-1 pihole-FTL --teleporter /tmp/import.zip
   docker restart homelab-pihole-1
   ```

   The restart matters. The import also restores the old settings, including
   the old web password, and `FTLCONF_*` values from git only take precedence
   again when Pi-hole starts. After that they show as read-only in the UI.

## Day to day

| Task | How |
|------|-----|
| Change a service | Edit `stacks/…`, open a PR, merge |
| Add a service | Add it to a stack (or a new `stacks/<x>/compose.yaml` listed in `compose.yaml`) with a `profiles:` entry, Traefik labels (`sso@docker` for admin UIs) and optionally `homelab.metrics.port` |
| Enable something on a host | Add its profile to that host's `COMPOSE_PROFILES` |
| Change host config | Edit `hosts/<name>.env`, then `scripts/provision.sh <name>` |
| Roll back | `git revert` and push |
| Deploy now | `scripts/provision.sh <name>`, or on the host `sudo /opt/homelab/scripts/sync.sh --force` |
| Validate locally | `scripts/validate.sh` (needs Docker) |
| Smoke-test the whole stack | `test/smoke.sh` on any Docker host with ports 80/443/1053 free (`--down` to remove) |

A secret needed only by one profile can't use `${VAR:?}` in compose, because
compose interpolates services whose profiles are off. Add it to
`required_by_profile` in `scripts/apply.sh` instead.


## Security notes

- **Rootful Docker, by choice.** Rootless Docker would break core pieces here.
  Pi-hole would lose real client IPs (all queries appear to come from one
  address) and needs port 53. Alloy needs real host /proc, cgroup and journal
  access. smartctl needs raw devices. `live-restore` isn't supported. The
  mitigations: no container except the proxy mounts the Docker socket; Traefik,
  Alloy and tinyauth get a read-only, GET-only API through `docker-proxy` on an
  internal network; most services run with `no-new-privileges`; and nothing
  listens on the internet.
- Only Alloy, Tailscale and smartctl-exporter run privileged or with host
  networking, because each needs host access.

## Layout

```
compose.yaml              project root: includes every stack, defines networks
.env.example              all host config, documented
hosts/<name>.env          each host's config (gitignored; source of truth)
stacks/traefik/           reverse proxy + ACME + read-only Docker API proxy
stacks/auth/              Pocket ID + tinyauth (SSO)
stacks/pihole/            profile: dns
stacks/observability/     profile: observability (prometheus, loki, grafana, alloy, ntfy)
stacks/tailscale/         profile: tailscale
stacks/backup/            profile: backup
stacks/unifi/             profile: unifi
stacks/smart/             profile: smart (locally built image)
scripts/provision.sh      push a host's env and deploy (runs bootstrap)
scripts/bootstrap.sh      idempotent host provisioning, on the host
scripts/sync.sh           git poll → apply (systemd timer)
scripts/apply.sh          docker compose converge
scripts/restore.sh        restore volumes from restic
scripts/gen-secrets.sh    generate per-site secrets
scripts/validate.sh       lint/verify (CI + local)
test/smoke.sh             end-to-end test on Docker Desktop (local.env, compose.local.yaml)
systemd/                  sync service + timer
```

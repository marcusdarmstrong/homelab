# homelab

Docker Compose config for my Raspberry Pis, deployed GitOps-style: push to
`main` and every host converges within about a minute.

| Host   | Hardware    | Site     | `COMPOSE_PROFILES`     |
|--------|-------------|----------|------------------------|
| luna   | Pi 4        | home     | `dns`                  |
| europa | Pi 5 + NVMe | basecamp | `sso,observability`    |

## How it works

The repo is one Compose project (`compose.yaml` includes `stacks/*/compose.yaml`).
Every host runs the same code. What runs where is a host's committed settings
(`hosts/<name>.env`, see [`hosts/README.md`](hosts/README.md)); its secrets
live only on the host. **Pis are cattle:** any of them can be rebuilt from
scratch, and any service can move to another host with a commit.

**Two layers.** Each site's LAN carries everything household: internet, every
device, DNS from that site's Pi-hole. The LANs never route to each other. The
**tailnet** joins the Pis to each other and to our own laptops and phones, and
carries everything admin: SSO, metrics, logs, admin pages. Nothing a
household device uses depends on the other site or on Tailscale.

| Profile         | Services                                    | Runs on              |
|-----------------|---------------------------------------------|----------------------|
| _(always)_      | Traefik, tinyauth, Tailscale, Alloy, DNS records, Docker API proxy | every host |
| `sso`           | Pocket ID, with its backups                 | exactly one host     |
| `observability` | Prometheus, Loki, Grafana (and its image renderer), ntfy | exactly one host |
| `dns`           | Pi-hole                                     | any number of hosts  |
| `unifi`         | UnPoller (that site's UniFi metrics)        | one host per site    |
| `smart`         | smartctl_exporter (NVMe/disk health)        | hosts with such a disk |

- **Names**: everything lives under one zone, `HOMELAB_DOMAIN`. Each host is
  `<host>.HOMELAB_DOMAIN` and its own pages sit under that
  (`pihole.luna.…`). Services that run once have a fixed name wherever they
  run (`id.…`, `grafana.…`, `ntfy.…`). Hosts keep these records current in
  Cloudflare themselves, pointing at their tailnet addresses (ntfy's at the
  site's public address), so a rebuilt Pi or a moved service fixes its own
  names. Nothing else knows which host runs what.
- **State**: most volumes are disposable; their contents come from git or
  config. A service with real state (Pocket ID) owns its backups: a sidecar
  snapshots it nightly, and a restore step fills an empty volume from the
  latest snapshot before the service starts. See [Backups and moving
  services](#backups-and-moving-services).
- **Deploys**: `scripts/sync.sh` runs every minute from a systemd timer. It
  hard-resets to `origin/main` and runs `scripts/apply.sh` whenever the commit
  or the host's `.env` differs from the last successful apply, after
  re-running `scripts/bootstrap.sh` if host-level settings changed. Services
  whose profile was turned off are stopped, after a final backup of anything
  they own. A failed apply retries on the next tick and raises the "Deploy
  failing" alert. Deploys are pull-based.
- **Image updates**: images are pinned to exact tags. Renovate opens a PR for
  each release once it's 14 days old, and merging the PR deploys it. Patch
  releases automerge once CI passes (see `renovate.json5`).
- **HTTPS**: each Traefik gets a Let's Encrypt cert for `*.BASE_DOMAIN` and
  `*.HOMELAB_DOMAIN` through the DNS-01 challenge, so nothing needs to be
  internet-exposed for it. Renewal is automatic, and an alert fires if it
  falls behind.
- **SSO, no passwords**: Pocket ID is a passkey-only OIDC provider, so
  1Password, Bitwarden, iCloud Keychain or a hardware key all work. Grafana
  logs in through it directly. Everything else (Traefik, Pi-hole, Prometheus,
  Alloy) sits behind tinyauth's `sso@docker` forward-auth middleware. No app
  has a password of its own.
- **Observability**: every host's Alloy collects host, container, Traefik and
  labelled service metrics, WAN probes, Docker logs and the systemd journal,
  and pushes them over the tailnet to the one Prometheus and Loki. Add
  metrics for any container with a `homelab.metrics.port` label.
- **Alerting**: Grafana alert rules (`provisioning/alerting/`) notify through
  ntfy, which phones reach from anywhere: hosts down, disk, memory,
  temperature, undervoltage, scrape targets, deploys, backups, cert expiry,
  WAN, SMART and OS updates. healthchecks.io notices if the monitoring host itself goes
  quiet.
- **OS updates**: unattended-upgrades applies everything from the Debian,
  Raspberry Pi and Docker repos daily, and reboots in a set window when a
  kernel or firmware update needs it.

## External setup

Everything outside the Pis, in the order you need it.

**Once**

1. **GitHub.** This repo. Once CI has run:
   - Protect `main` and require the `validate` check, since a merge deploys
     within a minute.
   - Install the [Renovate](https://github.com/apps/renovate) app on the repo
     for image-update PRs.
2. **Cloudflare DNS.** A zone holding `HOMELAB_DOMAIN`, and an API token with
   *Zone → DNS → Edit* on it → `CF_DNS_API_TOKEN`. The hosts create and
   update every record themselves.
   - Prefer a dedicated domain for the homelab. Cloudflare can't scope a token
     to a subdomain, so each Pi holds a token that can edit the whole zone. A
     cheap separate domain keeps your main domain's email and website out of
     reach.
   - Protect the Cloudflare account with a passkey or hardware key: it holds
     certificate issuance, the names and the backups (below).
3. **Tailscale.** One tailnet; the free plan is plenty.
   - Define the tag first (the OAuth client can't be created until you do).
     The Pis join as `tag:homelab` rather than as you, so their logins never
     expire and aren't tied to your account. In the admin console's *Access
     controls* page (the policy file), add inside the top-level `{ }`:

     ```jsonc
     "tagOwners": { "tag:homelab": ["autogroup:admin"] },
     ```

     The default rules let every device reach every other, which is all this
     needs. Only if you later replace them with stricter ones, keep the Pis
     reaching each other and your devices reaching their web pages:

     ```jsonc
     "grants": [
       { "src": ["tag:homelab"], "dst": ["tag:homelab"], "ip": ["*"] },
       { "src": ["autogroup:member"], "dst": ["tag:homelab"], "ip": ["tcp:443"] },
     ],
     ```
   - Then an OAuth client (*Settings → OAuth clients*, scope *Auth Keys:
     write*, tag `tag:homelab`). Use the secret as
     `TS_AUTHKEY=tskey-client-…?ephemeral=false&preauthorized=true`. Without
     `ephemeral=false`, OAuth-issued nodes vanish from the tailnet whenever
     the Pi goes offline.
   - Install Tailscale on your laptops and phones and invite your partner to
     the tailnet. Admin pages are only reachable from it.
   - Optionally **Tailnet Lock**, so Tailscale's servers can't add nodes. A
     rebuilt Pi then needs signing by a trusted device, unless its auth key
     is pre-signed; check that pre-signing works with the OAuth client before
     relying on unattended rebuilds.
4. **Cloudflare R2**, for backups: a bucket per service with state (today
   `homelab-pocket-id`), and an R2 API token with *Object Read & Write* on
   them → `RESTIC_S3_ACCESS_KEY_ID` / `RESTIC_S3_SECRET_ACCESS_KEY`, with
   `RESTIC_REPOSITORY_PREFIX=s3:https://<account-id>.r2.cloudflarestorage.com/homelab-`.
   R2 has no egress fees (restores are free), and these backups fit easily in
   the free tier.
5. **healthchecks.io** (optional): a check with a 5-minute period →
   `HEALTHCHECKS_URL`. Alerts come from the monitoring host, so only an
   outside check can notice when it's down or offline.
6. **Password manager.** Store `hosts/secrets.env` (and any
   `hosts/<name>.secrets.env`), above all `RESTIC_PASSWORD` and
   `POCKET_ID_ENCRYPTION_KEY`, plus the ntfy phone password from
   `scripts/gen-secrets.sh`. They're the one part of the system that isn't in
   git, and a restore is impossible or useless without them.

**Per site**, on its UniFi console:

7. A DHCP reservation for each Pi.
8. Networks: the Pi-hole SSID (and the wired network) hands out the site's
   Pi-hole as its only DNS server; a second SSID hands out an unfiltered one,
   for when Pi-hole is down or blocking something it shouldn't; IoT devices
   get their own network.
9. A port forward: TCP 443 on the WAN → port 8443 on the Pi that runs, or
   would take over, `observability`. Traefik serves nothing but ntfy there.
   Make sure NAT hairpinning works, so `ntfy.…` also resolves to something
   reachable from inside the LAN.
10. For the `unifi` profile, a local API key (*Settings → Control Plane →
    Integrations*) → `UNIFI_API_KEY` in that host's `hosts/<name>.secrets.env`,
    and `UNIFI_URL` in its settings.

**After the hosts are up**

11. **ntfy app** on each phone (see [Alerts on your phone](#alerts-on-your-phone)).

Let's Encrypt needs no setup; Traefik registers automatically.

## Setting up a host

1. Flash 64-bit Raspberry Pi OS Lite onto an SD card with Raspberry Pi
   Imager, with your user and SSH key, and boot from it. Do this even on a
   Pi with an NVMe drive: with `HOST_STORAGE=ssd`, `provision.sh` installs
   onto the NVMe itself, and asks first if the drive isn't blank. Make sure
   you can `ssh` to it (by default as `<name>.local`; set `HOST_SSH`
   otherwise).
2. Write `hosts/<name>.env` ([settings](hosts/README.md)), then commit and
   push it: the host reads its settings from git, and CI checks them.
3. The first time only: create `hosts/secrets.env` from
   [`hosts/secrets.env.example`](hosts/secrets.env.example), using
   `scripts/gen-secrets.sh` for the generated values. Leave the OIDC client
   fields empty for now.
4. Run `scripts/provision.sh <name>`, once per image. It copies
   `bootstrap.sh` over, which installs Docker, clones this repo over HTTPS,
   installs the host's `.env` and enables the deploy timer; then it runs the
   first deploy and shows the result. sudo may ask for your password. The
   Pi then reboots once, to turn on the memory cgroup.
5. If this is the first `sso` host, set up SSO (below) right away.

Both `provision.sh` and `push-env.sh` refuse to run unless `hosts/<name>.env`
matches what's pushed, check the result resolves (no placeholders, valid
compose config) and report the deploy's outcome. `push-env.sh` also prints
which keys changed, without printing any values. `provision.sh` refuses a
host that's already provisioned; after a re-image it runs again.

`bootstrap.sh` is idempotent. Every deploy re-runs it when it, `lib.sh`,
`systemd/`, `config/sdcard.env`, the host's settings or its `.env` changed
since its last successful run, so a commit that changes host-level settings
reaches every host like any other. It:

- installs Docker from Docker's apt repo, with log rotation and `live-restore`
- enables the memory cgroup and zram-only swap
- sets a PoE HAT's fan curve from `POE_FAN_TEMPS` and `POE_FAN_HYST`
- enables OS auto-updates with reboots (see below)
- sets the hostname and the Pi's own DNS from `HOST_NAME` and `HOST_DNS`
- clones the repo to `/opt/homelab`, installs `.env`, and enables the timer

When something it changed only takes effect on a reboot (the kernel command
line, firmware settings, swap), the Pi reboots as soon as that deploy
succeeds, and `bootstrap.sh` runs again afterwards. If the reboot didn't
help, it doesn't reboot again for the same reasons and settings, and the
"Reboot pending" alert fires after two days. `OS_AUTO_REBOOT=false` leaves
these reboots to you too.

The Pi resolves through fixed upstreams rather than its own Pi-hole, so it can
still pull images and sync git while Pi-hole restarts, and its containers
reach other hosts' services by their public names.

While you get things working, set `ACME_CA_SERVER` to Let's Encrypt staging
and `ACME_STORAGE=acme-staging.json` ([settings](hosts/README.md)), then delete
both lines. Let's Encrypt rate-limits failed production attempts, and the
separate storage file means the switch to production gets a fresh, trusted
cert.

### Single sign-on (once)

Pocket ID runs on the host with the `sso` profile, at
`https://id.HOMELAB_DOMAIN` wherever that is, so passkeys survive it moving.
Every host's tinyauth and Grafana log in through it. If it's down, existing
sessions keep working but new logins fail. Nothing else depends on it.

1. Right after the sso host's first deploy, open
   `https://id.HOMELAB_DOMAIN/setup` and register the admin passkey. Do this
   promptly: until someone does, anyone on the tailnet could claim the admin
   account.
2. Create an `admins` group and add yourself and your partner. The group page
   lists every user with a checkbox; only checked users are members. Send your
   partner their one-time login link to enroll a passkey from their own
   password manager. Without membership, logins fail with "You are not allowed
   to access this service."
3. Create two OIDC clients. Both are **confidential** (not public): tinyauth
   and Grafana run server-side and hold a client secret. Restrict both to the
   `admins` group.

   | Client   | Callback URL                                                | PKCE | Secrets                  |
   |----------|-------------------------------------------------------------|------|--------------------------|
   | tinyauth | `https://auth.*.HOMELAB_DOMAIN/api/oauth/callback/pocketid` | off  | `TINYAUTH_OIDC_CLIENT_*` |
   | grafana  | `https://grafana.HOMELAB_DOMAIN/login/generic_oauth`        | on   | `GRAFANA_OIDC_CLIENT_*`  |

   Pocket ID's `*` matches one hostname label, so the one tinyauth client
   serves every host.

   Grafana is configured to send PKCE. tinyauth sends it too, so PKCE on its
   client should also work, but only "off" has been tested.
4. Copy each client's ID and secret (Pocket ID shows the secret once) into
   `hosts/secrets.env` and run `scripts/push-env.sh <name>` for every host.
   Members of `admins` get the Grafana Admin role; anyone else who logs in
   gets Viewer.

### Alerts on your phone

Install the ntfy app, add the server `https://ntfy.HOMELAB_DOMAIN`, log in as
`phone` with the password from `scripts/gen-secrets.sh`, and subscribe to
`homelab-alerts`. It works from anywhere, without Tailscale: ntfy's name
points at the site's public address, and the site's port forward reaches a
Traefik entrypoint that serves nothing else. Nothing is readable without
logging in, and only Grafana's token can publish.

### OS updates

Upgrades run daily at `OS_UPGRADE_TIME` (default 04:00, after the 03:30
backups). That covers Debian (including security and point-release updates),
the Raspberry Pi repo (kernel, firmware, bootloader) and Docker. When an update
needs a reboot, the Pi reboots at `OS_REBOOT_TIME` (default 04:30); set
`OS_AUTO_REBOOT=false` to do it by hand. A reboot means a minute or two
without DNS from that Pi. Docker engine upgrades don't stop containers
(`live-restore`).

"OS auto-update failed" and "Reboot pending" (more than 2 days) alerts cover
the failure cases. These are host-level settings applied by `bootstrap.sh`,
which re-runs on the next deploy whenever they change.
Logs: `journalctl -u apt-daily-upgrade`.

### SD-card hosts

SD cards wear out with writes, so the stack keeps them low everywhere, and a
host whose settings declare `HOST_STORAGE=sdcard` also gets
[`config/sdcard.env`](config/sdcard.env), which trades a little durability
for far fewer writes. On an idle Pi 4 running `dns,observability`, the
defaults once wrote about **5.8 GB/day**, mostly Grafana's SQLite database,
Loki's and Alloy's write-ahead logs, Docker API access logs, and the ext4
journal commits all of those cause. Keeping `observability` on the NVMe host
avoids most of that.

Always on, since they only remove waste:

- zram-only swap (`bootstrap.sh`): Raspberry Pi OS otherwise writes idle
  swap pages to a 2 GB `/var/swap` file daily
- Alloy's write-ahead buffer and Pi-hole's log files in RAM (`tmpfs`)
- Grafana's SQLite in WAL mode, with dashboard rescans hourly instead of
  every minute (deploys recreate Grafana when dashboards change anyway)
- Alloy forwards only the metrics an alert or dashboard uses (an allowlist
  in `config.alloy`; add to it before charting something new), which cuts
  Prometheus to a few hundred series per host
- the Docker API proxy logs warnings only, instead of every call

`config/sdcard.env` sends Docker's copy of container logs to the
RAM-backed journal, turns off Loki's write-ahead log, and makes Pi-hole and
Grafana save their state every few minutes instead of every minute. Each
setting is explained in the file; a host's own settings override it.

Raspberry Pi OS already mounts `/` with `noatime`, keeps `/tmp` in RAM and
the journal volatile. The "SD card write rate high" alert fires if a card
averages over 2 GB/day for six hours. The dashboard's Disk section shows
each disk's writes per day and which containers they come from.
NVMe drives aren't held to that: a few GB a day is nothing against their
rated endurance, so the `smart` profile watches their wear instead ("Disk
wearing out").

### Tailscale

Every host joins the tailnet on its first deploy with `TS_AUTHKEY`, as
`HOST_NAME` tagged `tag:homelab`, and stays logged in through its state
volume. There are no subnet routes and no connection logs go to Tailscale.
Its `100.x` address is published as `BASE_DOMAIN`, so those addresses are in
public DNS; they lead nowhere outside the tailnet. If a name doesn't resolve
on one of our networks, check that resolver isn't dropping public answers in
`100.64.0.0/10` (DNS rebind protection).

If Tailscale's coordination servers are down, existing connections keep
working; households never notice.

### Pi-hole lists

Blocklists and allowed domains are in git
([`stacks/pihole/lists/`](stacks/pihole/lists)) and every Pi-hole applies them
on each deploy and hourly; changes to them in the web UI are undone. Anything
else changed in the UI (groups, clients) lives only in that Pi-hole's volume.

### Backups and moving services

Pocket ID is the only service whose data can't be recreated, so it's the only
one backed up: nightly at 03:30 by default (`BACKUP_CRON`), to its own R2
bucket, keeping 7 daily, 5 weekly and 12 monthly snapshots. Its SQLite
database is copied live; it writes rarely, but check what you restore.
Running `restic check` occasionally is worthwhile.

Before Pocket ID starts, `pocket-id-restore` looks at its volume. If it's
empty, it restores the latest snapshot, whichever host took it. It starts
fresh only when the repository answers that it has no snapshot; if the
repository can't be reached, Pocket ID doesn't start, so an outage can't turn
into an empty Pocket ID backing itself up as the latest snapshot.

Moving a service is a change of profiles:

- **Planned:** two commits. First take the profile off the old host: it stops
  the service, takes a final backup and removes it. Then add it to the new
  host: it restores into an empty volume and claims the service's names.
  Nothing is lost, and it never runs in two places.
- **Host dead:** one commit adding the profile to another host. It restores
  the last nightly backup. If the dead host was running Pocket ID within a
  few minutes of that backup, the new one refuses to start until the old
  one's lock in the database expires; the next sync tries again.

`observability` moves the same way, but its metrics and logs are history and
start over on the new host.

## Day to day

| Task | How |
|------|-----|
| Change a service | Edit `stacks/…`, open a PR, merge |
| Add a service | Add it to a stack (or a new `stacks/<x>/compose.yaml` listed in `compose.yaml`) with a `profiles:` entry, Traefik labels (`sso@docker` for admin pages) and optionally `homelab.metrics.port` |
| Enable something on a host | Add its profile to `COMPOSE_PROFILES` in `hosts/<name>.env`, open a PR, merge |
| Move a service | See [Backups and moving services](#backups-and-moving-services) |
| Change a host setting | Edit `hosts/<name>.env` or `hosts/common.env`, open a PR, merge |
| Change a secret | Edit `hosts/secrets.env`, then `scripts/push-env.sh <name>` for each host |
| Block or allow something | Edit `stacks/pihole/lists/`, open a PR, merge |
| Roll back | `git revert` and push |
| Deploy now | On the host, `sudo /opt/homelab/scripts/sync.sh --force` (otherwise within a minute) |
| Validate locally | `scripts/validate.sh` (needs Docker) |
| Smoke-test the whole stack | `test/smoke.sh` on any Docker host with ports 80/443/8443/1053 free (`--down` to remove) |

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
  internal network; most services run with `no-new-privileges`.
- **The only thing reachable from the internet is ntfy**, on its own Traefik
  entrypoint, with every topic behind a login. Admin pages are reached by name
  over the tailnet, and the endpoints only other hosts use (Prometheus remote
  write, Loki push) refuse anything that isn't from the tailnet.
- **The Pis are one trust domain.** Every host holds the secrets of every
  movable service, including the backup credentials, so a compromised Pi can
  reach any service's backups. Acceptable with one owner and two Pis.
- Only Alloy, Tailscale, the DNS-record updaters and smartctl-exporter run
  privileged or with host networking, because each needs host access.

## Layout

```
compose.yaml              project root: includes every stack, defines networks
hosts/README.md           every host setting, documented
hosts/common.env          settings every host shares
hosts/<name>.env          each host's settings (committed)
hosts/secrets.env.example every secret, documented (yours: hosts/secrets.env, gitignored)
config/sdcard.env         write-saving settings for SD-card hosts
stacks/traefik/           reverse proxy + ACME + Docker API proxy + this host's DNS records
stacks/tailscale/         tailnet membership
stacks/alloy/             metrics and logs from this host
stacks/auth/              Pocket ID (profile: sso) with backup and restore, tinyauth
stacks/pihole/            profile: dns, with lists from git
stacks/observability/     profile: observability (prometheus, loki, grafana, ntfy)
stacks/unifi/             profile: unifi
stacks/smart/             profile: smart (locally built image)
scripts/provision.sh      set up a freshly imaged host (runs bootstrap)
scripts/push-env.sh       push a host's secrets and deploy
scripts/bootstrap.sh      idempotent host provisioning, on the host
scripts/sync.sh           git poll → apply (systemd timer)
scripts/apply.sh          docker compose converge
scripts/gen-secrets.sh    generate secrets
scripts/validate.sh       lint/verify (CI + local)
test/smoke.sh             end-to-end test on Docker Desktop (local.env, compose.local.yaml)
systemd/                  sync service + timer
```

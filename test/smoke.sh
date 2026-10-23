#!/usr/bin/env bash
# End-to-end smoke test of the whole stack on Docker Desktop (or any Docker
# host with ports 80/443/8443/1053 free). Deploys through scripts/apply.sh
# with test/local.env and test/compose.local.yaml, then checks routing, SSO
# redirects, metrics and logs pushed through Traefik, alerting, backups and
# restores, DNS and profile teardown.
#
#   test/smoke.sh          deploy (or update) and run every check
#   test/smoke.sh --down   remove the test stack, including its volumes
#
# Can't cover: real certificates, the passkey ceremony, Tailscale, the
# Cloudflare records, the public port forward, journald, SMART data, a real
# UniFi controller, bootstrap.sh and sync.sh. Those need a Pi.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

oidc_env=test/.local-oidc.env
touch "$oidc_env"
export COMPOSE_FILE=compose.yaml:test/compose.local.yaml
export COMPOSE_ENV_FILES="test/local.env,$oidc_env"

if [[ "${1:-}" == "--down" ]]; then
  COMPOSE_PROFILES='*' docker compose down --volumes --remove-orphans
  rm -f "$oidc_env"
  exit 0
fi

env_value() { sed -n "s/^$1=//p" test/local.env; }
Z="$(env_value HOMELAB_DOMAIN)" # services that run once
H="$(env_value BASE_DOMAIN)"    # this host's own pages
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15'
API_KEY="$(env_value POCKET_ID_STATIC_API_KEY)"
NTFY_TOKEN="$(env_value NTFY_GRAFANA_TOKEN)"
PHONE=phone:local-phone-password

failures=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
check() { # check DESCRIPTION COMMAND...: pass if the command succeeds
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# https NAME [curl args...]: GET https://NAME$PATH_ through the local Traefik,
# on PORT_ (default 443).
https() { local name="$1"; shift; curl -sk --resolve "$name:${PORT_:-443}:127.0.0.1" "$@" "https://$name:${PORT_:-443}${PATH_:-/}"; }
status_and_location() { https "$1" -o /dev/null -A "$UA" -w '%{http_code} %{redirect_url}'; }
status() { https "$1" -o /dev/null -w '%{http_code}' "${@:2}"; }
pocket_id() { local path="$1"; shift; PATH_="$path" https "id.$Z" -H "X-API-KEY: $API_KEY" -H 'Content-Type: application/json' "$@"; }
grafana() { local path="$1"; shift; PATH_="$path" https "grafana.$Z" -u admin:local -H 'Content-Type: application/json' "$@"; }
promql() { docker compose exec -T prometheus wget -qO- "http://localhost:9090/api/v1/query?query=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")"; }
json() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }
wait_for() { # wait_for SECONDS COMMAND...
  local deadline=$((SECONDS + $1)); shift
  until "$@" >/dev/null 2>&1; do ((SECONDS < deadline)) || return 1; sleep 3; done
}
latest_snapshot() { # ID of the latest snapshot in Pocket ID's local repository
  docker run --rm -v homelab_local-restic:/restic -e RESTIC_PASSWORD="$(env_value RESTIC_PASSWORD)" \
    --entrypoint restic "$(grep -oE 'mazzolino/restic:\S+' stacks/auth/compose.yaml | head -1)" \
    -r /restic/pocket-id snapshots --latest 1 --json | json 'd[-1]["id"] if d else ""'
}
apply() { HOMELAB_SETTLE_SECONDS="${SETTLE:-15}" scripts/apply.sh 2>&1 | grep '\[homelab\]' | grep -v 'warning:' || true; }

section "Deploy"
apply
check "apply.sh converged" docker compose ps --status running -q traefik

section "SSO clients"
# Pocket ID's database lives in a volume; recreate the clients if it's new.
client_exists() { [[ -s "$oidc_env" ]] && pocket_id "/api/oidc/clients/$(sed -n 's/^TINYAUTH_OIDC_CLIENT_ID=//p' "$oidc_env")" -o /dev/null -w '%{http_code}' | grep -q 200; }
wait_for 60 pocket_id /api/oidc/clients -f
if client_exists; then
  pass "OIDC clients already registered"
else
  create_client() { # create_client NAME CALLBACK PKCE -> "id secret"
    local id
    id="$(pocket_id /api/oidc/clients -X POST -d "{\"name\":\"$1\",\"callbackURLs\":[\"$2\"],\"isPublic\":false,\"pkceEnabled\":$3}" | json 'd["id"]')"
    echo "$id $(pocket_id "/api/oidc/clients/$id/secrets" -X POST -d '{}' | json 'd["secret"]')"
  }
  read -r tid tsecret < <(create_client tinyauth "https://auth.*.$Z/api/oauth/callback/pocketid" false)
  read -r gid gsecret < <(create_client grafana "https://grafana.$Z/login/generic_oauth" true)
  printf 'TINYAUTH_OIDC_CLIENT_ID=%s\nTINYAUTH_OIDC_CLIENT_SECRET=%s\nGRAFANA_OIDC_CLIENT_ID=%s\nGRAFANA_OIDC_CLIENT_SECRET=%s\n' \
    "$tid" "$tsecret" "$gid" "$gsecret" >"$oidc_env"
  apply
  pass "OIDC clients created and deployed"
fi

section "Routing and SSO"
for name in "id.$Z" "ntfy.$Z" "auth.$H"; do
  check "$name serves directly" test "$(status_and_location "$name" | cut -d' ' -f1)" = 200
done
for name in "traefik.$H" "pihole.$H" "prometheus.$H" "alloy.$H"; do
  check "$name redirects to tinyauth" grep -q "^302 https://auth.$H/login" <<<"$(status_and_location "$name")"
done
check "tinyauth hands off to Pocket ID" grep -q "https://id.$Z/authorize" \
  <<<"$(PATH_="/api/oauth/url/pocketid?redirect_uri=https%3A%2F%2Fpihole.$H%2F" https "auth.$H" -A "$UA")"
check "Grafana login goes to Pocket ID (PKCE)" grep -q "^302 https://id.$Z/authorize.*code_challenge" \
  <<<"$(PATH_=/login/generic_oauth status_and_location "grafana.$Z")"
check "Grafana reaches Pocket ID server-side" docker compose exec -T grafana wget -qO- --no-check-certificate "https://id.$Z/.well-known/openid-configuration"
check "HTTP redirects to HTTPS" test "$(curl -s -o /dev/null --resolve "grafana.$Z:80:127.0.0.1" -w '%{http_code}' "http://grafana.$Z/")" = 301
check "public entrypoint serves ntfy" test "$(PORT_=8443 status "ntfy.$Z")" = 200
check "public entrypoint serves nothing else" test "$(PORT_=8443 status "grafana.$Z")" = 404

section "Metrics and logs (pushed through Traefik)"
expected_jobs="alloy cadvisor grafana loki node ntfy pocket-id prometheus smartctl-exporter traefik unpoller wan"
jobs_up() { [[ "$(promql 'count by (job) (up == 1)' | json '" ".join(sorted(r["metric"]["job"] for r in d["data"]["result"]))')" == *"$expected_jobs"* ]]; }
if wait_for 120 jobs_up; then pass "scrape jobs up: $expected_jobs"; else
  fail "scrape jobs up (have: $(promql 'count by (job) (up == 1)' | json '" ".join(sorted(r["metric"]["job"] for r in d["data"]["result"]))'))"
fi
check "WAN probes distinguishable" test "$(promql 'count(probe_success{job="wan",probe!=""})' | json 'd["data"]["result"][0]["value"][1]')" = 3
check "series carry host/site labels" test "$(promql 'count(up{host="local",site="local"})' | json 'd["data"]["result"][0]["value"][1]')" -gt 0
# Services that log steadily; quieter ones may have said everything before
# Traefik routed Loki's push API, and Alloy drops what's refused.
logs_present() { [[ "$(docker compose exec -T prometheus wget -qO- http://loki:3100/loki/api/v1/label/service/values | json '" ".join(d.get("data") or [])')" == *grafana*traefik* ]]; }
check "Loki receiving container logs" wait_for 60 logs_present
check "only the write API is at prometheus.$Z" test "$(PATH_=/graph status "prometheus.$Z")" = 404

section "Grafana"
for uid in prometheus loki; do
  check "datasource $uid healthy" test "$(grafana "/api/datasources/uid/$uid/health" | json 'd["status"]')" = OK
done
check "overview dashboard provisioned" test "$(grafana '/api/search?type=dash-db' | json 'len(d)')" -ge 1
rules_ok() { [[ "$(grafana /api/prometheus/grafana/api/v1/rules | json 'sum(r["health"]=="ok" for g in d["data"]["groups"] for r in g["rules"])')" -ge 15 ]]; }
check "15 alert rules evaluating" wait_for 120 rules_ok
# Annotation templates are only rendered at evaluation time, so a broken one
# shows up in the logs rather than in rule health.
check "alert templates render" test "$(docker compose logs grafana --since 2m 2>&1 | grep -c 'Error in expanding template')" = 0

section "Alerting (ntfy)"
receiver="$(grafana /apis/notifications.alerting.grafana.app/v1beta1/namespaces/default/receivers | json '[i["metadata"]["name"] for i in d["items"] if i["spec"]["title"]=="ntfy"][0]')"
test_body='{"integration":{"uid":"ntfy","type":"webhook","settings":{"url":"http://ntfy/homelab-alerts?template=grafana","httpMethod":"POST","authorization_scheme":"Bearer"},"secureFields":{"authorization_credentials":true}}}'
check "Grafana delivers a test alert" test "$(grafana "/apis/notifications.alerting.grafana.app/v1beta1/namespaces/default/receivers/$receiver/test" -X POST -d "$test_body" | json 'd["status"]')" = success
check "phone reads it, formatted by template" grep -q 'TestAlert' <<<"$(PATH_='/homelab-alerts/json?poll=1&since=2m' https "ntfy.$Z" -u "$PHONE")"
check "phone reads it on the public entrypoint" grep -q 'TestAlert' <<<"$(PORT_=8443 PATH_='/homelab-alerts/json?poll=1&since=2m' https "ntfy.$Z" -u "$PHONE")"
check "anonymous read refused" test "$(PATH_='/homelab-alerts/json?poll=1' status "ntfy.$Z")" = 403
check "anonymous publish refused" test "$(PATH_=/homelab-alerts status "ntfy.$Z" -d x)" = 403
check "phone can't publish" test "$(PATH_=/homelab-alerts status "ntfy.$Z" -u "$PHONE" -d x)" = 403
check "Grafana token can't publish elsewhere" test "$(PATH_=/other status "ntfy.$Z" -H "Authorization: Bearer $NTFY_TOKEN" -d x)" = 403

section "Pocket ID backups"
check "backup run succeeds" grep -q 'Backup successful' <<<"$(docker compose exec -T pocket-id-backup backup 2>&1)"
backup_metric() { [[ "$(promql 'count(homelab_backup_last_success_timestamp_seconds{service="pocket-id"})' | json 'len(d["data"]["result"])')" -ge 1 ]]; }
check "backup success metric in Prometheus" wait_for 90 backup_metric

section "DNS (Pi-hole, TCP on 1053)"
dns() { dig +short +tcp +time=3 @127.0.0.1 -p 1053 "$1" A | tail -1; }
check "upstream lookups work" grep -qE '^[0-9.]+$' <<<"$(dns github.com)"
check "ad domains blocked" test "$(dns doubleclick.net)" = 0.0.0.0
check "lists synced from git on deploy" grep -q 'lists in sync' <<<"$(docker compose logs pihole-lists 2>&1)"
docker compose exec -T pihole curl -fsS -X POST 'http://localhost/api/lists?type=block' \
  -H 'Content-Type: application/json' -d '{"address":"https://example.invalid/extra.txt"}' >/dev/null
check "list added in the web UI is removed" grep -q 'removed https://example.invalid/extra.txt' \
  <<<"$(docker compose exec -T pihole-lists /lists/sync.sh 2>&1)"

section "Moving Pocket ID (profile off, then on with an empty volume)"
before="$(latest_snapshot)"
COMPOSE_PROFILES=dns SETTLE=5 apply >/dev/null
check "final backup taken when sso is taken off" test "$(latest_snapshot)" != "$before"
check "disabled profiles stopped" test -z "$(docker compose ps -q grafana pocket-id pocket-id-backup 2>/dev/null)"
check "always-on and dns services kept" test "$(docker compose ps --status running --format '{{.Service}}' | sort | tr '\n' ' ')" = "alloy docker-proxy pihole pihole-lists tinyauth traefik "
# The host it moves to has no volume yet.
docker compose rm --force pocket-id-restore >/dev/null 2>&1
docker volume rm homelab_pocket-id-data >/dev/null
apply >/dev/null
check "re-enabled profiles back up" docker compose ps --status running -q grafana pocket-id
check "empty volume restored from the final backup" grep -q 'restored /data/pocket-id' <<<"$(docker compose logs pocket-id-restore 2>&1)"
check "OIDC clients survive the move" wait_for 60 client_exists

echo
if ((failures)); then
  printf '\033[31m%d check(s) failed\033[0m\n' "$failures"
  exit 1
fi
printf '\033[32mall checks passed\033[0m (stack left running; test/smoke.sh --down removes it)\n'

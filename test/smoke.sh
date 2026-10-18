#!/usr/bin/env bash
# End-to-end smoke test of the whole stack on Docker Desktop (or any Docker
# host with ports 80/443/1053 free). Deploys through scripts/apply.sh with
# test/local.env and test/compose.local.yaml, then checks routing, SSO
# redirects, metrics, logs, alerting, backups, DNS and profile teardown.
#
#   test/smoke.sh          deploy (or update) and run every check
#   test/smoke.sh --down   remove the test stack, including its volumes
#
# Can't cover: real certificates, the passkey ceremony, Tailscale, journald,
# SMART data, a real UniFi controller, bootstrap.sh and sync.sh. Those need
# a Pi.
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

D=home.lab.test
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15'
API_KEY="$(sed -n 's/^POCKET_ID_STATIC_API_KEY=//p' test/local.env)"
NTFY_TOKEN="$(sed -n 's/^NTFY_GRAFANA_TOKEN=//p' test/local.env)"

failures=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failures=$((failures + 1)); }
check() { # check DESCRIPTION COMMAND...: pass if the command succeeds
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

https() { local host="$1"; shift; curl -sk --resolve "$host.$D:443:127.0.0.1" "$@" "https://$host.$D${PATH_:-/}"; }
status_and_location() { https "$1" -o /dev/null -A "$UA" -w '%{http_code} %{redirect_url}'; }
pocket_id() { local path="$1"; shift; PATH_="$path" https id -H "X-API-KEY: $API_KEY" -H 'Content-Type: application/json' "$@"; }
grafana() { local path="$1"; shift; PATH_="$path" https grafana -u admin:local -H 'Content-Type: application/json' "$@"; }
promql() { docker compose exec -T prometheus wget -qO- "http://localhost:9090/api/v1/query?query=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")"; }
json() { python3 -c "import sys,json; d=json.load(sys.stdin); print($1)"; }
wait_for() { # wait_for SECONDS COMMAND...
  local deadline=$((SECONDS + $1)); shift
  until "$@" >/dev/null 2>&1; do ((SECONDS < deadline)) || return 1; sleep 3; done
}

section "Deploy"
HOMELAB_SETTLE_SECONDS=15 scripts/apply.sh 2>&1 | grep '\[homelab\]' | grep -v 'warning:' || true
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
  read -r tid tsecret < <(create_client tinyauth "https://auth.$D/api/oauth/callback/pocketid" false)
  read -r gid gsecret < <(create_client grafana "https://grafana.$D/login/generic_oauth" true)
  printf 'TINYAUTH_OIDC_CLIENT_ID=%s\nTINYAUTH_OIDC_CLIENT_SECRET=%s\nGRAFANA_OIDC_CLIENT_ID=%s\nGRAFANA_OIDC_CLIENT_SECRET=%s\n' \
    "$tid" "$tsecret" "$gid" "$gsecret" >"$oidc_env"
  HOMELAB_SETTLE_SECONDS=15 scripts/apply.sh 2>&1 | grep '\[homelab\]' || true
  pass "OIDC clients created and deployed"
fi

section "Routing and SSO"
for host in id auth ntfy; do
  check "$host.$D serves directly" test "$(status_and_location $host | cut -d' ' -f1)" = 200
done
for host in traefik pihole prometheus alloy; do
  check "$host.$D redirects to tinyauth" grep -q "^302 https://auth.$D/login" <<<"$(status_and_location $host)"
done
check "tinyauth hands off to Pocket ID" grep -q "https://id.$D/authorize" \
  <<<"$(PATH_="/api/oauth/url/pocketid?redirect_uri=https%3A%2F%2Fpihole.$D%2F" https auth -A "$UA")"
check "Grafana login goes to Pocket ID (PKCE)" grep -q "^302 https://id.$D/authorize.*code_challenge" \
  <<<"$(PATH_=/login/generic_oauth status_and_location grafana)"
check "HTTP redirects to HTTPS" test "$(curl -s -o /dev/null --resolve grafana.$D:80:127.0.0.1 -w '%{http_code}' http://grafana.$D/)" = 301

section "Metrics and logs"
expected_jobs="alloy cadvisor grafana loki node ntfy pocket-id prometheus smartctl-exporter traefik unpoller wan"
jobs_up() { [[ "$(promql 'count by (job) (up == 1)' | json '" ".join(sorted(r["metric"]["job"] for r in d["data"]["result"]))')" == *"$expected_jobs"* ]]; }
if wait_for 120 jobs_up; then pass "scrape jobs up: $expected_jobs"; else
  fail "scrape jobs up (have: $(promql 'count by (job) (up == 1)' | json '" ".join(sorted(r["metric"]["job"] for r in d["data"]["result"]))'))"
fi
check "WAN probes distinguishable" test "$(promql 'count(probe_success{job="wan",probe!=""})' | json 'd["data"]["result"][0]["value"][1]')" = 3
check "series carry host/site labels" test "$(promql 'count(up{host="local",site="local"})' | json 'd["data"]["result"][0]["value"][1]')" -gt 0
logs_present() { [[ "$(docker compose exec -T prometheus wget -qO- http://loki:3100/loki/api/v1/label/service/values | json 'len(d.get("data") or [])')" -ge 10 ]]; }
check "Loki receiving container logs" wait_for 60 logs_present

section "Grafana"
for uid in prometheus loki; do
  check "datasource $uid healthy" test "$(grafana "/api/datasources/uid/$uid/health" | json 'd["status"]')" = OK
done
check "overview dashboard provisioned" test "$(grafana '/api/search?type=dash-db' | json 'len(d)')" -ge 1
rules_ok() { [[ "$(grafana /api/prometheus/grafana/api/v1/rules | json 'sum(r["health"]=="ok" for g in d["data"]["groups"] for r in g["rules"])')" -ge 12 ]]; }
check "12 alert rules evaluating" wait_for 120 rules_ok
# Annotation templates are only rendered at evaluation time, so a broken one
# shows up in the logs rather than in rule health.
check "alert templates render" test "$(docker compose logs grafana --since 2m 2>&1 | grep -c 'Error in expanding template')" = 0

section "Alerting (ntfy)"
receiver="$(grafana /apis/notifications.alerting.grafana.app/v1beta1/namespaces/default/receivers | json '[i["metadata"]["name"] for i in d["items"] if i["spec"]["title"]=="ntfy"][0]')"
test_body='{"integration":{"uid":"ntfy","type":"webhook","settings":{"url":"http://ntfy/homelab-alerts?template=grafana","httpMethod":"POST","authorization_scheme":"Bearer"},"secureFields":{"authorization_credentials":true}}}'
check "Grafana delivers a test alert" test "$(grafana "/apis/notifications.alerting.grafana.app/v1beta1/namespaces/default/receivers/$receiver/test" -X POST -d "$test_body" | json 'd["status"]')" = success
check "alert readable anonymously, formatted by template" grep -q 'TestAlert' <<<"$(PATH_='/homelab-alerts/json?poll=1&since=2m' https ntfy)"
check "anonymous publish refused" test "$(PATH_=/homelab-alerts https ntfy -o /dev/null -w '%{http_code}' -d x)" = 403
check "Grafana token can't publish elsewhere" test "$(PATH_=/other https ntfy -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $NTFY_TOKEN" -d x)" = 403

section "Backups"
check "backup run succeeds" grep -q 'Backup successful' <<<"$(docker compose exec -T backup backup 2>&1)"
backup_metric() { [[ "$(promql 'count(homelab_backup_last_success_timestamp_seconds)' | json 'len(d["data"]["result"])')" -ge 1 ]]; }
check "backup success metric in Prometheus" wait_for 90 backup_metric

section "DNS (Pi-hole, TCP on 1053)"
dns() { dig +short +tcp +time=3 @127.0.0.1 -p 1053 "$1" A | tail -1; }
check "*.$D resolves to HOST_IP" test "$(dns anything.$D)" = 127.0.0.1
check "upstream lookups work" grep -qE '^[0-9.]+$' <<<"$(dns github.com)"
check "ad domains blocked" test "$(dns doubleclick.net)" = 0.0.0.0

section "Profile teardown"
COMPOSE_PROFILES=dns HOMELAB_SETTLE_SECONDS=5 scripts/apply.sh >/dev/null 2>&1 || true
check "disabled profiles stopped" test -z "$(docker compose ps -q grafana alloy backup 2>/dev/null)"
check "always-on and dns services kept" test "$(docker compose ps --status running --format '{{.Service}}' | sort | tr '\n' ' ')" = "docker-proxy pihole pocket-id tinyauth traefik "
HOMELAB_SETTLE_SECONDS=15 scripts/apply.sh >/dev/null 2>&1 || true
check "re-enabled profiles back up" docker compose ps --status running -q grafana

echo
if ((failures)); then
  printf '\033[31m%d check(s) failed\033[0m\n' "$failures"
  exit 1
fi
printf '\033[32mall checks passed\033[0m (stack left running; test/smoke.sh --down removes it)\n'

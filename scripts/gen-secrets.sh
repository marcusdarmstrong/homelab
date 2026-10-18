#!/usr/bin/env bash
# Print fresh values for the generated secrets in .env.example, ready to
# paste into a host's .env. Each site gets its own.
set -euo pipefail

command -v htpasswd >/dev/null || { echo "needs htpasswd (apache2-utils)" >&2; exit 1; }

# rand LENGTH [CHARSET]
rand() { LC_ALL=C tr -dc "${2:-A-Za-z0-9}" </dev/urandom | head -c "$1"; }

echo "POCKET_ID_ENCRYPTION_KEY=$(rand 48)"
# ntfy only accepts tokens shaped like its own `ntfy token generate`.
echo "NTFY_GRAFANA_TOKEN=tk_$(rand 29 a-z0-9)"
echo "NTFY_GRAFANA_PASSWORD_HASH='$(htpasswd -nbBC 10 grafana "$(rand 32)" | cut -d: -f2)'"
echo "RESTIC_PASSWORD=$(rand 48)"

#!/usr/bin/env bash
# Print fresh values for the generated secrets in hosts/secrets.env.example,
# ready to paste into hosts/secrets.env.
set -euo pipefail

command -v htpasswd >/dev/null || { echo "needs htpasswd (apache2-utils)" >&2; exit 1; }

# rand LENGTH [CHARSET]. (tr always dies of SIGPIPE once head has enough.)
rand() { (LC_ALL=C tr -dc "${2:-A-Za-z0-9}" </dev/urandom || true) | head -c "$1"; }
bcrypt() { htpasswd -nbBC 10 x "$1" | cut -d: -f2; }

phone_password="$(rand 24)"
echo "POCKET_ID_ENCRYPTION_KEY=$(rand 48)"
echo "RESTIC_PASSWORD=$(rand 48)"
# ntfy only accepts tokens shaped like its own `ntfy token generate`.
echo "NTFY_GRAFANA_TOKEN=tk_$(rand 29 a-z0-9)"
echo "NTFY_GRAFANA_PASSWORD_HASH='$(bcrypt "$(rand 32)")'"
echo "# Phones log in to ntfy as user 'phone' with: $phone_password"
echo "# Keep that in your password manager; only its hash goes in secrets.env."
echo "NTFY_PHONE_PASSWORD_HASH='$(bcrypt "$phone_password")'"

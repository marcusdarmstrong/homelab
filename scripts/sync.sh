#!/usr/bin/env bash
# Pull-based GitOps, run every minute by homelab-sync.timer.
#
# Fast-forwards to origin/<branch>, then applies whenever the commit or .env
# differs from the last successful apply. That means a push (code or this
# host's settings), pushed secrets, or a previously failed apply all converge
# on the next tick. Pass --force to apply regardless. Host-level settings
# (bootstrap.sh) follow the same way.
#
# The reset discards local edits to tracked files: git is the source of truth.
# Untracked/ignored files (.env) are left alone.
#
# Deploy outcome and OS update status are exported as metrics for Alloy's
# textfile collector, which the "Deploy failing" and OS update alerts watch.
#
# A tick where nothing changed writes nothing to disk: on SD-card hosts every
# small write costs several blocks of filesystem journal.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$REPO_DIR/scripts/lib.sh"

STATE_DIR="${HOMELAB_STATE_DIR:-/var/lib/homelab}"
state_file="$STATE_DIR/applied"
metrics_dir="$STATE_DIR/metrics"

force=0
[[ "${1:-}" == "--force" ]] && force=1

exec 9>/run/lock/homelab-sync.lock
flock -n 9 || { log "another sync is running"; exit 0; }

# write_metric FILE CONTENT: atomic, so the collector never reads a partial
# file, and skipped when the content is unchanged.
write_metric() {
  [[ -f "$metrics_dir/$1" && "$(<"$metrics_dir/$1")" == "$2" ]] && return
  mkdir -p "$metrics_dir"
  printf '%s\n' "$2" >"$metrics_dir/$1.tmp"
  mv "$metrics_dir/$1.tmp" "$metrics_dir/$1"
}
on_exit() {
  local rc=$?
  write_metric deploy.prom "homelab_deploy_success $((rc == 0))"
  # OS auto-update status, piggybacking on this every-minute timer.
  local reboot=0 upgrade_failed=0
  [[ -f /var/run/reboot-required ]] && reboot=1
  systemctl is-failed --quiet apt-daily-upgrade.service && upgrade_failed=1
  write_metric os.prom "homelab_os_reboot_required $reboot
homelab_os_upgrade_failed $upgrade_failed"
}
trap on_exit EXIT

cd "$REPO_DIR"
[[ -f .env ]] || die "missing $REPO_DIR/.env"

# ls-remote writes nothing locally, unlike fetch (FETCH_HEAD), so only fetch
# when the branch has moved.
remote="$(git ls-remote origin "refs/heads/$HOMELAB_BRANCH" | cut -f1)"
[[ -n "$remote" ]] || die "no branch $HOMELAB_BRANCH on origin"
if [[ "$remote" != "$(git rev-parse -q --verify "origin/$HOMELAB_BRANCH" || true)" ]]; then
  git fetch --quiet origin "$HOMELAB_BRANCH"
fi
target="$(git rev-parse "origin/$HOMELAB_BRANCH")"
current="$(git rev-parse HEAD)"
if [[ "$current" != "$target" ]]; then
  log "updating ${current:0:7} -> ${target:0:7}"
  git reset --quiet --hard "$target"
fi

# Host-level settings deploy the same way: bootstrap.sh re-runs whenever it,
# its inputs, this host's settings or .env changed since its last successful
# run.
if [[ "$(host_config_hash)" != "$(cat "$BOOTSTRAP_STATE" 2>/dev/null || true)" ]]; then
  log "host settings changed; running bootstrap.sh"
  "$REPO_DIR/scripts/bootstrap.sh" --from-sync --branch "$HOMELAB_BRANCH"
fi

desired="$target $(sha256sum .env | cut -d' ' -f1)"
if [[ "$force" == 0 && -f "$state_file" && "$(cat "$state_file")" == "$desired" ]]; then
  exit 0
fi

"$REPO_DIR/scripts/apply.sh"

mkdir -p "$STATE_DIR"
echo "$desired" >"$state_file"
write_metric deploy_success.prom "homelab_deploy_last_success_timestamp_seconds $(date +%s)
homelab_deploy_info{commit=\"${target:0:7}\"} 1"

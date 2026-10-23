#!/bin/bash
# Runs before a service with state starts: if its volume is empty, restore
# the volume's latest snapshot into it, wherever that snapshot was taken.
#
#   restore-if-empty.sh PATH
#
# Starts fresh only when the repository answers that it has nothing: it
# doesn't exist yet (restic exits 10), or it has no snapshot of PATH. Any
# other failure, such as the repository being unreachable, keeps the service
# from starting, so an outage can't produce an empty service whose first
# backup then becomes the latest snapshot.
set -euo pipefail

dir="${1:?usage: restore-if-empty.sh PATH}"

if [[ -n "$(ls -A "$dir")" ]]; then
  echo "$dir has data; nothing to restore"
  exit 0
fi

# restic retries an unreachable backend for a long time; give up sooner.
rc=0
timeout 120 restic cat config >/dev/null || rc=$?
case "$rc" in
  0) ;;
  10) echo "no repository yet; starting fresh"; exit 0 ;;
  *) echo "can't read the repository (exit $rc); not starting with an empty $dir" >&2; exit 1 ;;
esac

if [[ "$(restic snapshots --latest 1 --path "$dir" --json)" == "[]" ]]; then
  echo "no snapshot of $dir yet; starting fresh"
  exit 0
fi
restic restore latest --path "$dir" --target /
echo "restored $dir from its latest snapshot"

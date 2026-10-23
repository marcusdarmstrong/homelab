#!/bin/bash
# Make Pi-hole's lists match the files next to this script, and rebuild its
# blocking database when the blocklists changed. pihole-lists runs it on
# every deploy and hourly, so these lists are managed here: changes made to
# them in the web UI are undone.
#
#   blocklists.txt      URLs of blocklists
#   allow-domains.txt   exact domains never to block
#
# One entry per line; blank lines and # comments are ignored.
set -euo pipefail

api="${PIHOLE_API:-http://pihole/api}"
dir="$(dirname "$0")"

wanted() { sed -e 's/#.*//' -e 's/[[:space:]]//g' "$dir/$1" | grep . | sort -u || true; }
uri() { jq -rn --arg v "$1" '$v | @uri'; }

# sync FILE COLLECTION_PATH ARRAY FIELD [QUERY]: add and remove entries at
# $api/COLLECTION_PATH until its ARRAY[].FIELD values match FILE. Prints what
# changed.
sync() {
  local file="$1" path="$2" array="$3" field="$4" query="${5:-}" have want item
  have="$(curl -fsS "$api/$path$query" | jq -r ".${array}[].${field}" | sort -u)"
  want="$(wanted "$file")"
  for item in $(comm -13 <(echo "$have") <(echo "$want")); do
    curl -fsS -X POST "$api/$path$query" -H 'Content-Type: application/json' \
      -d "$(jq -n --arg v "$item" --arg f "$field" '{($f): $v}')" >/dev/null
    echo "added $item"
  done
  for item in $(comm -23 <(echo "$have") <(echo "$want")); do
    curl -fsS -X DELETE "$api/$path/$(uri "$item")$query" >/dev/null
    echo "removed $item"
  done
}

lists="$(sync blocklists.txt lists lists address '?type=block')"
domains="$(sync allow-domains.txt domains/allow/exact domains domain)"
[[ -z "$lists$domains" ]] || echo "$lists$domains"

if [[ -n "$lists" ]]; then
  echo "rebuilding the blocking database"
  curl -fsS -X POST "$api/action/gravity" --max-time 900 >/dev/null
fi
echo "lists in sync"

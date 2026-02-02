#!/usr/bin/env bash
set -euo pipefail

repo="${1:-}"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

if [[ -z "$repo" ]]; then
  remote=$(git remote get-url origin)
  if [[ "$remote" =~ github.com[:/]+([^/]+/[^/.]+) ]]; then
    repo="${BASH_REMATCH[1]}"
  else
    echo "Could not infer repo from remote: $remote" >&2
    exit 2
  fi
fi

poll_interval=5
max_wait=300
start=$(date +%s)

while true; do
  json=$(gh api "repos/$repo/pages/builds/latest" 2>/dev/null || true)
  if [[ -z "$json" ]]; then
    echo "No Pages build info (Pages may be disabled)." >&2
    exit 3
  fi

  status=$(python - <<'PY'
import json, sys
try:
    data=json.loads(sys.stdin.read())
    print(data.get('status',''))
except Exception:
    print('')
PY
<<< "$json")

  echo "$json" > .pages-build-last.json

  case "$status" in
    building)
      now=$(date +%s)
      if (( now - start > max_wait )); then
        echo "Pages build still running after ${max_wait}s" >&2
        exit 4
      fi
      sleep "$poll_interval"
      ;;
    built)
      echo "Pages build succeeded."
      exit 0
      ;;
    *)
      echo "Pages build status: $status" >&2
      exit 1
      ;;
  esac

done

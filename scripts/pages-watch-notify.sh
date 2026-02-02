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

state_dir="$HOME/.cache/ember-vecnet-ai"
mkdir -p "$state_dir"
state_file="$state_dir/pages-build-status.txt"

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

error_msg=$(python - <<'PY'
import json, sys
try:
    data=json.loads(sys.stdin.read())
    err=data.get('error') or {}
    print(err.get('message') or '')
except Exception:
    print('')
PY
<<< "$json")

prev=""
if [[ -f "$state_file" ]]; then
  prev=$(cat "$state_file")
fi

if [[ "$status" == "built" ]]; then
  echo "built" > "$state_file"
  exit 0
fi

# Only notify on transitions to non-built status
if [[ "$prev" != "$status" ]]; then
  msg="ember.vecnet.ai Pages build status: $status"
  if [[ -n "$error_msg" ]]; then
    msg="$msg — $error_msg"
  fi
  openclaw agent --agent main --message "$msg" --deliver --reply-channel telegram --reply-to @XertroV >/dev/null 2>&1 || true
  echo "$status" > "$state_file"
fi

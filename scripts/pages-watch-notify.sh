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

# Check latest workflow run (if it exists)
wf_json=$(gh api "repos/$repo/actions/workflows/deploy.yml/runs?per_page=1" 2>/dev/null || true)
wf_status=""
wf_conclusion=""
if [[ -n "$wf_json" ]]; then
  wf_status=$(python - <<'PY'
import json, sys
try:
    data=json.loads(sys.stdin.read())
    runs=data.get('workflow_runs') or []
    print((runs[0].get('status') if runs else '') or '')
except Exception:
    print('')
PY
<<< "$wf_json")

  wf_conclusion=$(python - <<'PY'
import json, sys
try:
    data=json.loads(sys.stdin.read())
    runs=data.get('workflow_runs') or []
    print((runs[0].get('conclusion') if runs else '') or '')
except Exception:
    print('')
PY
<<< "$wf_json")
fi

prev=""
if [[ -f "$state_file" ]]; then
  prev=$(cat "$state_file")
fi

combined="pages:${status}|wf:${wf_status}:${wf_conclusion}"

if [[ "$status" == "built" && ( -z "$wf_status" || ( "$wf_status" == "completed" && ( -z "$wf_conclusion" || "$wf_conclusion" == "success" ) ) ) ]]; then
  echo "$combined" > "$state_file"
  exit 0
fi

# Only notify on transitions to non-built status
if [[ "$prev" != "$combined" ]]; then
  msg="ember.vecnet.ai Pages build status: $status"
  if [[ -n "$error_msg" ]]; then
    msg="$msg — $error_msg"
  fi
  if [[ -n "$wf_status" ]]; then
    msg="$msg | workflow: $wf_status${wf_conclusion:+/$wf_conclusion}"
  fi
  openclaw agent --agent main --message "$msg" --deliver --reply-channel telegram --reply-to @XertroV >/dev/null 2>&1 || true
  echo "$combined" > "$state_file"
fi

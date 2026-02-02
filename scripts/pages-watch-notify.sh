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

# Check all recent workflow runs; succeed only if ALL are completed+success and none are queued/in_progress
runs_json=$(gh api "repos/$repo/actions/runs?per_page=20" 2>/dev/null || true)
wf_state="unknown"
wf_detail=""
if [[ -n "$runs_json" ]]; then
  wf_state=$(python - <<'PY'
import json, sys
try:
    data=json.loads(sys.stdin.read())
    runs=data.get('workflow_runs') or []
    # If any queued/in_progress, we are waiting
    for r in runs:
        if r.get('status') in ('queued','in_progress'):
            print('waiting')
            sys.exit(0)
    # If any completed with non-success, fail
    for r in runs:
        if r.get('status') == 'completed' and r.get('conclusion') not in (None, 'success'):
            print('failed')
            sys.exit(0)
    # If no runs, unknown
    if not runs:
        print('unknown')
        sys.exit(0)
    print('success')
except Exception:
    print('unknown')
PY
<<< "$runs_json")

  wf_detail=$(python - <<'PY'
import json, sys
try:
    data=json.loads(sys.stdin.read())
    runs=data.get('workflow_runs') or []
    # surface any failing run name if present
    for r in runs:
        if r.get('status') == 'completed' and r.get('conclusion') not in (None, 'success'):
            name=r.get('name') or r.get('workflow_id') or 'workflow'
            print(f"{name}:{r.get('conclusion')}")
            sys.exit(0)
    # surface any waiting run name
    for r in runs:
        if r.get('status') in ('queued','in_progress'):
            name=r.get('name') or r.get('workflow_id') or 'workflow'
            print(f"{name}:{r.get('status')}")
            sys.exit(0)
    print('')
except Exception:
    print('')
PY
<<< "$runs_json")
fi

prev=""
if [[ -f "$state_file" ]]; then
  prev=$(cat "$state_file")
fi

combined="pages:${status}|wf:${wf_state}:${wf_detail}"

if [[ "$status" == "built" && "$wf_state" == "success" ]]; then
  echo "$combined" > "$state_file"
  exit 0
fi

# Only notify on transitions to non-built status
if [[ "$prev" != "$combined" ]]; then
  msg="ember.vecnet.ai Pages build status: $status"
  if [[ -n "$error_msg" ]]; then
    msg="$msg — $error_msg"
  fi
  msg="$msg | workflows: $wf_state${wf_detail:+ ($wf_detail)}"
  openclaw agent --agent main --message "$msg" --deliver --reply-channel telegram --reply-to @XertroV >/dev/null 2>&1 || true
  echo "$combined" > "$state_file"
fi

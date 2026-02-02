#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/home/xertrov}"
export PATH="/usr/local/bin:/usr/bin:/bin:/home/xertrov/.bun/bin"

repo="${1:-}"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

if [[ -z "$repo" ]]; then
  remote=$(git remote get-url origin 2>/dev/null || true)
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
error_log="$state_dir/pages-build-error.log"

head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

json=$(gh api "repos/$repo/pages/builds/latest" 2>"$error_log" || true)
if [[ -z "$json" ]]; then
  status="unknown"
  error_msg="pages api unavailable"
else
  status=$(python -c 'import json,sys
try:
    data=json.loads(sys.stdin.read())
    print(data.get("status",""))
except Exception:
    print("")' <<< "$json")

  error_msg=$(python -c 'import json,sys
try:
    data=json.loads(sys.stdin.read())
    err=data.get("error") or {}
    print(err.get("message") or "")
except Exception:
    print("")' <<< "$json")
fi

# Check workflow runs for the current HEAD
runs_json=$(gh api "repos/$repo/actions/runs?per_page=50" 2>>"$error_log" || true)
wf_state="unknown"
wf_detail=""
if [[ -n "$runs_json" && -n "$head_sha" ]]; then
  wf_state=$(HEAD_SHA="$head_sha" python -c 'import json,os,sys
head_sha=os.environ.get("HEAD_SHA","")
try:
    data=json.loads(sys.stdin.read())
    runs=[r for r in (data.get("workflow_runs") or []) if r.get("head_sha")==head_sha]
    if not runs:
        print("unknown")
    elif any(r.get("status") in ("queued","in_progress") for r in runs):
        print("waiting")
    elif any(r.get("status")=="completed" and r.get("conclusion") not in (None,"success") for r in runs):
        print("failed")
    else:
        print("success")
except Exception:
    print("unknown")' <<< "$runs_json")

  wf_detail=$(HEAD_SHA="$head_sha" python -c 'import json,os,sys
head_sha=os.environ.get("HEAD_SHA","")
try:
    data=json.loads(sys.stdin.read())
    runs=[r for r in (data.get("workflow_runs") or []) if r.get("head_sha")==head_sha]
    for r in runs:
        if r.get("status")=="completed" and r.get("conclusion") not in (None,"success"):
            name=r.get("name") or r.get("workflow_id") or "workflow"
            print(f"{name}:{r.get('conclusion')}"); raise SystemExit
    for r in runs:
        if r.get("status") in ("queued","in_progress"):
            name=r.get("name") or r.get("workflow_id") or "workflow"
            print(f"{name}:{r.get('status')}"); raise SystemExit
    print("")
except Exception:
    print("")' <<< "$runs_json")
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
  openclaw agent --agent main --message "$msg" --deliver --reply-channel telegram --reply-to @XertroV --timeout 30 >/dev/null 2>&1 || true
  echo "$combined" > "$state_file"
fi

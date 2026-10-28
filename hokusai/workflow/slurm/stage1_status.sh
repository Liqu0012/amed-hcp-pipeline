#!/usr/bin/env bash
# Summary of the rolling stage-1 queue. Usage: stage1_status.sh CONFIG [-v]
set -uo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/bin/common.sh"
load_site "${1:?Usage: stage1_status.sh CONFIG [-v]}"
Q="${HCP_QUEUE_DIR:-$HCP_WORKFLOW_LOG_DIR/stage1_queue}"
INCLUDE="${HCP_INCLUDE_REGEX:-_HARP_}"
declare -A excluded=()
while IFS= read -r x; do [[ -n "$x" ]] && excluded[$x]=1; done < "${HCP_EXCLUDE_LIST:-/dev/null}"
IFS=: read -r -a dirs <<< "$HCP_SOURCE_DIRS"
declare -A n=()
detail=()
while IFS= read -r z; do
  s=$(basename "$z" .zip); [[ "$s" =~ $INCLUDE ]] || continue
  d="$HCP_STUDY/$s"
  if [[ -n "${excluded[$s]:-}" ]]; then st=excluded
  elif [[ -e "$d/.stage1_complete" ]]; then st=complete
  elif [[ -e "$d/.stage1_blocked" ]]; then st=blocked
  elif [[ -e "$d/.stage1_failed" ]]; then st=failed
  elif [[ -d "$Q/claims/$s" ]]; then st=running
  elif [[ -s "$Q/verified/$s" ]]; then st=queued
  else st=waiting_upload_or_check; fi
  n[$st]=$(( ${n[$st]:-0} + 1 ))
  [[ "$st" == failed || "$st" == blocked ]] && detail+=("$st $s")
done < <(find "${dirs[@]}" -maxdepth 1 -type f -name '*.zip' ! -name '.*' | sort)
for k in complete running queued waiting_upload_or_check blocked failed excluded; do
  printf '%-26s %s\n' "$k" "${n[$k]:-0}"
done
squeue -h -u "$USER" -n "${HCP_WORKER_NAME:-hcp_stage1}" -o '%i %T %M %N' | sort | sed 's/^/worker /'
[[ "${2:-}" == -v ]] && printf '%s\n' "${detail[@]}"
[[ -e "$Q/STOP" ]] && echo "STOP file present"
exit 0

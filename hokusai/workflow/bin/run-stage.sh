#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=common.sh
source "$root/bin/common.sh"

cfg="${1:?Usage: run-stage.sh CONFIG STAGE SESSION [ARCHIVE]}"
stage="${2:?stage required}"
session="${3:?session required}"
archive="${4:-}"
load_site "$cfg"
validate_session "$session"
export HCP_STUDY

params="$HCP_STUDY/$session/unprocessed/3T/params.sh"
# Sessions without usable dMRI or rfMRI (decided by hcp_select_inputs.py)
# skip those branches with success, so the session can still reach QC.
load_params() {
  [[ -s "$params" ]] || { echo "Missing conversion parameters: $params" >&2; exit 4; }
  source "$params"
}
skip_without() {
  local value="$1" what="$2"
  if [[ -z "$value" ]]; then
    echo "No usable $what for $session; stage $stage skipped"
    exit 0
  fi
}

case "$stage" in
  structural) run_words "$HCP_STRUCT_COMMAND" "$session" "$archive" ;;
  convert) run_words "$HCP_CONVERT_COMMAND" "$session" "$archive" ;;
  preeddy) load_params; skip_without "${DMRI_SHELLS_USABLE:-}" dMRI; run_words "$HCP_PREEDDY_COMMAND" "$session" ;;
  eddy) load_params; skip_without "${DMRI_SHELLS_USABLE:-}" dMRI; run_words "$HCP_EDDY_COMMAND" "$session" ;;
  posteddy)
    load_params; skip_without "${DMRI_SHELLS_USABLE:-}" dMRI
    ensure_white_deformed "$session"
    run_words "$HCP_POSTEDDY_COMMAND" "$session"
    ;;
  fmri)
    load_params; skip_without "${FMRI_RUNS:-}" rfMRI
    for run in $FMRI_RUNS; do
      run_words "$HCP_FMRI_COMMAND" "$session" "$run"
    done
    ;;
  icafix) load_params; skip_without "${FMRI_RUNS:-}" rfMRI; run_words "$HCP_ICAFIX_COMMAND" "$session" ;;
  msmall) load_params; skip_without "${FMRI_RUNS:-}" rfMRI; run_words "$HCP_MSMALL_COMMAND" "$session" ;;
  dedrift) load_params; skip_without "${FMRI_RUNS:-}" rfMRI; run_words "$HCP_DEDRIFT_COMMAND" "$session" ;;
  qc)
    # PASS (0) and REVIEW (1) are completed QC; FAIL (2) fails the job.
    rc=0
    python3 "$HCP_STAGE_SCRIPT_DIR/hcp_qc_session.py" "$HCP_STUDY" "$session" || rc=$?
    ((rc <= 1)) || exit "$rc"
    ;;
  *) echo "Unknown stage: $stage" >&2; exit 2 ;;
esac

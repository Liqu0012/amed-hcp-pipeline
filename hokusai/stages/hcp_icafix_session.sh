#!/usr/bin/env bash
set -Eeuo pipefail

session="${1:?Usage: hcp_icafix_session.sh SESSION}"
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe session: $session" >&2; exit 2; }

image="${HCP_IMAGE:?HCP_IMAGE is required}"
study="${HCP_STUDY:?HCP_STUDY is required}"
runtime="${HCP_CONTAINER_RUNTIME:-apptainer}"
session_root="$study/$session"
marker="$session_root/.hcp_icafix_complete.ok"
params="$session_root/unprocessed/3T/params.sh"
[[ -s "$params" ]] || { echo "Missing conversion parameters for $session" >&2; exit 1; }
source "$params"
: "${FMRI_RUNS:?FMRI_RUNS is missing from $params}"

for run in $FMRI_RUNS; do
  [[ -s "$session_root/.hcp_fmri_${run}_complete.ok" ]] || { echo "fMRI run $run not complete for $session" >&2; exit 1; }
done

if [[ -s "$marker" ]]; then
  echo "Already done: ICA-FIX for $session"
  exit 0
fi

results="$session_root/MNINonLinear/Results"
fmri_paths=()
for run in $FMRI_RUNS; do fmri_paths+=("${results}/${run}/${run}"); done
fmri_names=$(IFS=@; printf '%s' "${fmri_paths[*]}")
concat_name="${results}/fMRI_CONCAT_ALL/fMRI_CONCAT_ALL"

scratch_base="${SLURM_SCRATCH:-/tmp}/hcp-icafix-${session}"
export TMPDIR="$scratch_base/tmp"
mkdir -p "$TMPDIR"

echo "fmri_names=$fmri_names"
echo "concat_name=$concat_name"

"$runtime" exec --bind "$scratch_base:$scratch_base" "$image" bash -c '
  set -o pipefail
  source /opt/qunex/env/qunex_environment.sh >/dev/null 2>&1 || true
  unset -f which 2>/dev/null || true
  set -Ee
  training=$(find /opt/fsl -maxdepth 12 -path "*/pyfix/resources/models/HCP_Style_Single_Multirun_Dedrift.pyfix_model" 2>/dev/null | head -1)
  echo "training=$training"
  [[ -n "$training" ]] || { echo "ERROR: could not locate HCP_Style_Single_Multirun_Dedrift.pyfix_model" >&2; exit 5; }
  "$HCPPIPEDIR"/ICAFIX/hcp_fix_multi_run \
    --fmri-names="'"$fmri_names"'" \
    --high-pass=0 \
    --concat-fmri-name="'"$concat_name"'" \
    --motion-regression=FALSE \
    --training-file="$training" \
    --fix-threshold=10 \
    --delete-intermediates=FALSE \
    --processing-mode=HCPStyleData \
    --ica-method=MELODIC \
    --matlab-run-mode=0
'

printf 'session=%s\ncompleted=%s\n' "$session" "$(date -Is)" > "$marker"
echo "ICA-FIX complete: $session"

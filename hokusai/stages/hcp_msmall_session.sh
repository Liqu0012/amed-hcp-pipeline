#!/usr/bin/env bash
set -Eeuo pipefail

session="${1:?Usage: hcp_msmall_session.sh SESSION}"
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe session: $session" >&2; exit 2; }

image="${HCP_IMAGE:?HCP_IMAGE is required}"
study="${HCP_STUDY:?HCP_STUDY is required}"
runtime="${HCP_CONTAINER_RUNTIME:-apptainer}"
session_root="$study/$session"
marker="$session_root/.hcp_msmall_complete.ok"
icafix_marker="$session_root/.hcp_icafix_complete.ok"
params="$session_root/unprocessed/3T/params.sh"

[[ -s "$icafix_marker" ]] || { echo "ICA-FIX not complete for $session" >&2; exit 1; }
[[ -s "$params" ]] || { echo "Missing conversion parameters for $session" >&2; exit 1; }
source "$params"
: "${FMRI_RUNS:?FMRI_RUNS is missing from $params}"

if [[ -s "$marker" ]]; then
  echo "Already done: MSMAll for $session"
  exit 0
fi

mrfix_names="${FMRI_RUNS// /@}"

scratch_base="${SLURM_SCRATCH:-/tmp}/hcp-msmall-${session}"
export TMPDIR="$scratch_base/tmp"
mkdir -p "$TMPDIR"

"$runtime" exec --bind "$scratch_base:$scratch_base" "$image" bash -c '
  set -o pipefail
  source /opt/qunex/env/qunex_environment.sh >/dev/null 2>&1 || true
  unset -f which 2>/dev/null || true
  set -Ee
  "$HCPPIPEDIR"/MSMAll/MSMAllPipeline.sh \
    --path="'"$study"'" --subject="'"$session"'" \
    --fmri-names-list="" \
    --multirun-fix-names="'"$mrfix_names"'" \
    --multirun-fix-concat-name="fMRI_CONCAT_ALL" \
    --multirun-fix-names-to-use="'"$mrfix_names"'" \
    --output-fmri-name="rfMRI_REST_CONCAT" \
    --high-pass=0 \
    --fmri-proc-string="_Atlas_hp0_clean" \
    --msm-all-templates="$HCPPIPEDIR/global/templates/MSMAll" \
    --myelin-target-file="$HCPPIPEDIR/global/templates/MSMAll/Q1-Q6_RelatedParcellation210.MyelinMap_BC_MSMAll_2_d41_WRN_DeDrift.32k_fs_LR.dscalar.nii" \
    --output-registration-name="MSMAll_InitialReg" \
    --high-res-mesh=164 --low-res-mesh=32 \
    --input-registration-name="MSMSulc" \
    --matlab-run-mode=0
'

printf 'session=%s\ncompleted=%s\n' "$session" "$(date -Is)" > "$marker"
echo "MSMAll complete: $session"

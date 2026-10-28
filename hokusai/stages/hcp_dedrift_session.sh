#!/usr/bin/env bash
set -Eeuo pipefail

session="${1:?Usage: hcp_dedrift_session.sh SESSION}"
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe session: $session" >&2; exit 2; }

image="${HCP_IMAGE:?HCP_IMAGE is required}"
study="${HCP_STUDY:?HCP_STUDY is required}"
runtime="${HCP_CONTAINER_RUNTIME:-apptainer}"
session_root="$study/$session"
marker="$session_root/.hcp_dedrift_complete.ok"
msmall_marker="$session_root/.hcp_msmall_complete.ok"
params="$session_root/unprocessed/3T/params.sh"

[[ -s "$msmall_marker" ]] || { echo "MSMAll not complete for $session" >&2; exit 1; }
[[ -s "$params" ]] || { echo "Missing conversion parameters for $session" >&2; exit 1; }
source "$params"
: "${FMRI_RUNS:?FMRI_RUNS is missing from $params}"

if [[ -s "$marker" ]]; then
  echo "Already done: DeDriftAndResample for $session"
  exit 0
fi

mrfix_names="${FMRI_RUNS// /@}"

scratch_base="${SLURM_SCRATCH:-/tmp}/hcp-dedrift-${session}"
export TMPDIR="$scratch_base/tmp"
mkdir -p "$TMPDIR"

"$runtime" exec --bind "$scratch_base:$scratch_base" "$image" bash -c '
  set -o pipefail
  source /opt/qunex/env/qunex_environment.sh >/dev/null 2>&1 || true
  unset -f which 2>/dev/null || true
  set -Ee
  "$HCPPIPEDIR"/DeDriftAndResample/DeDriftAndResamplePipeline.sh \
    --path="'"$study"'" --subject="'"$session"'" \
    --high-res-mesh=164 --low-res-meshes=32 \
    --registration-name="MSMAll_InitialReg_2_d40_WRN" \
    --dedrift-reg-files="$HCPPIPEDIR/global/templates/MSMAll/DeDriftingGroup.L.sphere.DeDriftMSMAll.164k_fs_LR.surf.gii@$HCPPIPEDIR/global/templates/MSMAll/DeDriftingGroup.R.sphere.DeDriftMSMAll.164k_fs_LR.surf.gii" \
    --concat-reg-name="MSMAll" \
    --maps="sulc@curvature@corrThickness@thickness" \
    --myelin-maps="MyelinMap@SmoothedMyelinMap" \
    --multirun-fix-concat-names="fMRI_CONCAT_ALL" \
    --multirun-fix-names="'"$mrfix_names"'" \
    --multirun-fix-extract-concat-names="rfMRI_REST" \
    --multirun-fix-extract-names="'"$mrfix_names"'" \
    --multirun-fix-extract-volume=TRUE \
    --fix-names="" \
    --dont-fix-names="" \
    --smoothing-fwhm=2 \
    --high-pass=0 \
    --matlab-run-mode=0 \
    --motion-regression=FALSE \
    --myelin-target-file="$HCPPIPEDIR/global/templates/MSMAll/Q1-Q6_RelatedParcellation210.MyelinMap_BC_MSMAll_2_d41_WRN_DeDrift.32k_fs_LR.dscalar.nii"
'

printf 'session=%s\ncompleted=%s\n' "$session" "$(date -Is)" > "$marker"
echo "DeDriftAndResample complete: $session"

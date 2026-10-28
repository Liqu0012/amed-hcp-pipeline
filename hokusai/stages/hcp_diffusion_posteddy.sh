#!/usr/bin/env bash
set -Eeuo pipefail

session="${1:?Usage: hcp_diffusion_posteddy.sh SESSION}"
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe session: $session" >&2; exit 2; }

image="${HCP_IMAGE:?HCP_IMAGE is required}"
study="${HCP_STUDY:?HCP_STUDY is required}"
runtime="${HCP_CONTAINER_RUNTIME:-apptainer}"
session_root="$study/$session"
marker="$session_root/.hcp_diffusion_complete.ok"
eddy_marker="$session_root/.hcp_diffusion_eddy_complete.ok"

[[ -s "$eddy_marker" ]] || { echo "Eddy stage not complete for $session" >&2; exit 1; }

if [[ -s "$marker" ]]; then
  echo "Already done: PostEddy for $session"
  exit 0
fi

scratch_base="${SLURM_SCRATCH:-/tmp}/hcp-diffposteddy-${session}"
export TMPDIR="$scratch_base/tmp"
mkdir -p "$TMPDIR"

"$runtime" exec --bind "$scratch_base:$scratch_base" "$image" bash -c '
  set -o pipefail
  source /opt/qunex/env/qunex_environment.sh >/dev/null 2>&1 || true
  unset -f which 2>/dev/null || true
  set -Ee
  "$HCPPIPEDIR/DiffusionPreprocessing/DiffPreprocPipeline_PostEddy.sh" \
    --path="'"$study"'" --session="'"$session"'" --dwiname=Diffusion \
    --gdcoeffs=NONE \
    --dof=6 \
    --select-best-b0=FALSE \
    --combine-data-flag=2
'
# 2026-10-28: --combine-data-flag=2 (was 1). flag=1 averages AP/PA volumes by
# index, which mixes b-value shells when the AP and PA sets are not matched
# (e.g. 68 vs 69 volumes); flag=2 keeps every eddy-corrected volume.

printf 'session=%s\ncompleted=%s\n' "$session" "$(date -Is)" > "$marker"
echo "PostEddy complete: $session"

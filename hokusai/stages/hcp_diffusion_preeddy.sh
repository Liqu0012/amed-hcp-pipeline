#!/usr/bin/env bash
set -Eeuo pipefail

session="${1:?Usage: hcp_diffusion_preeddy.sh SESSION}"
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe session: $session" >&2; exit 2; }

image="${HCP_IMAGE:?HCP_IMAGE is required}"
study="${HCP_STUDY:?HCP_STUDY is required}"
runtime="${HCP_CONTAINER_RUNTIME:-apptainer}"
session_root="$study/$session"
unproc="$session_root/unprocessed/3T"
marker="$session_root/.hcp_diffusion_preeddy_complete.ok"
convert_marker="$session_root/.hcp_convert_complete.ok"

[[ -s "$convert_marker" ]] || { echo "Convert stage not complete for $session" >&2; exit 1; }

if [[ -s "$marker" ]]; then
  echo "Already done: PreEddy for $session"
  exit 0
fi

source "$unproc/params.sh"

posData=""
negData=""
for shell in $DMRI_SHELLS_USABLE; do
  pa="$unproc/dMRI_${shell}_PA.nii.gz"
  ap="$unproc/dMRI_${shell}_AP.nii.gz"
  [[ -s "$pa" && -s "$ap" ]] || { echo "Missing dMRI files for shell $shell" >&2; exit 4; }
  if [[ -z "$posData" ]]; then
    posData="$pa"; negData="$ap"
  else
    posData="${posData}@${pa}"; negData="${negData}@${ap}"
  fi
done
[[ -n "$posData" ]] || { echo "No usable dMRI shells for $session (DMRI_SHELLS_USABLE empty)" >&2; exit 4; }

echospacing_ms=$(awk -v s="$DMRI_ECHOSPACING_SEC" 'BEGIN{printf "%.6f", s*1000}')

echo "PosData: $posData"
echo "NegData: $negData"
echo "EchoSpacing (ms): $echospacing_ms"

scratch_base="${SLURM_SCRATCH:-/tmp}/hcp-diffpreeddy-${session}"
export TMPDIR="$scratch_base/tmp"
mkdir -p "$TMPDIR"

"$runtime" exec --bind "$scratch_base:$scratch_base" "$image" bash -c '
  set -o pipefail
  source /opt/qunex/env/qunex_environment.sh >/dev/null 2>&1 || true
  unset -f which 2>/dev/null || true
  set -Ee
  "$HCPPIPEDIR/DiffusionPreprocessing/DiffPreprocPipeline_PreEddy.sh" \
    --path="'"$study"'" --session="'"$session"'" --dwiname=Diffusion \
    --PEdir=2 \
    --posData="'"$posData"'" --negData="'"$negData"'" \
    --echospacing="'"$echospacing_ms"'" \
    --b0maxbval=50 \
    --topup-config-file="$HCPPIPEDIR_Config/b02b0.cnf" \
    --select-best-b0=FALSE --ensure-even-slices=FALSE \
    --combine-data-flag=2
'
# 2026-10-28: --combine-data-flag=2 (was 1) to match PostEddy; AP/PA sets in
# this cohort are not volume-matched, so nothing may be averaged across them.

printf 'session=%s\ncompleted=%s\n' "$session" "$(date -Is)" > "$marker"
echo "PreEddy complete: $session"

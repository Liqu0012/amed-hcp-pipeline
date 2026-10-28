#!/usr/bin/env bash
set -Eeuo pipefail
# GPU eddy (FSL eddy_cuda inside the QuNex image) for x86 clusters with NVIDIA
# GPUs, e.g. DB gcalc nodes. Same eddy options as the DB v6 stage 2:
# --gpu=TRUE --data_is_shelled --repol. The scheduler gives each session one
# GPU (--gres=gpu:1); the container gets the host driver through --nv.

session="${1:?Usage: hcp_diffusion_eddy_cuda.sh SESSION}"
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe session: $session" >&2; exit 2; }

image="${HCP_IMAGE:?HCP_IMAGE is required}"
study="${HCP_STUDY:?HCP_STUDY is required}"
runtime="${HCP_CONTAINER_RUNTIME:-apptainer}"
session_root="$study/$session"
marker="$session_root/.hcp_diffusion_eddy_complete.ok"
preeddy_marker="$session_root/.hcp_diffusion_preeddy_complete.ok"

[[ -s "$preeddy_marker" ]] || { echo "PreEddy not complete for $session" >&2; exit 1; }
if [[ -s "$marker" ]]; then
  echo "Already done: Eddy GPU for $session"
  exit 0
fi
command -v nvidia-smi >/dev/null && nvidia-smi -L || { echo "No NVIDIA GPU visible on $(hostname)" >&2; exit 3; }
echo "CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES:-unset}"

scratch_base="${SLURM_SCRATCH:-/tmp}/hcp-eddy-${session}"
export TMPDIR="$scratch_base/tmp"
mkdir -p "$TMPDIR"

"$runtime" exec --nv --bind "$scratch_base:$scratch_base" "$image" bash -c '
  set -o pipefail
  source /opt/qunex/env/qunex_environment.sh >/dev/null 2>&1 || true
  unset -f which 2>/dev/null || true
  set -Ee
  [[ -x "$FSLDIR/bin/eddy_cuda" ]] || { echo "ERROR: $FSLDIR/bin/eddy_cuda missing" >&2; exit 5; }
  "$HCPPIPEDIR/DiffusionPreprocessing/DiffPreprocPipeline_Eddy.sh" \
    --path="'"$study"'" --session="'"$session"'" \
    --gpu=TRUE \
    --extra-eddy-arg=--data_is_shelled \
    --extra-eddy-arg=--repol
'

printf 'session=%s\nmode=gpu\nhost=%s\ngpu=%s\ncompleted=%s\n' \
  "$session" "$(hostname)" "${CUDA_VISIBLE_DEVICES:-}" "$(date -Is)" > "$marker"
echo "Eddy GPU complete: $session"

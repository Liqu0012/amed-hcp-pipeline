#!/usr/bin/env bash
set -Eeuo pipefail

session="${1:?Usage: hcp_diffusion_eddy_gpu.sh SESSION}"
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe session: $session" >&2; exit 2; }

study=/home1/q0000239/hcp_test/study
session_root="$study/$session"
marker="$session_root/.hcp_diffusion_eddy_complete.ok"
preeddy_marker="$session_root/.hcp_diffusion_preeddy_complete.ok"

[[ -s "$preeddy_marker" ]] || { echo "PreEddy not complete for $session" >&2; exit 1; }

if [[ -s "$marker" ]]; then
  echo "Already done: Eddy GPU for $session"
  exit 0
fi

[[ "$(uname -m)" == "aarch64" ]] || { echo "This script must run on an ARM64 (aarch64) GPU node, got $(uname -m)" >&2; exit 3; }

export HCPPIPEDIR=/home1/q0000239/tools/HCPpipelines_scripts
export FSLDIR=/home1/q0000239/tools/fsl-aarch64-cuda
export PATH="$FSLDIR/bin:$PATH"
export LD_LIBRARY_PATH="$FSLDIR/lib:${LD_LIBRARY_PATH:-}"
source "$FSLDIR/etc/fslconf/fsl.sh"
export FSLOUTPUTTYPE=NIFTI_GZ

echo "Using FSLDIR=$FSLDIR"
nvidia-smi -L || echo "WARNING: nvidia-smi did not report a GPU"

bash "$HCPPIPEDIR/DiffusionPreprocessing/DiffPreprocPipeline_Eddy.sh" \
  --path="$study" --session="$session" \
  --gpu=True \
  --extra-eddy-arg=--data_is_shelled

printf 'session=%s\ncompleted=%s\n' "$session" "$(date -Is)" > "$marker"
echo "Eddy GPU complete: $session"

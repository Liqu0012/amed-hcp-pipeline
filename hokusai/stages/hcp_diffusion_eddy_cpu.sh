#!/usr/bin/env bash
set -Eeuo pipefail

session="${1:?Usage: hcp_diffusion_eddy_cpu.sh SESSION}"
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe session: $session" >&2; exit 2; }

image="${HCP_IMAGE:?HCP_IMAGE is required}"
study="${HCP_STUDY:?HCP_STUDY is required}"
runtime="${HCP_CONTAINER_RUNTIME:-apptainer}"
eddy_shim="${HCP_STAGE_SCRIPT_DIR:?HCP_STAGE_SCRIPT_DIR is required}/eddy_openmp"
threads="${SLURM_CPUS_PER_TASK:-${OMP_NUM_THREADS:-1}}"
session_root="$study/$session"
marker="$session_root/.hcp_diffusion_eddy_complete.ok"
preeddy_marker="$session_root/.hcp_diffusion_preeddy_complete.ok"

[[ -s "$preeddy_marker" ]] || { echo "PreEddy not complete for $session" >&2; exit 1; }
[[ -x "$eddy_shim" ]] || { echo "Missing executable Eddy CPU shim: $eddy_shim" >&2; exit 1; }

if [[ -s "$marker" ]]; then
  echo "Already done: Eddy CPU for $session"
  exit 0
fi

scratch_base="${SLURM_SCRATCH:-/tmp}/hcp-eddy-${session}"
export TMPDIR="$scratch_base/tmp"
mkdir -p "$TMPDIR"

echo "Running Eddy CPU with --nthr=$threads"
"$runtime" exec \
  --bind "$scratch_base:$scratch_base" \
  --bind "$eddy_shim:/opt/fsl/fsl/bin/eddy_openmp" \
  "$image" bash -c '
  set -o pipefail
  source /opt/qunex/env/qunex_environment.sh >/dev/null 2>&1 || true
  unset -f which 2>/dev/null || true
  set -Ee
  export OMP_NUM_THREADS="'"$threads"'"
  export MKL_NUM_THREADS="$OMP_NUM_THREADS"
  export OPENBLAS_NUM_THREADS="$OMP_NUM_THREADS"
  [[ -x "$FSLDIR/bin/eddy_openmp" ]] || {
    echo "ERROR: Eddy CPU shim is unavailable at $FSLDIR/bin/eddy_openmp" >&2
    exit 5
  }
  "$HCPPIPEDIR/DiffusionPreprocessing/DiffPreprocPipeline_Eddy.sh" \
    --path="'"$study"'" --session="'"$session"'" \
    --gpu=False \
    --extra-eddy-arg=--data_is_shelled \
    --extra-eddy-arg=--repol \
    --extra-eddy-arg=--nthr="'"$threads"'"
'

printf 'session=%s\nmode=cpu\nthreads=%s\ncompleted=%s\n' \
  "$session" "$threads" "$(date -Is)" > "$marker"
echo "Eddy CPU complete: $session"

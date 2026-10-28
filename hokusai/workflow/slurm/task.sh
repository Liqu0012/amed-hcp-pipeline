#!/usr/bin/env bash
set -Eeuo pipefail
root="${HCP_WORKFLOW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[[ -d "$root/bin" ]] || { echo "Invalid HCP_WORKFLOW_ROOT: $root" >&2; exit 2; }
source "$root/bin/common.sh"
: "${HCP_CONFIG:?HCP_CONFIG required}"
: "${HCP_MANIFEST:?HCP_MANIFEST required}"
: "${HCP_STAGE:?HCP_STAGE required}"
: "${SLURM_ARRAY_TASK_ID:?array task ID required}"
manifest_row "$HCP_MANIFEST" "$SLURM_ARRAY_TASK_ID"
export OMP_NUM_THREADS="${SLURM_CPUS_PER_TASK:-1}"
export MKL_NUM_THREADS="$OMP_NUM_THREADS"
export OPENBLAS_NUM_THREADS="$OMP_NUM_THREADS"
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$OMP_NUM_THREADS"
export SINGULARITYENV_LC_ALL=C SINGULARITYENV_LANG=C
export APPTAINERENV_LC_ALL=C APPTAINERENV_LANG=C
scratch_root="${HCP_SCRATCH_ROOT:-${SLURM_TMPDIR:-/tmp}}"
export SLURM_SCRATCH="$scratch_root/hcp-${SLURM_JOB_ID}-${SLURM_ARRAY_TASK_ID}"
mkdir -p "$SLURM_SCRATCH"
cleanup_scratch() { rm -rf -- "$SLURM_SCRATCH"; }
trap cleanup_scratch EXIT
bash "$root/bin/run-stage.sh" "$HCP_CONFIG" "$HCP_STAGE" "$SESSION" "$ARCHIVE"

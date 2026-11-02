#!/usr/bin/env bash
# Allocate the GPU only after structural processing, rather than holding it idle.
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/bin/common.sh"; load_site "$1"
cfg=$1; s=$2; validate_session "$s"
d=$HCP_NODE_QUEUE_DIR/state/$s
mkdir -p "$d"
exec 9>"$d/gpu-submit.lock"; flock 9
[[ ! -s "$HCP_STUDY/$s/.l4n_diffusion.ok" ]] || exit 0
job=$(cat "$d/gpu.job" 2>/dev/null || true)
if [[ -z "$job" ]] || [[ -z "$(squeue -h -j "$job" -o %i 2>/dev/null)" ]]; then
  job=$(sbatch --parsable -J hcp_l4n_diffusion -p "${L4N_GPU_PARTITION:-gcalc1}" \
    --nodes=1 --ntasks=1 --cpus-per-task=8 --mem=60G --time=12:00:00 \
    --gres="${L4N_GPU_GRES:-gpu:l40s:1}" --output="$d/gpu_%j.log" \
    "$root/slurm/diffusion.sbatch" "$cfg" "$s")
  job=${job%%;*}
  printf '%s\n' "$job" > "$d/gpu.job"
fi
flock -u 9
while [[ -n "$(squeue -h -j "$job" -o %i)" ]]; do sleep 30; done
[[ -s "$HCP_STUDY/$s/.l4n_diffusion.ok" ]] || { echo "GPU job $job failed; see $d/gpu_$job.log" >&2; exit 1; }

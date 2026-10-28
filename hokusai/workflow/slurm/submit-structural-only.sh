#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/bin/common.sh"
cfg=$(readlink -f "${1:?Usage: submit-structural-only.sh CONFIG MANIFEST TAG}")
manifest=$(readlink -f "${2:?manifest required}")
tag="${3:?tag required}"
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe tag" >&2; exit 2; }
load_site "$cfg"
bash "$root/bin/preflight.sh" "$cfg" "$manifest"
n=$(awk 'NF {n++} END {print n+0}' "$manifest")
mkdir -p "$HCP_WORKFLOW_LOG_DIR/$tag"
log="$HCP_WORKFLOW_LOG_DIR/$tag"
parallel="${HCP_STRUCTURAL_MAX_PARALLEL:-${HCP_MAX_PARALLEL:-12}}"

args=(--parsable "--partition=$HCP_CPU_PARTITION"
  "--export=ALL,HCP_WORKFLOW_ROOT=$root,HCP_CONFIG=$cfg,HCP_MANIFEST=$manifest,HCP_STAGE=structural"
  "--array=1-$n%$parallel" "--job-name=hcp_structural_${tag}"
  "--time=${HCP_STRUCT_TIME:-12:00:00}" "--cpus-per-task=${HCP_STRUCT_CPUS:-112}"
  --nodes=1 --ntasks=1 "--output=$log/structural_%A_%a.log")
[[ -z "${HCP_SLURM_ACCOUNT:-}" ]] || args+=("--account=$HCP_SLURM_ACCOUNT")
[[ -z "${HCP_SLURM_QOS:-}" ]] || args+=("--qos=$HCP_SLURM_QOS")
[[ "${HCP_STRUCT_MEM:--}" == - ]] || args+=("--mem=${HCP_STRUCT_MEM}")
if [[ -n "${HCP_INITIAL_DEPENDENCY:-}" ]]; then
  args+=("--dependency=$HCP_INITIAL_DEPENDENCY")
fi
job=$(sbatch "${args[@]}" "$root/slurm/task.sh")
printf 'stage\tjob_id\nstructural\t%s\n' "$job" | tee "$log/submission.tsv"

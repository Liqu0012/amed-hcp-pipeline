#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/bin/common.sh"
cfg=$(readlink -f "${1:?Usage: submit-packed-structural-only.sh CONFIG MANIFEST TAG}")
manifest=$(readlink -f "${2:?manifest required}")
tag="${3:?tag required}"
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe tag" >&2; exit 2; }
load_site "$cfg"
bash "$root/bin/preflight.sh" "$cfg" "$manifest"
n=$(awk 'NF {n++} END {print n+0}' "$manifest")
pack="${HCP_STRUCTURAL_PACK_SIZE:?HCP_STRUCTURAL_PACK_SIZE required}"
per_cpu="${HCP_STRUCTURAL_CPUS_PER_SESSION:?HCP_STRUCTURAL_CPUS_PER_SESSION required}"
chunks=$(( (n + pack - 1) / pack ))
parallel="${HCP_STRUCTURAL_MAX_PARALLEL:-${HCP_PACKED_MAX_PARALLEL:-12}}"
log="$HCP_WORKFLOW_LOG_DIR/$tag"
mkdir -p "$log"

args=(--parsable "--partition=$HCP_CPU_PARTITION"
  "--export=ALL,HCP_WORKFLOW_ROOT=$root,HCP_CONFIG=$cfg,HCP_MANIFEST=$manifest,HCP_STAGE=structural,HCP_PACK_SIZE=$pack,HCP_CPUS_PER_SESSION=$per_cpu,HCP_PACK_LOG_DIR=$log"
  "--array=1-$chunks%$parallel" "--job-name=hcp_pack_structural_${tag}"
  "--time=${HCP_STRUCT_TIME:-12:00:00}" "--cpus-per-task=${HCP_PACKED_NODE_CPUS:-112}"
  --nodes=1 --ntasks=1 "--mem=${HCP_PACKED_NODE_MEM:-112G}"
  "--output=$log/structural_node_%A_%a.log")
[[ -z "${HCP_SLURM_ACCOUNT:-}" ]] || args+=("--account=$HCP_SLURM_ACCOUNT")
[[ -z "${HCP_SLURM_QOS:-}" ]] || args+=("--qos=$HCP_SLURM_QOS")
[[ -z "${HCP_SLURM_EXCLUDE:-}" ]] || args+=("--exclude=$HCP_SLURM_EXCLUDE")
job=$(sbatch "${args[@]}" "$root/slurm/node-task.sh")
printf 'stage\tjob_id\nstructural\t%s\n' "$job" | tee "$log/submission.tsv"

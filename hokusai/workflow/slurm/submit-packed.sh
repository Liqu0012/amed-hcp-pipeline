#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/bin/common.sh"
cfg=$(readlink -f "${1:?Usage: submit-packed.sh CONFIG MANIFEST TAG}")
manifest=$(readlink -f "${2:?manifest required}")
tag="${3:?tag required}"
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe tag" >&2; exit 2; }
load_site "$cfg"
bash "$root/bin/preflight.sh" "$cfg" "$manifest"
n=$(awk 'NF {n++} END {print n+0}' "$manifest")
mkdir -p "$HCP_WORKFLOW_LOG_DIR/$tag"
log="$HCP_WORKFLOW_LOG_DIR/$tag"
export_arg="ALL,HCP_WORKFLOW_ROOT=$root,HCP_CONFIG=$cfg,HCP_MANIFEST=$manifest"
node_cpus="${HCP_PACKED_NODE_CPUS:-112}"
node_mem="${HCP_PACKED_NODE_MEM:-112G}"

submit() {
  local stage="$1" time="$2" dep="$3"
  local upper="${stage^^}"
  local pack_var="HCP_${upper}_PACK_SIZE" cpu_var="HCP_${upper}_CPUS_PER_SESSION"
  local max_var="HCP_${upper}_MAX_PARALLEL"
  local pack="${!pack_var:?$pack_var is required}"
  local per_cpu="${!cpu_var:?$cpu_var is required}"
  local parallel="${!max_var:-${HCP_PACKED_MAX_PARALLEL:-12}}"
  local chunks=$(( (n + pack - 1) / pack ))
  local -a args=(--parsable "--partition=$HCP_CPU_PARTITION"
    "--export=$export_arg,HCP_STAGE=$stage,HCP_PACK_SIZE=$pack,HCP_CPUS_PER_SESSION=$per_cpu,HCP_PACK_LOG_DIR=$log"
    "--array=1-$chunks%$parallel" "--job-name=hcp_pack_${stage}_${tag}"
    "--time=$time" "--cpus-per-task=$node_cpus" --nodes=1 --ntasks=1
    "--mem=$node_mem" "--output=$log/${stage}_node_%A_%a.log")
  [[ -z "${HCP_SLURM_ACCOUNT:-}" ]] || args+=("--account=$HCP_SLURM_ACCOUNT")
  [[ -z "${HCP_SLURM_QOS:-}" ]] || args+=("--qos=$HCP_SLURM_QOS")
  [[ -z "${HCP_SLURM_EXCLUDE:-}" ]] || args+=("--exclude=$HCP_SLURM_EXCLUDE")
  [[ "$dep" == - ]] || args+=("--dependency=$dep")
  sbatch "${args[@]}" "$root/slurm/node-task.sh"
}

j1=$(submit structural "${HCP_STRUCT_TIME:-12:00:00}" -)
j2=$(submit convert "${HCP_CONVERT_TIME:-01:00:00}" -)
j3=$(submit preeddy "${HCP_PREEDDY_TIME:-03:00:00}" "afterany:$j2")
j4=$(submit eddy "${HCP_EDDY_TIME:-12:00:00}" "afterany:$j3")
j5=$(submit posteddy "${HCP_POSTEDDY_TIME:-03:00:00}" "afterany:$j4:$j1")
j6=$(submit fmri "${HCP_FMRI_TIME:-08:00:00}" "afterany:$j1:$j2")
j7=$(submit icafix "${HCP_ICAFIX_TIME:-08:00:00}" "afterany:$j6")
j8=$(submit msmall "${HCP_MSMALL_TIME:-04:00:00}" "afterany:$j7")
j9=$(submit dedrift "${HCP_DEDRIFT_TIME:-04:00:00}" "afterany:$j8")
# QC gate: a session is usable only after hcp_qc_session.py passes.
j10=$(submit qc "${HCP_QC_TIME:-00:30:00}" "afterany:$j9:$j5")
printf 'stage\tjob_id\nstructural\t%s\nconvert\t%s\npreeddy\t%s\neddy\t%s\nposteddy\t%s\nfmri\t%s\nicafix\t%s\nmsmall\t%s\ndedrift\t%s\nqc\t%s\n' \
  "$j1" "$j2" "$j3" "$j4" "$j5" "$j6" "$j7" "$j8" "$j9" "$j10" | tee "$log/submission.tsv"

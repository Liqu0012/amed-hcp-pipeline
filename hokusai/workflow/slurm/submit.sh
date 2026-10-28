#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/bin/common.sh"
cfg=$(readlink -f "${1:?Usage: submit.sh CONFIG MANIFEST TAG}")
manifest=$(readlink -f "${2:?manifest required}")
tag="${3:?tag required}"
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe tag" >&2; exit 2; }
load_site "$cfg"
bash "$root/bin/preflight.sh" "$cfg" "$manifest"
n=$(awk 'NF {n++} END {print n+0}' "$manifest")
mkdir -p "$HCP_WORKFLOW_LOG_DIR/$tag"
log="$HCP_WORKFLOW_LOG_DIR/$tag"
export_arg="ALL,HCP_WORKFLOW_ROOT=$root,HCP_CONFIG=$cfg,HCP_MANIFEST=$manifest"

submit() {
  local stage="$1" partition="$2" time="$3" cpus="$4" mem="$5" dep="$6"
  local stage_upper="${stage^^}"
  local parallel_var="HCP_${stage_upper}_MAX_PARALLEL"
  local parallel="${!parallel_var:-${HCP_MAX_PARALLEL:-20}}"
  local -a args=(--parsable "--partition=$partition"
    "--export=$export_arg,HCP_STAGE=$stage" "--array=1-$n%$parallel"
    "--job-name=hcp_${stage}_${tag}" "--time=$time" "--cpus-per-task=$cpus"
    --nodes=1 --ntasks=1 "--output=$log/${stage}_%A_%a.log")
  [[ -z "${HCP_SLURM_ACCOUNT:-}" ]] || args+=("--account=$HCP_SLURM_ACCOUNT")
  [[ -z "${HCP_SLURM_QOS:-}" ]] || args+=("--qos=$HCP_SLURM_QOS")
  [[ "$mem" == - ]] || args+=("--mem=$mem")
  [[ "$dep" == - ]] || args+=("--dependency=$dep")
  sbatch "${args[@]}" "$root/slurm/task.sh"
}

initial_dep="${HCP_INITIAL_DEPENDENCY:--}"
j1=$(submit structural "$HCP_CPU_PARTITION" "${HCP_STRUCT_TIME:-12:00:00}" "${HCP_STRUCT_CPUS:-16}" "${HCP_STRUCT_MEM:-64G}" "$initial_dep")
j2=$(submit convert "$HCP_CPU_PARTITION" "${HCP_CONVERT_TIME:-01:00:00}" "${HCP_CONVERT_CPUS:-8}" "${HCP_CONVERT_MEM:-32G}" "$initial_dep")
j3=$(submit preeddy "$HCP_CPU_PARTITION" "${HCP_PREEDDY_TIME:-03:00:00}" "${HCP_PREEDDY_CPUS:-16}" "${HCP_PREEDDY_MEM:-64G}" "aftercorr:$j2")
j4=$(submit eddy "$HCP_CPU_PARTITION" "${HCP_EDDY_TIME:-12:00:00}" "${HCP_EDDY_CPUS:-112}" "${HCP_EDDY_MEM:-112G}" "aftercorr:$j3")
# PostEddy consumes both Eddy products and structural white surfaces.
j5=$(submit posteddy "$HCP_CPU_PARTITION" "${HCP_POSTEDDY_TIME:-03:00:00}" "${HCP_POSTEDDY_CPUS:-16}" "${HCP_POSTEDDY_MEM:-64G}" "aftercorr:$j4:$j1")
# fMRI is independent of diffusion but needs structural and converted fMRI inputs.
j6=$(submit fmri "$HCP_CPU_PARTITION" "${HCP_FMRI_TIME:-08:00:00}" "${HCP_FMRI_CPUS:-32}" "${HCP_FMRI_MEM:-64G}" "aftercorr:$j1:$j2")
j7=$(submit icafix "$HCP_CPU_PARTITION" "${HCP_ICAFIX_TIME:-08:00:00}" "${HCP_ICAFIX_CPUS:-32}" "${HCP_ICAFIX_MEM:-64G}" "aftercorr:$j6")
j8=$(submit msmall "$HCP_CPU_PARTITION" "${HCP_MSMALL_TIME:-04:00:00}" "${HCP_MSMALL_CPUS:-32}" "${HCP_MSMALL_MEM:-64G}" "aftercorr:$j7")
j9=$(submit dedrift "$HCP_CPU_PARTITION" "${HCP_DEDRIFT_TIME:-04:00:00}" "${HCP_DEDRIFT_CPUS:-32}" "${HCP_DEDRIFT_MEM:-64G}" "aftercorr:$j8")
# QC gate: a session is usable only after hcp_qc_session.py passes.
j10=$(submit qc "$HCP_CPU_PARTITION" "${HCP_QC_TIME:-00:30:00}" "${HCP_QC_CPUS:-2}" "${HCP_QC_MEM:-8G}" "aftercorr:$j9:$j5")
printf 'stage\tjob_id\nstructural\t%s\nconvert\t%s\npreeddy\t%s\neddy\t%s\nposteddy\t%s\nfmri\t%s\nicafix\t%s\nmsmall\t%s\ndedrift\t%s\nqc\t%s\n' "$j1" "$j2" "$j3" "$j4" "$j5" "$j6" "$j7" "$j8" "$j9" "$j10" | tee "$log/submission.tsv"

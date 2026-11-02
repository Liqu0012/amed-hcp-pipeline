#!/usr/bin/env bash
# Submit a held canary and dependent production chains. Release the canary only
# after release-image.py verifies the complete SIF. Old jobs must drain first.
set -Eeuo pipefail
cfg=$(readlink -f "${1:?CONFIG required}"); n=${2:-2}
[[ $n =~ ^[1-9][0-9]*$ ]] || exit 2
set -a; source "$cfg"; set +a
root=${L4N_ROOT:?}; Q=${HCP_NODE_QUEUE_DIR:?}
mkdir -p "$Q"
[[ ! -e "$Q/migration.jobs" ]] || { echo "Migration already submitted: $Q/migration.jobs" >&2; exit 2; }
[[ ! -e "$Q/STOP" ]] || { echo "New queue STOP present; refusing submission" >&2; exit 2; }
IFS=$'\t' read -r session archive < "$(dirname "$HCP_NODE_MANIFEST")/canary.tsv"
[[ -n "$session" && -n "$archive" ]] || exit 2
deps=$(squeue -h -u "$(id -un)" -o '%i|%T|%j' | \
  awk -F'|' '$2 ~ /^(RUNNING|COMPLETING)$/ && $3 ~ /^(hcp_node|hcp_stage1|hcp_stage2|hcp_stage3)$/ {print $1}' | paste -sd: -)
args=(--parsable -p "$HCP_NODE_PARTITION" --nodes=1 --ntasks=1 \
  "--cpus-per-task=$HCP_NODE_CPUS" "--mem=$HCP_NODE_MEM" "--time=$HCP_NODE_TIME" \
  "--export=ALL,HCP_WORKFLOW_ROOT=$root")
[[ -z ${HCP_SLURM_ACCOUNT:-} ]] || args+=("--account=$HCP_SLURM_ACCOUNT")
[[ -z ${HCP_SLURM_QOS:-} ]] || args+=("--qos=$HCP_SLURM_QOS")
[[ -z ${HCP_SLURM_EXCLUDE:-} ]] || args+=("--exclude=$HCP_SLURM_EXCLUDE")
dep_arg=(); [[ -z "$deps" ]] || dep_arg=("--dependency=afterany:$deps")
canary=$(sbatch "${args[@]}" --hold "${dep_arg[@]}" --job-name=hcp_l4n_canary \
  --output="$HCP_WORKFLOW_LOG_DIR/canary_%j.log" \
  "$root/slurm/canary.sbatch" "$cfg" "$session" "$archive")
canary=${canary%%;*}
printf 'CANARY=%s\nOLD_RUNNING=%s\n' "$canary" "$deps" > "$Q/migration.jobs"
for ((i=0;i<n;i++)); do
  job=$(sbatch "${args[@]}" "--dependency=afterok:$canary" --job-name=hcp_l4n_node \
    --output="$Q/worker_%j.out" "$root/slurm/hcp_node_pipeline.sh" worker "$cfg")
  printf 'PRODUCTION=%s\n' "${job%%;*}" >> "$Q/migration.jobs"
done
cat "$Q/migration.jobs"

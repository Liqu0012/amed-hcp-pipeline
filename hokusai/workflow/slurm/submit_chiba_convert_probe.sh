#!/usr/bin/env bash
set -Eeuo pipefail

root=/home/ziqing/hcp-portable-workflow
cfg="$root/config/hokusai.env"
manifest=/home/ziqing/hcp_manifests/chibau_probe.tsv
log=/home/ziqing/hcp_workflow_logs/chibau_convert_probe
probe_session="${CHIBA_PROBE_SESSION:-}"
if [[ -n "$probe_session" ]]; then
  awk -F '\t' -v session="$probe_session" '$1 == session {print; found=1} END {exit !found}' \
    /home/ziqing/hcp_manifests/chibau_full.tsv > "$manifest"
else
  head -n 1 /home/ziqing/hcp_manifests/chibau_full.tsv > "$manifest"
fi
mkdir -p "$log"

job=$(sbatch --parsable --partition=mpc --account=rb240007 --qos=normal \
  --array=1-1 --job-name=hcp_convert_chibau_probe --time=01:00:00 \
  --cpus-per-task=4 --nodes=1 --ntasks=1 --mem=16G \
  --export="ALL,HCP_WORKFLOW_ROOT=$root,HCP_CONFIG=$cfg,HCP_MANIFEST=$manifest,HCP_STAGE=convert" \
  --output="$log/convert_%A_%a.log" "$root/slurm/task.sh")
printf 'convert=%s\n' "$job"
squeue -j "$job" -o '%i|%j|%T|%R'

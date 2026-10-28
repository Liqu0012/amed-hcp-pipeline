#!/usr/bin/env bash
set -Eeuo pipefail

root=/home/ziqing/hcp-portable-workflow
cfg="$root/config/hokusai.env"
manifest=/home/ziqing/hcp_manifests/smoke_grouped.tsv
session=/home/ziqing/AMED/hcp_study/SWA_Skyraf_HARP_0699_001
log=/home/ziqing/hcp_workflow_logs/diffusion_cpu_probe
test -s "$session/.hcp_convert_complete.ok"
mkdir -p "$log"
export_args="ALL,HCP_WORKFLOW_ROOT=$root,HCP_CONFIG=$cfg,HCP_MANIFEST=$manifest"

jpre=$(sbatch --parsable --partition=mpc --account=rb240007 --qos=normal \
  --array=1-1 --job-name=hcp_preeddy_cpu_probe --time=03:00:00 \
  --cpus-per-task=112 --nodes=1 --ntasks=1 --mem=112G \
  --export="$export_args,HCP_STAGE=preeddy" \
  --output="$log/preeddy_%A_%a.log" "$root/slurm/task.sh")

jeddy=$(sbatch --parsable --partition=mpc --account=rb240007 --qos=normal \
  --array=1-1 --job-name=hcp_eddy_cpu_probe --time=12:00:00 \
  --cpus-per-task=112 --nodes=1 --ntasks=1 --mem=112G \
  --dependency="aftercorr:$jpre" \
  --export="$export_args,HCP_STAGE=eddy" \
  --output="$log/eddy_%A_%a.log" "$root/slurm/task.sh")

printf 'preeddy=%s\neddy=%s\n' "$jpre" "$jeddy"
squeue -j "$jpre,$jeddy" -o '%i|%j|%T|%R'

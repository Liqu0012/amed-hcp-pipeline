#!/usr/bin/env bash
set -Eeuo pipefail

site="${1:?Usage: submit_convert_probe.sh SITE FULL_MANIFEST [SESSION]}"
full_manifest="${2:?Usage: submit_convert_probe.sh SITE FULL_MANIFEST [SESSION]}"
probe_session="${3:-}"

[[ "$site" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe site name: $site" >&2; exit 2; }
[[ -s "$full_manifest" ]] || { echo "Missing manifest: $full_manifest" >&2; exit 2; }

root=/home/ziqing/hcp-portable-workflow
cfg="${HCP_PROBE_CONFIG:-$root/config/hokusai.env}"
manifest="/home/ziqing/hcp_manifests/${site}_probe.tsv"
tag="${site}_convert_probe_$(date +%Y%m%d_%H%M%S)"
log="/home/ziqing/hcp_workflow_logs/$tag"

if [[ -n "$probe_session" ]]; then
  awk -F '\t' -v session="$probe_session" '$1 == session {print; found=1} END {exit !found}' \
    "$full_manifest" > "$manifest"
else
  head -n 1 "$full_manifest" > "$manifest"
fi
mkdir -p "$log"

job=$(sbatch --parsable --partition=mpc --account=rb240007 --qos=normal \
  --exclude=bwmpc049,bwmpc253 \
  --array=1-1 --job-name="hcp_convert_${site}_probe" --time=01:00:00 \
  --cpus-per-task=4 --nodes=1 --ntasks=1 --mem=16G \
  --export="ALL,HCP_WORKFLOW_ROOT=$root,HCP_CONFIG=$cfg,HCP_MANIFEST=$manifest,HCP_STAGE=convert" \
  --output="$log/convert_%A_%a.log" "$root/slurm/task.sh")
printf 'tag=%s\nmanifest=%s\nconvert=%s\n' "$tag" "$manifest" "$job"
squeue -j "$job" -o '%i|%j|%T|%R'

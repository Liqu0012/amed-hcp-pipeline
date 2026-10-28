#!/usr/bin/env bash
set -Eeuo pipefail

mode="${1:?Usage: release-site-batch.sh MODE SITE MANIFEST}"
site="${2:?Usage: release-site-batch.sh MODE SITE MANIFEST}"
manifest="${3:?Usage: release-site-batch.sh MODE SITE MANIFEST}"
[[ "$mode" == harp || "$mode" == t1only ]] || { echo "Invalid mode: $mode" >&2; exit 2; }
[[ "$site" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe site: $site" >&2; exit 2; }
[[ -s "$manifest" ]] || { echo "Missing manifest: $manifest" >&2; exit 2; }

root=/home/ziqing/hcp-portable-workflow
study=/home/ziqing/AMED/hcp_study
session=$(awk -F '\t' 'NF {print $1; exit}' "$manifest")
if [[ "$mode" == harp ]]; then
  state_dir="/home/ziqing/hcp_workflow_logs/${site}_controller"
  marker="$study/$session/.hcp_convert_complete.ok"
  cfg="$root/config/hokusai_packed.env"
  tag="${site}_full_$(date +%Y%m%d_%H%M%S)"
else
  state_dir="/home/ziqing/hcp_workflow_logs/${site}_t1only_controller"
  marker="$study/$session/.hcp_structural_complete.ok"
  cfg="$root/config/hokusai_t1only_packed.env"
  tag="${site}_t1only_full_$(date +%Y%m%d_%H%M%S)"
fi
result="$state_dir/full_submission.txt"
mkdir -p "$state_dir"

exec 9>"$state_dir/release.lock"
flock -n 9 || { echo "Release already running for $site"; exit 0; }
[[ ! -s "$result" ]] || { cat "$result"; exit 0; }
if [[ ! -s "$marker" ]]; then
  printf 'Probe validation failed: marker not found: %s\n' "$marker" | tee "$state_dir/validation_failed.txt"
  exit 4
fi

if [[ "$mode" == harp ]]; then
  bash "$root/slurm/submit-packed.sh" "$cfg" "$manifest" "$tag" > "$result"
else
  bash "$root/slurm/submit-packed-structural-only.sh" "$cfg" "$manifest" "$tag" > "$result"
fi
cat "$result"

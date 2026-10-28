#!/usr/bin/env bash
set -Eeuo pipefail

site="${1:?Usage: register_harp_site.sh SITE DATA_DIR}"
data_dir="${2:?Usage: register_harp_site.sh SITE DATA_DIR}"
[[ "$site" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe site: $site" >&2; exit 2; }
[[ -d "$data_dir" ]] || { echo "Missing data directory: $data_dir" >&2; exit 2; }

root=/home/ziqing/hcp-portable-workflow
manifest="/home/ziqing/hcp_manifests/${site}_full.tsv"
state_dir="/home/ziqing/hcp_workflow_logs/${site}_controller"
probe_result="$state_dir/probe_submission.txt"
full_result="$state_dir/full_submission.txt"
mkdir -p "$state_dir"

exec 9>"$state_dir/controller.lock"
flock -n 9 || { echo "Controller already running for $site"; exit 0; }
[[ ! -s "$full_result" ]] || { cat "$full_result"; exit 0; }

bash "$root/bin/build-manifest.sh" "$manifest" "$data_dir"
if [[ ! -s "$probe_result" ]]; then
  bash "$root/slurm/submit-convert-probe.sh" "$site" "$manifest" > "$probe_result"
fi
probe_job=$(awk -F= '$1 == "convert" {print $2}' "$probe_result" | tail -1)
[[ "$probe_job" =~ ^[0-9]+ ]] || { echo "Cannot parse probe job from $probe_result" >&2; exit 1; }

tag="${site}_full_$(date +%Y%m%d_%H%M%S)"
HCP_INITIAL_DEPENDENCY="afterok:$probe_job" \
  bash "$root/slurm/submit.sh" "$root/config/hokusai.env" "$manifest" "$tag" > "$full_result"

printf 'site=%s\nmode=full-harp\nmanifest=%s\nprobe_job=%s\n' \
  "$site" "$manifest" "$probe_job"
cat "$full_result"

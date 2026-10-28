#!/usr/bin/env bash
set -Eeuo pipefail

site="${1:?Usage: register_t1only_site.sh SITE DATA_DIR}"
data_dir="${2:?Usage: register_t1only_site.sh SITE DATA_DIR}"
[[ "$site" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe site: $site" >&2; exit 2; }
[[ -d "$data_dir" ]] || { echo "Missing data directory: $data_dir" >&2; exit 2; }

root=/home/ziqing/hcp-portable-workflow
manifest="/home/ziqing/hcp_manifests/${site}_full.tsv"
probe_manifest="/home/ziqing/hcp_manifests/${site}_t1_probe.tsv"
state_dir="/home/ziqing/hcp_workflow_logs/${site}_t1only_controller"
probe_result="$state_dir/probe_submission.txt"
full_result="$state_dir/full_submission.txt"
mkdir -p "$state_dir"

exec 9>"$state_dir/controller.lock"
flock -n 9 || { echo "Controller already running for $site"; exit 0; }
[[ ! -s "$full_result" ]] || { cat "$full_result"; exit 0; }

bash "$root/bin/build-manifest.sh" "$manifest" "$data_dir"
head -n 1 "$manifest" > "$probe_manifest"
if [[ ! -s "$probe_result" ]]; then
  probe_tag="${site}_t1_probe_$(date +%Y%m%d_%H%M%S)"
  bash "$root/slurm/submit-structural-only.sh" \
    "$root/config/hokusai_t1only.env" "$probe_manifest" "$probe_tag" > "$probe_result"
fi
probe_job=$(awk -F '\t' '$1 == "structural" {print $2}' "$probe_result" | tail -1)
[[ "$probe_job" =~ ^[0-9]+ ]] || { echo "Cannot parse probe job from $probe_result" >&2; exit 1; }

tag="${site}_t1only_full_$(date +%Y%m%d_%H%M%S)"
HCP_INITIAL_DEPENDENCY="afterok:$probe_job" \
  bash "$root/slurm/submit-structural-only.sh" \
    "$root/config/hokusai_t1only.env" "$manifest" "$tag" > "$full_result"

printf 'site=%s\nmode=t1-only\nmanifest=%s\nprobe_job=%s\n' \
  "$site" "$manifest" "$probe_job"
cat "$full_result"

#!/usr/bin/env bash
set -Eeuo pipefail

site="${1:?Usage: release_fmri_batch.sh SITE MANIFEST}"
manifest="${2:?Usage: release_fmri_batch.sh SITE MANIFEST}"
root=/home/ziqing/hcp-portable-workflow
study=/home/ziqing/AMED/hcp_study
session=$(awk -F '\t' 'NF {print $1; exit}' "$manifest")
state_dir="/home/ziqing/hcp_workflow_logs/${site}_controller"
marker="$study/$session/.hcp_convert_complete.ok"
result="$state_dir/fmri_full_submission.txt"
tag="${site}_fmri_packed_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$state_dir"

[[ ! -s "$result" ]] || { cat "$result"; exit 0; }
if [[ ! -s "$marker" ]]; then
  echo "fMRI-mode validation failed: marker not found: $marker" >&2
  exit 4
fi
bash "$root/slurm/submit-packed-fmri-only.sh" \
  "$root/config/hokusai_fmri_packed.env" "$manifest" "$tag" > "$result"
cat "$result"

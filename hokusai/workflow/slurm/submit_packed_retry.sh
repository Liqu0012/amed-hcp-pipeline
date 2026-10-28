#!/usr/bin/env bash
set -Eeuo pipefail

manifest="${1:?Usage: submit_packed_retry.sh MANIFEST TAG}"
tag="${2:?Usage: submit_packed_retry.sh MANIFEST TAG}"
root=/home/ziqing/hcp-portable-workflow
[[ -s "$manifest" ]] || { echo "Missing manifest: $manifest" >&2; exit 2; }
[[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe tag: $tag" >&2; exit 2; }

result="/home/ziqing/hcp_workflow_logs/${tag}_submission.txt"
[[ ! -s "$result" ]] || { cat "$result"; exit 0; }
bash "$root/slurm/submit-packed.sh" \
  "$root/config/hokusai_packed.env" "$manifest" "$tag" > "$result"
cat "$result"

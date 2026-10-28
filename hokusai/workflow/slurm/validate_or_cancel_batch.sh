#!/usr/bin/env bash
set -Eeuo pipefail

marker="${1:?Usage: validate_or_cancel_batch.sh MARKER JOB_ID...}"
shift
(($# > 0)) || { echo "At least one dependent job ID is required" >&2; exit 2; }
for job in "$@"; do
  [[ "$job" =~ ^[0-9]+$ ]] || { echo "Invalid job ID: $job" >&2; exit 2; }
done

if [[ -s "$marker" ]]; then
  echo "Validation marker present; dependent batch remains active: $marker"
  exit 0
fi

echo "Validation marker missing; cancelling dependent jobs: $*" >&2
scancel "$@"
exit 4

#!/usr/bin/env bash
set -Eeuo pipefail

root="${HCP_WORKFLOW_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
: "${HCP_MANIFEST:?HCP_MANIFEST required}"
: "${HCP_STAGE:?HCP_STAGE required}"
: "${HCP_PACK_SIZE:?HCP_PACK_SIZE required}"
: "${HCP_CPUS_PER_SESSION:?HCP_CPUS_PER_SESSION required}"
: "${HCP_PACK_LOG_DIR:?HCP_PACK_LOG_DIR required}"
: "${SLURM_ARRAY_TASK_ID:?array task ID required}"

[[ "$HCP_PACK_SIZE" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid pack size" >&2; exit 2; }
[[ "$HCP_CPUS_PER_SESSION" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid per-session CPU count" >&2; exit 2; }
n=$(awk 'NF {n++} END {print n+0}' "$HCP_MANIFEST")
start=$(( (SLURM_ARRAY_TASK_ID - 1) * HCP_PACK_SIZE + 1 ))
end=$(( start + HCP_PACK_SIZE - 1 ))
(( end <= n )) || end=$n
(( start <= n )) || { echo "Chunk starts beyond manifest: $start > $n" >&2; exit 2; }

mkdir -p "$HCP_PACK_LOG_DIR"
echo "Node pack stage=$HCP_STAGE chunk=$SLURM_ARRAY_TASK_ID rows=$start-$end pack=$HCP_PACK_SIZE cpus_per_session=$HCP_CPUS_PER_SESSION host=$(hostname)"

pids=()
rows=()
sessions=()
for ((row=start; row<=end; row++)); do
  session=$(sed -n "${row}p" "$HCP_MANIFEST" | cut -f1)
  [[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe session at row $row: $session" >&2; exit 2; }
  child_log="$HCP_PACK_LOG_DIR/${HCP_STAGE}_${SLURM_ARRAY_JOB_ID:-$SLURM_JOB_ID}_${SLURM_ARRAY_TASK_ID}_row${row}_${session}.log"
  (
    export SLURM_ARRAY_TASK_ID="$row"
    export SLURM_CPUS_PER_TASK="$HCP_CPUS_PER_SESSION"
    export HCP_CPUS_PER_SESSION
    export OMP_NUM_THREADS="$HCP_CPUS_PER_SESSION"
    export MKL_NUM_THREADS="$HCP_CPUS_PER_SESSION"
    export OPENBLAS_NUM_THREADS="$HCP_CPUS_PER_SESSION"
    export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$HCP_CPUS_PER_SESSION"
    bash "$root/slurm/task.sh"
  ) >"$child_log" 2>&1 &
  pids+=("$!")
  rows+=("$row")
  sessions+=("$session")
done

failed=0
for i in "${!pids[@]}"; do
  if wait "${pids[$i]}"; then
    echo "OK row=${rows[$i]} session=${sessions[$i]}"
  else
    rc=$?
    echo "FAILED row=${rows[$i]} session=${sessions[$i]} exit=$rc" >&2
    failed=1
  fi
done
exit "$failed"

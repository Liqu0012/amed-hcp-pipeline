#!/bin/bash
# Inspect / widen the live stage1 semaphores without restarting the job.
#
# run_stage1_pre_eddy.sbatch implements its ENTRY (fd 3) and POST (fd 4) limits
# as counting semaphores over an unlinked FIFO: N newlines are written at
# startup, each worker does `read -u 3` to take a slot and `echo >&3` to give
# it back. The cap is therefore just "how many tokens exist" -- writing extra
# tokens into the same FIFO raises the limit live. The FIFO is unlinked but its
# inode is still open on every descendant's fd 3/4, so /proc/<pid>/fd/3 reaches
# it. Tokens are never destroyed, so this is additive and cannot be undone
# (lowering a limit would mean draining tokens, which would starve workers).
#
# Usage:
#   sem_tool.sh status
#   sem_tool.sh add entry N
#   sem_tool.sh add post  N
set -uo pipefail

find_main() {
  # the batch shell itself: has fd 3, and its parent is slurmstepd
  for pid in $(pgrep -u "$USER" -f 'slurm_script' 2>/dev/null); do
    [ -e "/proc/$pid/fd/3" ] || continue
    local ppid pcomm
    ppid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    pcomm=$(cat "/proc/$ppid/comm" 2>/dev/null)
    case "$pcomm" in slurmstepd*) echo "$pid"; return 0;; esac
  done
  # fallback: any descendant shares the same FIFO inode
  for pid in $(pgrep -u "$USER" -f 'slurm_script' 2>/dev/null); do
    [ -e "/proc/$pid/fd/3" ] && { echo "$pid"; return 0; }
  done
  return 1
}

count_active() {
  # subjects currently holding an ENTRY slot: one of the entry-phase pipelines
  local entry post
  entry=$(pgrep -c -f 'PreFreeSurferPipeline.sh|FreeSurferPipeline.sh|DiffPreprocPipeline_PreEddy.sh' 2>/dev/null || echo 0)
  post=$(pgrep -c -f 'PostFreeSurferPipeline.sh' 2>/dev/null || echo 0)
  echo "$entry $post"
}

H=$(hostname)
MAIN=$(find_main) || { echo "$H: no batch shell found"; exit 1; }

case "${1:-status}" in
  status)
    read -r e p < <(count_active)
    avail=$(awk '/^MemAvailable/{printf "%.0f", $2/1048576}' /proc/meminfo)
    load=$(cut -d' ' -f1 /proc/loadavg)
    printf "%-9s main=%-8s entry_procs=%-4s post_procs=%-4s load=%-7s avail=%sG\n" \
      "$H" "$MAIN" "$e" "$p" "$load" "$avail"
    ;;
  add)
    which=${2:?entry|post}; n=${3:?count}
    case "$which" in
      entry) fd=3 ;;
      post)  fd=4 ;;
      *) echo "usage: $0 add entry|post N" >&2; exit 2 ;;
    esac
    target="/proc/$MAIN/fd/$fd"
    [ -e "$target" ] || { echo "$H: $target missing"; exit 1; }
    for _ in $(seq 1 "$n"); do printf '\n' >> "$target" || { echo "$H: write failed"; exit 1; }; done
    printf "%-9s added %s tokens to %s (fd %s)\n" "$H" "$n" "$which" "$fd"
    ;;
  *)
    echo "usage: $0 status | add entry|post N" >&2; exit 2 ;;
esac

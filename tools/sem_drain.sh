#!/bin/bash
# Lower a live semaphore cap by consuming tokens. Writing to the FIFO raises
# the cap; reading one out and discarding it lowers the cap permanently
# (workers still return their own tokens when they finish). Non-blocking, so
# it stops early rather than hanging when the semaphore is already drained.
set -uo pipefail
which=${1:?entry|post}; want=${2:?count}
case "$which" in entry) fd=3;; post) fd=4;; *) echo "usage: $0 entry|post N" >&2; exit 2;; esac

main=""
for pid in $(pgrep -u "$USER" -f slurm_script 2>/dev/null); do
  [ -e "/proc/$pid/fd/$fd" ] || continue
  ppid=$(awk "/^PPid:/{print \$2}" "/proc/$pid/status" 2>/dev/null)
  case "$(cat /proc/$ppid/comm 2>/dev/null)" in slurmstepd*) main=$pid; break;; esac
done
[ -n "$main" ] || { echo "$(hostname): no batch shell"; exit 1; }

got=0
exec 9<"/proc/$main/fd/$fd" || { echo "$(hostname): cannot open fd $fd"; exit 1; }
for ((i=0; i<want; i++)); do
  if read -t 2 -u 9 _; then got=$((got+1)); else break; fi
done
exec 9<&-
printf "%-9s drained %s/%s tokens from %s\n" "$(hostname)" "$got" "$want" "$which"

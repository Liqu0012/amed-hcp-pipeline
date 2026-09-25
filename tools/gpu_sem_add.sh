#!/bin/bash
# Raise a running stage2 job's per-GPU concurrency by injecting tokens.
#
# The GPU semaphore is an unlinked FIFO on the batch shell's fd 3 holding one
# token per slot, the token being the GPU index the subject will be pinned to.
# Workers take one with `read -u 3` and return it with `echo "$id" >&3`, so
# extra newline-terminated tokens raise the cap live.
#
# Two of our jobs share gnode03, so the batch shell is identified by the
# SLURM_JOB_ID in its own environment, not by name.
#
# Usage: gpu_sem_add.sh JOBID NUM_GPUS EXTRA_PER_GPU
set -uo pipefail
job=${1:?jobid}; ngpu=${2:?num_gpus}; extra=${3:?extra per gpu}

main=""
for pid in $(pgrep -u "$USER" -f 'slurm_script' 2>/dev/null); do
  [ -e "/proc/$pid/fd/3" ] || continue
  if tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -qx "SLURM_JOB_ID=$job"; then
    ppid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    case "$(cat /proc/$ppid/comm 2>/dev/null)" in
      slurmstepd*) main=$pid; break ;;
    esac
  fi
done
[ -n "$main" ] || { echo "job $job: batch shell not found on $(hostname)"; exit 1; }

target="/proc/$main/fd/3"
[ -e "$target" ] || { echo "job $job: $target missing"; exit 1; }

for ((g = 0; g < ngpu; g++)); do
  for ((k = 0; k < extra; k++)); do
    printf '%s\n' "$g" >> "$target" || { echo "job $job: write failed"; exit 1; }
  done
done
echo "job $job on $(hostname): added $extra tokens x $ngpu GPUs = $((extra * ngpu)) slots (pid $main)"

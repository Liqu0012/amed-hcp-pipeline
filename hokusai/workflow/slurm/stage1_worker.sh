#!/usr/bin/env bash
# Rolling stage-1 worker: one whole node, keeps picking up new uploads.
#
# Stage 1 = structural (convert + PreFreeSurfer + FreeSurfer + PostFreeSurfer)
# followed by PreEddy (skipped when the selection found no usable dMRI).
#
# Each worker scans HCP_SOURCE_DIRS for *.zip, skips sessions in
# HCP_EXCLUDE_LIST or already finished, waits until an upload is complete
# (unchanged for HCP_UPLOAD_MIN_AGE_MIN minutes and `unzip -t` OK), claims it
# atomically (mkdir) and runs it. Several workers share the queue directory.
# At start it submits its own successor (afterany), so the node keeps working
# across the 3-day wall time; it stops claiming new sessions when less than
# HCP_WORKER_MARGIN_SEC remain. Create $QUEUE/STOP to end the chain.
#
# Session end states (in $HCP_STUDY/<session>/):
#   .stage1_complete   structural + PreEddy (or no dMRI) done
#   .stage1_blocked    input selection problems (.hcp_input_problems.txt)
#   .stage1_failed     a stage failed; see the log named inside. Remove to retry.
#
# Usage: sbatch [resources] stage1_worker.sh CONFIG
set -uo pipefail

cfg=$(readlink -f "${1:?Usage: stage1_worker.sh CONFIG}")
root="${HCP_WORKFLOW_ROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
[[ -s "$root/bin/run-stage.sh" ]] || root=$(cd "$(dirname "$cfg")/.." && pwd)
source "$root/bin/common.sh"
load_site "$cfg"
: "${HCP_SOURCE_DIRS:?HCP_SOURCE_DIRS (colon-separated) required}"
: "${SLURM_JOB_ID:?run under Slurm}"

SLOTS="${HCP_WORKER_SLOTS:-24}"
THREADS="${HCP_WORKER_THREADS:-8}"
MARGIN="${HCP_WORKER_MARGIN_SEC:-50400}"
MIN_AGE="${HCP_UPLOAD_MIN_AGE_MIN:-30}"
POLL="${HCP_WORKER_POLL_SEC:-300}"
INCLUDE="${HCP_INCLUDE_REGEX:-_HARP_}"
EXCLUDE="${HCP_EXCLUDE_LIST:-/dev/null}"
Q="${HCP_QUEUE_DIR:-$HCP_WORKFLOW_LOG_DIR/stage1_queue}"
mkdir -p "$Q/claims" "$Q/verified" "$Q/sessions" "$HCP_STUDY"
log() { printf '%s [%s %s] %s\n' "$(date -Is)" "$(hostname)" "$SLURM_JOB_ID" "$*"; }

[[ -e "$Q/STOP" ]] && { log "STOP file present; exiting without work or successor"; exit 0; }
[[ -s "$HCP_IMAGE" ]] || { log "container missing: $HCP_IMAGE"; exit 2; }

# Successor first, so a hard wall-time kill cannot break the chain.
if [[ "${HCP_WORKER_RESUBMIT:-1}" == 1 ]]; then
  succ=$(sbatch --parsable --dependency="afterany:$SLURM_JOB_ID" \
    --job-name="$SLURM_JOB_NAME" --partition="$SLURM_JOB_PARTITION" \
    --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-192}" \
    --mem="${HCP_WORKER_MEM:-1500G}" --time="${HCP_WORKER_TIME:-3-00:00:00}" \
    --output="$Q/worker_%j.out" \
    --export="ALL,HCP_WORKFLOW_ROOT=$root" "$root/slurm/stage1_worker.sh" "$cfg") \
    && log "successor $succ submitted" || log "WARNING: successor submission failed"
fi

end_epoch=$(date -d "$(squeue -h -j "$SLURM_JOB_ID" -o %e)" +%s 2>/dev/null || echo $(( $(date +%s) + 259200 )))
log "start slots=$SLOTS threads=$THREADS end=$(date -d @"$end_epoch" -Is) sources=$HCP_SOURCE_DIRS"

# A job counts as dead only when Slurm says so. If squeue itself fails (controller
# busy or restarting), the job is taken as alive, so its sessions are not taken over.
alive() {
  local out rc
  [[ -n "$1" ]] || return 1
  out=$(squeue -h -j "$1" -o %T 2>&1); rc=$?
  if (( rc == 0 )); then
    [[ -n "$out" && ! "$out" =~ ^(COMPLETED|CANCELLED|FAILED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|PREEMPTED|BOOT_FAIL|DEADLINE) ]]
    return
  fi
  [[ "$out" == *"Invalid job id"* ]] && return 1
  return 0
}

finished() {
  local d="$HCP_STUDY/$1"
  [[ -e "$d/.stage1_complete" || -e "$d/.stage1_failed" || -e "$d/.stage1_blocked" ]]
}

# Upload complete: old enough and a valid zip. Cached by size+mtime.
upload_ready() {
  local z="$1" s="$2" sig
  [[ -n "$(find "$z" -maxdepth 0 -mmin +"$MIN_AGE" 2>/dev/null)" ]] || return 1
  sig=$(stat -c '%s %Y' "$z")
  [[ -s "$Q/verified/$s" && "$(cat "$Q/verified/$s")" == "$sig" ]] && return 0
  unzip -tqq "$z" >/dev/null 2>&1 || return 1
  printf '%s' "$sig" > "$Q/verified/$s"
}

claim() {
  local s="$1" c="$Q/claims/$1" owner
  if mkdir "$c" 2>/dev/null; then
    echo "$SLURM_JOB_ID" > "$c/job"; return 0
  fi
  owner=$(cat "$c/job" 2>/dev/null || true)
  [[ -n "$owner" ]] && ! alive "$owner" || return 1
  # Take over a dead job's claim under one lock, and only if the claim still names
  # that job: two workers that both saw the dead owner cannot both win.
  (
    flock -w 120 9 || exit 1
    [[ "$(cat "$c/job" 2>/dev/null)" == "$owner" ]] || exit 1
    echo "$SLURM_JOB_ID" > "$c/job.$SLURM_JOB_ID" && mv -f -- "$c/job.$SLURM_JOB_ID" "$c/job"
  ) 9>"$Q/claims/.takeover.lock" || return 1
  return 0
}

process() {
  local s="$1" z="$2" d="$HCP_STUDY/$1" slog="$Q/sessions/$1.log" rc=0 stage
  export SLURM_SCRATCH="${HCP_SCRATCH_ROOT:-/tmp}/hcp-$SLURM_JOB_ID-$s"
  export OMP_NUM_THREADS="$THREADS" MKL_NUM_THREADS="$THREADS" OPENBLAS_NUM_THREADS="$THREADS"
  export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$THREADS" HCP_CPUS_PER_SESSION="$THREADS" SLURM_CPUS_PER_TASK="$THREADS"
  export SINGULARITYENV_LC_ALL=C SINGULARITYENV_LANG=C APPTAINERENV_LC_ALL=C APPTAINERENV_LANG=C
  mkdir -p "$SLURM_SCRATCH" "$d"
  {
    echo "=== $(date -Is) $s on $(hostname) job $SLURM_JOB_ID archive $z"
    # A FreeSurfer tree left by a killed job (no marker, no recon-all.error) is
    # moved aside so recon-all starts clean; nothing is deleted.
    if [[ -d "$d/T1w/$s" && ! -e "$d/.hcp_freesurfer_stage.ok" ]]; then
      mv "$d/T1w/$s" "$d/T1w/$s.interrupted-$(date +%Y%m%dT%H%M%S)"
    fi
    for stage in structural preeddy; do
      echo "=== $(date -Is) stage $stage"
      bash "$root/bin/run-stage.sh" "$cfg" "$stage" "$s" "$z" || { rc=$?; break; }
    done
  } >> "$slog" 2>&1
  rm -rf -- "$SLURM_SCRATCH"
  if ((rc == 0)); then
    printf 'completed=%s\njob=%s\n' "$(date -Is)" "$SLURM_JOB_ID" > "$d/.stage1_complete"
    log "COMPLETE $s"
  elif [[ -s "$d/.hcp_input_problems.txt" ]]; then
    printf 'rc=%s\nlog=%s\n' "$rc" "$slog" > "$d/.stage1_blocked"
    log "BLOCKED $s (input problems)"
  else
    printf 'rc=%s\nstage=%s\nlog=%s\njob=%s\n' "$rc" "$stage" "$slog" "$SLURM_JOB_ID" > "$d/.stage1_failed"
    log "FAILED $s rc=$rc stage=$stage"
  fi
  rm -rf -- "$Q/claims/$s"
}

declare -A excluded=()
while IFS= read -r x; do [[ -n "$x" ]] && excluded[$x]=1; done < "$EXCLUDE"

while :; do
  [[ -e "$Q/STOP" ]] && { log "STOP file: no new claims"; break; }
  (( end_epoch - $(date +%s) > MARGIN )) || { log "within margin of wall time: no new claims"; break; }
  running=$(jobs -rp | wc -l)
  launched=0
  if (( running < SLOTS )); then
    IFS=: read -r -a dirs <<< "$HCP_SOURCE_DIRS"
    while IFS= read -r z; do
      (( running < SLOTS )) || break
      s=$(basename "$z" .zip)
      [[ "$s" =~ ^[A-Za-z0-9._-]+$ && "$s" =~ $INCLUDE ]] || continue
      [[ -z "${excluded[$s]:-}" ]] || continue
      finished "$s" && continue
      [[ -d "$Q/claims/$s" ]] && alive "$(cat "$Q/claims/$s/job" 2>/dev/null)" && continue
      [[ -n "$(find "$z" -maxdepth 0 -mmin +"$MIN_AGE" 2>/dev/null)" ]] || continue
      # Claim before the (slow) zip test so workers never test the same file.
      claim "$s" || continue
      # Another worker may have finished the session between the check above and the claim.
      finished "$s" && { rm -rf -- "$Q/claims/$s"; continue; }
      if ! upload_ready "$z" "$s"; then
        rm -rf -- "$Q/claims/$s"; log "not ready (zip test failed, upload in progress?) $s"; continue
      fi
      if [[ "${HCP_WORKER_DRYRUN:-0}" == 1 ]]; then
        log "DRYRUN would process $s"; rm -rf -- "$Q/claims/$s"
        dry=$(( ${dry:-0} + 1 )); (( dry < ${HCP_DRYRUN_MAX:-3} )) && continue || break 2
      fi
      process "$s" "$z" &
      running=$((running + 1)); launched=$((launched + 1))
      log "CLAIM $s ($running/$SLOTS running)"
    done < <(find "${dirs[@]}" -maxdepth 1 -type f -name '*.zip' ! -name '.*' 2>/dev/null | sort)
  fi
  sleep "$POLL"
done

log "waiting for $(jobs -rp | wc -l) running sessions"
wait
log "worker done"

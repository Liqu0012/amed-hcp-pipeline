#!/usr/bin/env bash
# Rolling stage-3 worker: one whole node, keeps picking up sessions whose stage 1
# and stage 2 are complete.
#
# Stage 3 = fMRI (volume + surface, every run) -> multi-run ICA-FIX -> MSMAll ->
# DeDriftAndResample -> QC. Each stage script keeps its own completion marker
# (.hcp_fmri_<run>_complete.ok, .hcp_icafix_complete.ok, ...), so a session taken
# over after a killed job continues where it stopped. Sessions without usable
# rfMRI skip the fMRI stages with success (run-stage.sh) and still get QC.
#
# Each stage runs under a watchdog: it is killed and the session marked failed
# when it runs longer than HCP_STAGE3_<STAGE>_MAX_HOURS or its session log grows
# past HCP_STAGE3_LOG_MAX_GB (MSM on NaN input loops for hours and writes
# hundreds of GB of log without exiting).
#
# Like stage1_worker.sh: claims are atomic (mkdir) in $QUEUE/claims, several
# workers share the queue, each submits its own successor (afterany), and stops
# claiming when less than HCP_WORKER_MARGIN_SEC remain. Create $QUEUE/STOP to end
# the chain. When there is nothing to claim and nothing running for
# HCP_STAGE3_IDLE_EXIT_MIN minutes, the worker exits and holds its successor back
# by HCP_STAGE3_IDLE_DELAY_MIN, so an empty queue does not keep a node.
#
# Session end states (in $HCP_STUDY/<session>/):
#   .stage3_complete   all stage-3 steps done and QC PASS or REVIEW
#   .stage3_failed     a step failed, timed out or QC FAIL; see the log named inside. Remove to retry.
#
# Usage: sbatch [resources] stage3_worker.sh CONFIG
set -uo pipefail

cfg=$(readlink -f "${1:?Usage: stage3_worker.sh CONFIG}")
root="${HCP_WORKFLOW_ROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
[[ -s "$root/bin/run-stage.sh" ]] || root=$(cd "$(dirname "$cfg")/.." && pwd)
source "$root/bin/common.sh"
set +eE
load_site "$cfg"
: "${SLURM_JOB_ID:?run under Slurm}"

SLOTS="${HCP_WORKER_SLOTS:-24}"
THREADS="${HCP_WORKER_THREADS:-8}"
MARGIN="${HCP_WORKER_MARGIN_SEC:-43200}"
POLL="${HCP_WORKER_POLL_SEC:-120}"
IDLE_EXIT="${HCP_STAGE3_IDLE_EXIT_MIN:-60}"
IDLE_DELAY="${HCP_STAGE3_IDLE_DELAY_MIN:-120}"
LOG_MAX_KB=$(awk -v g="${HCP_STAGE3_LOG_MAX_GB:-5}" 'BEGIN{printf "%d", g*1024*1024}')
STAGES=(fmri icafix msmall dedrift qc)
declare -A MAXH=([fmri]=16 [icafix]=16 [msmall]=8 [dedrift]=4 [qc]=1)
for st in "${STAGES[@]}"; do v="HCP_STAGE3_${st^^}_MAX_HOURS"; MAXH[$st]="${!v:-${MAXH[$st]}}"; done
Q="${HCP_QUEUE_DIR:-$HCP_WORKFLOW_LOG_DIR/stage3_queue}"
mkdir -p "$Q/claims" "$Q/sessions"
log() { printf '%s [%s %s] %s\n' "$(date -Is)" "$(hostname)" "$SLURM_JOB_ID" "$*"; }

[[ -e "$Q/STOP" ]] && { log "STOP file present; exiting without work or successor"; exit 0; }
[[ -s "$HCP_IMAGE" ]] || { log "container missing: $HCP_IMAGE"; exit 2; }

succ=""
if [[ "${HCP_WORKER_RESUBMIT:-1}" == 1 ]]; then
  succ=$(sbatch --parsable --dependency="afterany:$SLURM_JOB_ID" \
    --job-name="$SLURM_JOB_NAME" --partition="$SLURM_JOB_PARTITION" \
    --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-192}" \
    --mem="${HCP_WORKER_MEM:-1500G}" --time="${HCP_WORKER_TIME:-3-00:00:00}" \
    --output="$Q/worker_%j.out" \
    --export="ALL,HCP_WORKFLOW_ROOT=$root" "$root/slurm/stage3_worker.sh" "$cfg") \
    && log "successor $succ submitted" || log "WARNING: successor submission failed"
fi

end_epoch=$(date -d "$(squeue -h -j "$SLURM_JOB_ID" -o %e)" +%s 2>/dev/null || echo $(( $(date +%s) + 259200 )))
log "start slots=$SLOTS threads=$THREADS end=$(date -d @"$end_epoch" -Is) max_hours=$(for st in "${STAGES[@]}"; do printf '%s:%s ' "$st" "${MAXH[$st]}"; done)log_max_gb=${HCP_STAGE3_LOG_MAX_GB:-5}"

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

ready() { local d="$HCP_STUDY/$1"; [[ -e "$d/.stage1_complete" && -e "$d/.stage2_complete" ]]; }
finished() { local d="$HCP_STUDY/$1"; [[ -e "$d/.stage3_complete" || -e "$d/.stage3_failed" ]]; }

claim() {
  local s="$1" c="$Q/claims/$1" owner
  if mkdir "$c" 2>/dev/null; then
    echo "$SLURM_JOB_ID" > "$c/job"; return 0
  fi
  owner=$(cat "$c/job" 2>/dev/null || true)
  [[ -n "$owner" ]] && ! alive "$owner" || return 1
  (
    flock -w 120 9 || exit 1
    [[ "$(cat "$c/job" 2>/dev/null)" == "$owner" ]] || exit 1
    echo "$SLURM_JOB_ID" > "$c/job.$SLURM_JOB_ID" && mv -f -- "$c/job.$SLURM_JOB_ID" "$c/job"
  ) 9>"$Q/claims/.takeover.lock" || return 1
  return 0
}

# One stage under the watchdog. Returns the stage's rc, 124 on timeout, 125 when
# the log outgrew LOG_MAX_KB.
run_watched() {
  local s=$1 st=$2 slog=$3 pid t0=$SECONDS lim=$(awk -v h="${MAXH[$2]}" 'BEGIN{printf "%d", h*3600}') base kb
  base=$(du -k "$slog" 2>/dev/null | cut -f1); base=${base:-0}
  setsid bash "$root/bin/run-stage.sh" "$cfg" "$st" "$s" "" >> "$slog" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    sleep 30
    kb=$(du -k "$slog" 2>/dev/null | cut -f1)
    if (( SECONDS - t0 > lim )); then
      kill -TERM -- "-$pid" 2>/dev/null; sleep 60; kill -KILL -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      echo "=== $(date -Is) WATCHDOG: stage $st ran longer than ${MAXH[$st]} h; killed" >> "$slog"; return 124
    fi
    if (( ${kb:-0} - base > LOG_MAX_KB )); then
      kill -TERM -- "-$pid" 2>/dev/null; sleep 60; kill -KILL -- "-$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      # Keep the head and tail of a runaway log only.
      { head -c 5000000 "$slog"; printf '\n######## TRUNCATED by stage3 watchdog %s ########\n' "$(date -Is)"; tail -c 5000000 "$slog"; } > "$slog.trim" && mv -f "$slog.trim" "$slog"
      echo "=== $(date -Is) WATCHDOG: stage $st log grew past ${HCP_STAGE3_LOG_MAX_GB:-5} GB; killed" >> "$slog"; return 125
    fi
  done
  wait "$pid"
}

process() {
  local s="$1" d="$HCP_STUDY/$1" slog="$Q/sessions/$1.log" rc=0 stage
  export SLURM_SCRATCH="${HCP_SCRATCH_ROOT:-/tmp}/hcp-$SLURM_JOB_ID-$s"
  export OMP_NUM_THREADS="$THREADS" MKL_NUM_THREADS="$THREADS" OPENBLAS_NUM_THREADS="$THREADS"
  export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$THREADS" HCP_CPUS_PER_SESSION="$THREADS" SLURM_CPUS_PER_TASK="$THREADS"
  export SINGULARITYENV_LC_ALL=C SINGULARITYENV_LANG=C APPTAINERENV_LC_ALL=C APPTAINERENV_LANG=C
  mkdir -p "$SLURM_SCRATCH"
  echo "=== $(date -Is) $s on $(hostname) job $SLURM_JOB_ID" >> "$slog"
  for stage in "${STAGES[@]}"; do
    echo "=== $(date -Is) stage $stage" >> "$slog"
    run_watched "$s" "$stage" "$slog" || { rc=$?; break; }
  done
  rm -rf -- "$SLURM_SCRATCH"
  if ((rc == 0)); then
    printf 'completed=%s\njob=%s\n' "$(date -Is)" "$SLURM_JOB_ID" > "$d/.stage3_complete"
    log "COMPLETE $s"
  else
    printf 'rc=%s\nstage=%s\nlog=%s\njob=%s\n' "$rc" "$stage" "$slog" "$SLURM_JOB_ID" > "$d/.stage3_failed"
    log "FAILED $s rc=$rc stage=$stage"
  fi
  rm -rf -- "$Q/claims/$s"
}

idle_since=$(date +%s)
while :; do
  [[ -e "$Q/STOP" ]] && { log "STOP file: no new claims"; break; }
  (( end_epoch - $(date +%s) > MARGIN )) || { log "within margin of wall time: no new claims"; break; }
  running=$(jobs -rp | wc -l)
  if (( running < SLOTS )); then
    for m in "$HCP_STUDY"/*/.stage2_complete; do
      (( running < SLOTS )) || break
      [[ -e "$m" ]] || continue
      s=$(basename "$(dirname "$m")")
      [[ "$s" =~ ^[A-Za-z0-9._-]+$ ]] || continue
      ready "$s" || continue
      finished "$s" && continue
      [[ -d "$Q/claims/$s" ]] && alive "$(cat "$Q/claims/$s/job" 2>/dev/null)" && continue
      claim "$s" || continue
      finished "$s" && { rm -rf -- "$Q/claims/$s"; continue; }
      if [[ "${HCP_WORKER_DRYRUN:-0}" == 1 ]]; then
        log "DRYRUN would process $s"; rm -rf -- "$Q/claims/$s"
        dry=$(( ${dry:-0} + 1 )); (( dry < ${HCP_DRYRUN_MAX:-3} )) && continue || break 2
      fi
      process "$s" &
      running=$((running + 1))
      log "CLAIM $s ($running/$SLOTS running)"
    done
  fi
  if (( $(jobs -rp | wc -l) > 0 )); then
    idle_since=$(date +%s)
  elif (( $(date +%s) - idle_since > IDLE_EXIT * 60 )); then
    if [[ -n "$succ" ]]; then
      scontrol update jobid="$succ" StartTime="now+${IDLE_DELAY}minutes" 2>/dev/null \
        && log "idle ${IDLE_EXIT} min: exiting, successor $succ delayed ${IDLE_DELAY} min"
    fi
    break
  fi
  sleep "$POLL"
done

log "waiting for $(jobs -rp | wc -l) running sessions"
wait
log "worker done"

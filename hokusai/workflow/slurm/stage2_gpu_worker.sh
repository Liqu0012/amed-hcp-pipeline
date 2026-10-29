#!/usr/bin/env bash
# Rolling stage-2 worker on one GPU node: GPU eddy, then PostEddy, for every
# session whose stage 1 is complete.
#
# Stage 2 = eddy (eddy_cuda, HCP_EDDY_COMMAND) + PostEddy (CPU). Eddy runs on
# the allocated GPUs, HCP_STAGE2_EDDY_PER_GPU sessions per GPU at a time; PostEddy
# runs on the job's CPUs, HCP_STAGE2_POSTEDDY_SLOTS at a time, so the GPUs do
# not wait for PostEddy.
#
# Sessions are taken from $HCP_STUDY/<session>/.stage1_complete and claimed
# atomically in $QUEUE/claims (several workers can share the queue). At start
# the worker submits its own successor (afterany). When it has had nothing to
# do for HCP_STAGE2_IDLE_EXIT_MIN minutes it exits and delays the successor by
# HCP_STAGE2_IDLE_DELAY_MIN, so idle GPUs are given back. Create $QUEUE/STOP to
# end the chain.
#
# Session end states (in $HCP_STUDY/<session>/):
#   .stage2_complete   eddy + PostEddy done (or skipped: no usable dMRI)
#   .stage2_failed     eddy or PostEddy failed; see the log named inside. Remove to retry.
#
# Usage: sbatch [GPU resources] stage2_gpu_worker.sh CONFIG
set -uo pipefail

cfg=$(readlink -f "${1:?Usage: stage2_gpu_worker.sh CONFIG}")
root="${HCP_WORKFLOW_ROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
[[ -s "$root/bin/run-stage.sh" ]] || root=$(cd "$(dirname "$cfg")/.." && pwd)
source "$root/bin/common.sh"
set +eE
load_site "$cfg"
: "${SLURM_JOB_ID:?run under Slurm}"

Q="${HCP_STAGE2_QUEUE_DIR:-$HCP_WORKFLOW_LOG_DIR/stage2_queue}"
PER_GPU="${HCP_STAGE2_EDDY_PER_GPU:-3}"
EDDY_THREADS="${HCP_STAGE2_EDDY_THREADS:-2}"
POST_SLOTS="${HCP_STAGE2_POSTEDDY_SLOTS:-4}"
POST_THREADS="${HCP_STAGE2_POSTEDDY_THREADS:-6}"
POLL="${HCP_STAGE2_POLL_SEC:-60}"
MARGIN="${HCP_STAGE2_MARGIN_SEC:-21600}"
IDLE_EXIT="${HCP_STAGE2_IDLE_EXIT_MIN:-60}"
IDLE_DELAY="${HCP_STAGE2_IDLE_DELAY_MIN:-120}"
mkdir -p "$Q/claims" "$Q/sessions"
log() { printf '%s [%s %s] %s\n' "$(date -Is)" "$(hostname)" "$SLURM_JOB_ID" "$*"; }

[[ -e "$Q/STOP" ]] && { log "STOP file present; exiting without work or successor"; exit 0; }
[[ -s "$HCP_IMAGE" ]] || { log "container missing: $HCP_IMAGE"; exit 2; }
IFS=, read -r -a GPUS <<< "${CUDA_VISIBLE_DEVICES:-}"
(( ${#GPUS[@]} > 0 )) || { log "no GPU allocated (CUDA_VISIBLE_DEVICES empty)"; exit 2; }

succ=""
if [[ "${HCP_STAGE2_RESUBMIT:-1}" == 1 ]]; then
  succ=$(sbatch --parsable --dependency="afterany:$SLURM_JOB_ID" \
    --job-name="$SLURM_JOB_NAME" --partition="$SLURM_JOB_PARTITION" \
    --nodes=1 --ntasks=1 --cpus-per-task="${SLURM_CPUS_PER_TASK:-32}" \
    --gres="${HCP_STAGE2_GRES:-gpu:h100:4}" --mem="${HCP_STAGE2_MEM:-250G}" \
    --time="${HCP_STAGE2_TIME:-3-00:00:00}" --output="$Q/worker_%j.out" \
    --export="ALL,HCP_WORKFLOW_ROOT=$root" "$root/slurm/stage2_gpu_worker.sh" "$cfg") \
    && log "successor $succ submitted" || log "WARNING: successor submission failed"
fi
end_epoch="${HCP_STAGE2_END_EPOCH:-$(date -d "$(squeue -h -j "$SLURM_JOB_ID" -o %e)" +%s 2>/dev/null || echo $(( $(date +%s) + 259200 )))}"
log "start gpus=${GPUS[*]} eddy_per_gpu=$PER_GPU posteddy_slots=$POST_SLOTS end=$(date -d @"$end_epoch" -Is)"

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
finished() { [[ -e "$HCP_STUDY/$1/.stage2_complete" || -e "$HCP_STUDY/$1/.stage2_failed" ]]; }
claim() {
  local s="$1" c="$Q/claims/$1" owner
  if mkdir "$c" 2>/dev/null; then echo "$SLURM_JOB_ID" > "$c/job"; return 0; fi
  owner=$(cat "$c/job" 2>/dev/null || true)
  [[ "$owner" == "$SLURM_JOB_ID" ]] && return 0
  [[ -n "$owner" ]] && ! alive "$owner" || return 1
  # Take over a dead job's claim under one lock, and only if the claim still names
  # that job: two workers that both saw the dead owner cannot both win.
  (
    flock -w 120 9 || exit 1
    [[ "$(cat "$c/job" 2>/dev/null)" == "$owner" ]] || exit 1
    echo "$SLURM_JOB_ID" > "$c/job.$SLURM_JOB_ID" && mv -f -- "$c/job.$SLURM_JOB_ID" "$c/job"
  ) 9>"$Q/claims/.takeover.lock" || return 1
  # Result files of the dead job's stages: those stages run again.
  rm -f -- "$c"/*.rc "$c"/*.rc.* 2>/dev/null
  return 0
}

# One stage of one session in the background; rc written to a file.
launch() {
  local s=$1 st=$2 t=$3 gpu=${4:-} rcf="$Q/claims/$1/$2.rc.$SLURM_JOB_ID"
  rm -f -- "$rcf"
  (
    export OMP_NUM_THREADS="$t" MKL_NUM_THREADS="$t" OPENBLAS_NUM_THREADS="$t"
    export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$t" HCP_CPUS_PER_SESSION="$t" SLURM_CPUS_PER_TASK="$t"
    export SINGULARITYENV_LC_ALL=C SINGULARITYENV_LANG=C APPTAINERENV_LC_ALL=C APPTAINERENV_LANG=C
    export SLURM_SCRATCH="${HCP_SCRATCH_ROOT:-/tmp}/hcp-$SLURM_JOB_ID-$s-$st"
    [[ -n "$gpu" ]] && export CUDA_VISIBLE_DEVICES="$gpu"
    mkdir -p "$SLURM_SCRATCH"
    echo "=== $(date -Is) $s stage $st on $(hostname) job $SLURM_JOB_ID threads $t gpu ${gpu:--}"
    rc=0; bash "$root/bin/run-stage.sh" "$cfg" "$st" "$s" "" || rc=$?
    rm -rf -- "$SLURM_SCRATCH"
    echo "=== $(date -Is) $s stage $st rc=$rc"
    echo "$rc" > "$rcf"
  ) >> "$Q/sessions/$s.log" 2>&1 &
  RUN_S[$!]=$s; RUN_ST[$!]=$st; RUN_G[$!]=$gpu
  [[ -n "$gpu" ]] && GLOAD[$gpu]=$(( ${GLOAD[$gpu]:-0} + 1 ))
  [[ "$st" == posteddy ]] && post_running=$((post_running + 1))
  log "START $s $st threads=$t gpu=${gpu:--}"
}

declare -A RUN_S=() RUN_ST=() RUN_G=() GLOAD=() INF=() PHASE=()
post_running=0

end_session() {   # $1 session, $2 marker file, $3 content
  printf '%s' "$3" > "$HCP_STUDY/$1/$2"
  rm -rf -- "$Q/claims/$1"; unset "INF[$1]" "PHASE[$1]"
}

reap() {
  local pid s st rc rcf
  for pid in "${!RUN_S[@]}"; do
    s=${RUN_S[$pid]}; st=${RUN_ST[$pid]}; rcf="$Q/claims/$s/$st.rc.$SLURM_JOB_ID"
    [[ -s "$rcf" ]] || continue
    wait "$pid" 2>/dev/null; rc=$(cat "$rcf")
    [[ -n "${RUN_G[$pid]}" ]] && GLOAD[${RUN_G[$pid]}]=$(( GLOAD[${RUN_G[$pid]}] - 1 ))
    [[ "$st" == posteddy ]] && post_running=$((post_running - 1))
    unset "RUN_S[$pid]" "RUN_ST[$pid]" "RUN_G[$pid]"
    if [[ "$rc" != 0 ]]; then
      log "FAILED $s $st rc=$rc"
      end_session "$s" .stage2_failed "$(printf 'rc=%s\nstage=%s\nlog=%s\njob=%s\n' "$rc" "$st" "$Q/sessions/$s.log" "$SLURM_JOB_ID")"
    elif [[ "$st" == eddy ]]; then
      log "DONE $s eddy"; PHASE[$s]=posteddy
    else
      log "COMPLETE $s"
      end_session "$s" .stage2_complete "$(printf 'completed=%s\njob=%s\n' "$(date -Is)" "$SLURM_JOB_ID")"
    fi
  done
}

claim_next() {
  local m d s
  for m in "$HCP_STUDY"/*/.stage1_complete; do
    [[ -e "$m" ]] || continue
    d=$(dirname "$m"); s=$(basename "$d")
    [[ "$s" =~ ^[A-Za-z0-9._-]+$ ]] || continue
    [[ -n "${INF[$s]:-}" ]] && continue
    finished "$s" && continue
    [[ -d "$Q/claims/$s" ]] && alive "$(cat "$Q/claims/$s/job" 2>/dev/null)" && continue
    claim "$s" || continue
    # Another worker may have finished the session between the check above and the claim.
    finished "$s" && { rm -rf -- "$Q/claims/$s"; continue; }
    # Sessions without usable dMRI: run-stage.sh skips eddy/PostEddy with success.
    INF[$s]=1
    if [[ -s "$d/.hcp_diffusion_eddy_complete.ok" ]]; then PHASE[$s]=posteddy; else PHASE[$s]=eddy; fi
    log "CLAIM $s (${PHASE[$s]})"
    return 0
  done
  return 1
}

least_loaded_gpu() {
  local g best="" bl=999
  for g in "${GPUS[@]}"; do (( ${GLOAD[$g]:-0} < bl )) && { bl=${GLOAD[$g]:-0}; best=$g; }; done
  (( bl < PER_GPU )) && echo "$best"
}
busy() { local p; for p in "${!RUN_S[@]}"; do [[ "${RUN_S[$p]}" == "$1" ]] && return 0; done; return 1; }

idle_since=$(date +%s)
while :; do
  reap
  stop=0; [[ -e "$Q/STOP" ]] && stop=1
  (( end_epoch - $(date +%s) > MARGIN )) || stop=1
  # PostEddy first (frees claims), then eddy on free GPU slots.
  for s in "${!PHASE[@]}"; do
    [[ "${PHASE[$s]}" == posteddy ]] || continue
    busy "$s" && continue
    (( post_running < POST_SLOTS )) || break
    launch "$s" posteddy "$POST_THREADS"
  done
  for s in "${!PHASE[@]}"; do
    [[ "${PHASE[$s]}" == eddy ]] || continue
    busy "$s" && continue
    g=$(least_loaded_gpu); [[ -n "$g" ]] || break
    launch "$s" eddy "$EDDY_THREADS" "$g"
  done
  # Keep enough sessions in hand to fill every GPU slot and PostEddy slot.
  if (( !stop )); then
    want=$(( ${#GPUS[@]} * PER_GPU + POST_SLOTS ))
    while (( ${#INF[@]} < want )) && claim_next; do :; done
  fi
  if (( ${#RUN_S[@]} > 0 || ${#INF[@]} > 0 )); then
    idle_since=$(date +%s)
  elif (( stop )); then
    log "stop requested or wall-time margin reached; nothing running"; break
  elif (( $(date +%s) - idle_since > IDLE_EXIT * 60 )); then
    if [[ -n "$succ" ]]; then
      scontrol update jobid="$succ" StartTime="now+${IDLE_DELAY}minutes" 2>/dev/null \
        && log "idle ${IDLE_EXIT} min: exiting, successor $succ delayed ${IDLE_DELAY} min"
    fi
    break
  fi
  sleep "$POLL"
done
log "waiting for ${#RUN_S[@]} running stages"
while (( ${#RUN_S[@]} > 0 )); do sleep "$POLL"; reap; done
log "worker done"

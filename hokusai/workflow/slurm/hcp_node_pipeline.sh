#!/usr/bin/env bash
# Whole-node HCP pipeline: one Slurm job = one whole node that runs every stage
# (convert, structural, PreEddy, CPU eddy, PostEddy, fMRI, ICA-FIX, MSMAll,
# dedrift, numeric QC) for the sessions it claims from a manifest.
#
# Inside the node the worker keeps a CPU / memory budget (default 106 CPU and
# 106 GiB, i.e. 5% of a 112-CPU / 112-GiB mpc node left for I/O) and starts any
# (session, stage) whose prerequisites are done as soon as its threads and peak
# memory fit, so eddy, structural and fMRI work of different sessions overlap.
# A stage is not started when its expected duration does not fit in the job's
# remaining wall time; the successor job (submitted at start, afterany) carries
# on. Several node chains can share one manifest: sessions are claimed with an
# atomic mkdir, and claims of dead jobs are taken over.
#
# Usage:
#   hcp_node_pipeline.sh submit CONFIG N    start N node chains
#   hcp_node_pipeline.sh status CONFIG      progress summary
#   hcp_node_pipeline.sh worker CONFIG      (what each Slurm job runs)
# touch $HCP_NODE_QUEUE_DIR/STOP to stop claiming new sessions and end the chains.
#
# State, under $HCP_NODE_QUEUE_DIR/state/<session>/:
#   <stage>.done | <stage>.failed       per stage
#   DONE | FAILED | BLOCKED             session finished (BLOCKED = input problems)
# Remove FAILED and the failed <stage>.failed to retry a session.
set -uo pipefail

mode="${1:?Usage: hcp_node_pipeline.sh submit|status|worker CONFIG [N]}"
cfg=$(readlink -f "${2:?CONFIG required}")
root="${HCP_WORKFLOW_ROOT:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
source "$root/bin/common.sh"
set +eE   # common.sh turns on errexit; the scheduler handles every return code itself
load_site "$cfg"
manifest="${HCP_NODE_MANIFEST:?HCP_NODE_MANIFEST required}"
[[ -s "$manifest" ]] || { echo "Missing manifest: $manifest" >&2; exit 2; }
Q="${HCP_NODE_QUEUE_DIR:-$HCP_WORKFLOW_LOG_DIR/node_pipeline}"
mkdir -p "$Q/claims" "$Q/state" "$Q/logs" "$Q/verified"
self="$root/slurm/hcp_node_pipeline.sh"

# Launch priority (short stages that unlock long ones first).
STAGES=(convert preeddy eddy structural posteddy fmri icafix msmall dedrift qc)
declare -A DEPS=([convert]="" [preeddy]="convert" [eddy]="preeddy" [structural]="convert"
  [posteddy]="eddy structural" [fmri]="structural" [icafix]="fmri" [msmall]="icafix"
  [dedrift]="msmall" [qc]="dedrift posteddy")
# threads, peak memory (GB), expected hours, max concurrent per node
declare -A DEF=(
  [convert]="4 1 0.5 26"      [preeddy]="4 1.5 1 26"    [eddy]="35 27 16 3"
  [structural]="5 4 12 21"    [posteddy]="5 5 1 21"     [fmri]="10 10 6 10"
  [icafix]="21 19.5 6 5"      [msmall]="5 3.5 6 21"     [dedrift]="21 19 1 5"
  [qc]="2 1 0.3 26")
declare -A THR MINT MEMMB SECS MAXC
for st in "${STAGES[@]}"; do
  read -r t m h c <<< "${DEF[$st]}"
  up=${st^^}
  v="HCP_NODE_${up}_THREADS"; t="${!v:-$t}"
  v="HCP_NODE_${up}_MEM_GB";  m="${!v:-$m}"
  v="HCP_NODE_${up}_HOURS";   h="${!v:-$h}"
  v="HCP_NODE_${up}_MAX";     c="${!v:-$c}"
  # A stage may start with fewer threads (down to MIN_THREADS) when that is all
  # the CPU budget has left, e.g. eddy next to a node full of structural runs.
  v="HCP_NODE_${up}_MIN_THREADS"; MINT[$st]="${!v:-$t}"
  THR[$st]=$t; MEMMB[$st]=$(awk -v m="$m" 'BEGIN{printf "%d", m*1024}')
  SECS[$st]=$(awk -v h="$h" 'BEGIN{printf "%d", h*3600}'); MAXC[$st]=$c
done
CPU_BUDGET="${HCP_NODE_CPU_BUDGET:-106}"
MEM_BUDGET_MB=$(awk -v g="${HCP_NODE_MEM_BUDGET_GB:-106}" 'BEGIN{printf "%d", g*1024}')
MAX_SESSIONS="${HCP_NODE_MAX_SESSIONS:-15}"
MIN_AGE="${HCP_UPLOAD_MIN_AGE_MIN:-30}"
# Disk guard: a stage starts only if the study file system keeps MIN_FREE_GB
# free after the growth expected from the stages already started by this job
# and from this stage (HCP_NODE_<STAGE>_DISK_GB). Several nodes share one quota,
# so the reserve should cover what the other nodes may still write.
DISK_MIN_FREE_GB="${HCP_NODE_DISK_MIN_FREE_GB:-400}"
declare -A DISKGB=([convert]=6 [preeddy]=2 [eddy]=3 [structural]=3 [posteddy]=2
  [fmri]=25 [icafix]=15 [msmall]=5 [dedrift]=5 [qc]=0)
for st in "${!DISKGB[@]}"; do v="HCP_NODE_${st^^}_DISK_GB"; DISKGB[$st]="${!v:-${DISKGB[$st]}}"; done
# Study directories in /lustre/tmp_work (HCP_NODE_STUDY_TMP): a new session gets
# its directory there with a symlink in HCP_STUDY. tmp_work deletes files not
# modified for 7 days. The age of a session's files is taken from
# state/<session>/convert.done on home (the purge cannot touch it; the inputs and
# the early outputs are about that old), not from the files themselves, which
# after a partial purge would all look young. While a session is idle:
#   - older than HCP_NODE_TMP_REHOME_DAYS (5): it is copied back to HCP_STUDY
#     (home) if the disk guard allows, and the symlink replaced by the copy;
#   - older than HCP_NODE_TMP_MAX_AGE_DAYS (6.5) and still in tmp_work: it gets
#     FAILED (failed_stages=tmp_work_expiry) so nothing continues on files that
#     may be purged; the pull keeps it on wu, and it is rerun from its zip.
#   - its tmp_work directory gone: FAILED (failed_stages=tmp_work_lost).
STUDY_TMP="${HCP_NODE_STUDY_TMP:-}"
TMP_REHOME_SEC=$(awk -v d="${HCP_NODE_TMP_REHOME_DAYS:-5}" 'BEGIN{printf "%d", d*86400}')
TMP_MAX_AGE_SEC=$(awk -v d="${HCP_NODE_TMP_MAX_AGE_DAYS:-6.5}" 'BEGIN{printf "%d", d*86400}')
place_study() {
  local s=$1
  [[ -n "$STUDY_TMP" && ! -e "$HCP_STUDY/$s" && ! -L "$HCP_STUDY/$s" ]] || return 0
  mkdir -p "$STUDY_TMP/$s" && ln -s "$STUDY_TMP/$s" "$HCP_STUDY/$s" && log "STUDY $s -> $STUDY_TMP/$s"
}
in_tmp() {
  local l
  [[ -L "$HCP_STUDY/$1" ]] || return 1
  l=$(readlink -- "$HCP_STUDY/$1")
  [[ "$l" == /lustre/tmp_work/* || ( -n "$STUDY_TMP" && "$l" == "$STUDY_TMP"/* ) ]]
}
tmp_age() {   # seconds since convert finished; 0 if not converted yet
  local f="$Q/state/$1/convert.done"
  [[ -e "$f" ]] && echo $(( $(date +%s) - $(stat -c %Y "$f") )) || echo 0
}
rehome() {    # copy an idle tmp_work session back to HCP_STUDY and replace the link
  local s=$1 d="$HCP_STUDY/$1" r need free t0=$SECONDS new="$HCP_STUDY/.$1.rehome"
  r=$(readlink -f -- "$d")
  need=$(du -s -BG "$r" 2>/dev/null | awk '{sub(/G$/,"",$1); print $1+1}')
  free=$(disk_free_gb || echo 0)
  if (( free - ${need:-999999} - disk_pending < DISK_MIN_FREE_GB )); then
    log "REHOME $s postponed: needs ${need} GB, ${free} GB free, reserve ${DISK_MIN_FREE_GB} GB"; return 1
  fi
  rm -rf -- "$new"
  if ! rsync -aH "$r/" "$new/" 2>>"$Q/logs/$s.rehome.log"; then
    rm -rf -- "$new"; log "REHOME $s: copy failed, left in tmp_work"; return 1
  fi
  rm -f -- "$d" && mv -T -- "$new" "$d" || { log "REHOME $s: swap failed (check $d and $new)"; return 1; }
  rm -rf -- "$r"
  log "REHOME $s: tmp_work -> $d (${need} GB, $((SECONDS - t0)) s)"
}
session_busy() { local st; for st in "${STAGES[@]}"; do [[ -n "${RUNNING[$1/$st]:-}" ]] && return 0; done; return 1; }
# Returns non-zero when the session must not continue (it was marked FAILED).
guard_tmp() {
  local s=$1 age
  in_tmp "$s" || return 0
  if [[ ! -d "$(readlink -f -- "$HCP_STUDY/$s")" ]]; then
    session_busy "$s" && return 0
    printf 'failed_stages=tmp_work_lost\njob=%s\n' "$SLURM_JOB_ID" > "$Q/state/$s/FAILED"
    log "SESSION FAILED $s: its tmp_work directory is gone"; return 1
  fi
  age=$(tmp_age "$s")
  (( age > TMP_REHOME_SEC )) || return 0
  session_busy "$s" && return 0
  rehome "$s" && return 0
  (( age > TMP_MAX_AGE_SEC )) || return 0
  printf 'failed_stages=tmp_work_expiry\nage_hours=%s\njob=%s\n' "$((age / 3600))" "$SLURM_JOB_ID" > "$Q/state/$s/FAILED"
  log "SESSION FAILED $s: still in tmp_work $((age / 3600)) h after convert and could not be copied home"
  return 1
}
disk_free_gb() { [[ -n "${HCP_NODE_TEST_DISK_FREE_GB:-}" ]] && { echo "$HCP_NODE_TEST_DISK_FREE_GB"; return; }; df -P -BG "$HCP_STUDY" 2>/dev/null | awk 'NR==2 {sub(/G$/,"",$4); print $4+0}'; }
POLL="${HCP_NODE_POLL_SEC:-30}"

declare -A ARCH=()
SESSIONS=()
while IFS=$'\t' read -r s a _; do
  [[ -n "$s" ]] || continue
  validate_session "$s"
  ARCH[$s]="$a"; SESSIONS+=("$s")
done < "$manifest"

sbatch_args() {
  local -a a=(--parsable "--job-name=${HCP_NODE_JOB_NAME:-hcp_node}"
    "--partition=${HCP_NODE_PARTITION:-$HCP_CPU_PARTITION}" --nodes=1 --ntasks=1
    "--cpus-per-task=${HCP_NODE_CPUS:-112}" "--mem=${HCP_NODE_MEM:-112G}"
    "--time=${HCP_NODE_TIME:-1-00:00:00}" "--output=$Q/worker_%j.out"
    "--export=ALL,HCP_WORKFLOW_ROOT=$root")
  [[ -z "${HCP_SLURM_ACCOUNT:-}" ]] || a+=("--account=$HCP_SLURM_ACCOUNT")
  [[ -z "${HCP_SLURM_QOS:-}" ]] || a+=("--qos=$HCP_SLURM_QOS")
  [[ -z "${HCP_SLURM_EXCLUDE:-}" ]] || a+=("--exclude=$HCP_SLURM_EXCLUDE")
  printf '%s\n' "${a[@]}"
}

terminal() { local d="$Q/state/$1"; [[ -e "$d/DONE" || -e "$d/FAILED" || -e "$d/BLOCKED" ]]; }

if [[ "$mode" == status ]]; then
  done_n=0 fail_n=0 block_n=0 claimed=0 waiting=0
  declare -A stage_done=()
  for s in "${SESSIONS[@]}"; do
    d="$Q/state/$s"
    if [[ -e "$d/DONE" ]]; then ((done_n++))
    elif [[ -e "$d/FAILED" ]]; then ((fail_n++))
    elif [[ -e "$d/BLOCKED" ]]; then ((block_n++))
    elif [[ -d "$Q/claims/$s" ]]; then ((claimed++))
    else ((waiting++)); fi
    for st in "${STAGES[@]}"; do [[ -e "$d/$st.done" ]] && stage_done[$st]=$(( ${stage_done[$st]:-0} + 1 )); done
  done
  echo "manifest=${#SESSIONS[@]} done=$done_n failed=$fail_n blocked=$block_n in_progress=$claimed not_started=$waiting"
  printf 'stage done:'; for st in "${STAGES[@]}"; do printf ' %s=%s' "$st" "${stage_done[$st]:-0}"; done; echo
  echo "running now:"; find "$Q/state" -name '*.running' -printf '  %h %f\n' 2>/dev/null | sed "s#$Q/state/##; s#\.running##" | awk '{c[$2]++} END{for(k in c) printf "  %s %d\n",k,c[k]}'
  [[ -e "$Q/STOP" ]] && echo "STOP file present"
  squeue -h -u "${USER:-$(id -un)}" -n "${HCP_NODE_JOB_NAME:-hcp_node}" -o '%i %T %M %L %N %R' 2>/dev/null
  for s in "${SESSIONS[@]}"; do [[ -e "$Q/state/$s/FAILED" ]] && echo "FAILED $s: $(cat "$Q/state/$s/FAILED")"; done
  exit 0
fi

if [[ "$mode" == submit ]]; then
  n="${3:?Usage: hcp_node_pipeline.sh submit CONFIG N}"
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || { echo "N must be a positive integer" >&2; exit 2; }
  [[ ! -e "$Q/STOP" ]] || { echo "Remove $Q/STOP first" >&2; exit 2; }
  [[ -s "$HCP_IMAGE" ]] || { echo "Missing image: $HCP_IMAGE" >&2; exit 2; }
  [[ -s "$HCP_FS_LICENSE" ]] || { echo "Missing FreeSurfer license: $HCP_FS_LICENSE" >&2; exit 2; }
  mapfile -t args < <(sbatch_args)
  for ((i = 1; i <= n; i++)); do sbatch "${args[@]}" "$self" worker "$cfg"; done
  exit 0
fi

[[ "$mode" == worker ]] || { echo "Unknown mode: $mode" >&2; exit 2; }
: "${SLURM_JOB_ID:?worker runs under Slurm}"
log() { printf '%s [%s %s] %s\n' "$(date -Is)" "$(hostname)" "$SLURM_JOB_ID" "$*"; }

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
claim_owner_alive() { alive "$(cat "$Q/claims/$1/job" 2>/dev/null)"; }
unfinished_left() { local s; for s in "${SESSIONS[@]}"; do terminal "$s" || return 0; done; return 1; }
unclaimed_left() {
  local s
  for s in "${SESSIONS[@]}"; do
    terminal "$s" && continue
    [[ -d "$Q/claims/$s" ]] && claim_owner_alive "$s" && continue
    return 0
  done
  return 1
}

[[ -e "$Q/STOP" ]] && { log "STOP file present; exiting"; exit 0; }
unfinished_left || { log "all manifest sessions finished; chain ends"; exit 0; }
[[ -s "$HCP_IMAGE" ]] || { log "container missing: $HCP_IMAGE"; exit 2; }

succ=""
if [[ "${HCP_NODE_RESUBMIT:-1}" == 1 ]]; then
  mapfile -t args < <(sbatch_args)
  succ=$(sbatch "${args[@]}" "--dependency=afterany:$SLURM_JOB_ID" "$self" worker "$cfg") \
    && log "successor $succ submitted" || log "WARNING: successor submission failed"
fi
end_epoch="${HCP_NODE_END_EPOCH:-$(date -d "$(squeue -h -j "$SLURM_JOB_ID" -o %e)" +%s 2>/dev/null || echo $(( $(date +%s) + 86400 )))}"
mem_total_mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
# Per-stage memory/CPU samples for tuning the budget (bin/node-memprof.sh).
memprof_pid=""
if [[ "${HCP_NODE_MEMPROF:-1}" == 1 ]]; then
  mkdir -p "$Q/memprof"
  bash "$root/bin/node-memprof.sh" "$Q/memprof/$SLURM_JOB_ID.tsv" 30 > /dev/null 2>&1 &
  memprof_pid=$!
fi
log "start budget=${CPU_BUDGET}cpu/$((MEM_BUDGET_MB/1024))GiB max_sessions=$MAX_SESSIONS end=$(date -d @"$end_epoch" -Is) manifest=$manifest"

upload_ready() {
  local z="$1" s="$2" sig
  [[ -s "$z" && -n "$(find "$z" -maxdepth 0 -mmin +"$MIN_AGE" 2>/dev/null)" ]] || return 1
  sig=$(stat -c '%s %Y' "$z")
  [[ -s "$Q/verified/$s" && "$(cat "$Q/verified/$s")" == "$sig" ]] && return 0
  unzip -tqq "$z" >/dev/null 2>&1 || return 1
  printf '%s' "$sig" > "$Q/verified/$s"
}

claim() {
  local s="$1" c="$Q/claims/$1" owner
  if mkdir "$c" 2>/dev/null; then echo "$SLURM_JOB_ID" > "$c/job"; return 0; fi
  owner=$(cat "$c/job" 2>/dev/null || true)
  [[ "$owner" == "$SLURM_JOB_ID" ]] && return 0
  [[ -n "$owner" ]] && ! alive "$owner" || return 1
  # Take over a dead job's claim under one lock, and only if the claim still names
  # that job: two jobs that both saw the dead owner cannot both win.
  (
    flock -w 120 9 || exit 1
    [[ "$(cat "$c/job" 2>/dev/null)" == "$owner" ]] || exit 1
    echo "$SLURM_JOB_ID" > "$c/job.$SLURM_JOB_ID" && mv -f -- "$c/job.$SLURM_JOB_ID" "$c/job"
  ) 9>"$Q/claims/.takeover.lock" || return 1
  # Stages the dead job left running have no .done: they run again.
  rm -f -- "$Q/state/$s/"*.running "$Q/state/$s/"*.rc.* 2>/dev/null
  return 0
}

declare -A INF=() RUN_S=() RUN_ST=() RUN_T=() RUNNING=() RUNC=() TMP_CHECKED=()
cpu_used=0 mem_used=0 disk_pending=0

claim_next() {
  local s
  for s in "${SESSIONS[@]}"; do
    [[ -n "${INF[$s]:-}" ]] && continue
    terminal "$s" && continue
    [[ -d "$Q/claims/$s" ]] && claim_owner_alive "$s" && continue
    converted=0; [[ -e "$Q/state/$s/convert.done" ]] && converted=1
    (( converted )) || [[ -s "${ARCH[$s]}" && -n "$(find "${ARCH[$s]}" -maxdepth 0 -mmin +"$MIN_AGE" 2>/dev/null)" ]] || continue
    claim "$s" || continue
    # Another job may have finished the session between the check above and the claim.
    terminal "$s" && { rm -rf -- "$Q/claims/$s"; continue; }
    if (( !converted )) && ! upload_ready "${ARCH[$s]}" "$s"; then
      rm -rf -- "$Q/claims/$s"; log "not ready (zip test failed) $s"; continue
    fi
    mkdir -p "$Q/state/$s"; INF[$s]=1; log "CLAIM $s (${#INF[@]} in progress)"
    guard_tmp "$s" || { rm -rf -- "$Q/claims/$s"; unset "INF[$s]"; continue; }
    TMP_CHECKED[$s]=$(date +%s); place_study "$s"
    return 0
  done
  return 1
}

stage_ready() {
  local s="$1" st="$2" d="$Q/state/$1" dep
  [[ -e "$d/$st.done" || -e "$d/$st.failed" || -n "${RUNNING[$s/$st]:-}" ]] && return 1
  for dep in ${DEPS[$st]}; do [[ -e "$d/$dep.done" ]] || return 1; done
  return 0
}

launch() {
  local s="$1" st="$2" t="$3" d="$Q/state/$1"
  local scratch="${HCP_SCRATCH_ROOT:-/tmp}/hcp-$SLURM_JOB_ID-$s-$st" rcf="$Q/state/$s/$st.rc.$SLURM_JOB_ID"
  rm -f -- "$rcf"; date -Is > "$d/$st.running"
  (
    export SLURM_CPUS_PER_TASK="$t" HCP_CPUS_PER_SESSION="$t" OMP_NUM_THREADS="$t" MKL_NUM_THREADS="$t"
    export OPENBLAS_NUM_THREADS="$t" ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$t"
    export SINGULARITYENV_LC_ALL=C SINGULARITYENV_LANG=C APPTAINERENV_LC_ALL=C APPTAINERENV_LANG=C
    export SLURM_SCRATCH="$scratch"
    mkdir -p "$scratch"
    echo "=== $(date -Is) $s stage $st on $(hostname) job $SLURM_JOB_ID threads $t"
    # A FreeSurfer tree left by a killed job is moved aside so recon-all starts clean.
    if [[ "$st" == structural && -d "$HCP_STUDY/$s/T1w/$s" && ! -s "$HCP_STUDY/$s/.hcp_freesurfer_stage.ok" ]]; then
      mv "$HCP_STUDY/$s/T1w/$s" "$HCP_STUDY/$s/T1w/$s.interrupted-$(date +%Y%m%dT%H%M%S)"
    fi
    rc=0
    bash "$root/bin/run-stage.sh" "$cfg" "$st" "$s" "${ARCH[$s]}" || rc=$?
    rm -rf -- "$scratch"
    echo "=== $(date -Is) $s stage $st rc=$rc"
    echo "$rc" > "$rcf"
    exit "$rc"
  ) >> "$Q/logs/$s.$st.log" 2>&1 &
  local pid=$!
  RUN_S[$pid]=$s; RUN_ST[$pid]=$st; RUN_T[$pid]=$t; RUNNING[$s/$st]=$pid
  RUNC[$st]=$(( ${RUNC[$st]:-0} + 1 ))
  cpu_used=$((cpu_used + t)); mem_used=$((mem_used + MEMMB[$st])); disk_pending=$((disk_pending + DISKGB[$st]))
  log "START $s $st threads=$t (cpu $cpu_used/$CPU_BUDGET mem $((mem_used/1024))/$((MEM_BUDGET_MB/1024))G)"
}

reap() {
  local pid s st rc rcf
  for pid in "${!RUN_S[@]}"; do
    s=${RUN_S[$pid]}; st=${RUN_ST[$pid]}; rcf="$Q/state/$s/$st.rc.$SLURM_JOB_ID"
    [[ -s "$rcf" ]] || continue
    wait "$pid" 2>/dev/null; rc=$(cat "$rcf"); rm -f -- "$rcf" "$Q/state/$s/$st.running"
    RUNC[$st]=$(( ${RUNC[$st]} - 1 ))
    cpu_used=$((cpu_used - ${RUN_T[$pid]})); mem_used=$((mem_used - MEMMB[$st])); disk_pending=$((disk_pending - DISKGB[$st]))
    unset "RUN_S[$pid]" "RUN_ST[$pid]" "RUN_T[$pid]" "RUNNING[$s/$st]"
    if [[ "$rc" == 0 ]]; then
      printf 'completed=%s\njob=%s\n' "$(date -Is)" "$SLURM_JOB_ID" > "$Q/state/$s/$st.done"
      log "DONE $s $st"
    elif [[ "$st" == convert && -s "$HCP_STUDY/$s/.hcp_input_problems.txt" ]]; then
      printf 'rc=%s\nproblems=%s\n' "$rc" "$HCP_STUDY/$s/.hcp_input_problems.txt" > "$Q/state/$s/BLOCKED"
      log "BLOCKED $s (input problems)"
    else
      printf 'rc=%s\nlog=%s\njob=%s\n' "$rc" "$Q/logs/$s.$st.log" "$SLURM_JOB_ID" > "$Q/state/$s/$st.failed"
      log "FAILED $s $st rc=$rc"
    fi
  done
}

# A session is finished when nothing of it runs and no stage can become ready.
finalize() {
  local s st busy any_ready failed d
  for s in "${!INF[@]}"; do
    d="$Q/state/$s"
    if [[ -e "$d/BLOCKED" ]]; then busy=0; any_ready=0
    else
      busy=0; any_ready=0
      for st in "${STAGES[@]}"; do
        [[ -n "${RUNNING[$s/$st]:-}" ]] && busy=1
        stage_ready "$s" "$st" && any_ready=1
      done
    fi
    (( busy || any_ready )) && continue
    if [[ -e "$d/BLOCKED" ]]; then :
    else
      failed=$(cd "$d" && ls -- *.failed 2>/dev/null | sed 's/\.failed$//' | paste -sd, -)
      if [[ -z "$failed" && -e "$d/qc.done" ]]; then
        # File count of the finished session: the pull to wu checks its copy against it.
        printf 'completed=%s\njob=%s\nfiles=%s\n' "$(date -Is)" "$SLURM_JOB_ID" \
          "$(find "$HCP_STUDY/$s/" -type f 2>/dev/null | wc -l)" > "$d/DONE"; log "SESSION DONE $s"
      else
        printf 'failed_stages=%s\njob=%s\n' "${failed:-unknown}" "$SLURM_JOB_ID" > "$d/FAILED"; log "SESSION FAILED $s ($failed)"
      fi
    fi
    rm -rf -- "$Q/claims/$s"; unset "INF[$s]"
  done
}

# Resume sessions this chain held when the previous job ended (claims of dead jobs).
for s in "${SESSIONS[@]}"; do
  terminal "$s" && continue
  [[ -d "$Q/claims/$s" ]] || continue
  owner=$(cat "$Q/claims/$s/job" 2>/dev/null || true)
  [[ -n "$owner" ]] && alive "$owner" && continue
  (( ${#INF[@]} < MAX_SESSIONS )) || break
  # claim() clears the stages the killed job left marked as running.
  claim "$s" || continue
  terminal "$s" && { rm -rf -- "$Q/claims/$s"; continue; }
  mkdir -p "$Q/state/$s"; INF[$s]=1; log "RESUME $s"
  guard_tmp "$s" || { rm -rf -- "$Q/claims/$s"; unset "INF[$s]"; continue; }
  TMP_CHECKED[$s]=$(date +%s); place_study "$s"
done

while :; do
  reap
  finalize
  now=$(date +%s)
  # tmp_work age of the sessions held here, at most every 10 min per session
  # (guard_tmp may copy a session home, which takes minutes).
  for s in "${!INF[@]}"; do
    (( now - ${TMP_CHECKED[$s]:-0} >= 600 )) || continue
    TMP_CHECKED[$s]=$now
    guard_tmp "$s" || { rm -rf -- "$Q/claims/$s"; unset "INF[$s]" "TMP_CHECKED[$s]"; }
  done
  launched=0 time_blocked=0 disk_blocked=0
  disk_left=$(( $(disk_free_gb || echo 0) - DISK_MIN_FREE_GB - disk_pending ))
  avail_mb=$(awk '/^MemAvailable:/ {a=$2} /^MemFree:/ {f=$2} END {print int((a ? a : f)/1024)}' /proc/meminfo)
  for st in "${STAGES[@]}"; do
    for s in $(printf '%s\n' "${!INF[@]}" | sort); do
      stage_ready "$s" "$st" || continue
      (( ${RUNC[$st]:-0} < MAXC[$st] )) || break
      t=${THR[$st]}; free=$((CPU_BUDGET - cpu_used))
      (( free < t && free >= MINT[$st] )) && t=$free
      (( cpu_used + t <= CPU_BUDGET && mem_used + MEMMB[$st] <= MEM_BUDGET_MB )) || break
      (( avail_mb - MEMMB[$st] >= mem_total_mb / 20 )) || break
      if (( DISKGB[$st] > disk_left )); then disk_blocked=1; continue; fi
      # Fewer threads take proportionally longer.
      if (( now + SECS[$st] * THR[$st] / t + 600 > end_epoch )); then time_blocked=1; continue; fi
      launch "$s" "$st" "$t"; launched=$((launched + 1)); disk_left=$((disk_left - DISKGB[$st])); avail_mb=$((avail_mb - MEMMB[$st]))
    done
  done
  stopping=0; [[ -e "$Q/STOP" ]] && stopping=1
  admitted=0
  if (( !stopping && !disk_blocked && disk_left > 60 && now + SECS[structural] + 600 <= end_epoch )); then
    if (( ${#INF[@]} < MAX_SESSIONS )) || (( launched == 0 && cpu_used * 2 < CPU_BUDGET && ${#INF[@]} < 2 * MAX_SESSIONS )); then
      claim_next && admitted=1
    fi
  fi
  (( admitted )) && continue
  if (( ${#RUN_S[@]} == 0 && launched == 0 )); then
    if (( ${#INF[@]} == 0 )) && ! unclaimed_left; then
      # Everything is finished or held by other live chains: end this chain.
      log "no unclaimed sessions left; chain ends"
      [[ -n "$succ" ]] && scancel "$succ" 2>/dev/null && log "successor $succ cancelled"
      break
    fi
    (( time_blocked || stopping )) && { log "remaining work does not fit in this job; successor continues"; break; }
    if (( disk_blocked )); then
      # Nothing runs here and the disk is full: wait for results to be pulled
      # off HOKUSAI, but do not hold an idle node for more than DISK_WAIT_MIN.
      disk_wait_since=${disk_wait_since:-$now}
      if (( now - disk_wait_since > ${HCP_NODE_DISK_WAIT_MIN:-60} * 60 )); then
        log "not enough disk for $(( ${HCP_NODE_DISK_WAIT_MIN:-60} )) min with nothing running; successor continues"; break
      fi
    fi
    (( ${#INF[@]} == 0 )) && { log "no session could be started (uploads in progress or not enough wall time); successor continues"; break; }
  fi
  (( disk_blocked && ${#RUN_S[@]} == 0 )) || disk_wait_since=
  sleep "$POLL"
done

log "waiting for ${#RUN_S[@]} running stages"
while (( ${#RUN_S[@]} > 0 )); do sleep "$POLL"; reap; done
finalize
[[ -n "$memprof_pid" ]] && kill "$memprof_pid" 2>/dev/null
log "worker done"

#!/usr/bin/env bash
# Stage 3 (CPU node): everything after eddy. PostEddy has no GPU option in
# HCP Pipelines v6.0.0 (only the Eddy sub-script does), so it runs here on
# CPU along with the rest of the pipeline: fMRIVolume -> fMRISurface -> FIX
# -> PostFix -> MSMAll (all --matlab-run-mode=0, the compiled MCR runtime,
# not the licensed-MATLAB path), HCP stages only -- the MRtrix3 connectome step is deferred
# for subjects that have diffusion data.
#
# Depends on Stage 1 (structural + PreEddy) for every subject, and on
# Stage 2 (GPU eddy) for subjects with DWI data before PostEddy can run.
#
# Resumable via a "<output>/<subject>/.stage3_complete" sentinel.
#
# SUBJECT_LIST format: one SUBJECT per line.
# Usage: sbatch --job-name=stage3_batch run_stage3_post_eddy_rest.sbatch SUBJECT_LIST
#SBATCH --partition=ccalc
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=192
#SBATCH --mem=1500G
#SBATCH --time=30-00:00:00
#SBATCH --output=logs/stage3_batch_%x_%j.out
#SBATCH --error=logs/stage3_batch_%x_%j.err

set -uo pipefail
[[ $# -eq 1 ]] || { echo "usage: sbatch $0 SUBJECT_LIST" >&2; exit 2; }
SUBJECT_LIST=$1
[[ -f "$SUBJECT_LIST" ]] || { echo "missing subject list: $SUBJECT_LIST" >&2; exit 2; }

ROOT=${AMED_ROOT:-/data/juntendodb/amedhcp}          # override with your own data root
SIF=${HCP_SIF:-/data/juntendodb/containers/hcp_pipelines_v6_complete_20260831.sif}  # path to the container built from container/hcp_v6_complete.def
LICENSE=${FS_LICENSE:-$HOME/.licenses/freesurfer/license.txt}  # your own FreeSurfer license -- see https://surfer.nmr.mgh.harvard.edu/registration.html
test -s "$LICENSE"

# Three-tier concurrency (2026-09-28): the 2026-09-27 two-tier design
# treated "everything other than MSMAll" as one ~5.9-core/subject tier, on
# the strength of a 2026-09-25 measurement (80 concurrent -> load 474/192)
# that was actually a BLEND of several phases running at once, not FIX in
# isolation. Once ENTRY_MAX_CONCURRENT was raised, subjects piled up in FIX
# alone (19 concurrent on one node) and load hit 474/192 again -- direct
# measurement (`ps` on the FIX classifier's MCR processes) showed FIX costs
# ~10.1 real cores/subject, essentially as heavy as MSMAll (12.8), not 5.9.
# FIX and MSMAll are both compiled MCR binaries (--matlab-run-mode=0) that
# ignore OMP_NUM_THREADS/ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS the same way;
# PostEddy/fMRIVolume/fMRISurface/PostFix are the only genuinely light
# phases. So there are now three semaphores: ENTRY_MAX_CONCURRENT (the
# whole pipeline, sized for the light phases), and separate, tight gates
# FIX_MAX_CONCURRENT and MSMALL_MAX_CONCURRENT around just those two calls
# -- a subject can be in at most one of the three tiers at a time, but two
# *different* subjects can independently saturate FIX and MSMAll at once,
# so the worst case sums all three:
#   FIX_MAX_CONCURRENT*10.1 + MSMALL_MAX_CONCURRENT*12.8
#     + (ENTRY_MAX_CONCURRENT - FIX_MAX_CONCURRENT - MSMALL_MAX_CONCURRENT)*5.9
#   = 6*10.1 + 6*12.8 + 5*5.9 = 60.6 + 76.8 + 29.5 = 166.9, under the 192-core budget.
# A subject waiting for a FIX or MSMAll slot costs ~nothing (blocked on a
# pipe read) since the phases before each in this per-subject sequential
# pipeline have already finished for it by then.
ENTRY_MAX_CONCURRENT=17
FIX_MAX_CONCURRENT=6
MSMALL_MAX_CONCURRENT=6
PER_SUBJECT_THREADS=2

SEM_FIFO=$(mktemp -u /tmp/stage3_sem.XXXXXX)
mkfifo "$SEM_FIFO"; exec 3<>"$SEM_FIFO"; rm -f "$SEM_FIFO"
for _ in $(seq 1 "$ENTRY_MAX_CONCURRENT"); do echo >&3; done

FIX_SEM_FIFO=$(mktemp -u /tmp/stage3_fix_sem.XXXXXX)
mkfifo "$FIX_SEM_FIFO"; exec 5<>"$FIX_SEM_FIFO"; rm -f "$FIX_SEM_FIFO"
for _ in $(seq 1 "$FIX_MAX_CONCURRENT"); do echo >&5; done

MSMALL_SEM_FIFO=$(mktemp -u /tmp/stage3_msmall_sem.XXXXXX)
mkfifo "$MSMALL_SEM_FIFO"; exec 4<>"$MSMALL_SEM_FIFO"; rm -f "$MSMALL_SEM_FIFO"
for _ in $(seq 1 "$MSMALL_MAX_CONCURRENT"); do echo >&4; done

run_post_eddy() {
  local subject=$1
  apptainer exec --cleanenv \
    --env OMP_NUM_THREADS="$PER_SUBJECT_THREADS" \
    --env ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$PER_SUBJECT_THREADS" \
    --env FS_LICENSE=/opt/freesurfer-license/license.txt \
    --bind "${LICENSE}:/opt/freesurfer-license/license.txt:ro" --bind "${ROOT}:/work" \
    "$SIF" /bin/bash -c "source /work/scripts/hcp_env.sh; \${HCPPIPEDIR}/DiffusionPreprocessing/DiffPreprocPipeline_PostEddy.sh \
      --path=/work/output --session=${subject} --dwiname=Diffusion \
      --gdcoeffs=NONE --dof=6 --select-best-b0=FALSE --combine-data-flag=1"
}

run_fmri() {
  local stage=$1 subject=$2 index=$3
  apptainer exec --cleanenv \
    --env OMP_NUM_THREADS="$PER_SUBJECT_THREADS" \
    --env ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$PER_SUBJECT_THREADS" \
    --env FS_LICENSE=/opt/freesurfer-license/license.txt \
    --bind "${LICENSE}:/opt/freesurfer-license/license.txt:ro" --bind "${ROOT}:/work" \
    "$SIF" /bin/bash /work/scripts/run_fmri_generic.sh "$stage" "$subject" "$index"
}

run_advanced_fmri() {
  local stage=$1 subject=$2
  apptainer exec --cleanenv \
    --env OMP_NUM_THREADS="$PER_SUBJECT_THREADS" \
    --env ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$PER_SUBJECT_THREADS" \
    --env FS_LICENSE=/opt/freesurfer-license/license.txt \
    --bind "${LICENSE}:/opt/freesurfer-license/license.txt:ro" --bind "${ROOT}:/work" \
    "$SIF" /bin/bash /work/scripts/run_advanced_fmri_generic.sh "$stage" "$subject"
}

process_subject() {
  local subject=$1
  local marker="${ROOT}/output/${subject}/.stage3_complete"
  if [[ -f "$marker" ]]; then
    echo "[$(date +%T)] SKIP subject=${subject} (already complete)"
    return 0
  fi

  local have_slot=0
  release_slot() { (( have_slot == 1 )) && { echo >&3; have_slot=0; }; }
  trap release_slot RETURN

  read -u 3; have_slot=1
  local log="${ROOT}/logs/stage3_${subject}_${SLURM_JOB_ID}.log"
  (
    set -euo pipefail
    echo "[$(date +%T)] === ${subject}: entry slot acquired (max ${ENTRY_MAX_CONCURRENT} concurrent) ==="

    local env_file="${ROOT}/raw_nifti/${subject}/subject.env"
    [[ -f "$env_file" ]] || { echo "missing subject env: $env_file"; exit 3; }
    source "$env_file"

    local has_dwi=0
    if [[ -n "${HCP_DWI_POS:-}" && "${HCP_DWI_POS}" != NONE ]]; then
      has_dwi=1
      echo "[$(date +%T)] === ${subject}: [1/N] PostEddy ==="
      run_post_eddy "$subject"
    else
      echo "[$(date +%T)] === ${subject}: no DWI data, skipping PostEddy ==="
    fi

    if (( HCP_FMRI_COUNT > 0 )); then
      echo "[$(date +%T)] === ${subject}: fMRIVolume (${HCP_FMRI_COUNT} runs) ==="
      for ((i=0; i<HCP_FMRI_COUNT; i++)); do run_fmri volume "$subject" "$i"; done

      echo "[$(date +%T)] === ${subject}: fMRISurface (${HCP_FMRI_COUNT} runs) ==="
      for ((i=0; i<HCP_FMRI_COUNT; i++)); do run_fmri surface "$subject" "$i"; done

      if (( HCP_FMRI_COUNT >= 2 )); then
        echo "[$(date +%T)] === ${subject}: waiting for FIX slot (max ${FIX_MAX_CONCURRENT} concurrent, separate cap) ==="
        local have_fix_slot=0
        release_fix_slot() { (( have_fix_slot == 1 )) && { echo >&5; have_fix_slot=0; }; }
        trap release_fix_slot EXIT
        read -u 5; have_fix_slot=1
        echo "[$(date +%T)] === ${subject}: FIX ==="
        run_advanced_fmri fix "$subject"
        release_fix_slot
        trap - EXIT
        echo "[$(date +%T)] === ${subject}: PostFix ==="
        run_advanced_fmri postfix "$subject"

        echo "[$(date +%T)] === ${subject}: waiting for MSMAll slot (max ${MSMALL_MAX_CONCURRENT} concurrent, separate cap) ==="
        local have_msmall_slot=0
        release_msmall_slot() { (( have_msmall_slot == 1 )) && { echo >&4; have_msmall_slot=0; }; }
        trap release_msmall_slot EXIT
        read -u 4; have_msmall_slot=1
        echo "[$(date +%T)] === ${subject}: MSMAll ==="
        run_advanced_fmri msmall "$subject"
      else
        echo "[$(date +%T)] === ${subject}: only 1 fMRI run, skipping FIX/PostFix/MSMAll ==="
      fi
    else
      echo "[$(date +%T)] === ${subject}: no fMRI runs, skipping fMRI stages ==="
    fi

    echo "[$(date +%T)] === ${subject}: STAGE3_COMPLETE ==="
  ) > "$log" 2>&1
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    touch "$marker"
  fi
  echo "[$(date +%T)] DONE subject=${subject} rc=${rc} (log: ${log})"
  return "$rc"
}

pids=()
while IFS= read -r subject; do
  [[ -z "$subject" ]] && continue
  process_subject "$subject" &
  pids+=($!)
done < "$SUBJECT_LIST"

fail=0
for pid in "${pids[@]}"; do
  wait "$pid" || fail=1
done

exec 3>&-
exec 4>&-
exec 5>&-
echo "[$(date +%T)] STAGE3_BATCH_COMPLETE fail=${fail}"
exit "$fail"

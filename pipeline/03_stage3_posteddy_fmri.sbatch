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
# Usage: sbatch --job-name=stage3_batch 03_stage3_posteddy_fmri.sbatch SUBJECT_LIST
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

# Two-tier concurrency (2026-09-27): a single flat cap sized for MSMAll's
# worst case (12.8 measured cores/subject) left PostEddy/fMRIVolume/
# fMRISurface/PostFix badly underusing the node whenever subjects weren't
# actually in MSMAll. Split into two semaphores instead: ENTRY_MAX_CONCURRENT
# admits subjects into the whole pipeline (sized for ICAFIX, the worst *other*
# phase, measured 2026-09-25 at 80 concurrent -> load 474/192, i.e. ~5.9
# cores/subject), and a separate, much tighter MSMALL_MAX_CONCURRENT gates
# only the MSMAll step itself. Worst realistic case is MSMALL_MAX_CONCURRENT
# subjects all in MSMAll at once (12.8 each) plus every other admitted
# subject simultaneously in ICAFIX (5.9 each):
#   6*12.8 + (20-6)*5.9 = 76.8 + 82.6 = 159.4, safely under the 192-core budget.
# A subject waiting for an MSMAll slot costs ~nothing (blocked on a pipe
# read) since FIX/PostFix -- the phases before MSMAll in this per-subject
# sequential pipeline -- have already finished for it by then.
#
# Measured from real subject logs (2026-09-27): PostEddy..PostFix averages
# ~4.9 hours, MSMAll itself only ~1 hour -- so per-node throughput is
# min(ENTRY_MAX_CONCURRENT/4.9h, MSMALL_MAX_CONCURRENT/1h) instead of the
# flat design's single_cap/(4.9h+1h); at 20/6 that's ~4.1 subjects/hour vs.
# the flat cap=12 design's ~2.0/hour -- roughly double.
ENTRY_MAX_CONCURRENT=20
MSMALL_MAX_CONCURRENT=6
PER_SUBJECT_THREADS=2

SEM_FIFO=$(mktemp -u /tmp/stage3_sem.XXXXXX)
mkfifo "$SEM_FIFO"; exec 3<>"$SEM_FIFO"; rm -f "$SEM_FIFO"
for _ in $(seq 1 "$ENTRY_MAX_CONCURRENT"); do echo >&3; done

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
        echo "[$(date +%T)] === ${subject}: FIX ==="
        run_advanced_fmri fix "$subject"
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
echo "[$(date +%T)] STAGE3_BATCH_COMPLETE fail=${fail}"
exit "$fail"

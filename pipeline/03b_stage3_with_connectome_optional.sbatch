#!/usr/bin/env bash
# Stage 3 (CPU node): everything after eddy. PostEddy has no GPU option in
# HCP Pipelines v6.0.0 (only the Eddy sub-script does), so it runs here on
# CPU along with the rest of the pipeline: fMRIVolume -> fMRISurface -> FIX
# -> PostFix -> MSMAll (all --matlab-run-mode=0, the compiled MCR runtime,
# not the licensed-MATLAB path), then our own MRtrix3 connectome pipeline
# for subjects that have diffusion data.
#
# Depends on Stage 1 (structural + PreEddy) for every subject, and on
# Stage 2 (GPU eddy) for subjects with DWI data before PostEddy can run.
#
# Concurrency: all these stages measured at a few GB to ~14GB peak RAM per
# subject (CPU-bound, not memory-bound -- see 2026-09-11 investigation).
# Capped at a CPU-budget-appropriate concurrency; no PostFreeSurfer-style
# outlier stage here.
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

ENTRY_MAX_CONCURRENT=20
PER_SUBJECT_THREADS=8

SEM_FIFO=$(mktemp -u /tmp/stage3_sem.XXXXXX)
mkfifo "$SEM_FIFO"; exec 3<>"$SEM_FIFO"; rm -f "$SEM_FIFO"
for _ in $(seq 1 "$ENTRY_MAX_CONCURRENT"); do echo >&3; done

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

run_connectome() {
  local subject=$1
  apptainer exec --cleanenv \
    --env NTHREADS="$PER_SUBJECT_THREADS" \
    --bind "${ROOT}:/work" \
    "$SIF" /opt/amed-connectome/scripts/run_pipeline.sh "$subject" \
      --hcpstyle --steps=1-5 \
      --input-root=/work/output --output-root=/work/output --fs-root=/work/output
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
        echo "[$(date +%T)] === ${subject}: MSMAll ==="
        run_advanced_fmri msmall "$subject"
      else
        echo "[$(date +%T)] === ${subject}: only 1 fMRI run, skipping FIX/PostFix/MSMAll ==="
      fi
    else
      echo "[$(date +%T)] === ${subject}: no fMRI runs, skipping fMRI stages ==="
    fi

    if (( has_dwi == 1 )); then
      echo "[$(date +%T)] === ${subject}: connectome ==="
      run_connectome "$subject"
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
echo "[$(date +%T)] STAGE3_BATCH_COMPLETE fail=${fail}"
exit "$fail"

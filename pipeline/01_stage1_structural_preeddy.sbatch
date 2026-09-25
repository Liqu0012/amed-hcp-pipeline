#!/usr/bin/env bash
# Stage 1 (CPU node): everything up through DiffPreprocPipeline_PreEddy.sh.
# None of these steps (conversion, PreFreeSurfer, FreeSurfer, PostFreeSurfer,
# PreEddy -- gradient-distortion prep + topup) are GPU-accelerated in HCP
# Pipelines v6.0.0, so all of it runs on a CPU node regardless.
#
# Concurrency limits (see 2026-09-11 memory investigation, the 2026-09-14
# production run that oversubscribed CPU by running 600+ subjects at once
# unthrottled, and a user-measured finding that giving one subject 8 OpenMP
# threads only yields ~1.5x speedup over 1 thread -- i.e. per-subject
# multi-threading has poor returns here. So threads-per-subject is kept at
# 1 and concurrency is maximized instead (task-level parallelism beats
# thread-level parallelism at this efficiency ratio), throttled down only
# where memory actually requires it:
#   ENTRY_MAX_CONCURRENT -- caps conversion/PreFreeSurfer/FreeSurfer/PreEddy
#     entries (all CPU-bound, a few GB each: ~1.7GB PreFS, ~7.6GB FreeSurfer
#     peak). Sized so that, even in the worst case of POST_MAX_CONCURRENT
#     PostFreeSurfer instances running at once (~420GB each), the remaining
#     node memory still covers this many entry-phase subjects at FreeSurfer's
#     ~7.6GB peak: (1536GB - 3*420GB) / 7.6GB =~ 36; set to 30 for margin.
#     At 1 thread/subject, 30 concurrent only uses 30 of 192 cores, so CPU
#     is not the constraint -- memory co-occurrence with PostFreeSurfer is.
#   POST_MAX_CONCURRENT  -- PostFreeSurfer alone measured ~330-420GB peak
#     RAM (native-resolution MSMSulc registration, independent of thread
#     count). A 1536GB node only safely holds 3 of these at once.
#
# Resumable via a "<output>/<subject>/.stage1_complete" sentinel -- rerunning
# with the same (or a superset) SUBJECT_LIST skips anything already done.
# Subjects with no DWI data (per raw_nifti/<subject>/subject.env) stop after
# PostFreeSurfer and are marked complete there; PreEddy only runs for
# subjects that actually have diffusion data.
#
# SUBJECT_LIST format: one "ARCHIVE<TAB>SUBJECT" pair per line.
# Usage: sbatch --job-name=stage1_batch run_stage1_pre_eddy.sbatch SUBJECT_LIST
#SBATCH --partition=ccalc
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=192
#SBATCH --mem=1500G
#SBATCH --time=30-00:00:00
#SBATCH --output=logs/stage1_batch_%x_%j.out
#SBATCH --error=logs/stage1_batch_%x_%j.err

set -uo pipefail
[[ $# -eq 1 ]] || { echo "usage: sbatch $0 SUBJECT_LIST" >&2; exit 2; }
SUBJECT_LIST=$1
[[ -f "$SUBJECT_LIST" ]] || { echo "missing subject list: $SUBJECT_LIST" >&2; exit 2; }

ROOT=${AMED_ROOT:-/data/juntendodb/amedhcp}          # override with your own data root
SIF=${HCP_SIF:-/data/juntendodb/containers/hcp_pipelines_v6_complete_20260831.sif}  # path to the container built from container/hcp_v6_complete.def
LICENSE=${FS_LICENSE:-$HOME/.licenses/freesurfer/license.txt}  # your own FreeSurfer license -- see https://surfer.nmr.mgh.harvard.edu/registration.html
test -s "$LICENSE"

ENTRY_MAX_CONCURRENT=150
POST_MAX_CONCURRENT=25
PER_SUBJECT_THREADS=1

ENTRY_SEM_FIFO=$(mktemp -u /tmp/entry_sem.XXXXXX)
mkfifo "$ENTRY_SEM_FIFO"; exec 3<>"$ENTRY_SEM_FIFO"; rm -f "$ENTRY_SEM_FIFO"
for _ in $(seq 1 "$ENTRY_MAX_CONCURRENT"); do echo >&3; done

POST_SEM_FIFO=$(mktemp -u /tmp/post_sem.XXXXXX)
mkfifo "$POST_SEM_FIFO"; exec 4<>"$POST_SEM_FIFO"; rm -f "$POST_SEM_FIFO"
for _ in $(seq 1 "$POST_MAX_CONCURRENT"); do echo >&4; done

run_structural_stage() {
  local stage=$1 subject=$2
  apptainer exec --cleanenv \
    --env OMP_NUM_THREADS="$PER_SUBJECT_THREADS" \
    --env ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$PER_SUBJECT_THREADS" \
    --env RECONALL_THREADS="$PER_SUBJECT_THREADS" \
    --env FS_LICENSE=/opt/freesurfer-license/license.txt \
    --bind "${LICENSE}:/opt/freesurfer-license/license.txt:ro" --bind "${ROOT}:/work" \
    "$SIF" /bin/bash /work/scripts/run_structural_generic.sh "$stage" "$subject"
}

run_pre_eddy() {
  local subject=$1
  # HCP_DWI_ECHO in raw_nifti/<subject>/subject.env is in seconds;
  # DiffPreprocPipeline_PreEddy.sh's --echospacing wants milliseconds
  # (DiffPreprocPipeline.sh itself does this same *1000 conversion
  # internally before calling PreEddy -- replicated here since we're
  # calling PreEddy directly).
  local echospacing_ms
  echospacing_ms=$(echo "$HCP_DWI_ECHO * 1000" | bc -l)
  apptainer exec --cleanenv \
    --env OMP_NUM_THREADS="$PER_SUBJECT_THREADS" \
    --env ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$PER_SUBJECT_THREADS" \
    --env FS_LICENSE=/opt/freesurfer-license/license.txt \
    --bind "${LICENSE}:/opt/freesurfer-license/license.txt:ro" --bind "${ROOT}:/work" \
    "$SIF" /bin/bash -c "source /work/scripts/hcp_env.sh; \${HCPPIPEDIR}/DiffusionPreprocessing/DiffPreprocPipeline_PreEddy.sh \
      --path=/work/output --session=${subject} --dwiname=Diffusion \
      --PEdir=${HCP_DWI_PE_DIR} --posData=${HCP_DWI_POS} --negData=${HCP_DWI_NEG} \
      --echospacing=${echospacing_ms} --b0maxbval=50 \
      --topup-config-file=\${HCPPIPEDIR_Config}/b02b0.cnf \
      --select-best-b0=FALSE --ensure-even-slices=FALSE --combine-data-flag=1"
}

process_subject() {
  local archive=$1 subject=$2
  local marker="${ROOT}/output/${subject}/.stage1_complete"
  if [[ -f "$marker" ]]; then
    echo "[$(date +%T)] SKIP subject=${subject} (already complete)"
    return 0
  fi

  local have_entry=0 have_post=0
  release_slots() {
    (( have_post == 1 )) && { echo >&4; have_post=0; }
    (( have_entry == 1 )) && { echo >&3; have_entry=0; }
  }
  trap release_slots RETURN

  read -u 3; have_entry=1
  local log="${ROOT}/logs/stage1_${subject}_${SLURM_JOB_ID}.log"
  (
    set -euo pipefail
    echo "[$(date +%T)] === ${subject}: entry slot acquired (max ${ENTRY_MAX_CONCURRENT} concurrent) ==="
    echo "[$(date +%T)] === ${subject}: [1/5] DICOM -> NIfTI conversion ==="
    "${ROOT}/scripts/convert_one_subject.sh" "$archive" "$subject" "${ROOT}/raw_nifti/${subject}"
    python3 "${ROOT}/scripts/build_subject_manifest.py" "${ROOT}/raw_nifti/${subject}"

    echo "[$(date +%T)] === ${subject}: [2/5] PreFreeSurfer ==="
    run_structural_stage pre "$subject"

    echo "[$(date +%T)] === ${subject}: [3/5] FreeSurfer ==="
    run_structural_stage fs "$subject"
  ) > "$log" 2>&1
  local rc=$?

  echo >&3; have_entry=0
  [[ $rc -ne 0 ]] && { echo "[$(date +%T)] DONE subject=${subject} rc=${rc} (log: ${log})"; return "$rc"; }

  read -u 4; have_post=1
  (
    set -euo pipefail
    echo "[$(date +%T)] === ${subject}: [4/5] PostFreeSurfer (post slot acquired, max ${POST_MAX_CONCURRENT}) ==="
    run_structural_stage post "$subject"
  ) >> "$log" 2>&1
  rc=$?
  echo >&4; have_post=0
  [[ $rc -ne 0 ]] && { echo "[$(date +%T)] DONE subject=${subject} rc=${rc} (log: ${log})"; return "$rc"; }

  local env_file="${ROOT}/raw_nifti/${subject}/subject.env"
  if [[ -f "$env_file" ]]; then
    (
      set -euo pipefail
      source "$env_file"
      if [[ -z "${HCP_DWI_POS:-}" || "${HCP_DWI_POS}" == NONE || -z "${HCP_DWI_NEG:-}" || "${HCP_DWI_NEG}" == NONE ]]; then
        echo "[$(date +%T)] === ${subject}: no diffusion series in raw data, skipping PreEddy ==="
      elif [[ -z "${HCP_DWI_ECHO:-}" ]]; then
        # Distinct from "no DWI": the data is there but unusable. Treating this
        # as a skip is what silently dropped diffusion for 576 subjects while
        # still marking them complete.
        echo "[$(date +%T)] ERROR ${subject}: diffusion present but HCP_DWI_ECHO unresolved" >&2
        exit 91
      else
        echo "[$(date +%T)] === ${subject}: [5/5] PreEddy ==="
        run_pre_eddy "$subject"
      fi
    ) >> "$log" 2>&1
    rc=$?
  fi

  if [[ $rc -eq 0 ]]; then
    touch "$marker"
    echo "[$(date +%T)] === ${subject}: STAGE1_COMPLETE ===" >> "$log"
  fi
  echo "[$(date +%T)] DONE subject=${subject} rc=${rc} (log: ${log})"
  return "$rc"
}

pids=()
while IFS=$'\t' read -r archive subject; do
  [[ -z "$archive" ]] && continue
  process_subject "$archive" "$subject" &
  pids+=($!)
done < "$SUBJECT_LIST"

fail=0
for pid in "${pids[@]}"; do
  wait "$pid" || fail=1
done

exec 3>&- 4>&-
echo "[$(date +%T)] STAGE1_BATCH_COMPLETE fail=${fail}"
exit "$fail"

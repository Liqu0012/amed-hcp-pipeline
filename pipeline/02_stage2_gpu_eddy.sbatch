#!/usr/bin/env bash
# Stage 2 (GPU node): DiffPreprocPipeline_Eddy.sh only -- the one sub-step
# of DiffusionPreprocessing that actually benefits from GPU
# (eddy_cuda11.0). Depends on Stage 1 having produced each subject's
# T1w/Diffusion/ pre-eddy working files.
#
# Subjects are spread over the allocated GPUs, PER_GPU of them sharing
# each card via CUDA_VISIBLE_DEVICES. Resumable via a
# "<output>/<subject>/.stage2_complete" sentinel.
#
# SUBJECT_LIST format: one SUBJECT per line.
# Usage: sbatch --job-name=stage2_batch run_stage2_gpu_eddy.sbatch SUBJECT_LIST
#SBATCH --partition=gcalc2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=30
#SBATCH --mem=500G
#SBATCH --gres=gpu:h100:3
#SBATCH --time=30-00:00:00
#SBATCH --output=logs/stage2_batch_%x_%j.out
#SBATCH --error=logs/stage2_batch_%x_%j.err

set -uo pipefail
[[ $# -eq 1 ]] || { echo "usage: sbatch $0 SUBJECT_LIST" >&2; exit 2; }
SUBJECT_LIST=$1
[[ -f "$SUBJECT_LIST" ]] || { echo "missing subject list: $SUBJECT_LIST" >&2; exit 2; }

ROOT=${AMED_ROOT:-/data/juntendodb/amedhcp}          # override with your own data root
SIF=${HCP_SIF:-/data/juntendodb/containers/hcp_pipelines_v6_complete_20260831.sif}  # path to the container built from container/hcp_v6_complete.def
LICENSE=${FS_LICENSE:-$HOME/.licenses/freesurfer/license.txt}  # your own FreeSurfer license -- see https://surfer.nmr.mgh.harvard.edu/registration.html
test -s "$LICENSE"

NUM_GPUS=3
PER_GPU=${PER_GPU:-16}

GPU_SEM_FIFO=$(mktemp -u /tmp/gpu_sem.XXXXXX)
mkfifo "$GPU_SEM_FIFO"; exec 3<>"$GPU_SEM_FIFO"; rm -f "$GPU_SEM_FIFO"
for ((g=0; g<NUM_GPUS; g++)); do
  for ((k=0; k<PER_GPU; k++)); do printf "%s" "$g" >&3; done
done

process_subject() {
  local subject=$1
  local marker="${ROOT}/output/${subject}/.stage2_complete"
  if [[ -f "$marker" ]]; then
    echo "[$(date +%T)] SKIP subject=${subject} (already complete)"
    return 0
  fi

  local have_gpu=0 gpu_id=""
  release_slot() {
    (( have_gpu == 1 )) && { printf "%s" "$gpu_id" >&3; have_gpu=0; }
  }
  trap release_slot RETURN

  local log="${ROOT}/logs/stage2_${subject}_${SLURM_JOB_ID}.log"
  echo "[$(date +%T)] ${subject}: waiting for a GPU slot (max $((NUM_GPUS * PER_GPU)) concurrent over ${NUM_GPUS} cards)"
  read -r -N 1 -u 3 gpu_id
  if [[ ! "$gpu_id" =~ ^[0-9]$ ]] || (( gpu_id >= NUM_GPUS )); then echo "[$(date +%T)] ${subject}: BAD GPU TOKEN [$gpu_id]" >&2; return 97; fi
  have_gpu=1
  (
    set -euo pipefail
    echo "[$(date +%T)] ${subject}: acquired GPU ${gpu_id}, running DiffPreprocPipeline_Eddy.sh"
    apptainer exec --cleanenv --nv \
      --env CUDA_VISIBLE_DEVICES="$gpu_id" \
      --env OMP_NUM_THREADS=1 \
      --env ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=1 \
      --env FS_LICENSE=/opt/freesurfer-license/license.txt \
      --bind "${LICENSE}:/opt/freesurfer-license/license.txt:ro" --bind "${ROOT}:/work" \
      "$SIF" /bin/bash -c "source /work/scripts/hcp_env.sh; \${HCPPIPEDIR}/DiffusionPreprocessing/DiffPreprocPipeline_Eddy.sh \
        --path=/work/output --session=${subject} --dwiname=Diffusion \
        --gpu=TRUE --cuda-version=11.0 \
        --extra-eddy-arg=--data_is_shelled --extra-eddy-arg=--repol"
  ) > "$log" 2>&1
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    touch "$marker"
    echo "[$(date +%T)] STAGE2_COMPLETE" >> "$log"
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
echo "[$(date +%T)] STAGE2_BATCH_COMPLETE fail=${fail}"
exit "$fail"

#!/usr/bin/env bash
# Stage 2 (GPU node): DiffPreprocPipeline_Eddy.sh only -- the one sub-step
# of DiffusionPreprocessing that actually benefits from GPU
# (eddy_cuda11.0). Depends on Stage 1 having produced each subject's
# T1w/Diffusion/ pre-eddy working files.
#
# MPS was tried and reverted (2026-09-26): with MPS correctly routing each
# subject to its own physical GPU (confirmed via nvidia-smi per-GPU process
# lists), utilization at full concurrency (65 subjects / 4 GPUs) measured
# 5-8%, WORSE than plain CUDA_VISIBLE_DEVICES sharing's already-low 23-28%.
# Conclusion: eddy's low GPU utilization isn't multi-process contention MPS
# can fix -- it's inherent to eddy's own sequential per-iteration host<->
# device round trips, and MPS's extra proxy hop made each round trip a
# little slower instead. Back to plain per-GPU CUDA_VISIBLE_DEVICES sharing.
#
# Subjects are spread over the allocated GPUs, PER_GPU of them sharing
# each card via CUDA_VISIBLE_DEVICES. Resumable via a
# "<output>/<subject>/.stage2_complete" sentinel.
#
# To scale NUM_GPUS: change --gres/NUM_GPUS/--cpus-per-task/--mem together,
# in the same ratio (this cluster's job-submit policy caps CPUs at 10 per
# requested GPU: 4 GPUs -> 40 CPUs -> 650G was generous headroom at
# ~1GB/subject VRAM, adjust to taste). A single job can request as many
# GPUs as your account's quota allows; only split into multiple submissions
# if you need more GPUs than fit in one job's own per-job request limit,
# in which case Slurm places them on the same physical GPU node (GRES is
# tracked per-device, not per-job) as long as enough cards are free.
#
# SUBJECT_LIST format: one SUBJECT per line.
# Usage: sbatch --job-name=stage2_batch 02_stage2_gpu_eddy.sbatch SUBJECT_LIST
#SBATCH --partition=gcalc2
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=40
#SBATCH --mem=650G
#SBATCH --gres=gpu:h100:4
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

NUM_GPUS=${NUM_GPUS:-4}          # must match #SBATCH --gres above (see header)
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

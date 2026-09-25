#!/usr/bin/env bash
# PreEddy repair run (CPU node).
#
# Why this exists: build_subject_manifest.py used to treat the scanner's
# DERIVED diffusion maps (TRACEW / ADC, JTD's clinical ep2d_tra series) as
# real DWI series. Their readout differs from the HCP-style DWI (0.000248181 s
# vs 0.000619994 s), so the echo-spacing set had two members, the manifest
# wrote HCP_DWI_ECHO='' rather than erroring, and run_stage1_pre_eddy.sbatch's
# gate read that empty value as "subject has no DWI" -- skipping PreEddy while
# still leaving rc=0 and touching .stage1_complete. 576 subjects (all
# JTD_Prisma_HARP) were marked complete with an empty Diffusion/ directory.
#
# The manifest is fixed (is_derived_diffusion()); this script regenerates
# subject.env for the affected subjects and runs only the missing step. Their
# structural outputs were verified sound (recon-all "finished without error",
# all 12 key outputs present) and are left untouched.
#
# Concurrency: PreEddy is gradient-distortion prep plus topup -- a few GB per
# subject, nothing like PostFreeSurfer's ~400GB. Memory is not the binding
# constraint here, cores are, so concurrency x threads is sized to the node's
# 192 cores.
#
# Resumable via "<output>/<subject>/.preeddy_complete".
#
# SUBJECT_LIST format: one SUBJECT id per line.
# Usage: sbatch --job-name=preeddy_fix run_repair_preeddy.sbatch SUBJECT_LIST
#SBATCH --partition=ccalc
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=192
#SBATCH --mem=1500G
#SBATCH --time=5-00:00:00
#SBATCH --output=logs/preeddy_fix_%x_%j.out
#SBATCH --error=logs/preeddy_fix_%x_%j.err

set -uo pipefail
[[ $# -eq 1 ]] || { echo "usage: sbatch $0 SUBJECT_LIST" >&2; exit 2; }
SUBJECT_LIST=$1
[[ -f "$SUBJECT_LIST" ]] || { echo "missing subject list: $SUBJECT_LIST" >&2; exit 2; }

ROOT=${AMED_ROOT:-/data/juntendodb/amedhcp}          # override with your own data root
SIF=${HCP_SIF:-/data/juntendodb/containers/hcp_pipelines_v6_complete_20260831.sif}  # path to the container built from container/hcp_v6_complete.def
LICENSE=${FS_LICENSE:-$HOME/.licenses/freesurfer/license.txt}  # your own FreeSurfer license -- see https://surfer.nmr.mgh.harvard.edu/registration.html
test -s "$LICENSE"

MAX_CONCURRENT=48
PER_SUBJECT_THREADS=4

SEM_FIFO=$(mktemp -u /tmp/preeddy_sem.XXXXXX)
mkfifo "$SEM_FIFO"; exec 3<>"$SEM_FIFO"; rm -f "$SEM_FIFO"
for _ in $(seq 1 "$MAX_CONCURRENT"); do echo >&3; done

echo "[$(date +%T)] host=$(hostname) list=$(basename "$SUBJECT_LIST") subjects=$(wc -l < "$SUBJECT_LIST") concurrency=${MAX_CONCURRENT}x${PER_SUBJECT_THREADS}threads"

run_pre_eddy() {
  local subject=$1
  # HCP_DWI_ECHO is in seconds; DiffPreprocPipeline_PreEddy.sh --echospacing
  # wants milliseconds. DiffPreprocPipeline.sh:305 does this same *1000
  # conversion before calling PreEddy; replicated here because the staged
  # layout calls PreEddy directly.
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
  local subject=$1
  local marker="${ROOT}/output/${subject}/.preeddy_complete"
  if [[ -f "$marker" ]] || [[ -s "${ROOT}/output/${subject}/Diffusion/topup/hifib0.nii.gz" ]]; then
    echo "[$(date +%T)] SKIP subject=${subject} (PreEddy already present)"
    return 0
  fi

  local have_slot=0
  release_slot() { (( have_slot == 1 )) && { echo >&3; have_slot=0; }; }
  trap release_slot RETURN

  read -u 3; have_slot=1
  local log="${ROOT}/logs/preeddy_fix_${subject}_${SLURM_JOB_ID}.log"
  local rc=0
  (
    set -uo pipefail
    echo "[$(date +%T)] === ${subject}: regenerating manifest ==="
    python3 "${ROOT}/scripts/build_subject_manifest.py" "${ROOT}/raw_nifti/${subject}" || exit 92

    source "${ROOT}/raw_nifti/${subject}/subject.env"

    # Distinguish "no diffusion data" from "diffusion present but unusable
    # parameters" -- conflating the two is what hid this bug for 576 subjects.
    if [[ -z "${HCP_DWI_POS:-}" || "${HCP_DWI_POS}" == NONE || -z "${HCP_DWI_NEG:-}" || "${HCP_DWI_NEG}" == NONE ]]; then
      echo "[$(date +%T)] ${subject}: no diffusion series in raw data, nothing to repair"
      exit 93
    fi
    if [[ -z "${HCP_DWI_ECHO:-}" ]]; then
      echo "[$(date +%T)] ERROR ${subject}: diffusion present but HCP_DWI_ECHO unresolved" >&2
      exit 91
    fi

    echo "[$(date +%T)] === ${subject}: PreEddy (echo=${HCP_DWI_ECHO}s pedir=${HCP_DWI_PE_DIR}) ==="
    run_pre_eddy "$subject"
  ) > "$log" 2>&1
  rc=$?

  echo >&3; have_slot=0

  if [[ $rc -eq 0 ]] && [[ -s "${ROOT}/output/${subject}/Diffusion/topup/hifib0.nii.gz" ]]; then
    touch "$marker"
    echo "[$(date +%T)] DONE subject=${subject} rc=0 REPAIRED (log: ${log})"
    return 0
  fi
  [[ $rc -eq 0 ]] && rc=94   # PreEddy returned 0 but produced no topup output
  echo "[$(date +%T)] DONE subject=${subject} rc=${rc} (log: ${log})"
  return "$rc"
}

pids=()
while read -r subject; do
  [[ -z "$subject" ]] && continue
  process_subject "$subject" &
  pids+=($!)
done < "$SUBJECT_LIST"

fail=0
for pid in "${pids[@]}"; do
  wait "$pid" || fail=1
done

exec 3>&-
echo "[$(date +%T)] PREEDDY_REPAIR_COMPLETE fail=${fail}"
exit "$fail"

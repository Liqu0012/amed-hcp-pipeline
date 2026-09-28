#!/usr/bin/env bash
# PostEddy repair run (CPU node): redo the AP/PA combine step with
# --combine-data-flag=2 for subjects already processed under flag=1.
#
# Why this exists: --combine-data-flag=1 averages each AP/PA volume pair
# by acquisition index, which is only correct if the two phase-encoding
# acquisitions are gradient-direction-matched at each index. See the
# "PostEddy's AP/PA combine flag" section of the README for how that was
# found to be false for part of this cohort (raw .bval files showed b~700
# paired with b~2000 at the same index in one subject; the fix in
# 03_stage3_posteddy_fmri.sbatch is flag=2 going forward). This script is
# for subjects that already completed stage 3 *before* that fix landed --
# their diffusion output was built with the wrong flag and needs redoing.
#
# This does NOT rerun eddy (stage 2): eddy corrects each original volume
# independently of how PostEddy later combines them, so its output is
# reused as-is. It also does NOT touch fMRIVolume/fMRISurface/FIX/PostFix/
# MSMAll -- none of those depend on this flag, and this subject's existing
# .stage3_complete marker (and everything it represents) is left alone.
#
# Isolation: the existing "<dwiname>/eddy" and "<dwiname>/topup" that
# PostEddy needs as input live inside the SAME directory tree its own
# combined output (data.nii.gz/bvals/bvecs/...) gets written into --
# DiffPreprocPipeline_PostEddy.sh has no option to read one dwiname and
# write another. So this script copies the whole existing "Diffusion" tree
# to "Diffusion_flag2" first (reusing eddy/topup, not rerunning them), then
# runs PostEddy with --dwiname=Diffusion_flag2 -- the original "Diffusion"
# directory (built under flag=1) is never modified. Once you've validated
# a subject's Diffusion_flag2 output, decide for yourself whether to
# replace Diffusion/ with it and update anything downstream that points at
# a hardcoded "Diffusion" dwiname; this script does not do that for you.
#
# Resumable via "<output>/<subject>/.posteddy_flag2_complete".
#
# SUBJECT_LIST format: one SUBJECT id per line -- subjects that already
# have DWI data and already completed stage 3 under the old flag=1.
# Usage: sbatch --job-name=posteddy_fix repair_posteddy_flag2.sbatch SUBJECT_LIST
#SBATCH --partition=ccalc
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=192
#SBATCH --mem=1500G
#SBATCH --time=3-00:00:00
#SBATCH --output=logs/posteddy_fix_%x_%j.out
#SBATCH --error=logs/posteddy_fix_%x_%j.err

set -uo pipefail
[[ $# -eq 1 ]] || { echo "usage: sbatch $0 SUBJECT_LIST" >&2; exit 2; }
SUBJECT_LIST=$1
[[ -f "$SUBJECT_LIST" ]] || { echo "missing subject list: $SUBJECT_LIST" >&2; exit 2; }

ROOT=${AMED_ROOT:-/data/juntendodb/amedhcp}          # override with your own data root
SIF=${HCP_SIF:-/data/juntendodb/containers/hcp_pipelines_v6_complete_20260831.sif}  # path to the container built from container/hcp_v6_complete.def
LICENSE=${FS_LICENSE:-$HOME/.licenses/freesurfer/license.txt}  # your own FreeSurfer license -- see https://surfer.nmr.mgh.harvard.edu/registration.html
test -s "$LICENSE"

MAX_CONCURRENT=${MAX_CONCURRENT:-30}   # PostEddy alone is a light CPU step; see 03_stage3_posteddy_fmri.sbatch's own concurrency notes if you need to retune this
PER_SUBJECT_THREADS=2

SEM_FIFO=$(mktemp -u /tmp/posteddy_fix_sem.XXXXXX)
mkfifo "$SEM_FIFO"; exec 3<>"$SEM_FIFO"; rm -f "$SEM_FIFO"
for _ in $(seq 1 "$MAX_CONCURRENT"); do echo >&3; done

echo "[$(date +%T)] host=$(hostname) list=$(basename "$SUBJECT_LIST") subjects=$(wc -l < "$SUBJECT_LIST") concurrency=${MAX_CONCURRENT}x${PER_SUBJECT_THREADS}threads"

run_post_eddy_flag2() {
  local subject=$1
  apptainer exec --cleanenv \
    --env OMP_NUM_THREADS="$PER_SUBJECT_THREADS" \
    --env ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$PER_SUBJECT_THREADS" \
    --env FS_LICENSE=/opt/freesurfer-license/license.txt \
    --bind "${LICENSE}:/opt/freesurfer-license/license.txt:ro" --bind "${ROOT}:/work" \
    "$SIF" /bin/bash -c "source /work/scripts/hcp_env.sh; \${HCPPIPEDIR}/DiffusionPreprocessing/DiffPreprocPipeline_PostEddy.sh \
      --path=/work/output --session=${subject} --dwiname=Diffusion_flag2 \
      --gdcoeffs=NONE --dof=6 --select-best-b0=FALSE --combine-data-flag=2"
}

process_subject() {
  local subject=$1
  local marker="${ROOT}/output/${subject}/.posteddy_flag2_complete"
  local orig_diff="${ROOT}/output/${subject}/Diffusion"
  local new_diff="${ROOT}/output/${subject}/Diffusion_flag2"
  if [[ -f "$marker" ]]; then
    echo "[$(date +%T)] SKIP subject=${subject} (already repaired)"
    return 0
  fi
  if [[ ! -s "${orig_diff}/eddy/eddy_unwarped_images.nii.gz" ]]; then
    echo "[$(date +%T)] SKIP subject=${subject} (no eddy output at ${orig_diff}/eddy -- run/verify stage 2 first, e.g. tools/qc_stage2.py)"
    return 0
  fi

  local have_slot=0
  release_slot() { (( have_slot == 1 )) && { echo >&3; have_slot=0; }; }
  trap release_slot RETURN

  read -u 3; have_slot=1
  local log="${ROOT}/logs/posteddy_fix_${subject}_${SLURM_JOB_ID}.log"
  (
    set -uo pipefail
    echo "[$(date +%T)] === ${subject}: copying ${orig_diff} -> ${new_diff} (reusing eddy/topup, not rerunning them) ==="
    rm -rf "$new_diff"
    cp -a "$orig_diff" "$new_diff" || exit 95
    echo "[$(date +%T)] === ${subject}: PostEddy --combine-data-flag=2 into ${new_diff} ==="
    run_post_eddy_flag2 "$subject"
  ) > "$log" 2>&1
  local rc=$?

  if [[ $rc -eq 0 ]] && [[ -s "${new_diff}/data.nii.gz" ]]; then
    touch "$marker"
    echo "[$(date +%T)] DONE subject=${subject} rc=0 REPAIRED -> ${new_diff} (log: ${log})"
    return 0
  fi
  [[ $rc -eq 0 ]] && rc=96   # PostEddy returned 0 but produced no combined output
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
echo "[$(date +%T)] POSTEDDY_FLAG2_REPAIR_COMPLETE fail=${fail}"
exit "$fail"

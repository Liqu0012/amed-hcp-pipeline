#!/usr/bin/env bash
set -Eeuo pipefail

session="${1:?Usage: hcp_structural_session.sh SESSION_ID}"
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe session ID: $session" >&2; exit 2; }

image="${HCP_IMAGE:?HCP_IMAGE is required}"
freesurfer="${HCP_FS_HOME:-}"
license="${HCP_FS_LICENSE:?HCP_FS_LICENSE is required}"
study="${HCP_STUDY:?HCP_STUDY is required}"
runtime="${HCP_CONTAINER_RUNTIME:-apptainer}"
session_root="$study/$session"
fs_subject="$session_root/T1w/$session"
complete_marker="$session_root/.hcp_structural_complete.ok"
fs_marker="$session_root/.hcp_freesurfer_stage.ok"
threads="${HCP_CPUS_PER_SESSION:-${SLURM_CPUS_PER_TASK:-8}}"

[[ -s "$image" ]] || { echo "Missing container: $image" >&2; exit 1; }
[[ -z "$freesurfer" || -x "$freesurfer/bin/recon-all" ]] || { echo "Missing FreeSurfer: $freesurfer" >&2; exit 1; }
[[ -s "$license" ]] || { echo "Missing license: $license" >&2; exit 1; }
for f in T1w/T1w_acpc_dc_restore.nii.gz T1w/T1w_acpc_dc_restore_brain.nii.gz; do
  [[ -s "$session_root/$f" ]] || { echo "Missing PreFreeSurfer output: $session_root/$f" >&2; exit 1; }
done
t2w_image="$session_root/T1w/T2w_acpc_dc_restore.nii.gz"
[[ -s "$t2w_image" ]] || t2w_image=NONE
processing_mode=HCPStyleData
[[ "$t2w_image" == NONE ]] && processing_mode=LegacyStyleData

if [[ -s "$complete_marker" ]]; then
  echo "Already complete: $session"
  exit 0
fi

# Prevent two jobs from writing the same session simultaneously.
exec 9>"$session_root/.hcp_structural.lock"
flock -n 9 || { echo "Session is already running: $session" >&2; exit 3; }

export OMP_NUM_THREADS="$threads"
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="$threads"
scratch_base="${SLURM_SCRATCH:-/tmp}/hcp-${session}-${SLURM_PROCID:-0}"
export TMPDIR="$scratch_base/tmp"
mkdir -p "$TMPDIR"

# Preserve failed FreeSurfer attempts. Never merge a failed subject tree into a retry.
if [[ -f "$fs_subject/scripts/recon-all.error" ]]; then
  mv "$fs_subject" "${fs_subject}.failed-${SLURM_JOB_ID:-manual}-$(date +%Y%m%dT%H%M%S)"
  rm -f "$fs_marker"
fi

"$runtime" exec --bind "$TMPDIR:$TMPDIR" "$image" bash -c '
  set -o pipefail
  source /opt/qunex/env/qunex_environment.sh >/dev/null 2>&1 || true
  unset -f which 2>/dev/null || true
  export FS_LICENSE="'"$license"'"
  export LC_ALL=C LANG=C
  if [[ -n "'"$freesurfer"'" ]]; then export FREESURFER_HOME="'"$freesurfer"'"; fi
  : "${FREESURFER_HOME:?FreeSurfer is unavailable inside the container and HCP_FS_HOME is empty}"
  source "$FREESURFER_HOME/SetUpFreeSurfer.sh" >/dev/null
  set -Ee
  study="'"$study"'"
  session="'"$session"'"
  threads="'"$threads"'"
  t2w_image="'"$t2w_image"'"
  processing_mode="'"$processing_mode"'"

  if [[ ! -s "$study/$session/.hcp_freesurfer_stage.ok" ]]; then
    echo "=== FreeSurfer stage started: $(date) ==="
    "$HCPPIPEDIR/FreeSurfer/FreeSurferPipeline.sh" \
      --session="$session" \
      --session-dir="$study/$session/T1w" \
      --t1w-image="$study/$session/T1w/T1w_acpc_dc_restore.nii.gz" \
      --t1w-brain="$study/$session/T1w/T1w_acpc_dc_restore_brain.nii.gz" \
      --t2w-image="$t2w_image" \
      --processing-mode="$processing_mode" \
      --extra-reconall-arg=-parallel \
      --extra-reconall-arg=-openmp \
      --extra-reconall-arg="$threads"
    touch "$study/$session/.hcp_freesurfer_stage.ok"
    echo "=== FreeSurfer stage completed: $(date) ==="
  fi

  echo "=== PostFreeSurfer stage started: $(date) ==="
  "$HCPPIPEDIR/PostFreeSurfer/PostFreeSurferPipeline.sh" \
    --study-folder="$study" --subject="$session" \
    --processing-mode="$processing_mode" \
    --surfatlasdir="$HCPPIPEDIR_Templates/standard_mesh_atlases" \
    --grayordinatesdir="$HCPPIPEDIR_Templates/91282_Greyordinates" \
    --grayordinatesres=2 --hiresmesh=164 --lowresmesh=32 \
    --subcortgraylabels="$HCPPIPEDIR_Config/FreeSurferSubcorticalLabelTableLut.txt" \
    --freesurferlabels="$HCPPIPEDIR_Config/FreeSurferAllLut.txt" \
    --refmyelinmaps="$HCPPIPEDIR_Templates/standard_mesh_atlases/Conte69.MyelinMap_BC.164k_fs_LR.dscalar.nii" \
    --regname=MSMSulc --use-ind-mean=YES --structural-qc=no
  echo "=== PostFreeSurfer stage completed: $(date) ==="
'

printf 'session=%s\ncompleted=%s\njob=%s\n' "$session" "$(date -Is)" "${SLURM_JOB_ID:-manual}" > "$complete_marker"
echo "HCP structural pipeline completed: $session"

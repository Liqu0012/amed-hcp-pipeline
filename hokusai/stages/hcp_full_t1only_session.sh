#!/usr/bin/env bash
set -Eeuo pipefail

session="${1:?Usage: hcp_full_t1only_session.sh SESSION ARCHIVE_OR_ARCHIVE_LIST}"
archive="${2:?Usage: hcp_full_t1only_session.sh SESSION ARCHIVE_OR_ARCHIVE_LIST}"
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe session: $session" >&2; exit 2; }
IFS=@ read -r -a archives <<< "$archive"
((${#archives[@]} > 0)) || { echo "No archives supplied" >&2; exit 1; }
for archive_path in "${archives[@]}"; do
  [[ -s "$archive_path" ]] || { echo "Missing archive: $archive_path" >&2; exit 1; }
done

image="${HCP_IMAGE:?HCP_IMAGE is required}"
study="${HCP_STUDY:?HCP_STUDY is required}"
runtime="${HCP_CONTAINER_RUNTIME:-apptainer}"
session_root="$study/$session"
prefree_marker="$session_root/.hcp_prefreesurfer_stage.ok"
scratch="${SLURM_SCRATCH:?SLURM_SCRATCH is required}/t1only-${session}"
dicom="$scratch/dicom"
nifti="$scratch/nifti"

mkdir -p "$session_root" "$dicom" "$nifti" "$scratch/tmp"
export TMPDIR="$scratch/tmp"

if [[ ! -s "$prefree_marker" ]]; then
  echo "=== T1-only DICOM extraction started: $(date) ==="
  for i in "${!archives[@]}"; do
    mkdir -p "$dicom/archive_$i"
    unzip -q "${archives[$i]}" -d "$dicom/archive_$i"
  done

  echo "=== T1-only dcm2niix started: $(date) ==="
  "$runtime" exec --bind "$scratch:$scratch" "$image" bash -c '
    source /opt/qunex/env/qunex_environment.sh >/dev/null 2>&1 || true
    unset -f which 2>/dev/null || true
    dcm2niix -z y -b y -f "%p_%s" -o "'"$nifti"'" "'"$dicom"'"
  '

  t1=""
  # Prefer the unfiltered original GE BRAVO volume.  Keio's anonymized export
  # uses a generic protocol name, while SeriesDescription still identifies the
  # 3D T1 acquisition (for example "ORIG Sag BRAVO 3D").
  for description_pattern in \
      'ORIG[^"[:cntrl:]]*BRAVO' \
      '(BRAVO|3D-IR-T1SPGR|MPRAGE|T1w|T1[_ -]?MPR)'; do
    for json in "$nifti"/*.json; do
      [[ -f "$json" ]] || continue
      grep -qiE '"MRAcquisitionType"[[:space:]]*:[[:space:]]*"3D"' "$json" || continue
      grep -qiE '"SeriesDescription".*'"$description_pattern" "$json" || continue
      grep -qiE '"ImageType".*"DERIVED"' "$json" && continue
      candidate="${json%.json}.nii.gz"
      [[ -s "$candidate" ]] && { t1="$candidate"; break 2; }
    done
  done
  if [[ -z "$t1" ]]; then
    t1=$(find "$nifti" -maxdepth 1 -type f \( -iname '*BRAVO*.nii.gz' -o -iname '*T1*MPR*.nii.gz' -o -iname '*T1SPGR*.nii.gz' \) ! -iname '*NORM*' | sort -V | head -1 || true)
  fi
  [[ -n "$t1" && -s "$t1" ]] || { echo "No usable 3D T1 found for $session" >&2; exit 4; }
  echo "Selected T1-only input: $t1"

  echo "=== T1-only PreFreeSurfer started: $(date) ==="
  "$runtime" exec --bind "$scratch:$scratch" "$image" bash -c '
    set -o pipefail
    source /opt/qunex/env/qunex_environment.sh >/dev/null 2>&1 || true
    unset -f which 2>/dev/null || true
    set -Ee
    T="$HCPPIPEDIR_Templates"
    C="$HCPPIPEDIR_Config"
    "$HCPPIPEDIR/PreFreeSurfer/PreFreeSurferPipeline.sh" \
      --path="'"$study"'" --session="'"$session"'" \
      --t1="'"$t1"'" --t2=NONE \
      --t1template="$T/MNI152_T1_0.8mm.nii.gz" \
      --t1templatebrain="$T/MNI152_T1_0.8mm_brain.nii.gz" \
      --t1template2mm="$T/MNI152_T1_2mm.nii.gz" \
      --t2template="$T/MNI152_T2_0.8mm.nii.gz" \
      --t2templatebrain="$T/MNI152_T2_0.8mm_brain.nii.gz" \
      --t2template2mm="$T/MNI152_T2_2mm.nii.gz" \
      --templatemask="$T/MNI152_T1_0.8mm_brain_mask.nii.gz" \
      --template2mmmask="$T/MNI152_T1_2mm_brain_mask_dil.nii.gz" \
      --brainsize=150 --fnirtconfig="$C/T1_2_MNI152_2mm.cnf" \
      --fmapmag=NONE --fmapphase=NONE --fmapcombined=NONE --echodiff=NONE \
      --SEPhaseNeg=NONE --SEPhasePos=NONE --seechospacing=NONE --seunwarpdir=NONE \
      --t1samplespacing=NONE --t2samplespacing=NONE --unwarpdir=NONE \
      --gdcoeffs=NONE --avgrdcmethod=NONE --topupconfig=NONE \
      --processing-mode=LegacyStyleData
  '
  printf 'session=%s\narchive=%s\nmode=t1-only\ncompleted=%s\n' \
    "$session" "$archive" "$(date -Is)" > "$prefree_marker"
  echo "=== T1-only PreFreeSurfer completed: $(date) ==="
fi

exec "${HCP_STAGE_SCRIPT_DIR:?HCP_STAGE_SCRIPT_DIR is required}/hcp_structural_session.sh" "$session"

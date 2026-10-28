#!/usr/bin/env bash
set -Eeuo pipefail
# Structural stage entry: conversion/selection (shared with the convert stage),
# PreFreeSurfer, then FreeSurfer + PostFreeSurfer (hcp_structural_session.sh).
# 2026-10-28: PreFreeSurfer now gets exactly one T1w and one T2w selected from
# DICOM metadata (no averaging) and the same readout-distortion settings as
# the DB v6 production run: SE TOPUP pair nearest the T1, DwellTime sample
# spacing, unwarpdir=z, usejacobian=FALSE.

session="${1:?Usage: hcp_full_test_session.sh SESSION ARCHIVE_OR_ARCHIVE_LIST}"
archive="${2:?Usage: hcp_full_test_session.sh SESSION ARCHIVE_OR_ARCHIVE_LIST}"
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe session: $session" >&2; exit 2; }

image="${HCP_IMAGE:?HCP_IMAGE is required}"
study="${HCP_STUDY:?HCP_STUDY is required}"
runtime="${HCP_CONTAINER_RUNTIME:-apptainer}"
stage_dir="${HCP_STAGE_SCRIPT_DIR:?HCP_STAGE_SCRIPT_DIR is required}"
session_root="$study/$session"
unproc="$session_root/unprocessed/3T"
prefree_marker="$session_root/.hcp_prefreesurfer_stage.ok"

bash "$stage_dir/hcp_convert_session.sh" "$session" "$archive"
source "$unproc/params.sh"

if [[ ! -s "$prefree_marker" ]]; then
  t1="$unproc/T1w_MPR.nii.gz"
  t2="$unproc/T2w_SPC.nii.gz"
  [[ -s "$t1" && -s "$t2" && -n "$T1_DWELL_SEC" && -n "$T2_DWELL_SEC" ]] || {
    echo "T1/T2 or DwellTime unavailable for $session" >&2; exit 4; }
  if [[ "$STRUCT_SE_NEG" != NONE ]]; then
    distortion="--SEPhaseNeg=$STRUCT_SE_NEG --SEPhasePos=$STRUCT_SE_POS --seechospacing=$STRUCT_SE_ECHOSPACING_SEC --seunwarpdir=j --avgrdcmethod=TOPUP --topupconfig=TOPUPCNF"
  else
    distortion="--SEPhaseNeg=NONE --SEPhasePos=NONE --seechospacing=NONE --seunwarpdir=NONE --avgrdcmethod=NONE --topupconfig=NONE"
  fi
  echo "Selected T1: $t1 (dwell $T1_DWELL_SEC)"
  echo "Selected T2: $t2 (dwell $T2_DWELL_SEC)"
  echo "Readout distortion: $distortion"

  scratch="${SLURM_SCRATCH:-/tmp}/prefs-${session}"
  mkdir -p "$scratch/tmp"
  export TMPDIR="$scratch/tmp"
  echo "=== PreFreeSurfer started: $(date) ==="
  "$runtime" exec --bind "$scratch:$scratch" "$image" bash -c '
    set -o pipefail
    source /opt/qunex/env/qunex_environment.sh >/dev/null 2>&1 || true
    unset -f which 2>/dev/null || true
    set -Ee
    T="$HCPPIPEDIR_Templates"
    C="$HCPPIPEDIR_Config"
    distortion="'"$distortion"'"
    distortion="${distortion/TOPUPCNF/$C/b02b0.cnf}"
    "$HCPPIPEDIR/PreFreeSurfer/PreFreeSurferPipeline.sh" \
      --path="'"$study"'" --session="'"$session"'" \
      --t1="'"$t1"'" --t2="'"$t2"'" \
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
      --gdcoeffs=NONE --usejacobian=FALSE \
      --t1samplespacing="'"$T1_DWELL_SEC"'" --t2samplespacing="'"$T2_DWELL_SEC"'" \
      --unwarpdir=z --processing-mode=HCPStyleData \
      $distortion
  '
  printf 'session=%s\narchive=%s\ncompleted=%s\n' "$session" "$archive" "$(date -Is)" > "$prefree_marker"
  echo "=== PreFreeSurfer completed: $(date) ==="
fi

exec bash "$stage_dir/hcp_structural_session.sh" "$session"

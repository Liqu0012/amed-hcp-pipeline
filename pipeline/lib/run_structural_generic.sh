#!/usr/bin/env bash
set -euo pipefail
source /work/scripts/hcp_env.sh

[[ $# -eq 2 ]] || { echo "usage: $0 pre|fs|post SUBJECT" >&2; exit 2; }
stage=$1
SESSION=$2
STUDY=/work/output
ENV_FILE=/work/raw_nifti/${SESSION}/subject.env
[[ -f "$ENV_FILE" ]] || { echo "missing subject env: $ENV_FILE" >&2; exit 3; }
source "$ENV_FILE"
[[ "$HCP_SUBJECT" == "$SESSION" ]] || { echo "subject env mismatch" >&2; exit 3; }
export SUBJECTS_DIR=${STUDY}

case "$stage" in
  pre)
    [[ -n "$HCP_T1" && -n "$HCP_T2" ]] || { echo "T1/T2 unavailable" >&2; exit 4; }
    distortion_args=(
      --fmapmag=NONE --fmapphase=NONE --fmapcombined=NONE --echodiff=NONE
      --gdcoeffs=NONE --usejacobian=FALSE
    )
    if [[ "$HCP_STRUCT_FMAP_NEG" != NONE && "$HCP_STRUCT_FMAP_POS" != NONE && -n "$HCP_STRUCT_FMAP_ECHO" ]]; then
      distortion_args+=(
        --SEPhaseNeg="$HCP_STRUCT_FMAP_NEG"
        --SEPhasePos="$HCP_STRUCT_FMAP_POS"
        --seechospacing="$HCP_STRUCT_FMAP_ECHO"
        --seunwarpdir=j
        --avgrdcmethod=TOPUP
        --topupconfig="${HCPPIPEDIR_Config}/b02b0.cnf"
      )
    else
      distortion_args+=(
        --SEPhaseNeg=NONE --SEPhasePos=NONE --seechospacing=NONE
        --seunwarpdir=NONE --avgrdcmethod=NONE --topupconfig=NONE
      )
    fi
    "${HCPPIPEDIR}/PreFreeSurfer/PreFreeSurferPipeline.sh" \
      --path="$STUDY" --session="$SESSION" --t1="$HCP_T1" --t2="$HCP_T2" \
      --t1template="${HCPPIPEDIR_Templates}/MNI152_T1_0.8mm.nii.gz" \
      --t1templatebrain="${HCPPIPEDIR_Templates}/MNI152_T1_0.8mm_brain.nii.gz" \
      --t1template2mm="${HCPPIPEDIR_Templates}/MNI152_T1_2mm.nii.gz" \
      --t2template="${HCPPIPEDIR_Templates}/MNI152_T2_0.8mm.nii.gz" \
      --t2templatebrain="${HCPPIPEDIR_Templates}/MNI152_T2_0.8mm_brain.nii.gz" \
      --t2template2mm="${HCPPIPEDIR_Templates}/MNI152_T2_2mm.nii.gz" \
      --templatemask="${HCPPIPEDIR_Templates}/MNI152_T1_0.8mm_brain_mask.nii.gz" \
      --template2mmmask="${HCPPIPEDIR_Templates}/MNI152_T1_2mm_brain_mask_dil.nii.gz" \
      --brainsize=150 --fnirtconfig="${HCPPIPEDIR_Config}/T1_2_MNI152_2mm.cnf" \
      --t1samplespacing="$HCP_T1_DWELL" --t2samplespacing="$HCP_T2_DWELL" \
      --unwarpdir=z --processing-mode=HCPStyleData \
      "${distortion_args[@]}"
    ;;
  fs)
    SESSION_DIR=${STUDY}/${SESSION}/T1w
    "${HCPPIPEDIR}/FreeSurfer/FreeSurferPipeline.sh" \
      --session="$SESSION" --session-dir="$SESSION_DIR" \
      --t1w-image="${SESSION_DIR}/T1w_acpc_dc_restore.nii.gz" \
      --t1w-brain="${SESSION_DIR}/T1w_acpc_dc_restore_brain.nii.gz" \
      --t2w-image="${SESSION_DIR}/T2w_acpc_dc_restore.nii.gz" \
      --extra-reconall-arg=-parallel --extra-reconall-arg=-openmp --extra-reconall-arg="${RECONALL_THREADS:-8}"
    ;;
  post)
    "${HCPPIPEDIR}/PostFreeSurfer/PostFreeSurferPipeline.sh" \
      --study-folder="$STUDY" --subject="$SESSION" \
      --surfatlasdir="${HCPPIPEDIR_Templates}/standard_mesh_atlases" \
      --grayordinatesdir="${HCPPIPEDIR_Templates}/91282_Greyordinates" \
      --grayordinatesres=2 --hiresmesh=164 --lowresmesh=32 \
      --subcortgraylabels="${HCPPIPEDIR_Config}/FreeSurferSubcorticalLabelTableLut.txt" \
      --freesurferlabels="${HCPPIPEDIR_Config}/FreeSurferAllLut.txt" \
      --refmyelinmaps="${HCPPIPEDIR_Templates}/standard_mesh_atlases/Conte69.MyelinMap_BC.164k_fs_LR.dscalar.nii" \
      --regname=MSMSulc --use-ind-mean=YES --structural-qc=no
    ;;
  *) echo "invalid structural stage: $stage" >&2; exit 2 ;;
esac


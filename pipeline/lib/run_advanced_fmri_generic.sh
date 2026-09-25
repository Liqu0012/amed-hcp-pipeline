#!/usr/bin/env bash
set -euo pipefail
source /work/scripts/hcp_env.sh

[[ $# -eq 2 ]] || { echo "usage: $0 fix|postfix|msmall SUBJECT" >&2; exit 2; }
stage=$1
SESSION=$2
source "/work/raw_nifti/${SESSION}/subject.env"
(( HCP_FMRI_COUNT >= 2 )) || { echo "multi-run fMRI requires at least two runs" >&2; exit 3; }

RESULTS=/work/output/${SESSION}/MNINonLinear/Results
RUN_NAMES=""
INPUTS=""
for ((index=0; index<HCP_FMRI_COUNT; index++)); do
  key="HCP_FMRI_${index}_NAME"
  run=${!key}
  [[ -n "$run" ]] || { echo "missing fMRI name at index ${index}" >&2; exit 4; }
  RUN_NAMES+="${RUN_NAMES:+@}${run}"
  prefix="${RESULTS}/${run}/${run}"
  INPUTS+="${INPUTS:+@}${prefix}"
done

case "$stage" in
  fix)
    IFS=@ read -r -a runs <<< "$RUN_NAMES"
    for run in "${runs[@]}"; do
      [[ -s "${RESULTS}/${run}/${run}_Atlas.dtseries.nii" ]] || {
        echo "missing fMRI surface output for ${run}" >&2
        exit 5
      }
    done
    export FSL_FIXDIR="${FSLDIR}/bin"
    "${HCPPIPEDIR}/ICAFIX/hcp_fix_multi_run" \
      --fmri-names="${INPUTS}" \
      --high-pass=0 \
      --concat-fmri-name="${RESULTS}/REST_ALL/REST_ALL" \
      --motion-regression=FALSE \
      --training-file=/usr/local/fsl/lib/python3.12/site-packages/pyfix/resources/models/HCP_Style_Single_Multirun_Dedrift.pyfix_model \
      --fix-threshold=10 \
      --delete-intermediates=FALSE \
      --processing-mode=HCPStyleData \
      --ica-method=MELODIC \
      --matlab-run-mode=0 \
      --enable-legacy-fix=FALSE \
      --T1wTemplateBrain="${HCPPIPEDIR_Templates}/MNI152_T1_0.8mm_brain.nii.gz" \
      --parallel-limit=8
    ;;
  postfix)
    "${HCPPIPEDIR}/ICAFIX/PostFix.sh" \
      --study-folder=/work/output \
      --subject="$SESSION" \
      --fmri-name=REST_ALL \
      --high-pass=0 \
      --template-scene-dual-screen="${HCPPIPEDIR}/ICAFIX/PostFixScenes/ICA_Classification_DualScreenTemplate.scene" \
      --template-scene-single-screen="${HCPPIPEDIR}/ICAFIX/PostFixScenes/ICA_Classification_SingleScreenTemplate.scene" \
      --reuse-high-pass=YES \
      --matlab-run-mode=0
    ;;
  msmall)
    "${HCPPIPEDIR}/MSMAll/MSMAllPipeline.sh" \
      --study-folder=/work/output \
      --session="$SESSION" \
      --fmri-names-list="" \
      --multirun-fix-names="$RUN_NAMES" \
      --multirun-fix-concat-name=REST_ALL \
      --multirun-fix-names-to-use="$RUN_NAMES" \
      --output-fmri-name=REST_ALL_MSMAll \
      --high-pass=0 \
      --fmri-proc-string=_Atlas_hp0_clean \
      --msm-all-templates="${HCPPIPEDIR}/global/templates/MSMAll" \
      --myelin-target-file="${HCPPIPEDIR}/global/templates/MSMAll/Q1-Q6_RelatedParcellation210.MyelinMap_BC_MSMAll_2_d41_WRN_DeDrift.32k_fs_LR.dscalar.nii" \
      --input-registration-name=MSMSulc \
      --output-registration-name=MSMAll_InitialReg \
      --high-res-mesh=164 \
      --low-res-mesh=32 \
      --matlab-run-mode=0
    ;;
  *) echo "invalid stage: $stage" >&2; exit 2 ;;
esac


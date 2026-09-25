#!/usr/bin/env bash
set -euo pipefail
source /work/scripts/hcp_env.sh

[[ $# -eq 3 ]] || { echo "usage: $0 volume|surface SUBJECT INDEX" >&2; exit 2; }
stage=$1
SESSION=$2
INDEX=$3
STUDY=/work/output
source "/work/raw_nifti/${SESSION}/subject.env"
(( INDEX >= 0 && INDEX < HCP_FMRI_COUNT )) || { echo "invalid fMRI index" >&2; exit 3; }

value() {
  local key="HCP_FMRI_${INDEX}_$1"
  printf '%s' "${!key}"
}
NAME=$(value NAME)

case "$stage" in
  volume)
    TCS=$(value TCS); SCOUT=$(value SCOUT); FMAP_NEG=$(value FMAP_NEG)
    FMAP_POS=$(value FMAP_POS); ECHO=$(value ECHO); UNWARP=$(value UNWARP)
    [[ "$SCOUT" != NONE && "$FMAP_NEG" != NONE && "$FMAP_POS" != NONE && -n "$ECHO" ]] || {
      echo "incomplete fMRI inputs for $NAME" >&2; exit 4;
    }
    "${HCPPIPEDIR}/fMRIVolume/GenericfMRIVolumeProcessingPipeline.sh" \
      --studyfolder="$STUDY" --session="$SESSION" --fmritcs="$TCS" \
      --fmriscout="$SCOUT" --fmriname="$NAME" --fmrires=2 \
      --biascorrection=SEBASED --gdcoeffs=NONE --dcmethod=TOPUP \
      --echospacing="$ECHO" --unwarpdir="$UNWARP" \
      --SEPhaseNeg="$FMAP_NEG" --SEPhasePos="$FMAP_POS" \
      --topupconfig="${HCPPIPEDIR_Config}/b02b0.cnf" \
      --usejacobian=TRUE --processing-mode=HCPStyleData --wb-resample=TRUE \
      --matlab-run-mode=0 --doslicetime=FALSE
    ;;
  surface)
    "${HCPPIPEDIR}/fMRISurface/GenericfMRISurfaceProcessingPipeline.sh" \
      --studyfolder="$STUDY" --session="$SESSION" --fmriname="$NAME" \
      --lowresmesh=32 --fmrires=2 --smoothingFWHM=2 --grayordinatesres=2 \
      --regname=MSMSulc --fmri-qc=YES --goodvoxel=YES
    ;;
  *) echo "invalid fMRI stage: $stage" >&2; exit 2 ;;
esac


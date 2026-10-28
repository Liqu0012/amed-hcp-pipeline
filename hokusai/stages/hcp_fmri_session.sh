#!/usr/bin/env bash
set -Eeuo pipefail

session="${1:?Usage: hcp_fmri_session.sh SESSION RUNNAME}"
runname="${2:?Usage: hcp_fmri_session.sh SESSION RUNNAME}"
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe session: $session" >&2; exit 2; }
[[ "$runname" =~ ^rfMRI_REST[0-9]+_(AP|PA)$ ]] || { echo "Unsupported runname: $runname" >&2; exit 2; }

image="${HCP_IMAGE:?HCP_IMAGE is required}"
study="${HCP_STUDY:?HCP_STUDY is required}"
runtime="${HCP_CONTAINER_RUNTIME:-apptainer}"
session_root="$study/$session"
unproc="$session_root/unprocessed/3T"
marker="$session_root/.hcp_fmri_${runname}_complete.ok"
structural_marker="$session_root/.hcp_structural_complete.ok"

[[ -s "$structural_marker" ]] || { echo "Structural stage not complete for $session" >&2; exit 1; }
[[ -s "$unproc/params.sh" ]] || { echo "Convert stage not complete for $session" >&2; exit 1; }

if [[ -s "$marker" ]]; then
  echo "Already done: fMRI $runname for $session"
  exit 0
fi

source "$unproc/params.sh"

# Run names and AP/PA come from PhaseEncodingDirection (hcp_select_inputs.py);
# each run has its own nearest SE field-map pair, copied as *_${runname}.
pedir="${runname: -2}"

case "$pedir" in
  PA) unwarpdir="y" ;;
  AP) unwarpdir="y-" ;;
  *) echo "bad pedir $pedir" >&2; exit 2 ;;
esac

fmritcs="$unproc/${runname}.nii.gz"
fmriscout="$unproc/${runname}_SBRef.nii.gz"
sefm_neg="$unproc/SpinEchoFieldMap_AP_${runname}.nii.gz"
sefm_pos="$unproc/SpinEchoFieldMap_PA_${runname}.nii.gz"

for f in "$fmritcs" "$fmriscout" "$sefm_neg" "$sefm_pos"; do
  [[ -s "$f" ]] || { echo "Missing input file: $f" >&2; exit 4; }
done

scratch_base="${SLURM_SCRATCH:-/tmp}/hcp-fmri-${session}-${runname}"
export TMPDIR="$scratch_base/tmp"
mkdir -p "$TMPDIR"

echo "Run: $runname  UnwarpDir: $unwarpdir"
echo "fmritcs=$fmritcs"
echo "fmriscout=$fmriscout"
echo "SEPhaseNeg=$sefm_neg"
echo "SEPhasePos=$sefm_pos"
echo "EchoSpacing=$FMRI_ECHOSPACING_SEC"

"$runtime" exec --bind "$scratch_base:$scratch_base" "$image" bash -c '
  set -o pipefail
  source /opt/qunex/env/qunex_environment.sh >/dev/null 2>&1 || true
  unset -f which 2>/dev/null || true
  set -Ee
  "$HCPPIPEDIR"/fMRIVolume/GenericfMRIVolumeProcessingPipeline.sh \
    --path="'"$study"'" --subject="'"$session"'" \
    --fmriname="'"$runname"'" \
    --fmritcs="'"$fmritcs"'" --fmriscout="'"$fmriscout"'" \
    --SEPhaseNeg="'"$sefm_neg"'" --SEPhasePos="'"$sefm_pos"'" \
    --fmapmag=NONE --fmapphase=NONE --fmapcombined=NONE \
    --echospacing="'"$FMRI_ECHOSPACING_SEC"'" --echodiff=NONE \
    --unwarpdir="'"$unwarpdir"'" \
    --fmrires=2 \
    --dcmethod=TOPUP --gdcoeffs=NONE \
    --topupconfig="$HCPPIPEDIR_Config/b02b0.cnf" \
    --biascorrection=SEBASED \
    --mctype=MCFLIRT \
    --usejacobian=TRUE --processing-mode=HCPStyleData --wb-resample=TRUE \
    --doslicetime=FALSE --matlab-run-mode=0
'

"$runtime" exec --bind "$scratch_base:$scratch_base" "$image" bash -c '
  set -o pipefail
  source /opt/qunex/env/qunex_environment.sh >/dev/null 2>&1 || true
  unset -f which 2>/dev/null || true
  set -Ee
  "$HCPPIPEDIR"/fMRISurface/GenericfMRISurfaceProcessingPipeline.sh \
    --path="'"$study"'" --subject="'"$session"'" \
    --fmriname="'"$runname"'" \
    --lowresmesh=32 --fmrires=2 --smoothingFWHM=2 --grayordinatesres=2 \
    --regname=MSMSulc --fmri-qc=NO --goodvoxel=YES
'

printf 'session=%s\nrun=%s\ncompleted=%s\n' "$session" "$runname" "$(date -Is)" > "$marker"
echo "fMRI $runname complete: $session"

#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/bin/common.sh"
cfg="${1:?Usage: validate-runtime.sh CONFIG}"
load_site "$cfg"

runtime="${HCP_CONTAINER_RUNTIME:-apptainer}"
shim="$HCP_STAGE_SCRIPT_DIR/eddy_openmp"
command -v "$runtime" >/dev/null
[[ -s "$HCP_IMAGE" ]]
[[ -x "$shim" ]]

"$runtime" exec --env LC_ALL=C,LANG=C \
  --bind "$shim:/opt/fsl/fsl/bin/eddy_openmp" \
  "$HCP_IMAGE" bash -lc '
    set -Eeo pipefail
    source /opt/qunex/env/qunex_environment.sh >/dev/null 2>&1 || true
    set -u
    printf "FSLDIR=%s\nFREESURFER_HOME=%s\nHCPPIPEDIR=%s\n" \
      "$FSLDIR" "$FREESURFER_HOME" "$HCPPIPEDIR"
    [[ -x "$FSLDIR/bin/eddy_openmp" ]] || { echo "Missing eddy_openmp shim" >&2; exit 5; }
    [[ -x "$FSLDIR/bin/eddy_cpu" ]] || { echo "Missing eddy_cpu" >&2; exit 5; }
    [[ -x "$FREESURFER_HOME/bin/recon-all" ]] || { echo "Missing recon-all" >&2; exit 5; }
    [[ -x "$HCPPIPEDIR/DiffusionPreprocessing/DiffPreprocPipeline_Eddy.sh" ]] || { echo "Missing HCP Eddy wrapper" >&2; exit 5; }
    command -v dcm2niix >/dev/null || { echo "Missing dcm2niix" >&2; exit 5; }
  '
echo 'RUNTIME_OK'

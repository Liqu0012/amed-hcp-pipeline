#!/usr/bin/env bash
set -euo pipefail

show_help() {
    cat <<'EOF'
Complete HCP Pipelines v6 container

Usage:
  hcp-container version
  hcp-container check
  hcp-container shell
  hcp-container run COMMAND [ARG ...]
  hcp-container pipeline NAME [ARG ...]

Pipeline aliases:
  prefreesurfer, freesurfer, postfreesurfer
  diffusion
  fmri-volume, fmri-surface
  icafix, msmall, dedrift
  task-fmri, resting-state, tica

MATLAB modes accepted by HCP pipeline options:
  --matlab-run-mode=0   compiled MATLAB using built-in R2022b Runtime
  --matlab-run-mode=1   licensed MATLAB bound at /opt/matlab/R2024a
  --matlab-run-mode=2   built-in Octave
EOF
}

pipeline_path() {
    case "$1" in
        prefreesurfer) echo "$HCPPIPEDIR/PreFreeSurfer/PreFreeSurferPipeline.sh" ;;
        freesurfer) echo "$HCPPIPEDIR/FreeSurfer/FreeSurferPipeline.sh" ;;
        postfreesurfer) echo "$HCPPIPEDIR/PostFreeSurfer/PostFreeSurferPipeline.sh" ;;
        diffusion) echo "$HCPPIPEDIR/DiffusionPreprocessing/DiffPreprocPipeline.sh" ;;
        fmri-volume) echo "$HCPPIPEDIR/fMRIVolume/GenericfMRIVolumeProcessingPipeline.sh" ;;
        fmri-surface) echo "$HCPPIPEDIR/fMRISurface/GenericfMRISurfaceProcessingPipeline.sh" ;;
        icafix) echo "$HCPPIPEDIR/ICAFIX/hcp_fix_multi_run" ;;
        msmall) echo "$HCPPIPEDIR/MSMAll/MSMAllPipeline.sh" ;;
        dedrift) echo "$HCPPIPEDIR/DeDriftAndResample/DeDriftAndResamplePipeline.sh" ;;
        task-fmri) echo "$HCPPIPEDIR/TaskfMRIAnalysis/TaskfMRIAnalysis.sh" ;;
        resting-state) echo "$HCPPIPEDIR/RestingStateStats/RestingStateStats.sh" ;;
        tica) echo "$HCPPIPEDIR/tICA/tICAPipeline.sh" ;;
        *) return 1 ;;
    esac
}

cmd=${1:-help}
case "$cmd" in
    help|-h|--help)
        show_help
        ;;
    version)
        "$HCPPIPEDIR/show_version" --short
        ;;
    check)
        exec /usr/local/bin/validate-hcp-complete
        ;;
    shell)
        exec /bin/bash --noprofile --norc
        ;;
    run)
        shift
        [[ $# -gt 0 ]] || { echo "ERROR: run requires a command" >&2; exit 2; }
        exec "$@"
        ;;
    pipeline)
        shift
        name=${1:?pipeline requires an alias; run hcp-container help}
        shift
        path=$(pipeline_path "$name") || { echo "ERROR: unknown pipeline alias: $name" >&2; exit 2; }
        exec "$path" "$@"
        ;;
    *)
        exec "$@"
        ;;
esac

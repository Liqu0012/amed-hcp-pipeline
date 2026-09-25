#!/usr/bin/env bash
set -euo pipefail

static_only=0
[[ ${1:-} == --static ]] && static_only=1

required_commands=(
    fslmaths topup eddy eddy_cpu melodic fix
    recon-all wb_command msm gradient_unwarp.py
    Rscript octave-cli python3
)
required_pipelines=(
    PreFreeSurfer FreeSurfer PostFreeSurfer
    DiffusionPreprocessing fMRIVolume fMRISurface
    ICAFIX MSMAll DeDriftAndResample
    TaskfMRIAnalysis RestingStateStats tICA
)

fail=0
for command_name in "${required_commands[@]}"; do
    if command -v "$command_name" >/dev/null 2>&1; then
        printf 'OK command %-24s %s\n' "$command_name" "$(command -v "$command_name")"
    else
        printf 'MISSING command %s\n' "$command_name" >&2
        fail=1
    fi
done

for pipeline_name in "${required_pipelines[@]}"; do
    if [[ -d "$HCPPIPEDIR/$pipeline_name" ]]; then
        printf 'OK pipeline %s\n' "$pipeline_name"
    else
        printf 'MISSING pipeline %s\n' "$pipeline_name" >&2
        fail=1
    fi
done

[[ -x "$HCPPIPEDIR/show_version" ]] || fail=1
[[ -d "$MATLAB_COMPILER_RUNTIME/runtime/glnxa64" ]] || { echo "MISSING MATLAB Runtime R2022b at $MATLAB_COMPILER_RUNTIME" >&2; fail=1; }
[[ -x "$HCPPIPEDIR/MSMAll/scripts/Compiled_ComputeVN/run_ComputeVN.sh" ]] || fail=1
[[ -x "$HCPPIPEDIR/MSMAll/scripts/Compiled_MSMregression/run_MSMregression.sh" ]] || fail=1

if (( ! static_only )); then
    echo "HCP version: $($HCPPIPEDIR/show_version --short)"
    Rscript -e 'cat("R runtime OK\n")'
    octave-cli --no-history --no-window-system --quiet --eval 'disp("Octave runtime OK")'
    gradient_unwarp.py --help >/dev/null
    if command -v matlab >/dev/null 2>&1; then
        echo "Licensed MATLAB path available: $(command -v matlab)"
    else
        echo "Licensed MATLAB not bound (optional mode 1); modes 0 and 2 remain available"
    fi
fi

(( fail == 0 )) || exit 1
echo "Complete HCP multimodal environment validation passed"

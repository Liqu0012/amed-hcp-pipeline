#!/usr/bin/env bash

HCPPIPEDIR=/home/brain/git/HCPpipelines
HCPPIPEDIR_Templates=${HCPPIPEDIR}/global/templates
HCPPIPEDIR_Config=${HCPPIPEDIR}/global/config
HCPPIPEDIR_Global=${HCPPIPEDIR}/global/scripts
FSLDIR=/usr/local/fsl
FREESURFER_HOME=/usr/local/freesurfer/6.0.1
CARET7DIR=/usr/bin
MSMBINDIR=/usr/local/fsl/bin
MATLAB_COMPILER_RUNTIME=/opt/mcr/current

export HCPPIPEDIR HCPPIPEDIR_Templates HCPPIPEDIR_Config HCPPIPEDIR_Global
export FSLDIR FREESURFER_HOME CARET7DIR MSMBINDIR MATLAB_COMPILER_RUNTIME
export PATH=${HCPPIPEDIR}:${FSLDIR}/share/fsl/bin:${FSLDIR}/bin:${FREESURFER_HOME}/bin:${CARET7DIR}:${PATH}

source "${FSLDIR}/etc/fslconf/fsl.sh"
set +eu
source "${FREESURFER_HOME}/SetUpFreeSurfer.sh"
source "${HCPPIPEDIR}/Examples/Scripts/SetUpHCPPipeline.sh"
set -eu

# The image's example environment is site-customized and may overwrite this
# with a host-only path.  Force the executable location inside the container.
MSMBINDIR=${FSLDIR}/bin
MATLAB_COMPILER_RUNTIME=/opt/mcr/current
export MSMBINDIR MATLAB_COMPILER_RUNTIME

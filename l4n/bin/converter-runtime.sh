#!/usr/bin/env bash
# Compatibility shim limited to the legacy DICOM converter's exec invocation.
set -Eeuo pipefail
[[ $1 == exec ]] || exit 2
shift
args=()
while [[ ${1:-} == --bind ]]; do args+=(--bind "$2"); shift 2; done
image=${1:?}; shift
[[ $1 == bash && $2 == -c ]] || exit 2
command=$3
exec "${L4N_RUNTIME:-apptainer}" exec --cleanenv --no-home "${args[@]}" "$image" bash --noprofile --norc -c '
 export HOME=/home/brain
 source /home/brain/.bash_aliases
 eval "$1"
' bash "$command"

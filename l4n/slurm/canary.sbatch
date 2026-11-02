#!/usr/bin/env bash
set -Eeuo pipefail
cfg=$1; session=$2; archive=$3
source "$cfg"
root=${L4N_ROOT:?}
source "$root/bin/start-metrics.sh"
[[ -s "$L4N_IMAGE_READY" ]] || exit 2
export HCP_CPUS_PER_SESSION=8
bash "$root/bin/run-stage.sh" "$cfg" convert "$session" "$archive"
source "$root/bin/container.sh"
L4N_PREFS_ONLY=1 bash "$root/bin/run-stage.sh" "$cfg" structural "$session"
[[ -s "$HCP_STUDY/$session/MNINonLinear/T1w_restore.nii.gz" ]] || exit 3
printf 'completed=%s\nimage=%s\n' "$(date -Is)" "$HCP_IMAGE" > "$HCP_STUDY/$session/.l4n_prefs.ok"
printf 'session=%s\ncompleted=%s\n' "$session" "$(date -Is)" > "$L4N_CANARY_OK"

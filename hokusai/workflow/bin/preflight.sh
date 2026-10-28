#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/bin/common.sh"
cfg="${1:?Usage: preflight.sh CONFIG MANIFEST}"
manifest="${2:?manifest required}"
load_site "$cfg"

[[ -s "$manifest" ]] || { echo "Missing manifest: $manifest" >&2; exit 2; }
[[ -d "$HCP_STUDY" ]] || { echo "Missing study directory: $HCP_STUDY" >&2; exit 2; }
[[ -s "$HCP_IMAGE" ]] || { echo "Missing image: $HCP_IMAGE" >&2; exit 2; }
[[ -s "$HCP_FS_LICENSE" ]] || { echo "Missing FreeSurfer license: $HCP_FS_LICENSE" >&2; exit 2; }
[[ -d "$HCP_STAGE_SCRIPT_DIR" ]] || { echo "Missing stage script directory: $HCP_STAGE_SCRIPT_DIR" >&2; exit 2; }
command -v sbatch >/dev/null || { echo "sbatch not found" >&2; exit 2; }
runtime="${HCP_CONTAINER_RUNTIME:-apptainer}"
command -v "$runtime" >/dev/null || { echo "Container runtime not found: $runtime" >&2; exit 2; }

for variable in HCP_STRUCT_COMMAND HCP_CONVERT_COMMAND HCP_PREEDDY_COMMAND \
  HCP_EDDY_COMMAND HCP_POSTEDDY_COMMAND HCP_FMRI_COMMAND \
  HCP_ICAFIX_COMMAND HCP_MSMALL_COMMAND HCP_DEDRIFT_COMMAND; do
  command_value="${!variable:-}"
  [[ -n "$command_value" ]] || { echo "Missing stage command: $variable" >&2; exit 2; }
  read -r command_bin command_script _ <<< "$command_value"
  command -v "$command_bin" >/dev/null || { echo "Command not found for $variable: $command_bin" >&2; exit 2; }
  if [[ "$command_bin" == bash ]]; then
    [[ -s "$command_script" ]] || { echo "Missing stage script for $variable: $command_script" >&2; exit 2; }
  fi
done
[[ -s "$HCP_STAGE_SCRIPT_DIR/hcp_structural_session.sh" ]] || {
  echo "Missing structural helper: $HCP_STAGE_SCRIPT_DIR/hcp_structural_session.sh" >&2
  exit 2
}
for helper in hcp_select_inputs.py hcp_qc_session.py; do
  [[ -s "$HCP_STAGE_SCRIPT_DIR/$helper" ]] || { echo "Missing helper: $HCP_STAGE_SCRIPT_DIR/$helper" >&2; exit 2; }
done
command -v python3 >/dev/null || { echo "python3 not found" >&2; exit 2; }
[[ -x "$HCP_STAGE_SCRIPT_DIR/eddy_openmp" ]] || {
  echo "Missing executable Eddy CPU shim: $HCP_STAGE_SCRIPT_DIR/eddy_openmp" >&2
  exit 2
}

bad=0 count=0
while IFS=$'\t' read -r session archive extra; do
  [[ -n "$session" ]] || continue
  count=$((count + 1))
  if ! [[ "$session" =~ ^[A-Za-z0-9._-]+$ ]]; then echo "Bad session: $session"; bad=1; fi
  if [[ -n "$extra" ]]; then echo "Too many columns for $session"; bad=1; fi
  IFS=@ read -r -a archives <<< "$archive"
  if ((${#archives[@]} == 0)); then echo "No archives for $session"; bad=1; fi
  for archive_path in "${archives[@]}"; do
    if [[ ! -s "$archive_path" ]]; then echo "Missing archive for $session: $archive_path"; bad=1; fi
  done
done < "$manifest"
((count > 0)) || { echo "Manifest is empty" >&2; exit 2; }
((bad == 0)) || exit 4
mkdir -p "$HCP_WORKFLOW_LOG_DIR"
echo "Preflight OK: $count sessions"
echo "Study: $HCP_STUDY"
echo "Image: $HCP_IMAGE"
echo "Container runtime: $runtime"

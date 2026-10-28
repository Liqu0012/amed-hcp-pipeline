#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/bin/common.sh"
cfg="${1:?Usage: status.sh CONFIG MANIFEST}"
manifest="${2:?manifest required}"
load_site "$cfg"
printf 'session\tstructural\tconvert\tpreeddy\teddy\tdiffusion\tfmri\ticafix\tmsmall\tdedrift\tqc\n'
while IFS=$'\t' read -r s archive rest; do
  [[ -n "$s" ]] || continue
  d="$HCP_STUDY/$s"
  mark() { [[ -s "$1" ]] && printf OK || printf -- -; }
  printf '%s\t' "$s"
  mark "$d/.hcp_structural_complete.ok"; printf '\t'
  mark "$d/.hcp_convert_complete.ok"; printf '\t'
  mark "$d/.hcp_diffusion_preeddy_complete.ok"; printf '\t'
  mark "$d/.hcp_diffusion_eddy_complete.ok"; printf '\t'
  mark "$d/.hcp_diffusion_complete.ok"; printf '\t'
  params="$d/unprocessed/3T/params.sh"
  runs=""; [[ ! -s "$params" ]] || { source "$params"; runs="${FMRI_RUNS:-}"; }
  n=0; total=0; for r in $runs; do total=$((total+1)); [[ -s "$d/.hcp_fmri_${r}_complete.ok" ]] && n=$((n+1)); done
  printf '%s/%s\t' "$n" "$total"
  mark "$d/.hcp_icafix_complete.ok"; printf '\t'
  mark "$d/.hcp_msmall_complete.ok"; printf '\t'
  mark "$d/.hcp_dedrift_complete.ok"; printf '\t'
  if [[ -s "$d/.hcp_qc_pass.ok" ]]; then printf PASS
  elif [[ -s "$d/qc/hcp_qc.json" ]]; then
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["status"], end="")' "$d/qc/hcp_qc.json"
  elif [[ -s "$d/.hcp_input_problems.txt" ]]; then printf BLOCKED
  else printf -- -; fi
  printf '\n'
done < "$manifest"

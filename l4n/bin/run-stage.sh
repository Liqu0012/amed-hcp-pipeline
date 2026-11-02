#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/bin/common.sh"
cfg=${1:?}; stage=${2:?}; session=${3:?}; archive=${4:-}
load_site "$cfg"; validate_session "$session"
source "$root/bin/container.sh"
[[ ${L4N_FORCE_GPU:-0} != 1 ]] || export L4N_GPU=1
S=$HCP_STUDY; J=$session; D=$S/$J
mkdir -p "$D"
conf=$D/RawData/hcppipe_conf.txt
mark() { printf 'completed=%s\njob=%s\nimage=%s\n' "$(date -Is)" "${SLURM_JOB_ID:-manual}" "$HCP_IMAGE" > "$D/.l4n_$1.ok"; }
step() { local n=$1; shift; [[ -s "$D/.l4n_$n.ok" ]] || { l4n_exec "$@" "$S" "$J"; mark "$n"; }; }
has_fmri() { [[ -s "$conf" ]] && (source "$conf"; [[ -n ${Tasklist:-} ]]); }
has_diffusion() { [[ -s "$conf" ]] && (source "$conf"; [[ -n ${DiffPosData:-} && -n ${DiffNegData:-} ]]); }
case "$stage" in
 convert)
  if [[ -s "$conf" ]]; then
    python3 "$root/bin/rebase-seriesinfo.py" "$D/RawData" "$L4N_INPUTS/$session/hcp_mapping"
    exit 0
  fi
  input=$L4N_INPUTS/$session/unprocessed/3T
  # Copy preserved inputs into the new namespace: old result collectors may remove
  # old sessions after draining. Never leave new RawData linked to an old tree.
  if [[ ! -s "$input/params.sh" ]]; then
    legacy=$L4N_LEGACY_STUDY/$session/unprocessed/3T
    if [[ -s "$legacy/params.sh" ]]; then
      mkdir -p "$input"; cp -aL "$legacy/." "$input/"
    else
      export HCP_STUDY=$L4N_INPUTS
      # The converter uses this small runtime shim for new-image environment setup.
      original_runtime=$HCP_CONTAINER_RUNTIME
      export HCP_CONTAINER_RUNTIME="$root/bin/converter-runtime.sh"
      export L4N_RUNTIME=${L4N_RUNTIME:-apptainer}
      bash "$root/../hokusai/stages/hcp_convert_session.sh" "$session" "$archive"
      export HCP_CONTAINER_RUNTIME=$original_runtime
      export HCP_STUDY=$S
    fi
  fi
  bids=$L4N_INPUTS/$session/bids
  read -r sub ses generated < <(python3 "$root/bin/legacy_to_bids.py" "$input" "$bids" "$session")
  # Keep the original session ID in HCP outputs and FreeSurfer subject names.
  temp=$L4N_INPUTS/$session/hcp_mapping
  if [[ ! -s "$temp/$generated/RawData/hcppipe_conf.txt" ]]; then
    l4n_exec bids2hcp.sh -s "$sub" -e "$ses" -b "$bids" -o "$temp" -l
  fi
  mv "$temp/$generated/RawData" "$D/RawData"
  python3 "$root/bin/rebase-seriesinfo.py" "$D/RawData" "$temp"
  cp "$bids/identity_mapping.json" "$D/input_provenance.json"
  mark convert
  ;;
 structural)
  step prefs bmb_10_prefs.sh
  [[ ${L4N_PREFS_ONLY:-0} != 1 ]] || exit 0
  step fs bmb_11_fs.sh
  step postfs bmb_12_postfs.sh
  ;;
 diffusion)
  if [[ ${L4N_EXTERNAL_DIFFUSION:-0} == 1 && ${L4N_FORCE_GPU:-0} != 1 ]] && has_diffusion; then
    exec bash "$root/bin/dispatch-diffusion.sh" "$cfg" "$session"
  fi
  if has_diffusion; then
    if [[ ${L4N_GPU:-0} == 1 ]]; then
      [[ -s "$D/.l4n_diffusion.ok" ]] || { l4n_exec bmb_20_diffusion.sh "$S" "$J" --gpu; mark diffusion; }
    else step diffusion bmb_20_diffusion.sh; fi
  else printf 'No diffusion input\n' > "$D/.l4n_diffusion.skipped"; fi
  ;;
 fmri) if has_fmri; then step volume bmb_30_fmrivolume.sh; step surface bmb_31_fmrisurface.sh; fi ;;
 icafix) if has_fmri; then step icafix bmb_32_icafix.sh; step postfix bmb_33_postfix.sh; fi ;;
 msmall) if has_fmri; then step msmall bmb_34_msmall.sh; fi ;;
 dedrift) if has_fmri; then step dedrift bmb_35_dedrift.sh; fi ;;
 stats) if has_fmri; then step stats bmb_36_fmristats.sh; fi ;;
 qc)
  flags=(-s); has_diffusion && flags+=(-d); has_fmri && flags+=(-f)
  l4n_exec hcppipe_qc "$S" "$J" "${flags[@]}"
  # Report generation is not a claim of scientific QC PASS.
  mark qc_report
  ;;
 *) echo "Unknown stage: $stage" >&2; exit 2 ;;
esac

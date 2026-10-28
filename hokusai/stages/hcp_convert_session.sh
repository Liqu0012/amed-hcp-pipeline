#!/usr/bin/env bash
set -Eeuo pipefail
# DICOM -> NIfTI and metadata-based input selection (hcp_select_inputs.py).
# 2026-10-28: replaced filename/order-based selection with the corrected DB
# rules (one structural image per contrast, PE from metadata, REST-only
# fMRI >= 100 volumes, per-run nearest SE pair, blocking on missing params).
# Safe to call from several stages: a per-session lock serialises it and the
# marker makes repeat calls return immediately.

session="${1:?Usage: hcp_convert_session.sh SESSION ARCHIVE_OR_ARCHIVE_LIST}"
archive="${2:?Usage: hcp_convert_session.sh SESSION ARCHIVE_OR_ARCHIVE_LIST}"
[[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Unsafe session: $session" >&2; exit 2; }
IFS=@ read -r -a archives <<< "$archive"
((${#archives[@]} > 0)) || { echo "No archives supplied" >&2; exit 1; }
for archive_path in "${archives[@]}"; do [[ -s "$archive_path" ]] || { echo "Missing archive: $archive_path" >&2; exit 1; }; done

image="${HCP_IMAGE:?HCP_IMAGE is required}"
study="${HCP_STUDY:?HCP_STUDY is required}"
runtime="${HCP_CONTAINER_RUNTIME:-apptainer}"
selector="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hcp_select_inputs.py"
session_root="$study/$session"
unproc="$session_root/unprocessed/3T"
marker="$session_root/.hcp_convert_complete.ok"
problems_file="$session_root/.hcp_input_problems.txt"
[[ -s "$selector" ]] || { echo "Missing selector: $selector" >&2; exit 1; }

mkdir -p "$session_root"
exec 8>"$session_root/.hcp_convert.lock"
flock 8
if [[ -s "$marker" ]]; then
  echo "Already converted: $session"
  exit 0
fi

scratch="${SLURM_SCRATCH:-${TMPDIR:-/tmp}}/convert-${session}-$$"
dicom="$scratch/dicom"
nifti="$scratch/nifti"
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$unproc" "$dicom" "$nifti" "$scratch/tmp"
export TMPDIR="$scratch/tmp"

echo "=== DICOM extraction started: $(date) ==="
for i in "${!archives[@]}"; do
  mkdir -p "$dicom/archive_$i"
  unzip -q "${archives[$i]}" -d "$dicom/archive_$i"
done

echo "=== dcm2niix started: $(date) ==="
"$runtime" exec --bind "$scratch:$scratch" "$image" bash -c '
  source /opt/qunex/env/qunex_environment.sh >/dev/null 2>&1 || true
  unset -f which 2>/dev/null || true
  dcm2niix -z y -b y -f "%p_%s" -o "'"$nifti"'" "'"$dicom"'"
'

echo "=== input selection (DICOM metadata) ==="
rc=0
python3 "$selector" "$nifti" "$scratch/selection.json" || rc=$?
mkdir -p "$unproc/selection"
cp "$scratch/selection.json" "$unproc/selection/input_selection.json"
for json in "$nifti"/*.json; do cp "$json" "$unproc/selection/"; done
if ((rc != 0)); then
  python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["problems"]))' \
    "$scratch/selection.json" > "$problems_file"
  echo "ERROR: input problems for $session (see $problems_file); session must not run" >&2
  exit 3
fi
rm -f "$problems_file"

copy_with_sidecars() {
  local src_base="$1" dst_base="$2" ext
  cp "${src_base}.nii.gz" "${dst_base}.nii.gz"
  for ext in json bval bvec; do
    if [[ -s "${src_base}.${ext}" ]]; then cp "${src_base}.${ext}" "${dst_base}.${ext}"; fi
  done
}

# Selection -> shell assignments (values shell-quoted by Python).
eval "$(python3 - "$scratch/selection.json" <<'PY'
import json, shlex, sys
s = json.load(open(sys.argv[1]))
q = shlex.quote
print('SEL_T1=%s SEL_T2=%s SEL_T1_DWELL=%s SEL_T2_DWELL=%s' % (
    q(s['t1']), q(s['t2']), q(repr(s['t1_dwell'])), q(repr(s['t2_dwell']))))
se = s['struct_se']
print('SEL_SE_NEG=%s SEL_SE_POS=%s SEL_SE_ECHO=%s' % (
    q(se['neg'] if se else ''), q(se['pos'] if se else ''), q(repr(se['ees']) if se else '')))
print('SEL_FMRI=(%s)' % ' '.join(q('%s|%s|%s|%s|%s' % (r['name'], r['tcs'], r['sbref'], r['se_ap'], r['se_pa']))
                                 for r in s['fmri_runs']))
print('SEL_FMRI_ECHO=%s' % q(repr(s['fmri_echospacing_sec']) if s['fmri_echospacing_sec'] else ''))
print('SEL_DMRI=(%s)' % ' '.join(q('%s|%s|%s' % (d['set'], d['ap'], d['pa'])) for d in s['dmri_sets']))
print('SEL_DMRI_ECHO=%s' % q(repr(s['dmri_echospacing_sec']) if s['dmri_echospacing_sec'] else ''))
PY
)"

copy_with_sidecars "$SEL_T1" "$unproc/T1w_MPR"
copy_with_sidecars "$SEL_T2" "$unproc/T2w_SPC"
if [[ -n "$SEL_SE_NEG" ]]; then
  copy_with_sidecars "$SEL_SE_NEG" "$unproc/SpinEchoFieldMap_AP_struct"
  copy_with_sidecars "$SEL_SE_POS" "$unproc/SpinEchoFieldMap_PA_struct"
fi

fmri_runs=()
for entry in "${SEL_FMRI[@]}"; do
  IFS='|' read -r run tcs sbref se_ap se_pa <<< "$entry"
  copy_with_sidecars "$tcs" "$unproc/$run"
  copy_with_sidecars "$sbref" "$unproc/${run}_SBRef"
  copy_with_sidecars "$se_ap" "$unproc/SpinEchoFieldMap_AP_${run}"
  copy_with_sidecars "$se_pa" "$unproc/SpinEchoFieldMap_PA_${run}"
  fmri_runs+=("$run")
done

dmri_sets=()
for entry in "${SEL_DMRI[@]}"; do
  IFS='|' read -r set ap pa <<< "$entry"
  copy_with_sidecars "$ap" "$unproc/dMRI_${set}_AP"
  copy_with_sidecars "$pa" "$unproc/dMRI_${set}_PA"
  dmri_sets+=("$set")
done
if ((${#dmri_sets[@]} == 0)) && [[ "${HCP_REQUIRE_DMRI:-0}" == 1 ]]; then
  echo "ERROR: no usable dMRI for $session and HCP_REQUIRE_DMRI=1" >&2; exit 4
fi

struct_se_neg=NONE; struct_se_pos=NONE
if [[ -n "$SEL_SE_NEG" ]]; then
  struct_se_neg="$unproc/SpinEchoFieldMap_AP_struct.nii.gz"
  struct_se_pos="$unproc/SpinEchoFieldMap_PA_struct.nii.gz"
fi

cat > "$unproc/params.sh.tmp" <<EOF
# Auto-generated by hcp_convert_session.sh on $(date -Is); selection in selection/input_selection.json
T1_DWELL_SEC=${SEL_T1_DWELL}
T2_DWELL_SEC=${SEL_T2_DWELL}
STRUCT_SE_NEG=${struct_se_neg}
STRUCT_SE_POS=${struct_se_pos}
STRUCT_SE_ECHOSPACING_SEC=${SEL_SE_ECHO}
FMRI_ECHOSPACING_SEC=${SEL_FMRI_ECHO}
FMRI_RUNS="${fmri_runs[*]}"
DMRI_ECHOSPACING_SEC=${SEL_DMRI_ECHO}
DMRI_SHELLS_USABLE="${dmri_sets[*]}"
EOF
mv "$unproc/params.sh.tmp" "$unproc/params.sh"
cat "$unproc/params.sh"

printf 'session=%s\narchive=%s\ncompleted=%s\n' "$session" "$archive" "$(date -Is)" > "$marker"
echo "=== conversion completed: $(date) ==="

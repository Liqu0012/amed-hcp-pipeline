#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 ZIP_PATH SUBJECT_ID OUTPUT_DIR" >&2
  exit 2
fi

ZIP_PATH=$1
SUBJECT_ID=$2
OUTPUT_DIR=$3
SIF=${HCP_SIF:-/data/juntendodb/containers/hcp_pipelines_v6_complete_20260831.sif}

# --- deferred-cohort gate ---------------------------------------------------
# Subjects matching any pattern in skip_patterns.txt exit immediately with 90,
# releasing their scheduler slot. We used this to defer an entire protocol
# (subjects whose two exported T1w series get incorrectly averaged together --
# see build_subject_manifest.py) until it had a real fix, without touching
# already-running jobs. Empty the file, or delete it, to stop deferring.
SKIPLIST=${SKIPLIST:-${AMED_ROOT:-/data/juntendodb/amedhcp}/manifests/skip_patterns.txt}
if [[ -f "$SKIPLIST" ]]; then
  while IFS= read -r pat; do
    [[ -z "$pat" || "$pat" == \#* ]] && continue
    if [[ "$SUBJECT_ID" == *"$pat"* ]]; then
      echo "SKIP subject=$SUBJECT_ID deferred (pattern: $pat)" >&2
      exit 90
    fi
  done < "$SKIPLIST"
fi
# ---------------------------------------------------------------------------

[[ -f "$ZIP_PATH" ]] || { echo "missing ZIP: $ZIP_PATH" >&2; exit 3; }
mkdir -p "$OUTPUT_DIR"

node_tmp=$(mktemp -d /tmp/amed_hcp_convert.XXXXXX)
cleanup() {
  case "$node_tmp" in
    /tmp/amed_hcp_convert.*) rm -rf -- "$node_tmp" ;;
  esac
}
trap cleanup EXIT

echo "HOST=$(hostname) JOB=${SLURM_JOB_ID:-none} SUBJECT=$SUBJECT_ID"
echo "Extracting $(basename "$ZIP_PATH")"
mkdir -p "$node_tmp/dicom"
unzip -q "$ZIP_PATH" -d "$node_tmp/dicom"

echo "Converting DICOM to NIfTI"
apptainer exec --cleanenv \
  --bind "$node_tmp:/input" \
  --bind "$OUTPUT_DIR:/output" \
  "$SIF" \
  /usr/local/dcm2niix/dcm2niix \
    -b y -ba n -z y -f '%s_%p' -o /output /input/dicom

find "$OUTPUT_DIR" -maxdepth 1 -type f -printf '%f %s bytes\n' | sort
printf '%s\n' "subject=$SUBJECT_ID" "source=$ZIP_PATH" "job=${SLURM_JOB_ID:-none}" > "$OUTPUT_DIR/.conversion_complete"
echo "CONVERSION_COMPLETED"

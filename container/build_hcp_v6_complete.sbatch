#!/usr/bin/env bash
#SBATCH --job-name=build_hcp_v6_full
#SBATCH --partition=ccalc
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=8
#SBATCH --mem=64G
#SBATCH --time=08:00:00
#SBATCH --output=/data/juntendodb/containers/build-context/hcp_v6_complete_%j.out
#SBATCH --error=/data/juntendodb/containers/build-context/hcp_v6_complete_%j.err

set -euo pipefail

CONTEXT=/data/juntendodb/containers/build-context/hcp-v6-complete
DEFINITION="$CONTEXT/hcp_v6_complete.def"
OUTPUT=/data/juntendodb/containers/.hcp_pipelines_v6_complete_20260831.partial.sif
FINAL=/data/juntendodb/containers/hcp_pipelines_v6_complete_20260831.sif
LOCAL_TMP=/tmp/hcp-v6-complete-${SLURM_JOB_ID}

[[ -s "$DEFINITION" ]]
[[ ! -e "$OUTPUT" ]]
[[ ! -e "$FINAL" ]]
mkdir -p "$LOCAL_TMP"
export APPTAINER_TMPDIR="$LOCAL_TMP"
export APPTAINER_CACHEDIR="$LOCAL_TMP/cache"

cd "$CONTEXT"
apptainer build --fakeroot \
    --mksquashfs-args "-processors ${SLURM_CPUS_PER_TASK} -mem 8G" \
    "$OUTPUT" "$DEFINITION"

apptainer test "$OUTPUT"
mv "$OUTPUT" "$FINAL"
chmod 0444 "$FINAL"
echo "BUILT $FINAL"

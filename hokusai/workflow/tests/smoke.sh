#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/study" "$tmp/stages" "$tmp/logs"
printf 'image\n' > "$tmp/qunex.sif"
printf 'license\n' > "$tmp/license.txt"
printf 'archive\n' > "$tmp/input.zip"
printf '1000\n' > "$tmp/sbatch.counter"

cat > "$tmp/bin/singularity" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat > "$tmp/bin/sbatch" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$HCP_TEST_SBATCH_LOG"
id=$(<"$HCP_TEST_SBATCH_COUNTER")
id=$((id + 1))
printf '%s\n' "$id" > "$HCP_TEST_SBATCH_COUNTER"
printf '%s\n' "$id"
EOF
chmod +x "$tmp/bin/singularity" "$tmp/bin/sbatch"

stages=(
  hcp_full_test_session.sh
  hcp_structural_session.sh
  hcp_convert_session.sh
  hcp_diffusion_preeddy.sh
  hcp_diffusion_eddy_cpu.sh
  hcp_diffusion_posteddy.sh
  hcp_fmri_session.sh
  hcp_icafix_session.sh
  hcp_msmall_session.sh
  hcp_dedrift_session.sh
  eddy_openmp
  hcp_select_inputs.py
  hcp_qc_session.py
)
for stage in "${stages[@]}"; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/stages/$stage"
done
chmod +x "$tmp/stages/eddy_openmp"

cat > "$tmp/site.env" <<EOF
HCP_STUDY=$tmp/study
HCP_IMAGE=$tmp/qunex.sif
HCP_FS_HOME=$tmp/freesurfer
HCP_FS_LICENSE=$tmp/license.txt
HCP_STAGE_SCRIPT_DIR=$tmp/stages
HCP_WORKFLOW_LOG_DIR=$tmp/logs
HCP_CONTAINER_RUNTIME=singularity
HCP_SLURM_ACCOUNT=rb240007
HCP_SLURM_QOS=normal
HCP_CPU_PARTITION=mpc
HCP_MAX_PARALLEL=8
HCP_STRUCT_COMMAND="bash $tmp/stages/hcp_full_test_session.sh"
HCP_CONVERT_COMMAND="bash $tmp/stages/hcp_convert_session.sh"
HCP_PREEDDY_COMMAND="bash $tmp/stages/hcp_diffusion_preeddy.sh"
HCP_EDDY_COMMAND="bash $tmp/stages/hcp_diffusion_eddy_cpu.sh"
HCP_POSTEDDY_COMMAND="bash $tmp/stages/hcp_diffusion_posteddy.sh"
HCP_FMRI_COMMAND="bash $tmp/stages/hcp_fmri_session.sh"
HCP_ICAFIX_COMMAND="bash $tmp/stages/hcp_icafix_session.sh"
HCP_MSMALL_COMMAND="bash $tmp/stages/hcp_msmall_session.sh"
HCP_DEDRIFT_COMMAND="bash $tmp/stages/hcp_dedrift_session.sh"
EOF
printf 'TEST_SESSION\t%s\n' "$tmp/input.zip" > "$tmp/manifest.tsv"

export PATH="$tmp/bin:$PATH"
export HCP_TEST_SBATCH_LOG="$tmp/sbatch.log"
export HCP_TEST_SBATCH_COUNTER="$tmp/sbatch.counter"
bash "$root/slurm/submit.sh" "$tmp/site.env" "$tmp/manifest.tsv" smoke >/dev/null

[[ $(wc -l < "$tmp/sbatch.log") -eq 10 ]]
if grep -E -- '--gres=|gpu:|--partition=gpu' "$tmp/sbatch.log"; then
  echo 'Unexpected GPU resource request' >&2
  exit 1
fi
while IFS= read -r line; do
  [[ "$line" == *'--partition=mpc'* ]]
  [[ "$line" == *'--account=rb240007'* ]]
  [[ "$line" == *'--qos=normal'* ]]
  [[ "$line" == *'--nodes=1'* ]]
  [[ "$line" == *'--ntasks=1'* ]]
done < "$tmp/sbatch.log"

eddy=$(sed -n '4p' "$tmp/sbatch.log")
[[ "$eddy" == *'--job-name=hcp_eddy_smoke'* ]]
[[ "$eddy" == *'--cpus-per-task=112'* ]]
[[ "$eddy" == *'--mem=112G'* ]]
[[ "$eddy" == *'--dependency=aftercorr:1003'* ]]

convert=$(sed -n '2p' "$tmp/sbatch.log")
[[ "$convert" != *'--dependency='* ]]
posteddy=$(sed -n '5p' "$tmp/sbatch.log")
[[ "$posteddy" == *'--dependency=aftercorr:1004:1001'* ]]
fmri=$(sed -n '6p' "$tmp/sbatch.log")
[[ "$fmri" == *'--dependency=aftercorr:1001:1002'* ]]

submission="$tmp/logs/smoke/submission.tsv"
[[ -s "$submission" ]]
grep -qx $'eddy\t1004' "$submission"
grep -qx $'dedrift\t1009' "$submission"
grep -qx $'qc\t1010' "$submission"
qc=$(sed -n '10p' "$tmp/sbatch.log")
[[ "$qc" == *'--dependency=aftercorr:1009:1005'* ]]

cat >> "$tmp/site.env" <<EOF
HCP_PACKED_NODE_CPUS=112
HCP_PACKED_NODE_MEM=112G
HCP_PACKED_MAX_PARALLEL=12
HCP_STRUCTURAL_PACK_SIZE=7
HCP_STRUCTURAL_CPUS_PER_SESSION=16
HCP_CONVERT_PACK_SIZE=14
HCP_CONVERT_CPUS_PER_SESSION=8
HCP_PREEDDY_PACK_SIZE=7
HCP_PREEDDY_CPUS_PER_SESSION=16
HCP_EDDY_PACK_SIZE=1
HCP_EDDY_CPUS_PER_SESSION=112
HCP_POSTEDDY_PACK_SIZE=7
HCP_POSTEDDY_CPUS_PER_SESSION=16
HCP_FMRI_PACK_SIZE=4
HCP_FMRI_CPUS_PER_SESSION=28
HCP_ICAFIX_PACK_SIZE=4
HCP_ICAFIX_CPUS_PER_SESSION=28
HCP_MSMALL_PACK_SIZE=4
HCP_MSMALL_CPUS_PER_SESSION=28
HCP_DEDRIFT_PACK_SIZE=4
HCP_DEDRIFT_CPUS_PER_SESSION=28
HCP_QC_PACK_SIZE=28
HCP_QC_CPUS_PER_SESSION=4
EOF

: > "$tmp/sbatch.log"
printf '2000\n' > "$tmp/sbatch.counter"
: > "$tmp/packed_manifest.tsv"
for i in $(seq 1 15); do printf 'PACKED_%02d\t%s\n' "$i" "$tmp/input.zip" >> "$tmp/packed_manifest.tsv"; done
bash "$root/slurm/submit-packed.sh" "$tmp/site.env" "$tmp/packed_manifest.tsv" packed >/dev/null
[[ $(wc -l < "$tmp/sbatch.log") -eq 10 ]]
packed_struct=$(sed -n '1p' "$tmp/sbatch.log")
packed_convert=$(sed -n '2p' "$tmp/sbatch.log")
packed_eddy=$(sed -n '4p' "$tmp/sbatch.log")
[[ "$packed_struct" == *'--array=1-3%12'* && "$packed_struct" == *'HCP_PACK_SIZE=7'* && "$packed_struct" == *'/slurm/node-task.sh'* ]]
[[ "$packed_convert" == *'--array=1-2%12'* && "$packed_convert" == *'HCP_PACK_SIZE=14'* ]]
[[ "$packed_eddy" == *'--array=1-15%12'* && "$packed_eddy" == *'HCP_CPUS_PER_SESSION=112'* ]]
[[ "$packed_eddy" == *'--dependency=afterany:2003'* ]]

export HCP_WORKFLOW_ROOT="$root" HCP_CONFIG="$tmp/site.env" HCP_MANIFEST="$tmp/packed_manifest.tsv"
export HCP_STAGE=structural HCP_PACK_SIZE=2 HCP_CPUS_PER_SESSION=8 HCP_PACK_LOG_DIR="$tmp/packed_logs"
export SLURM_ARRAY_TASK_ID=1 SLURM_ARRAY_JOB_ID=3000 SLURM_JOB_ID=3001 SLURM_CPUS_PER_TASK=112
bash "$root/slurm/node-task.sh" >/dev/null
[[ -f "$tmp/packed_logs/structural_3000_1_row1_PACKED_01.log" ]]
[[ -f "$tmp/packed_logs/structural_3000_1_row2_PACKED_02.log" ]]

mkdir -p "$tmp/grouped"
printf 'mr1\n' > "$tmp/grouped/GROUPED_SUBJECT_MR1.zip"
printf 'mr2\n' > "$tmp/grouped/GROUPED_SUBJECT_MR2.zip"
printf 'single\n' > "$tmp/grouped/SINGLE_SUBJECT.zip"
# One session per archive with its full name: MR1/MR2 are never merged.
bash "$root/bin/build-manifest.sh" "$tmp/grouped.tsv" "$tmp/grouped" >/dev/null
[[ $(wc -l < "$tmp/grouped.tsv") -eq 3 ]]
grep -q $'^GROUPED_SUBJECT_MR1\t.*GROUPED_SUBJECT_MR1.zip$' "$tmp/grouped.tsv"
grep -q $'^GROUPED_SUBJECT_MR2\t.*GROUPED_SUBJECT_MR2.zip$' "$tmp/grouped.tsv"
grep -q $'^SINGLE_SUBJECT\t.*SINGLE_SUBJECT.zip$' "$tmp/grouped.tsv"
# List-file input works; a duplicated session is rejected.
ls "$tmp/grouped"/*.zip > "$tmp/ziplist.txt"
bash "$root/bin/build-manifest.sh" "$tmp/fromlist.tsv" "$tmp/ziplist.txt" >/dev/null
[[ $(wc -l < "$tmp/fromlist.tsv") -eq 3 ]]
ls "$tmp/grouped"/SINGLE*.zip >> "$tmp/ziplist.txt"
if bash "$root/bin/build-manifest.sh" "$tmp/dup.tsv" "$tmp/ziplist.txt" 2>/dev/null; then
  echo 'Duplicate session was not rejected' >&2; exit 1
fi

echo 'SMOKE_OK'

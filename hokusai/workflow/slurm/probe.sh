#!/usr/bin/env bash
#SBATCH --partition=mpc
#SBATCH --account=rb240007
#SBATCH --qos=normal
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=1G
#SBATCH --time=00:05:00
#SBATCH --job-name=hcp_probe

set -Eeuo pipefail
echo "host=$(hostname)"
echo "arch=$(uname -m)"
echo "cpus=${SLURM_CPUS_PER_TASK:-unset}"
echo "job=${SLURM_JOB_ID:-unset}"
echo "tmpdir=${TMPDIR:-unset}"
echo "slurm_tmpdir=${SLURM_TMPDIR:-unset}"
command -v singularity
singularity --version
df -h /tmp /home/ziqing

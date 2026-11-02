#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
# sbatch executes a spool copy, so the config supplies the deployed root.
source "$1"
root=${L4N_ROOT:?}
source "$root/bin/start-metrics.sh"
export L4N_FORCE_GPU=1 HCP_CPUS_PER_SESSION=8
exec bash "$root/bin/run-stage.sh" "$1" diffusion "$2"

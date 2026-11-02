#!/usr/bin/env bash
# Source after loading a site config. Never inherit host neuroimaging software.
l4n_exec() {
  local -a gpu=() binds=()
  [[ ${L4N_GPU:-0} == 1 ]] && gpu=(--nv)
  local b
  IFS=, read -r -a binds <<< "${L4N_BINDS:?L4N_BINDS required}"
  local -a args=()
  for b in "${binds[@]}"; do args+=(--bind "$b"); done
  "${HCP_CONTAINER_RUNTIME:-apptainer}" exec "${gpu[@]}" --cleanenv --no-home \
    "${args[@]}" --bind "${HCP_FS_LICENSE:?}:/usr/local/freesurfer/6.0.1/license.txt:ro" \
    "${HCP_IMAGE:?}" bash --noprofile --norc -c '
      export HOME=/home/brain
      source /home/brain/.bash_aliases
      export OMP_NUM_THREADS="${1}" ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS="${1}"
      export MKL_NUM_THREADS="${1}" OPENBLAS_NUM_THREADS=1
      shift
      exec "$@"
    ' bash "${HCP_CPUS_PER_SESSION:-${SLURM_CPUS_PER_TASK:-8}}" "$@"
}

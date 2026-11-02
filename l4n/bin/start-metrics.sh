# Source inside an allocated job, after its site config.
if [[ -n ${SLURM_JOB_ID:-} && -s ${HCP_METRICS_ROOT:-}/resource_sampler.py ]]; then
  python3 "$HCP_METRICS_ROOT/resource_sampler.py" \
    --out "$HCP_METRICS_ROOT/$SLURM_JOB_ID.steps.jsonl" --interval 30 --parent "$$" \
    > "$HCP_METRICS_ROOT/$SLURM_JOB_ID.l4n_sampler.log" 2>&1 &
  l4n_sampler_pid=$!
  trap 'kill "$l4n_sampler_pid" 2>/dev/null || true' EXIT
fi

# Lin4Neuro BMB migration

This is an independent workflow for `kytk/l4n-bmb:latest`. It does not edit
running QuNex workers or reuse their FreeSurfer trees. Keep the old queue STOP
files until migration has been reviewed. Cancel only PENDING old jobs when
draining; let claimed sessions finish.

## Data and reproducibility

* `l4n_study`, `l4n_inputs`, `l4n_logs`, and `l4n_manifests` are new namespaces.
* A preserved `unprocessed/3T` is copied into the new input namespace; otherwise
  the existing metadata-based DICOM converter is used with the new image.
* `legacy_to_bids.py` adapts these selected images to BIDS names. It copies JSON
  rather than modifying old sidecars. Only a missing structural DwellTime is
  filled from the preserved selector's recorded value; every derivation and ID
  mapping is recorded. It does not invent PE, T2w, SE maps, or resolutions.
* The image's own `bids2hcp.sh` validates/selects the inputs. The generated
  RawData directory is placed under the original session ID before processing;
  all subsequent HCP/FreeSurfer subject names use that original ID.
* Missing T2w/SE maps, unsupported T1w resolution, and metadata disagreement
  fail visibly. Do not silently substitute scientific parameters to get past
  these checks. Original ZIPs and old results are never deleted here.
* Install an image only after checksum verification and write the immutable
  checksum/digest record to `l4n-bmb_latest.sif.ready.json`. No worker starts
  without this record. A canary must finish before `canary.ok` permits rollout.

## Processing

The official scripts are called in this order:

1. `bids2hcp.sh`
2. `bmb_10_prefs.sh`, `bmb_11_fs.sh`, `bmb_12_postfs.sh`
3. `bmb_20_diffusion.sh` (if diffusion exists)
4. `bmb_30_fmrivolume.sh`, `bmb_31_fmrisurface.sh`
5. `bmb_32_icafix.sh`, `bmb_33_postfix.sh`
6. `bmb_34_msmall.sh`, `bmb_35_dedrift.sh`, `bmb_36_fmristats.sh`
7. `hcppipe_qc` with flags for the available modalities.

Structural and diffusion outputs from another image are not used to bypass new
processing. ICA-FIX uses the image's HARP pyfix model. QC report command success
means a report was generated, **not** a scientific QC PASS. Old completed/QC
passed or pulled sessions are excluded from new production claims.

## Scheduler and graceful stop

The node scheduler retains atomic session claims, dead-job recovery, per-stage
CPU/memory budgets, 7-day tmp_work guards, disk reserves, and successor jobs
from the existing workflow, with a new dependency graph for the BMB scripts.
HOKUSAI uses CPU diffusion. DB submits a separate 8-CPU/60-GiB L40S diffusion
job only once structural processing is ready; it does not hold a GPU during
FreeSurfer. Per-session locking and completion markers prevent concurrent GPU
re-execution. Initial rollout is deliberately limited to two node chains/site.

Set `L4N_ROOT` to the deployed `l4n` directory, then:

```bash
bash "$L4N_ROOT/slurm/hcp_node_pipeline.sh" status "$L4N_ROOT/config/db.env"
bash "$L4N_ROOT/slurm/hcp_node_pipeline.sh" submit "$L4N_ROOT/config/db.env" 2
touch /data/juntendodb/amedhcp/l4n_logs/node_pipeline/STOP
```

For HOKUSAI use `hokusai.env` or `hokusaiwang.env`. The STOP file prevents new
claims; claimed sessions may continue through their remaining stages. All
resubmitted initial jobs must depend on the captured old job IDs with
`afterany`, and rollout must additionally depend on a successful canary with
`afterok`. Never remove old STOP files as part of deployment.

## Validation and limitations

The extracted DB image completed a real 0.8-mm session's PreFreeSurfer on
2026-11-02 (RC=0), including MNI registration. That is not evidence that
FreeSurfer, diffusion, all functional processing, or scientific QC have passed.
The final SIF and each platform's runtime therefore get their own canary.
The shell explicitly sets HOME **inside** the container; runtime HOME env
overrides alone were rejected by Apptainer in DB testing.

Run `python3 -m unittest discover -s l4n/tests`. Validate shell syntax on Linux.
Use per-session/per-step schema-2 resource samples; no cross-session sums or
claims that 30-second observations are full-run guaranteed maxima.

Upstream sources: https://github.com/kytk/l4n-BMB and
https://hub.docker.com/r/kytk/l4n-bmb . The image's actual scripts take priority
over older Docker Hub command-name examples.

# AMED HCP Pipeline v6.0.0 (sMRI / dMRI / fMRI)

Slurm + Apptainer/Singularity pipeline that runs full [HCP Pipelines
v6.0.0](https://github.com/Washington-University/HCPpipelines/releases/tag/v6.0.0)
structural, diffusion and functional preprocessing on a multi-site,
multi-vendor (Siemens / GE) cohort, split into three stages so that only the
one step that benefits from a GPU (`eddy`) actually asks for one.

**No subject data, DICOM, or pipeline outputs are included here.** This is
code only. Site/scanner/protocol codes that appear in a few comments (e.g.
`JTD_Prisma_HARP`, `UTK_Prisma_CRHD`) are pseudonymous cohort identifiers
used as running examples during development, not personal identifiers.

## Layout

```
pipeline/
  01_stage1_structural_preeddy.sbatch   entrypoint: CPU node, one whole node per job
  02_stage2_gpu_eddy.sbatch             entrypoint: GPU node (H100, eddy_cuda11.0)
  03_stage3_posteddy_fmri.sbatch        entrypoint: CPU node
  repair_preeddy.sbatch                 entrypoint: CPU node, re-run PreEddy only
  lib/                                  helpers the entrypoints call by path at
    hcp_env.sh                          runtime ($AMED_ROOT/scripts/<name> inside
    convert_one_subject.sh              the container) -- not meant to be run
    build_subject_manifest.py           directly. See "Deploying" below for why
    run_structural_generic.sh           this subfolder gets flattened back out.
    run_fmri_generic.sh
    run_advanced_fmri_generic.sh
container/
  hcp_v6_complete.def                   Apptainer build recipe
  build_hcp_v6_complete.sbatch          the build job
  hcp_container_entrypoint.sh           baked into the image's %environment
  validate_hcp_complete.sh              post-build smoke test
tools/
  sem_tool.sh, sem_drain.sh             live-retune stage 1's concurrency caps
  gpu_sem_add.sh                        same idea, per-GPU, for stage 2
  qc_stage2.py                          verify eddy output before stage 3 sees it
  scope_report.py                       cohort x protocol completion counts
```

## Pipeline stages

| Stage | Script | Runs on | What it does |
|---|---|---|---|
| 1 | `pipeline/01_stage1_structural_preeddy.sbatch` | CPU node | DICOM→NIfTI, manifest build, PreFreeSurfer, FreeSurfer, PostFreeSurfer, and `DiffPreprocPipeline_PreEddy.sh` (gradient-distortion prep + topup) if the subject has diffusion data |
| 2 | `pipeline/02_stage2_gpu_eddy.sbatch` | GPU node (H100, `eddy_cuda11.0`) | `DiffPreprocPipeline_Eddy.sh --gpu=TRUE` only -- the single HCP sub-step that is GPU-accelerated |
| 3 | `pipeline/03_stage3_posteddy_fmri.sbatch` | CPU node | PostEddy, fMRIVolume, fMRISurface, ICAFIX, PostFix, MSMAll (MATLAB Runtime / `--matlab-run-mode=0`, no MATLAB license needed) |
| repair | `pipeline/repair_preeddy.sbatch` | CPU node | Re-runs only PreEddy for subjects whose manifest had to be regenerated (see the DWI-gate note below) |

Each stage is one `sbatch` submission per **whole node**, with its own
internal scheduler (a Bash counting semaphore over an unlinked FIFO) rather
than one Slurm job per subject -- see "Concurrency" below for why, and
`tools/` for how to retune it on a job that's already running.

**Adding a connectome step (optional, not included):** stage 3 stops at
MSMAll on purpose -- tractography/connectome generation is site-specific and
not part of this repo. If you have your own MRtrix3-based pipeline, the
integration point is a single extra call after stage 3's fMRI block, once
`DiffPreprocPipeline.sh`/stage 2 has written `T1w/Diffusion/{data,bvals,bvecs,
nodif_brain_mask}` and FreeSurfer has written `T1w/<subject>`:

```bash
apptainer exec --cleanenv --bind "${ROOT}:/work" "$SIF" \
  /path/to/your/connectome/pipeline "$subject" \
  --input-root=/work/output --output-root=/work/output --fs-root=/work/output
```

## Requirements

- Slurm cluster with a CPU partition and a GPU partition (NVIDIA driver
  supporting the container's CUDA toolkit; developed against H100s with
  `eddy_cuda11.0`).
- [Apptainer](https://apptainer.org/) or Singularity.
- A container built from `container/hcp_v6_complete.def`: HCP Pipelines
  v6.0.0, FSL (with `eddy_cuda11.0`), FreeSurfer 6.0.1, Connectome Workbench,
  dcm2niix, and the MATLAB Runtime (R2022b Update 10) so ICAFIX/MSMAll run
  under `--matlab-run-mode=0` without a MATLAB license. `container/` also has
  the build job, an entrypoint/environment script baked into the image, and
  `validate_hcp_complete.sh` for a post-build smoke test. The MATLAB Runtime
  installer itself is **not** redistributed here -- download it from
  MathWorks under their own license and point the `.def` file's `%files` at
  it before building.
- Your own [FreeSurfer license](https://surfer.nmr.mgh.harvard.edu/registration.html)
  file -- not included, never commit one.

## Configuration

Every stage script reads these from the environment, falling back to this
institution's own paths if unset -- override all three for another site:

```bash
export AMED_ROOT=/path/to/your/data/root      # raw_nifti/, output/, logs/, manifests/, scripts/
export HCP_SIF=/path/to/hcp_pipelines_v6.sif  # built from container/hcp_v6_complete.def
export FS_LICENSE=/path/to/license.txt
```

`AMED_ROOT` is expected to contain:

```
raw_nifti/<subject>/       dcm2niix output + subject_manifest.json + subject.env
output/<subject>/          HCP Pipelines output tree
logs/                      per-subject and per-batch-job logs
scripts/                   this repo's scripts (see Deploying)
```

### Deploying

The entrypoints call their helpers by a flat runtime path,
`${AMED_ROOT}/scripts/<name>` (see e.g. stage 1 calling
`"${ROOT}/scripts/convert_one_subject.sh"`), independent of how this repo
itself is laid out. So when installing onto a cluster, flatten `pipeline/`
(entrypoints and `pipeline/lib/*` together, no subfolder) into
`$AMED_ROOT/scripts/`:

```bash
cp pipeline/*.sbatch pipeline/lib/* "$AMED_ROOT/scripts/"
cp tools/* "$AMED_ROOT/scripts/"   # optional, only needed for live retuning
```

Then submit from `$AMED_ROOT/scripts/`, e.g.
`sbatch 01_stage1_structural_preeddy.sbatch my_subject_list.tsv`.

## Manifest generation (`pipeline/lib/build_subject_manifest.py`)

Reads dcm2niix's per-series JSON sidecars and classifies each series into
T1w / T2w / fMRI / diffusion / spin-echo fieldmap, then writes
`subject_manifest.json` and a `subject.env` of `HCP_*` variables the stage
scripts source directly.

Two things about it are worth reading before trusting it on a new site's
data, because both came from real failures in a ~5,700-subject, ~20-site run:

- **T1w/T2w matching is vendor-name-aware, and was deliberately NOT widened
  as far as it could go.** Siemens' product names (`t1_mpr`, `t2_spc`) don't
  match GE's (`T1_MPR` happens to overlap, but GE's 3D T2 is `T2_CUBE`) or
  Philips' (`VISTA`). Matching on the vendor product names `fspgr`/`cube` was
  safe against every unique `SeriesDescription` string in this cohort (zero
  false positives); matching on the generic words `mprage`/`space` was
  **not** -- both also matched several 3-4mm low-resolution reference/scout
  series in this same data (e.g. `mpr_mprage_3mm_axi`,
  `t1_space1315A_axi_w3x3`), which would have silently substituted a scout
  for the real structural scan on any site using that naming. `bravo` and
  `vista` are included defensively (GE T1 / Philips T2 product names) even
  though they don't occur in this cohort -- re-run the same false-positive
  check against your own site names before trusting them on real subjects.
- **Diffusion series matching excludes scanner-computed derived maps**
  (`ImageType` containing `DERIVED`, or a `TRACEW`/`ADC`/`FA`/... tag). One
  site's protocol included clinical trace-weighted and ADC maps alongside the
  real diffusion-weighted series; without this filter they get averaged into
  the "gradient table" and their different readout time makes the effective
  echo spacing ambiguous. A subject_manifest.json is written to
  `raw_nifti/<subject>/`.

If DICOM anonymization stripped the Siemens CSA field dcm2niix normally
reads `DwellTime` from, `resolve_dwell_time()` derives it from
`PixelBandwidth` and `BaseResolution` (Siemens only -- GE/Philips don't
carry `BaseResolution`, so this cohort's few GE subjects still need their
own dwell-time derivation; that's an open item, not solved here).

## Concurrency

Stage 1's defaults (`ENTRY_MAX_CONCURRENT`, `POST_MAX_CONCURRENT` near the
top of the script) came from *measuring*, not guessing:

- FreeSurfer's `recon-all` is a long chain of small, mostly-serial steps, so
  giving one subject more OpenMP threads bought only ~1.5x speedup --
  concurrency (more subjects at once, one thread each) beats per-subject
  parallelism here.
- PostFreeSurfer with QC scene rendering disabled peaks at a few hundred MB
  to ~2GB per subject (measured from FreeSurfer's own
  `touch/rusage.*.dat` records), not the "hundreds of GB" a naive first
  estimate suggested -- so memory is rarely the binding constraint; CPU core
  count is.

Because each stage runs as one long-lived `sbatch` per node with a Bash
semaphore over an unlinked FIFO (`exec 3<>fifo`, N tokens written at
startup, `read -u 3` / `echo >&3` to take/return a slot), the concurrency cap
can be **raised or lowered on an already-running job** without restarting
it, by writing (or reading-and-discarding) tokens on that FIFO from another
`srun --overlap` session. `tools/sem_tool.sh status|add`,
`tools/sem_drain.sh`, and `tools/gpu_sem_add.sh` (same idea, per-GPU, for
stage 2) implement this. Useful when the node turns out to have far more
headroom than the original request assumed -- check CPU `user+sys` time and
GPU `nvidia-smi` utilization (not just load average, which conflates
runnable and uninterruptible-sleep processes) before pushing concurrency
higher.

## QC before stage 3 (`tools/qc_stage2.py`)

Some subjects get attempted more than once (a node dies, a job is
resubmitted); a file simply existing doesn't mean the run that produced it
finished cleanly. Before feeding `eddy`'s output to stage 3, this checks that
the corrected 4-D series' volume count agrees with the gradient table, the
rotated bvecs, eddy's own per-volume parameter file, and `index.txt` --
which is exactly what would silently break tensor fitting downstream if any
one of them were left over from an interrupted run.

## License

No license file is included yet. Treat this as reference/example code
(all rights reserved) unless the repository owner adds one.

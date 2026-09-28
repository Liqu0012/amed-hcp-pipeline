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
  repair_posteddy_flag2.sbatch          entrypoint: CPU node, redo PostEddy's
                                         AP/PA combine with flag=2 for subjects
                                         already run under the old flag=1
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
  qc_stage1.py                          verify FreeSurfer/PostFreeSurfer output
  qc_stage2.py                          verify eddy output before stage 3 sees it
  qc_stage3.py                          verify MSMAll output
  scope_report.py                       cohort x protocol completion counts
```

## Pipeline stages

| Stage | Script | Runs on | What it does |
|---|---|---|---|
| 1 | `pipeline/01_stage1_structural_preeddy.sbatch` | CPU node | DICOM→NIfTI, manifest build, PreFreeSurfer, FreeSurfer, PostFreeSurfer, and `DiffPreprocPipeline_PreEddy.sh` (gradient-distortion prep + topup) if the subject has diffusion data |
| 2 | `pipeline/02_stage2_gpu_eddy.sbatch` | GPU node (H100, `eddy_cuda11.0`) | `DiffPreprocPipeline_Eddy.sh --gpu=TRUE` only -- the single HCP sub-step that is GPU-accelerated |
| 3 | `pipeline/03_stage3_posteddy_fmri.sbatch` | CPU node | PostEddy, fMRIVolume, fMRISurface, ICAFIX, PostFix, MSMAll (MATLAB Runtime / `--matlab-run-mode=0`, no MATLAB license needed) |
| repair | `pipeline/repair_preeddy.sbatch` | CPU node | Re-runs only PreEddy for subjects whose manifest had to be regenerated (see the DWI-gate note below) |
| repair | `pipeline/repair_posteddy_flag2.sbatch` | CPU node | Redoes PostEddy with `--combine-data-flag=2` for subjects already processed under the old, incorrect `flag=1` (see "PostEddy's AP/PA combine flag" below) -- reuses existing eddy output, writes to an isolated `Diffusion_flag2/` directory rather than overwriting the original |

Each stage is one `sbatch` submission per **whole node**, with its own
internal scheduler (a Bash counting semaphore over an unlinked FIFO) rather
than one Slurm job per subject. `tools/sem_tool.sh`, `sem_drain.sh`, and
`gpu_sem_add.sh` can retune the concurrency cap on a job that's already
running, without restarting it.

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
- **AP/PA direction is read from the series name first, metadata second --
  and only the name is trusted.** `direction_label()` matches `_AP_`/`_PA_`
  in the `SeriesDescription` before falling back to the DICOM
  `PhaseEncodingDirection` field. When both are present it now cross-checks
  them and prints a `WARNING` to stderr on disagreement, but it still goes
  with the name -- a series mislabeled at the scanner, or a site whose
  naming convention doesn't mean what this cohort's does, needs a human to
  look at that warning, not an automatic override. This is a different
  failure mode from the AP/PA *gradient-table* mismatch described under
  "PostEddy's AP/PA combine flag" below: that one is about whether two
  correctly-labeled AP/PA series can be validly paired at all; this one is
  about whether "AP" and "PA" were assigned to the right series in the
  first place.
- **T1w/T2w selection silently takes the first match if more than one
  series matches.** `HCP_T1`/`HCP_T2` are built from `t1[0]`/`t2[0]`. A
  repeated acquisition (motion, protocol restart) or a second series that
  also matches the vendor terms above means there's a real choice being
  made, not just "the" T1w -- a `WARNING` is now printed listing every
  candidate and which one was picked, so check it rather than assuming the
  first series in acquisition order was the usable one.

If DICOM anonymization stripped the Siemens CSA field dcm2niix normally
reads `DwellTime` from, `resolve_dwell_time()` derives it from
`PixelBandwidth` and `BaseResolution` (Siemens only -- GE/Philips don't
carry `BaseResolution`, so this cohort's few GE subjects still need their
own dwell-time derivation; that's an open item, not solved here).

## PostEddy's AP/PA combine flag (`pipeline/03_stage3_posteddy_fmri.sbatch`)

`DiffPreprocPipeline_PostEddy.sh --combine-data-flag=N` controls how the
two opposite-phase-encoding (AP/PA) acquisitions get combined after eddy:
`1` averages each Pos/Neg volume pair by acquisition index; `2` keeps
every corrected volume unmerged. `1` is the more common HCP choice, but it
is only correct if AP and PA are gradient-direction-matched at each index
-- and that has to be checked against your own raw `.bval`/`.bvec` files,
not assumed from matching volume counts or filenames.

This cohort's multi-shell (b~700 / b~2000) protocol is not matched: pairing
by index mixed shells (one subject's index 2 was b=2010 on AP vs. b=695 on
PA, gradient directions ~89.8 degrees apart, verified directly against the
raw `.bval` files), and even the best possible one-to-one direction
matching *within* a shell across the whole acquisition has a median angle
of 17-27 degrees with no pairs under 5 degrees -- there is no valid pairing
to average here, at any index. `--combine-data-flag=1` was silently
producing physically meaningless composite volumes for roughly two-thirds
of the non-b0 pairs; `03_stage3_posteddy_fmri.sbatch` uses `flag=2`
instead. This does **not** require rerunning eddy (stage 2) -- eddy
corrects each original volume independently of how PostEddy later combines
them, so already-computed eddy output is reusable; only PostEddy and
everything downstream (registration, tensor/ODF fitting, tractography)
depends on this flag.

`qc_stage2.py`'s volume-count/bval-length/bvec-length checks do not catch
this: they confirm eddy's own output is internally consistent, not whether
the two volumes flag=1 is about to average actually represent the same
diffusion encoding. `qc_stage3.py` now checks that PostEddy's *combined*
output (`T1w/Diffusion/{data.nii.gz,bvals,bvecs}`) has matching volume
counts, which would catch a flag silently dropping or duplicating volumes
-- but it still can't tell you whether flag=1 averaged the right pairs,
since that requires the raw, pre-merge gradient tables this pass has no
way to reconstruct from merged output alone. If you switch back to flag=1
on other data, check those raw per-volume gradient tables directly first.

**Subjects already processed under the old flag=1 are not automatically
fixed by changing the flag** -- stage 3 skips anything with
`.stage3_complete` already set, and there is no in-place way to redo just
one step of an already-completed subject. `pipeline/repair_posteddy_flag2.sbatch`
reprocesses a subject list with flag=2 into an isolated `Diffusion_flag2/`
directory (copying the existing `eddy/`/`topup/` output rather than
rerunning eddy, and never touching the original `Diffusion/` or the
subject's fMRI outputs). Decide for yourself, after checking the new
output, whether and how to promote it in place of the original.

## QC (`tools/qc_stage1.py`, `tools/qc_stage2.py`, `tools/qc_stage3.py`)

Some subjects get attempted more than once (a node dies, a job is
resubmitted); a file simply existing doesn't mean the run that produced it
finished cleanly, and none of the stage scripts' own exit-code checks catch
a step that returns 0 but writes truncated or incomplete output. Each QC
tool re-derives pass/fail from the actual output files instead of trusting
the `.stageN_complete` sentinel:

- **`qc_stage1.py`** -- confirms `recon-all.log` reports a clean finish,
  `aparc+aseg.mgz` is a plausible size, and both hemispheres'
  PostFreeSurfer 32k surface files exist and aren't truncated.
- **`qc_stage2.py`** -- before feeding `eddy`'s output to stage 3, checks
  that the corrected 4-D series' volume count agrees with the gradient
  table, the rotated bvecs, eddy's own per-volume parameter file, and
  `index.txt` -- which is exactly what would silently break tensor fitting
  downstream if any one of them were left over from an interrupted run.
- **`qc_stage3.py`** -- confirms the final MSMAll-registered, ICA-FIX-cleaned
  dense timeseries and both hemispheres' MSMAll sphere registrations exist
  and aren't truncated. Subjects with fewer than 2 fMRI runs legitimately
  skip FIX/PostFix/MSMAll entirely (this pipeline's multi-run FIX design
  needs runs to concatenate) -- the tool checks each subject's actual run
  count first so it doesn't flag those as failures. Independently of the
  fMRI checks, it also confirms PostEddy's combined diffusion output
  (`T1w/Diffusion/{data.nii.gz,bvals,bvecs}`) has matching volume counts,
  for any subject that has one -- see "PostEddy's AP/PA combine flag"
  above for what this can and can't catch.

Stage 3 also checks `.stage2_complete` itself before running PostEddy on a
subject with diffusion data, rather than only checking the manifest for
whether diffusion series exist. The manifest says a subject *has* DWI; it
says nothing about whether stage 2 (GPU eddy) has actually *finished* for
it, and running PostEddy against missing or partial eddy output is a
confusing way to find that out.

## License

No license file is included yet. Treat this as reference/example code
(all rights reserved) unless the repository owner adds one.

# HOKUSAI pipeline (HCP Pipelines v6.0.0 via QuNex 1.5.1)

The DB cluster is gone, so the HARP sessions that were not already processed,
downloaded and accepted (1083 sessions) are reprocessed on RIKEN HOKUSAI BW2.
This directory is the HOKUSAI deployment. It started from the Rokosan
"portable workflow" (Slurm + Singularity, CPU-only) and was corrected on
2026-10-28 so that every problem found on DB is handled before anything runs.

```
stages/      per-session stage scripts      -> HOKUSAI ~/hcp_pipeline/
workflow/    scheduler layer (bin, slurm,   -> HOKUSAI ~/hcp-portable-workflow/
             config, tests)
transfer/    wu-side index + parallel upload of raw zips (list-driven)
```

## Problems found on DB, and how this version handles them

| # | Problem on DB | Effect there | Handling here |
|---|---|---|---|
| 1 | Several reconstructions of one acquisition (MPR_Cor/Sag/Tra reformats, MIP, FIL, ND + DIS2D, NORM + non-NORM) passed to PreFreeSurfer with `@` and **averaged** | 728 HARP structurals invalid (425 + 303 reworked) | `hcp_select_inputs.py`: one T1w and one T2w; DERIVED, MIP and non-3D/anisotropic images dropped; prefer ND (ImageType *and* ImageTypeText), then NORM, then lowest series. DIS-only sessions run with a warning |
| 2 | PostEddy (and PreEddy) `--combine-data-flag=1` averages AP/PA volumes by index; AP/PA sets are not matched (e.g. 68 vs 69), so b-value shells were mixed | all flag=1 diffusion redone with flag=2 | PreEddy and PostEddy use `--combine-data-flag=2`; QC compares final bvals/bvecs/volume counts with eddy's |
| 3 | Every `bold`/`rfmri` series treated as REST (POSNER, EMOTION, CARIT) | REST_ALL/FIX/MSMAll of those sessions invalid | REST runs only; task fMRI excluded |
| 4 | Aborted 54-volume run kept | fMRI of that session invalid | runs with < 100 volumes excluded; QC fails < 100 time points |
| 5 | GE `_SB` not recognised as SBRef -> duplicate run names | 104 sessions failed early | `_SB`/`SBRef` recognised; SBRef matched by description + preceding series; runs renumbered per direction |
| 6 | AP/PA taken from the series name | UKY_Skyra_HARP_3003_002 used the wrong TOPUP pair; 26 DWI / 8 BOLD conflicts | direction from `PhaseEncodingDirection` (j- = AP, j = PA); a contradicting name blocks the session |
| 7 | Missing PE / EffectiveEchoSpacing / DwellTime / T1 passed silently | failures or empty parameters | missing values block the session (exit 3, `.hcp_input_problems.txt`) |
| 8 | Derived diffusion maps (ADC/FA/TRACEW) and stale envs | PreEddy repairs | DERIVED or no bval/bvec excluded; inputs re-selected from DICOM every run |
| 9 | Completion marker treated as "usable"; structural QC off | all of the above found only by audit | new `qc` stage (`hcp_qc_session.py`): PASS / REVIEW / FAIL; only PASS writes `.hcp_qc_pass.ok` |
| 10 | Stage 3 did not check stage 2 completion | possible use of unfinished eddy | every stage checks its prerequisite marker |
| 11 | `build-manifest.sh` (Rokosan) stripped `_MRn` and merged MR1/MR2 zips into one session | would mix scan visits, names differ from DB | one archive per session, full name kept, duplicates rejected; list-file input |
| 12 | Interrupted FreeSurfer (segfault, power loss) | manual cleanup | failed subject tree renamed before retry (`recon-all.error`) |

Processing parameters were aligned with the DB v6 production run (see
`pipeline/lib/run_structural_generic.sh`, `run_fmri_generic.sh` on `main`):
PreFreeSurfer readout distortion correction with the SE pair nearest the T1
(`--avgrdcmethod=TOPUP`, `--seunwarpdir=j`, DwellTime sample spacing,
`--unwarpdir=z`, `--usejacobian=FALSE`); FreeSurfer `-parallel -openmp`;
fMRIVolume `--usejacobian=TRUE --wb-resample=TRUE --doslicetime=FALSE`;
fMRISurface `--fmri-qc=YES --goodvoxel=YES`; eddy `--data_is_shelled --repol`;
PreEddy `--select-best-b0=FALSE --ensure-even-slices=FALSE`, b02b0 topup config.

## QC gate (`stages/hcp_qc_session.py`)

| Area | FAIL (rerun) | REVIEW (look at it) |
|---|---|---|
| inputs | selection problems, missing T1w/T2w | selection warnings (DIS-only, unpaired SE) |
| structural | recon-all not finished, aparc+aseg / 32k surfaces missing | Euler lh+rh < -200, BrainSegVol/eTIV > 0.94, eTIV out of range |
| diffusion | bvals differ from eddy, volume mismatch, bvecs not unit / not eddy-rotated, flag=1 artefacts | |
| fMRI | run without dense timeseries or < 100 time points, no MSMAll cleaned output | mean relative RMS > 0.5 mm |

Thresholds are environment variables (`HCP_QC_EULER_MIN`, `HCP_QC_BRAIN_ETIV_MAX`,
`HCP_QC_RELRMS_MAX`). `HCP_QC_READONLY=1` reports without writing. Tried
read-only on 43 downloaded DB sessions: 40 PASS, 3 REVIEW; the known bad
54-volume run (SWA_Skyraf_HARP_0827_001_MR1) FAILs.

## Running a batch on HOKUSAI

HOKUSAI storage (~4 TB quota) cannot hold all inputs and outputs: a session
needs ~1.1 GiB of zip and ~25 GiB of full output, so run ~70 sessions per batch
and move QC-passed sessions off HOKUSAI before the next one.

```bash
cd ~/hcp-portable-workflow
bash bin/build-manifest.sh ~/AMED_HCP/manifests/batch01.tsv batch01_zips.txt
bash bin/preflight.sh config/hokusai_packed.env ~/AMED_HCP/manifests/batch01.tsv
bash slurm/submit-packed.sh config/hokusai_packed.env ~/AMED_HCP/manifests/batch01.tsv batch01
bash bin/status.sh config/hokusai_packed.env ~/AMED_HCP/manifests/batch01.tsv   # last column: QC
bash tests/smoke.sh                                                              # scheduler wiring
```

## Known differences from the DB run

- eddy runs on CPU (`eddy_cpu`, 112 threads); DB used `eddy_cuda11.0`.
  Results are close but not bit-identical. HOKUSAI has a `gpu` partition and
  the container has `eddy_cuda` if strict parity is needed.
  `stages/hcp_diffusion_eddy_gpu.sh` is the Rokosan ARM GPU variant and is not
  used on HOKUSAI.
- QuNex 1.5.1 ships HCP Pipelines v6.0.0 (same as DB), FSL 6.0.7.23 and
  FreeSurfer 6.0.0 (the DB container used FreeSurfer 6.0.1).
- Concat names differ (`fMRI_CONCAT_ALL` here, `REST_ALL` on DB); HOKUSAI also
  runs DeDriftAndResample.
- Sessions blocked by missing parameters (about 102 GE without DwellTime and
  25 without T1 on DB) are reported, not processed.

## Status (2026-10-28)

- Input selection and conversion: tested end to end on real data from 5 sites
  (ATR_Verio, SWA_Skyraf, TMG_Prismaf, TMG_Triot, UOS_Prisma).
- QC gate: tested read-only on downloaded DB outputs.
- Scheduler: `tests/smoke.sh` passes (10 stages including QC).
- Not yet run: a full PreFreeSurfer -> MSMAll -> QC session on HOKUSAI.
  Do that on one session before submitting batches.

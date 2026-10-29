# HCP recompute session tracking

Snapshot: **2026-10-28 19:05:19 JST**. These are observed records at that time, not a live monitor.

- [Excel tracker](HCP_stage_tracker.xlsx): 2,762 sessions; each stage has its own node and status dropdown. Completion boxes follow the corresponding stage status.
- [Online session table](sessions.md): compact per-session checklist.
- [CSV tracker](HCP_stage_tracker.csv): the same session metadata for filtering and comparison in Git.

## Computation plan (2026-10-28 20:10 JST)

Each session runs all three stages on one system, so the node columns for Stage 1, 2 and 3 are the same. Sessions not yet scheduled are `待处理`.

| System | Sessions | Raw data | Eddy |
|---|---:|---|---|
| digital brain | 2,167 | 1,487 already on DB; 680 still to upload (UHI_PT 632, KyotoU2_PT 48) | GPU (H100) |
| hokusai chang (ziqing) | 295 | BMB_OsakaU_PT 101 already on ziqing (names and sizes checked); BMB_TS KyotoU/NagoyaU/OsakaU/TokyoU/UHI/UTI 194 being uploaded | CPU |
| hokusai wang (haruka74) | 300 | BMB_UHI_PT, the last 300 by name (`UHI_Skyraf_HARP_5328_003_MR1` to `UHI_Skyraf_HARP_7066_001_MR1`), uploaded from wu | CPU |

Rationale: a HOKUSAI session costs about 7 mpc node-hours (structural 7 per node in about 8 h; CPU eddy one session per node, about 4.7 h; fMRI chain 4 per node in about 4.4 h), while DB packs 24 structural sessions per node and runs eddy on GPU. HOKUSAI therefore takes the sessions that are already there or not yet on DB. The HOKUSAI-assigned sessions have the digital brain upload plan unchecked and must be excluded from the DB upload list and the DB Stage 1 scan.

| Observed item | Sessions |
|---|---:|
| Recompute list / digital brain upload target | 2,762 |
| Stage 1 running on digital brain | 144 |
| Stage 1 configured on digital brain, not yet claimed | 528 |
| Outside the current Stage 1 source-directory scope | 2,090 |
| ZIP file observed on DB (existence only) | 1,487 |
| Upload recorded as checksum-verified on wu | 1,480 |
| Full Stage 1 completion markers observed | 0 |
| Full Stage 2 completion markers observed | 0 |
| Full Stage 3 completion markers observed | 0 |

## Submissions

Rows submitted to a system are marked `已计划` for all three stages, with the job IDs in `Stage 1 任务/依据`. Do not run them anywhere else.

| Time (JST) | System | Tag | Sessions | Jobs |
|---|---|---|---:|---|
| 2026-10-28 20:30 (**cancelled 20:40**, none started; rows back to `待处理`) | hokusai chang (ziqing), mpc | `chang_osakau_pt_20261028` | 101 (BMB_OsakaU_PT) | structural 9706723, convert 9706724, preeddy 9706725, eddy 9706726, posteddy 9706727, fmri 9706728, icafix 9706729, msmall 9706730, dedrift 9706731, qc 9706732 |
| 2026-10-28 20:55 (**cancelled 21:00**, none started; replaced by the node pipeline below) | hokusai chang (ziqing), per-stage arrays | `chang_osakau_pt_20261028b` | 101 (BMB_OsakaU_PT) | structural 9706744, convert 9706745, preeddy 9706746, eddy 9706747 (3 x 35 threads per node), posteddy 9706748, fmri 9706749, icafix 9706750, msmall 9706751, dedrift 9706752, qc 9706753 |
| 2026-10-28 21:00 | hokusai chang (ziqing), mpc, whole-node pipeline (`slurm/hcp_node_pipeline.sh`, one job = one node running all stages, 106 CPU / 106 GiB budget) | `hokusai_node.env` | 295 (BMB_OsakaU_PT 101 + BMB_TS HARP 194; TS start automatically once uploaded) | 12 node chains, first jobs 9706786–9706797; status: `hcp_node_pipeline.sh status config/hokusai_node.env` |
| 2026-10-29 17:55 | digital brain, stage 2 GPU (4× H100, gcalc2) | `db_stage2.env` | rolling: every DB session with `.stage1_complete` (614 now) | `hcp_stage2` 24205 (queued) |
| 2026-10-29 21:30 | digital brain, stage 2 GPU (4× L40S, gcalc1, 28 CPU / 218 GB) | `db_stage2_l40s.env` | same rolling stage-2 queue as 24205 (a session is taken by only one worker) | `hcp_stage2` 24206 (queued) |
| 2026-10-29 17:53 | digital brain, stage 1 extended scope (5 nodes) | `db_stage1.env` | rolling: all DB-assigned sessions on DB (1,487 + 680 being uploaded) | successors 23838–23842 (23896 held) |
| 2026-10-28 21:10 | hokusai wang (haruka74), mpc, whole-node pipeline (same script; container copied from ziqing, sha256 ccef8d7c… checked) | `hokusai_wang_node.env` | 300 (BMB_UHI_PT, uploaded from wu; start automatically once each upload completes) | 12 node chains, first jobs 9706857–9706868; status: `hcp_node_pipeline.sh status config/hokusai_wang_node.env` |

### HOKUSAI results and problem sessions (2026-10-29 12:50 JST)

HOKUSAI home space is not enough for all results (ziqing 1.9 TB free for 295 sessions, haruka74 1.6 TB for 300; about 13-14 GB per finished session). A loop on wu (`~/harp_recompute_index_20261028/pull_hokusai_results.sh`, started with `start_pull.sh`, every 30 min) copies each session whose node-pipeline state is `DONE` to `wu:/mnt/data/amed_hcp/hokusai_v6_20261028/output/<session>/` (with its node-pipeline logs and state under `hcp_node_pipeline/`), verifies it by checksum, and only then deletes the HOKUSAI study directory and writes `state/<session>/PULLED`. Failed and blocked sessions stay on HOKUSAI. Raw zips are kept. Record: `pull_state/pulled.tsv` on wu.

Results on wu are now pulled to `wu:/mnt/data/HCP/amed_hcp_v6_hokusai/<session>/` (4 sessions in parallel per HOKUSAI account).

### Problem sessions (checked 2026-10-29 15:50 JST)

Checked: the convert and structural logs of every session started so far, 181 on hokusai chang, 153 on hokusai wang and 672 on digital brain, for a missing or unusable T1w/T2w, truncated DICOM files, and FreeSurfer Talairach failures. Seven sessions stopped. They are marked `阻塞` (input data cannot be used as is) or `失败` (a stage failed) in the Excel/CSV tracker, with the details in `备注`. None has been rerun or had its parameters changed; each needs a decision.

| Session | System | Status | Problem | Suggested action |
|---|---|---|---|---|
| `UOS_Prisma_HARP_0054_001_MR1` | hokusai chang | 阻塞 (convert) | No T2w in the raw data (and no DWI): only T1_MPR, BOLD_REST1 and scouts | Record as missing data |
| `JTD_Prisma_HARP_1674_001_MR1` | digital brain | 阻塞 (convert) | No 3D T1w or T2w: only 2D t1_tse/t2_tse/FLAIR, MRA, and a DERIVED DWI; no rfMRI | Record as missing data |
| `UHI_Skyraf_HARP_6210_001_MR1` | hokusai wang | 阻塞 (convert) | T2_SPC_13 is 0.8×0.8×1.6 mm (212 slices). The input selector requires near-isotropic voxels (longest edge ≤ 1.5 × shortest), so it reports "no usable T2w" | Decide whether this T2w may be used (selector rule change; preprocessing-parameter issue) |
| `UHI_Skyraf_HARP_6127_001_MR1` | hokusai wang | 失败 (convert, rc=8) | One truncated DICOM in series 11 = BOLD_REST1_PA (375 volumes): `File not large enough to store image data`, 1720 of 2095 files converted. The zip matches wu byte for byte, so the source itself is damaged. T1w/T2w are fine | Run without the REST1_PA run, or exclude the session |
| `JTD_Prisma_HARP_1220_001_MR1` | digital brain | 失败 (convert, rc=8) | One truncated DICOM in series 24 (after BOLD_REST1_AP_23, the SBRef, so probably the REST1_AP run), 640 of 642 files converted. Its T1_MPR/T2_SPC are 320×320×146, unlike other JTD sessions | Confirm the damaged series, then drop that run or exclude the session |
| `UHI_Skyraf_HARP_2088_001_MR1` | digital brain | 失败 (convert, rc=8) | Same as 6127: one truncated DICOM in series 11 = BOLD_REST1_PA and one in series 20 = BOLD_REST2_AP, 1345 of 2095 files converted. CRCs inside the zip are fine and the md5 on wu and DB match, so the source is damaged. T1w/T2w/DWI are fine | Run without the two damaged runs, or exclude the session |
| `UHI_Skyraf_HARP_2091_004_MR1` | digital brain | 失败 (convert, rc=8) | Same as 6127: one truncated DICOM in series 15 = BOLD_REST1_PA, 1720 of 2095 files converted; zip CRCs fine, md5 on wu and DB match. T1w/T2w/DWI are fine | Run without REST1_PA, or exclude the session |
| `UHI_Skyraf_HARP_2098_001_MR1` | digital brain | 阻塞 (convert) | No T2w in the raw data (and no DWI): only T1_MPR, BOLD_REST1 AP/PA and SE field maps | Record as missing data |
| `UKY_Skyra_HARP_3003_002_MR1` | digital brain | 阻塞 (convert) | Series names contradict the DICOM: SEField1_PA (series 9) and BOLD_REST1_PA (series 11) have PhaseEncodingDirection j- (AP); the selector stops instead of correcting with the wrong direction | Check the real phase-encoding direction, then decide |
| `UHI_Skyraf_HARP_6151_001_MR1` | hokusai wang | 失败 (structural) | FreeSurfer Talairach registration really failed: `talairach.xfm` scales about 1.77 with about 30° rotation (normal sessions about 1.02–1.14, almost no rotation), so `talairach_afd` p=0.0049 < 0.005 is not a borderline case. The upstream AC-PC alignment is normal | Do not just skip the check with `-notal-check`: inspect the T1w first (head position, FOV, artefacts), then fix the Talairach transform by hand or mark the session QC-failed |
| `JTD_Prisma_HARP_1125_002_MR1` | digital brain | 失败 (structural) | Caused by our recon-all `-parallel` option: inside a parallel batch, `rm -f rh.white.H` ran after `ln -s rh.white.preaparc.H rh.white.H` and removed the link (`Cannot find rh.white.H`), a FreeSurfer 6 race. It can only stop a session; it cannot give a wrong result | Rerun once |

### Does this affect other sessions? (checked 2026-10-29 16:20 JST)

The NIfTI headers of the inputs actually used by all 1,006 started sessions (672 DB, 181 hokusai chang, 153 hokusai wang) were read:

- Every selected T1w and T2w is 0.8 mm isotropic (224×300×320, apart from small field-of-view differences), every rfMRI run is 2.4 mm, 86×86×60. No session uses a wrong or low-resolution image. `UHI_Skyraf_HARP_6220_001_MR1` stores its T2w as 300×320×223 (a different slice direction), still 0.8 mm isotropic; check its T2w-to-T1w registration once structural finishes.
- Truncated DICOMs, missing T1w/T2w and the Talairach failure are specific to those sessions' data and do not change other sessions' results.
- The `-parallel` race in `JTD_Prisma_HARP_1125_002_MR1` can make any session stop at random (1 of about 1,000 so far), but cannot give a wrong result silently; a rerun fixes it.
- By the input-selection rules, some sessions are processed with less data than the full protocol. This is deliberate, logged per session, and has to be considered when comparing sessions:
  - 21 DB JTD sessions have no usable rfMRI (aborted runs under 100 volumes, or no AP/PA spin-echo pair); without a spin-echo pair, PreFreeSurfer runs without readout distortion correction (`WARNING no spin-echo pair` in the session log).
  - Runs between 100 and 374 volumes are used as they are. On DB, 6 JTD sessions have one short run (148–320 volumes); in `JTD_Prisma_HARP_1082_001_MR1` an interrupted REST1_AP (217 volumes) is kept as `rfMRI_REST1_AP` and the repeat (375) as `rfMRI_REST2_AP`. On hokusai chang, one UNG session has a 251-volume run.
  - Run counts follow each site's protocol: UHI PT 4, UHI/UKY/UNG/UTI TS 6, UOS 2 or 6, JTD/ATR 2.

No other session has these problems: on HOKUSAI every other session has a T2w with 224 slices (`UHI_Skyraf_HARP_6220_001_MR1` has 223 slices at isotropic resolution, was accepted, and is running), there is no other truncated DICOM, and no other Talairach warning; on DB there is no other `PROBLEM`, truncated DICOM or Talairach failure.

### Audit and fixes 2026-10-30 (03:40 JST)

- **Parameters** checked on the sidecars of 1,145 sessions (DB, ziqing, haruka74, wu): phase-encoding directions and echo-spacing units are right everywhere; SE and BOLD echo spacing are equal (0.00063 s) at every site; every chosen T1w/T2w is 0.8 mm ND+NORM; no FLAIR, phase image or wrong SBRef was selected. UKY (47) and ATR (42) sessions without dMRI have no DWI in the raw data.
- **TOPUP** checked on 1,342 corrections (DB stage 1, haruka74): the correlation of the two phase-encoding images inside the brain goes from 0.37–0.64 to a median of 0.885–0.952 after correction (lowest 0.81); fields about −75/+100 Hz. No correction failed. DWI AP/PA are concatenated, not averaged (`--combine-data-flag=2`), on purpose: AP and PA have different gradient directions (median 57° apart in UOS_0089).
- **Needs a visual check**: `UHI_Skyraf_HARP_5337_002_MR1` (TOPUP fine, but field about ±170 Hz and EPI→T1w BBR cost 0.85 / 0.62 for REST1_AP / PA, normal < 0.5; possible metal artefact). `UHI_Skyraf_HARP_6201_001_MR1` has a large field (+210 Hz) but corrects well.
- **Versions**: the QuNex container has HCP Pipelines v6.0.0-rc.1 (b79d9fb), FreeSurfer 6.0.0, FSL 6.0.7.23. rc.1 differs from v6.0.0 only in FreeSurfer 8 symlinks, so results are the same. The earlier DB container (the 1,083 accepted sessions) had v6.0.0 with FreeSurfer 6.0.1.
- **Gradient non-linearity correction**: not applied anywhere (`--gdcoeffs=NONE`). No Siemens `coeff*.grad` file was found on wu, DB, HOKUSAI or rokosan.
- **Scheduler fixes** (pipeline commit ed8aada, deployed to ziqing, haruka74 and DB; queued jobs run them through the config re-exec hooks):
  - an squeue error no longer counts as "job dead", so live sessions are not taken over;
  - claim takeover is locked, so two jobs cannot both win;
  - tmp_work age is taken from `convert.done`. Sessions older than 5 days are copied home; any still in tmp_work after 6.5 days get `FAILED tmp_work_expiry`. The deadline for the current batch is about 2026-11-05 01:50;
  - DONE records the file count, and the wu pull checks it;
  - converted sessions no longer need their zip;
  - the tmp_work migrators were stopped (`MIGRATE_STOP`); every in-progress session is already in tmp_work.
- **digital brain stage 2**: the L40S job 24206 started at about 01:11.

### Status 2026-10-29 22:10 JST

- **digital brain stage 1**: 666 complete, 4 failed (1125_002, 1220 and the two new UHI sessions 2088_001 and 2091_004, both truncated BOLD DICOMs in the source zip), 1 blocked, about 76 running on 5 nodes. The 680 uploads from wu finished at 19:54 (680/680 verified).
- **digital brain stage 2**: H100 job 24205 waits for gnode03 (all 6 H100 used by another user). L40S job 24206 (4× L40S) is not starting either. Another user's pending 5-minute two-GPU test job (one GPU on gnode01, one on gnode03) holds gnode01 as `PLANNED`, and it cannot run until an H100 frees. A 3-GPU request did not start either, so the request was set back to 4 GPUs. It should start when that job runs, which is expected when gnode03 frees, about 2026-10-30 afternoon.
- **HOKUSAI CPU eddy**: the eddy time estimate was 16 h. Measured (43 runs, 31 threads): median 4.9 h, max 5.3 h. The node pipeline does not start a stage that would outlast the job (24 h), so after ~8 h into each job no eddy was started: only 21 of 180 (ziqing) and 22 of 151 (haruka74) sessions had eddy. `HCP_NODE_EDDY_HOURS` is now 7 in `hokusai_node.env` and `hokusai_wang_node.env` (commit c02acc3), effective for each job that starts from now on.
- **HOKUSAI**: ziqing 15 sessions DONE (13 pulled to wu and removed from HOKUSAI), 6 nodes running, 12 jobs waiting (successors pending in the cluster queue); haruka74 0 DONE, 10 nodes running. All in-progress sessions are in `/lustre/tmp_work` (ziqing home 311 GB used).

### digital brain: stage 1 extended, stage 2 on H100, missing uploads (2026-10-29 18:05 JST)

- **Stage 1** (structural + PreEddy, rolling worker `stage1_worker.sh`): the first 672 sessions (BMB_ATRG3-1_PT, BMB_JTD_PT) are at 614 complete, 55 running, 2 failed, 1 blocked; all were claimed by 13:26 and should finish around 20:00–21:00. `db_stage1.env` now scans every folder that holds DB-assigned sessions (18 folders in `amedhcp1028` and `amedhcp/raw`) and excludes the 1,083 accepted sessions and the 595 HOKUSAI sessions (`lists/stage1_exclude_20261029.txt`). The running workers were told to stop claiming (STOP file, removed again at 17:53); as each finishes its sessions, its successor starts with the new scope. **5 chains** continue (23838–23842); successor 23896 is held so the 6th node is left for the GPU job.
- **Stage 2** (GPU eddy + PostEddy, new rolling worker `slurm/stage2_gpu_worker.sh`, `config/db_stage2.env`): one job, 4× H100 on gnode03 (gcalc2), 32 CPU, 250 GB, 3 eddy per GPU, 4 PostEddy at a time; it takes every session with `.stage1_complete` and writes `.stage2_complete` / `.stage2_failed`. Job **24205** (`hcp_stage2`) is queued: all 6 H100 on gnode03 are in use by another user until about 2026-10-30 13:00–17:30. gnode01 (8× L40S) is idle.
- **Uploads**: of the 2,167 DB-assigned sessions, 1,487 are on DB with sizes matching wu; the 680 missing ones (BMB_UHI_PT 632, BMB_KyotoU2_PT 48, 779 GiB) are being pushed from wu to `/data/juntendodb/amedhcp/raw` since 17:47 (`push_state_db`); stage 1 picks each one up 30 min after it arrives and passes `unzip -t`.

## What the checkmarks mean

`☑` in **digital brain upload plan** means the transfer list targets digital brain. It does not mean all three computation stages have been scheduled or completed. All 2,762 sessions are in that transfer list. The transfer process itself was not observed running during this inspection.

The currently running Stage 1 workers scan only `BMB_ATRG3-1_PT` and `BMB_JTD_PT`, excluding the accepted-session list. Exactly 672 recompute sessions match those directories: 144 have active claims owned by running jobs and session start logs, while 528 have not yet been claimed. Sessions in nested TS folders do not match this source-directory scope, even when their site/scanner prefix is similar. The `digital brain` Stage 1 node selection is filled only for this confirmed computation scope.

The 144 active sessions have conversion and PreFreeSurfer success markers. Neither marker means the whole Stage 1 is finished. Completion boxes stay unchecked until a whole-stage completion record is observed; the current snapshot found no `.stage1_complete`, `.stage2_complete`, or `.stage3_complete` records. These markers record workflow completion and do not replace output QC.

No Stage 2 or Stage 3 jobs were observed in this account's current queue or today's accounting records. Stage 2/3 nodes and statuses remain unconfirmed; the presence of a DB configuration file alone does not establish a per-session submission. The other selectable nodes remain `hokusai sun`, `hokusai chang`, and `hokusai wang`; those systems were not inspected in this update.

## Scheduler snapshot

Six Stage 1 jobs were running: `23814`–`23819`, on `cnode04`–`cnode09`. Six successor jobs (`23838`–`23842`, `23896`) were waiting on dependencies, and job `23848` was held by the user. These are multi-session workers, not one job per session; pending successor jobs must not be counted as additional scheduled sessions.

## Sources and limits

- wu: `/home/sun/harp_recompute_index_20261028/harp_recompute_2762_zips.list` and `harp_recompute.tsv` establish the session set and original ZIP paths.
- wu: `push_harp_list.sh` establishes the digital brain transfer destination; `push_state/done.txt` records successful checksum-verified transfers. A historical failure is not treated as current if the same ZIP also appears in `done.txt`.
- DB: `/data/juntendodb/amedhcp/pipeline/hokusai/workflow/config/db_stage1.env` establishes the Stage 1 scan scope and exclusion list.
- DB: `/data/juntendodb/amedhcp/logs/stage1_queue/claims/<session>/job`, session logs, `squeue`, and `sacct` establish active work.
- DB: `/data/juntendodb/amedhcp/study/<session>/` supplies stage marker filenames; `/data/juntendodb/amedhcp1028/` supplies archive presence.

Remote reads were taken within a short interval, not as an atomic snapshot. A present ZIP may still be uploading; existence alone is not an integrity check. The tracker is operational session metadata only: no images, DICOM content, credentials, licenses, or pipeline outputs are committed.

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

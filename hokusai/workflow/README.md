# Portable HCP workflow

This project wraps the tested Rokosan HCP pipeline with a portable, restartable
Slurm workflow.  Software runs through Apptainer; data and the FreeSurfer license
remain outside the image.

## Quick start on Rokosan

```bash
cp config/rokosan.env config/site.env
cp config/manifest.example.tsv manifest.tsv
# edit manifest.tsv: SESSION<TAB>/absolute/path/to/archive.zip
bash bin/preflight.sh config/site.env manifest.tsv
bash slurm/submit.sh config/site.env manifest.tsv my_run
```

Check progress:

```bash
bash bin/status.sh config/site.env manifest.tsv
```

Validate scheduler wiring without submitting real jobs:

```bash
bash tests/smoke.sh
```

Resume is safe: every stage checks both its marker and prerequisites. Submit the
same manifest again; completed stages return immediately. Slurm `aftercorr`
dependencies preserve per-subject array dependencies.

## Build the image

Rokosan already has the tested image. On another x86_64 machine:

```bash
apptainer build qunex_suite-1.5.1.sif docker://qunex/qunex_suite:1.5.1
```

`containers/Dockerfile` documents the pinned upstream image and adds workflow
metadata. Never copy a FreeSurfer license into an image; mount it at runtime.

## Porting to another cluster

Copy `config/site.example.env` to `config/site.env` and set paths, scheduler
account/partition, scratch location, and stage script directory. The CPU image is
amd64. Configure `HCP_EDDY_COMMAND` for the site's CPU/OpenMP Eddy
implementation; Eddy is submitted to `HCP_CPU_PARTITION` like every other stage.
`config/hokusai.env` is the CPU-only HOKUSAI BW2 profile and requests one full
112-core, 112-GiB MPC node for Eddy.

## Safety and completion rules

- Session IDs are restricted to letters, numbers, dot, underscore, and hyphen.
- Existing results are never deleted.
- `preflight.sh` validates archives, container, license, scripts and study path.
- Before PostEddy, valid `lh.white` and `rh.white` are required and missing
  `*.white.deformed` compatibility symlinks are created atomically.
- A stage marker is accepted only after the stage command exits successfully.
- Logs and a TSV submission ledger are written below `HCP_WORKFLOW_LOG_DIR`.

The current stage implementations are the scripts already validated on Rokosan.
They can later be replaced independently without changing the scheduler layer.

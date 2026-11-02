#!/usr/bin/env python3
"""Inventory remaining assignments without deleting or moving any old results."""
import argparse
import json
import pathlib
import shutil

p = argparse.ArgumentParser()
p.add_argument('--base', required=True); p.add_argument('--study', required=True)
p.add_argument('--old-queue'); p.add_argument('--manifest'); p.add_argument('--assigned')
p.add_argument('--zip-index'); p.add_argument('--copy-canary', action='store_true')
a = p.parse_args(); base = pathlib.Path(a.base); study = pathlib.Path(a.study)
rows = []
if a.manifest:
    rows = [line.split('\t')[:2] for line in pathlib.Path(a.manifest).read_text().splitlines() if line.strip()]
else:
    index = {}
    for line in pathlib.Path(a.zip_index).read_text().splitlines():
        parts = line.split('\t')
        if len(parts) >= 2:
            path = pathlib.Path(parts[-1]); index[path.stem] = str(path)
    for session in pathlib.Path(a.assigned).read_text().splitlines():
        marker = study / session / '.hcp_convert_complete.ok'
        fields = dict(line.split('=', 1) for line in marker.read_text().splitlines() if '=' in line) if marker.exists() else {}
        rows.append([session, fields.get('archive', index.get(session, 'PRESERVED_INPUTS_ONLY'))])
remaining, excluded, canaries = [], [], []
for session, archive in rows:
    d = study / session; inputs = d / 'unprocessed/3T'
    oldstate = pathlib.Path(a.old_queue) / 'state' / session if a.old_queue else None
    complete = (d / '.hcp_qc_pass.ok').exists() or (oldstate is not None and any((oldstate / n).exists() for n in ['DONE', 'PULLED']))
    preserved = (inputs / 'params.sh').is_file()
    archives = archive.split('@')
    available = preserved or all(pathlib.Path(z).is_file() for z in archives)
    if complete:
        excluded.append([session, 'previously_complete_or_pulled'])
    elif not available:
        excluded.append([session, 'input_unavailable'])
    else:
        remaining.append([session, archive])
    if preserved and all((inputs / (n + '.nii.gz')).is_file() for n in ['T1w_MPR', 'T2w_SPC', 'SpinEchoFieldMap_AP_struct', 'SpinEchoFieldMap_PA_struct']) and list(inputs.glob('rfMRI_REST*_AP.nii.gz')):
        canaries.append((complete, session, archive, inputs))
out = base / 'l4n_manifests'; out.mkdir(parents=True, exist_ok=True)
(out / 'remaining.tsv').write_text(''.join('\t'.join(r) + '\n' for r in remaining))
(out / 'excluded.tsv').write_text(''.join('\t'.join(r) + '\n' for r in excluded))
if not canaries:
    raise SystemExit('No preserved T1/T2/SE/fMRI canary input found')
canaries.sort(key=lambda row: (row[0], row[1]))
_, session, archive, inputs = canaries[0]
(out / 'canary.tsv').write_text(session + '\t' + archive + '\n')
if a.copy_canary:
    target = base / 'l4n_inputs' / session / 'unprocessed/3T'
    if not (target / 'params.sh').is_file():
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(str(inputs), str(target))
summary = {'assigned': len(rows), 'remaining_with_inputs': len(remaining),
           'previously_complete': sum(r[1] == 'previously_complete_or_pulled' for r in excluded),
           'input_unavailable': sum(r[1] == 'input_unavailable' for r in excluded), 'canary': session}
(out / 'inventory.json').write_text(json.dumps(summary, indent=2))
print(json.dumps(summary))

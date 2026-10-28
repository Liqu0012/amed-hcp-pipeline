#!/usr/bin/env python3
"""Index of HARP sessions to recompute: all HARP raw zips on wu minus the
sessions already processed, downloaded and passing the new-manifest check."""
import os, re, csv, json, collections
AMED = '/mnt/data/AMED'
DONE = '/mnt/data/amed_hcp/harp_hcp_v6_scheme3/output'
OUT = os.path.dirname(os.path.abspath(__file__))
PAT = re.compile(r'^([A-Z]+_[A-Za-z0-9]+)_HARP_(\d+[A-Z]?)_(\d+)_MR(\d+)\.zip$')
# Downloaded but not usable as-is (new manifest rules, 2026-10-15 check).
RERUN = {
    'TMG_Prismaf_HARP_0027_002_MR1': 'structural input averaged reconstructions',
    'TMG_Prismaf_HARP_0052_001_MR1': 'structural input averaged reconstructions',
    'KRC_Verio_HARP_9549_001_MR1': 'task fMRI mixed into REST',
    'KRC_Verio_HARP_9551_001_MR1': 'task fMRI mixed into REST',
    'SWA_Skyraf_HARP_0754_001_MR1': 'task fMRI mixed into REST',
    'SWA_Skyraf_HARP_0827_001_MR1': 'aborted 54-volume run in REST',
}
copies = collections.defaultdict(list)
for root, dirs, files in os.walk(AMED):
    dirs[:] = [d for d in dirs if d != '@eaDir']
    for f in files:
        if PAT.match(f):
            p = os.path.join(root, f)
            copies[f[:-4]].append((p, os.path.getsize(p)))
done = set(os.listdir(DONE))
rows, cnt = [], collections.Counter()
for s in sorted(copies):
    c = sorted(copies[s], key=lambda x: (x[0].count('/'), x[0]))
    sizes = {z for _, z in c}
    if s in done and s not in RERUN:
        action, note = 'skip', 'done_downloaded_qc_ok'
    elif s in RERUN:
        action, note = 'recompute', 'downloaded_but_' + RERUN[s].replace(' ', '_')
    else:
        action, note = 'recompute', 'not_done'
    if len(sizes) > 1:
        note += ';COPY_SIZE_MISMATCH'
    cnt[(action, note.split(';')[0])] += 1
    rows.append({'session': s, 'site': PAT.match(s + '.zip').group(1), 'action': action,
                 'note': note, 'zip': c[0][0], 'zip_bytes': c[0][1], 'n_copies': len(c),
                 'transfer_status': 'pending' if action == 'recompute' else ''})
with open(os.path.join(OUT, 'harp_index_all.tsv'), 'w', newline='') as f:
    w = csv.DictWriter(f, rows[0].keys(), delimiter='\t'); w.writeheader(); w.writerows(rows)
todo = [r for r in rows if r['action'] == 'recompute']
with open(os.path.join(OUT, 'harp_recompute.tsv'), 'w', newline='') as f:
    w = csv.DictWriter(f, rows[0].keys(), delimiter='\t'); w.writeheader(); w.writerows(todo)
missing = sorted(done - set(copies) - {d for d in done if '_HARP_' not in d})
summary = {'harp_zip_sessions': len(rows), 'recompute': len(todo),
           'recompute_bytes': sum(r['zip_bytes'] for r in todo),
           'by_action_note': {f'{a}/{n}': v for (a, n), v in sorted(cnt.items())},
           'recompute_by_site': dict(collections.Counter(r['site'] for r in todo).most_common()),
           'downloaded_without_raw_zip': missing,
           'copy_size_mismatch': [r['session'] for r in rows if 'MISMATCH' in r['note']]}
json.dump(summary, open(os.path.join(OUT, 'summary.json'), 'w'), indent=1)
print(json.dumps(summary, indent=1))

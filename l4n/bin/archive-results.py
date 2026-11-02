#!/usr/bin/env python3
"""Copy/checksum completed HOKUSAI outputs to wu; never delete remote results.

RawData symlinks are materialized separately so the archive has usable inputs.
Other scientific output symlinks retain their original representation.
"""
import base64
import datetime
import json
import pathlib
import re
import shutil
import subprocess
import time

DEST = pathlib.Path('/mnt/data/HCP/amed_hcp_v6_l4n')
STATE = DEST / '_archive_state'
TARGETS = {'HOKUSAI': '/home/ziqing/AMED_HCP', 'HOKUSAIwang': '/home/haruka74/AMED_HCP'}
STATE.mkdir(parents=True, exist_ok=True)
SSH = ['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=30']
scan_code = r'''import pathlib,json
base=pathlib.Path(BASE);q=base/'l4n_logs/node_pipeline/state';rows=[]
if q.exists():
 for d in q.iterdir():
  if d.is_dir() and (d/'DONE').is_file() and (base/'l4n_study'/d.name).is_dir():rows.append(d.name)
print('@@JSON'+json.dumps(rows))
'''


def remote_scan(host, base):
    encoded = base64.b64encode(scan_code.replace('BASE', repr(base)).encode()).decode()
    text = subprocess.check_output(SSH + [host, "python3 -c \"import base64;exec(base64.b64decode('%s'))\"" % encoded], universal_newlines=True, timeout=90)
    return json.loads(next(line[6:] for line in text.splitlines() if line.startswith('@@JSON')))


def sync(host, source, target, follow=False, verify=False, excludes=()):
    args = ['rsync', '-a' + ('L' if follow else '') + ('nc' if verify else ''), '--partial',
            '-e', ' '.join(SSH)]
    args += ['--exclude=' + item for item in excludes]
    if verify:
        args += ['--out-format=%i %n']
    return subprocess.check_output(args + [host + ':' + source + '/', str(target) + '/'], universal_newlines=True, timeout=21600)


while not (STATE / 'STOP').exists():
    errors, copied = [], []
    for host, base in TARGETS.items():
        try:
            for session in remote_scan(host, base):
                if not re.fullmatch(r'[A-Za-z0-9._-]+', session):
                    raise ValueError('Unsafe session name')
                marker = STATE / (host + '_' + session + '.verified.json')
                if marker.exists():
                    continue
                if shutil.disk_usage(str(DEST)).free < 500 * 1024 ** 3:
                    raise RuntimeError('Archive filesystem reserve below500GiB; remote results retained')
                target = DEST / host / session; target.mkdir(parents=True, exist_ok=True)
                source = base + '/l4n_study/' + session
                sync(host, source, target, excludes=('RawData/',))
                (target / 'RawData').mkdir(exist_ok=True)
                sync(host, source + '/RawData', target / 'RawData', follow=True)
                changed = sync(host, source, target, verify=True, excludes=('RawData/', '_workflow/'))
                changed += sync(host, source + '/RawData', target / 'RawData', follow=True, verify=True)
                if any(line.strip() and not line.startswith('.d..t') for line in changed.splitlines()):
                    raise RuntimeError('Checksum comparison found differences: ' + host + '/' + session)
                workflow = target / '_workflow'; workflow.mkdir(exist_ok=True)
                sync(host, base + '/l4n_logs/node_pipeline/state/' + session, workflow)
                marker.write_text(json.dumps({'host': host, 'session': session, 'archived_at': datetime.datetime.now().isoformat(),
                                              'remote_results_deleted': False}, indent=2))
                copied.append(host + '/' + session)
        except Exception as error:
            errors.append(host + ': ' + str(error))
    status = {'checked_at': datetime.datetime.now().isoformat(), 'copied_this_cycle': copied, 'errors': errors,
              'policy': 'copy and checksum only; remote results and original ZIPs are retained'}
    (STATE / 'latest.json').write_text(json.dumps(status, indent=2))
    print(json.dumps(status), flush=True)
    time.sleep(300)

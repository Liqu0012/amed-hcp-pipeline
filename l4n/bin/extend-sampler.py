#!/usr/bin/env python3
"""Extend measurement-only session roots for the new workflow, keeping a backup."""
import datetime
import pathlib
import sys

p = pathlib.Path(sys.argv[1])
s = p.read_text()
if '# L4N_BMB_MEASUREMENT_ROOTS' not in s:
    old = "('convert','structural','preeddy','eddy','posteddy','fmri','icafix','msmall','dedrift','qc')"
    new = "('convert','structural','preeddy','eddy','posteddy','diffusion','fmri','icafix','msmall','dedrift','stats','qc')"
    if old not in s:
        raise SystemExit('Unrecognized sampler root logic; no changes made')
    backup = p.with_name(p.name + '.before_l4n_' + datetime.datetime.now().strftime('%Y%m%dT%H%M%S'))
    backup.write_text(s)
    s = s.replace(old, new)
    s = s.replace("FALLBACK={'convert':", "FALLBACK={'diffusion':'Eddy_unconfirmed','stats':'fMRIStats','convert':")
    # Completed command-level PSS only. Group PSS already has its own complete-
    # process check in the existing exporter.
    s = s.replace("pss_bytes=0,cpu_ticks=0))", "pss_bytes=0,pss_missing_processes=0,cpu_ticks=0))")
    s = s.replace("command['processes']+=1;", "command['pss_missing_processes']+=int(item['pss'] is None)\n   command['processes']+=1;")
    s = s.replace("   g.update(schema_version=2", "   for command in g['commands'].values():\n    if command.get('pss_missing_processes',0):command['pss_bytes']=None\n   g.update(schema_version=2")
    s += '\n# L4N_BMB_MEASUREMENT_ROOTS\n'
    compile(s, str(p), 'exec')
    temporary = p.with_suffix('.l4n.tmp'); temporary.write_text(s); temporary.replace(p)
if '# L4N_JOB_SCOPED_ROOTS' not in s:
    old = "     stage,sid=cmd[i+2:i+4]"
    if old not in s:
        raise SystemExit('Unrecognized sampler root assignment; cannot scope job')
    new = "     current_job=os.environ.get('SLURM_JOB_ID')\n     if current_job and ('SLURM_JOB_ID='+current_job).encode() not in (path/'environ').read_bytes().split(b'\\0'):continue\n" + old
    s = s.replace(old, new) + '\n# L4N_JOB_SCOPED_ROOTS\n'
    compile(s, str(p), 'exec')
    temporary = p.with_suffix('.l4n.tmp'); temporary.write_text(s); temporary.replace(p)
print(p)

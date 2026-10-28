#!/usr/bin/env python3
"""Per-session QC gate: a session counts as usable only after this passes.

A completion marker only proves every step exited 0 (DB lesson: averaged
structurals, flag=1 diffusion, task runs in REST all had clean markers).
This checks the outputs themselves:

  inputs      selection has no problems; exactly one T1w and one T2w input
  structural  recon-all finished cleanly; aparc+aseg and 32k surfaces present;
              Euler number (lh+rh, orig.nofix) and BrainSegVol/eTIV in range
  diffusion   PostEddy flag=2: bvals identical to eddy's Pos_Neg.bvals,
              volume counts agree, bvecs unit norm and equal to eddy's rotated
              bvecs, no flag=1 artefacts (same checks as wu dwi_flag2_guard.py)
  fMRI        every REST run has a dense timeseries, >= 100 volumes; MSMAll
              cleaned dense timeseries present; mean relative RMS motion

FAIL = broken or wrong output (must be rerun). REVIEW = output complete but an
image-quality flag needs a visual check. Writes <session>/qc/hcp_qc.json and
.hcp_qc_pass.ok only on PASS. Exit 0 PASS, 1 REVIEW, 2 FAIL.
Usage: hcp_qc_session.py STUDY SESSION      (Python 3.6+, stdlib only)
"""
import glob
import gzip
import json
import math
import os
import re
import struct
import sys
from datetime import datetime

EULER_MIN = int(os.environ.get('HCP_QC_EULER_MIN', '-200'))        # lh+rh
BRAIN_ETIV_MAX = float(os.environ.get('HCP_QC_BRAIN_ETIV_MAX', '0.94'))
ETIV_RANGE = (8.0e5, 2.4e6)                                          # mm^3
MIN_BOLD_VOLUMES = 100
MOTION_REVIEW_MM = float(os.environ.get('HCP_QC_RELRMS_MAX', '0.5'))
FLAG1_ARTEFACTS = ('avg_data.idxs', 'bvals_noRot')


def nifti_vols(path):
    with gzip.open(path, 'rb') as f:
        h = f.read(348)
    e = '<' if struct.unpack_from('<i', h)[0] == 348 else '>'
    d = struct.unpack_from(e + '8h', h, 40)
    return int(d[4] if d[0] >= 4 else 1)


def cifti_rows(path):
    """Number of time points of a .dtseries.nii (NIfTI-2, dim[5])."""
    with open(path, 'rb') as f:
        h = f.read(540)
    e = '<' if struct.unpack_from('<i', h)[0] == 540 else '>'
    d = struct.unpack_from(e + '8q', h, 16)
    return int(d[5])


def numbers(path):
    with open(path) as f:
        return [float(x) for x in f.read().split()]


def size_ok(path, minimum):
    return os.path.isfile(path) and os.path.getsize(path) >= minimum


def check(study, session):
    root = os.path.join(study, session)
    fail, review, info = [], [], {}

    # ---------------- inputs ----------------
    sel_path = os.path.join(root, 'unprocessed', '3T', 'selection', 'input_selection.json')
    if os.path.isfile(sel_path):
        with open(sel_path) as f:
            sel = json.load(f)
        if sel.get('problems'):
            fail.append('input selection problems: %s' % '; '.join(sel['problems']))
        if not sel.get('t1') or not sel.get('t2'):
            fail.append('T1w/T2w input missing in selection')
        for w in sel.get('warnings', []):
            review.append('input warning: %s' % w)
    else:
        info['input_selection'] = 'not available (not produced by hcp_select_inputs.py)'

    # ---------------- structural ----------------
    fs = os.path.join(root, 'T1w', session)
    log = os.path.join(fs, 'scripts', 'recon-all.log')
    if not os.path.isfile(log):
        fail.append('missing recon-all.log')
    else:
        with open(log, errors='replace') as f:
            text = f.read()
        if 'finished without error' not in text[-3000:]:
            fail.append('recon-all did not finish cleanly')
        m = re.findall(r'orig\.nofix lheno\s*=\s*(-?\d+),\s*rheno\s*=\s*(-?\d+)', text)
        if m:
            lh, rh = int(m[-1][0]), int(m[-1][1])
            info['euler_lh_rh'] = [lh, rh]
            if lh + rh < EULER_MIN:
                review.append('Euler number lh+rh=%d < %d (surface defects; check visually)' % (lh + rh, EULER_MIN))
        else:
            review.append('Euler number not found in recon-all.log')
    if not size_ok(os.path.join(fs, 'mri', 'aparc+aseg.mgz'), 200 * 1024):
        fail.append('aparc+aseg.mgz missing or truncated')
    for hemi in ('L', 'R'):
        surf = os.path.join(root, 'MNINonLinear', 'fsaverage_LR32k',
                            '%s.%s.midthickness.32k_fs_LR.surf.gii' % (session, hemi))
        if not size_ok(surf, 50 * 1024):
            fail.append('%s midthickness 32k surface missing or truncated' % hemi)
    aseg = os.path.join(fs, 'stats', 'aseg.stats')
    if os.path.isfile(aseg):
        with open(aseg) as f:
            text = f.read()
        etiv = re.search(r'EstimatedTotalIntraCranialVol,[^,]*,[^,]*,\s*([\d.]+)', text)
        brain = re.search(r'BrainSegVol,[^,]*,\s*([\d.]+)', text)
        if etiv and brain:
            etiv, brain = float(etiv.group(1)), float(brain.group(1))
            info['eTIV'], info['BrainSegVol'] = etiv, brain
            if not ETIV_RANGE[0] <= etiv <= ETIV_RANGE[1]:
                review.append('eTIV %.0f outside %.0f-%.0f' % ((etiv,) + ETIV_RANGE))
            if brain / etiv > BRAIN_ETIV_MAX:
                review.append('BrainSegVol/eTIV %.3f > %.2f (skull strip / eTIV check)' % (brain / etiv, BRAIN_ETIV_MAX))
    else:
        fail.append('aseg.stats missing')

    # ---------------- diffusion ----------------
    eddy_bvals = os.path.join(root, 'Diffusion', 'eddy', 'Pos_Neg.bvals')
    if os.path.isfile(eddy_bvals):
        try:
            vals = numbers(eddy_bvals)
            n = len(vals)
            info['dwi_volumes'] = n
            for rel in ('Diffusion/data', 'T1w/Diffusion'):
                d = os.path.join(root, rel)
                if numbers(os.path.join(d, 'bvals')) != vals:
                    raise ValueError('%s bvals differ from eddy (flag=1 averaging?)' % rel)
                if nifti_vols(os.path.join(d, 'data.nii.gz')) != n:
                    raise ValueError('%s volume count differs from eddy' % rel)
                with open(os.path.join(d, 'bvecs')) as f:
                    rows = [[float(x) for x in line.split()] for line in f if line.strip()]
                if len(rows) != 3 or any(len(r) != n for r in rows):
                    raise ValueError('%s bvecs shape mismatch' % rel)
                for i in range(n):
                    norm = math.sqrt(sum(r[i] ** 2 for r in rows))
                    if not math.isfinite(norm) or (norm > .1 and abs(norm - 1) > .02):
                        raise ValueError('%s bvec %d not unit length' % (rel, i))
            rotated = numbers(os.path.join(root, 'Diffusion', 'eddy', 'eddy_unwarped_images.eddy_rotated_bvecs'))
            post = numbers(os.path.join(root, 'Diffusion', 'data', 'bvecs'))
            if len(rotated) != len(post) or any(abs(a - b) > 1e-5 for a, b in zip(rotated, post)):
                raise ValueError('PostEddy bvecs differ from eddy rotated bvecs')
            for name in FLAG1_ARTEFACTS:
                if glob.glob(os.path.join(root, 'Diffusion', '**', name), recursive=True):
                    raise ValueError('flag=1 artefact %s present' % name)
        except (OSError, ValueError) as exc:
            fail.append('diffusion: %s' % exc)
    elif os.path.isdir(os.path.join(root, 'Diffusion')):
        fail.append('diffusion directory present but eddy output missing')

    # ---------------- fMRI ----------------
    results = os.path.join(root, 'MNINonLinear', 'Results')
    params = os.path.join(root, 'unprocessed', '3T', 'params.sh')
    runs = []
    if os.path.isfile(params):
        with open(params) as f:
            m = re.search(r'^FMRI_RUNS="([^"]*)"', f.read(), re.M)
        runs = m.group(1).split() if m else []
    elif os.path.isdir(results):
        runs = sorted(d for d in os.listdir(results)
                      if re.match(r'^(rfMRI_)?REST\d+_(AP|PA)$', d))
    info['fmri_runs'] = runs
    motion = {}
    for run in runs:
        d = os.path.join(results, run)
        dts = sorted(glob.glob(os.path.join(d, run + '_Atlas*.dtseries.nii')))
        if not dts:
            fail.append('fMRI %s: no dense timeseries' % run)
            continue
        try:
            t = cifti_rows(dts[0])
            if t < MIN_BOLD_VOLUMES:
                fail.append('fMRI %s: only %d time points' % (run, t))
        except OSError as exc:
            fail.append('fMRI %s: unreadable %s (%s)' % (run, os.path.basename(dts[0]), exc))
        rms = os.path.join(d, 'Movement_RelativeRMS_mean.txt')
        if os.path.isfile(rms):
            motion[run] = numbers(rms)[0]
            if motion[run] > MOTION_REVIEW_MM:
                review.append('fMRI %s mean relative RMS %.2f mm > %.2f' % (run, motion[run], MOTION_REVIEW_MM))
    info['mean_relative_rms_mm'] = motion
    if runs:
        clean = glob.glob(os.path.join(results, '*', '*MSMAll*hp0_clean*.dtseries.nii'))
        if not clean:
            fail.append('no MSMAll ICA-FIX cleaned dense timeseries')

    status = 'FAIL' if fail else 'REVIEW' if review else 'PASS'
    return {'session': session, 'status': status, 'fail': fail, 'review': review,
            'info': info, 'checked': datetime.now().isoformat(timespec='seconds')}


def main():
    if len(sys.argv) != 3:
        sys.exit('usage: hcp_qc_session.py STUDY SESSION')
    study, session = sys.argv[1], sys.argv[2]
    if not re.match(r'^[A-Za-z0-9._-]+$', session):
        sys.exit('unsafe session id')
    res = check(study, session)
    root = os.path.join(study, session)
    if os.environ.get('HCP_QC_READONLY') == '1':      # report only, write nothing
        print(json.dumps(res))
        return {'PASS': 0, 'REVIEW': 1, 'FAIL': 2}[res['status']]
    os.makedirs(os.path.join(root, 'qc'), exist_ok=True)
    out = os.path.join(root, 'qc', 'hcp_qc.json')
    with open(out + '.tmp', 'w') as f:
        json.dump(res, f, indent=1)
    os.replace(out + '.tmp', out)
    marker = os.path.join(root, '.hcp_qc_pass.ok')
    if res['status'] == 'PASS':
        with open(marker, 'w') as f:
            f.write('session=%s\nchecked=%s\n' % (session, res['checked']))
    elif os.path.exists(marker):
        os.remove(marker)
    print('%s %s' % (session, res['status']))
    for x in res['fail']:
        print('  FAIL   %s' % x)
    for x in res['review']:
        print('  REVIEW %s' % x)
    return {'PASS': 0, 'REVIEW': 1, 'FAIL': 2}[res['status']]


if __name__ == '__main__':
    sys.exit(main())

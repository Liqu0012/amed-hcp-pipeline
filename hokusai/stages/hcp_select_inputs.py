#!/usr/bin/env python3
"""Select HCP inputs from a dcm2niix output directory using DICOM metadata.

Same rules as the corrected DB build_subject_manifest.py (2026-10), which
produced the 1083 sessions already accepted:
  * Structural: one image per contrast, never averaged. DERIVED, MIP and
    non-3D / anisotropic reformats are dropped; prefer ND, then NORM, then the
    lowest series number. DIS-only sessions are kept with a warning.
    DwellTime from JSON, or derived for Siemens from PixelBandwidth and
    BaseResolution; missing -> problem (PreFreeSurfer readout correction).
  * Phase encoding comes from PhaseEncodingDirection (j- = AP, j = PA); a name
    that contradicts the metadata blocks the session.
  * rfMRI: only REST runs (task fMRI excluded), >= 100 volumes, DERIVED dropped,
    SBRef matched by description and preceding series, each run gets the
    nearest spin-echo AP/PA pair. No SE pair -> BOLD runs excluded (warning).
  * Structural SE pair: the pair nearest the selected T1 (as on DB).
  * dMRI: non-SBRef series with bval/bvec, >= 20 volumes; AP = neg, PA = pos.
  * Missing PE / EffectiveEchoSpacing for a selected series, or no T1 -> problem.
Writes JSON to OUT; exit 3 when problems exist (the session must not run).
Python 3.6 compatible (HOKUSAI system python).
"""
import gzip
import json
import os
import re
import struct
import sys

MIN_BOLD_VOLUMES = 100
MIN_DWI_VOLUMES = 20
T1_TERMS = ('t1_mpr', 't1w', 'bravo', 'fspgr')
T2_TERMS = ('t2_spc', 't2w', 'cube', 'vista')
SKIP_TERMS = ('scout', 'localizer', 'setup', 'flair')
FMAP_TERMS = ('sefield', 'spinechofieldmap')
TASK_TERMS = ('posner', 'emotion', 'carit', 'task', 'nback', 'gambling')
PE_LABEL = {'j-': 'AP', 'j': 'PA'}
SBREF_SUFFIX = re.compile(r'(_sbref|_sb)$')


def nifti_info(path):
    with gzip.open(path, 'rb') as f:
        h = f.read(348)
    e = '<' if struct.unpack_from('<i', h)[0] == 348 else '>'
    dims = struct.unpack_from(e + '8h', h, 40)
    pix = struct.unpack_from(e + '8f', h, 76)
    return list(dims[1:dims[0] + 1]), [abs(x) for x in pix[1:4]]


def dwell_time(meta):
    """DwellTime in seconds, as on DB (Siemens fallback from PixelBandwidth)."""
    if meta.get('DwellTime') is not None:
        return float(meta['DwellTime']), 'json'
    bw, base = meta.get('PixelBandwidth'), meta.get('BaseResolution')
    if str(meta.get('Manufacturer', '')).lower().startswith('siemens') and bw and base:
        return round(1e9 / (float(bw) * float(base) * 2), -2) / 1e9, 'derived_pixelbandwidth'
    return None, 'missing'


def load(nifti_dir):
    out = []
    for fn in sorted(os.listdir(nifti_dir)):
        if not fn.endswith('.json'):
            continue
        base = os.path.join(nifti_dir, fn[:-5])
        if not os.path.exists(base + '.nii.gz'):
            continue
        with open(base + '.json') as f:
            d = json.load(f)
        try:
            shape, pix = nifti_info(base + '.nii.gz')
        except Exception:
            shape, pix = [], []
        desc = d.get('SeriesDescription') or d.get('ProtocolName') or os.path.basename(base)
        nb = None
        if os.path.exists(base + '.bval'):
            with open(base + '.bval') as f:
                nb = len(f.read().split())
        dwell, dwell_src = dwell_time(d)
        out.append({
            'base': base, 'file': os.path.basename(base), 'series': int(d.get('SeriesNumber') or 0),
            'desc': desc, 'lower': desc.lower(),
            'tokens': set(d.get('ImageType') or []) | set(d.get('ImageTypeText') or []),
            'pe': d.get('PhaseEncodingDirection'), 'ees': d.get('EffectiveEchoSpacing'),
            'dwell': dwell, 'dwell_src': dwell_src,
            'shape': shape, 'pix': pix, 'vols': shape[3] if len(shape) >= 4 else 1,
            'nbval': nb, 'has_bvec': os.path.exists(base + '.bvec')})
    return out


def name_dir(desc):
    found = set(re.split(r'[^A-Za-z0-9]+', desc.upper())) & {'AP', 'PA'}
    return found.pop() if len(found) == 1 else None


def has(lower, terms):
    return any(t in lower for t in terms)


def describe(s):
    return '%s(series %d)' % (s['desc'], s['series'])


def main(nifti_dir, out_path):
    series = load(nifti_dir)
    problems, warnings, excluded = [], [], []

    def exclude(kind, s, why):
        excluded.append({'kind': kind, 'series': s['series'], 'desc': s['desc'],
                         'file': s['file'], 'reason': why})

    def pe_of(kind, s):
        lab = PE_LABEL.get(s['pe'])
        if lab is None:
            problems.append('%s %s: PhaseEncodingDirection missing or not AP/PA (%r)'
                            % (kind, describe(s), s['pe']))
            return None
        nd = name_dir(s['desc'])
        if nd and nd != lab:
            problems.append('%s %s: name says %s but PhaseEncodingDirection=%s (%s)'
                            % (kind, describe(s), nd, s['pe'], lab))
            return None
        return lab

    # ---------------- structural ----------------
    def structural(kind, terms, not_terms):
        cands = []
        for s in series:
            if not has(s['lower'], terms) or has(s['lower'], SKIP_TERMS + not_terms):
                continue
            t = s['tokens']
            if 'DERIVED' in t:
                exclude(kind, s, 'DERIVED reconstruction')
                continue
            if 'MIP' in t or 'PROJECTION IMAGE' in t:
                exclude(kind, s, 'MIP projection')
                continue
            sh, px = s['shape'], s['pix']
            if (len(sh) != 3 or min(sh) < 96 or not px
                    or max(px) / max(min(px), 1e-6) > 1.5 or max(px) > 1.6):
                exclude(kind, s, 'not a 3D isotropic acquisition %s %s'
                        % (sh, ['%.2g' % x for x in px]))
                continue
            cands.append(s)
        if not cands:
            return None
        cands.sort(key=lambda s: (0 if 'ND' in s['tokens'] else 1 if 'NORM' in s['tokens'] else 2,
                                  s['series']))
        chosen = cands[0]
        for s in cands[1:]:
            exclude(kind, s, 'only one image per contrast is used (kept %s)' % describe(chosen))
        if 'ND' not in chosen['tokens'] and chosen['tokens'] & {'DIS2D', 'DIS3D'}:
            warnings.append('%s %s is scanner distortion-corrected (no ND reconstruction available)'
                            % (kind, describe(chosen)))
        if chosen['dwell'] is None:
            problems.append('%s %s: DwellTime missing (needed for readout distortion correction)'
                            % (kind, describe(chosen)))
        return chosen

    t1 = structural('T1w', T1_TERMS, ())
    t2 = structural('T2w', T2_TERMS, T1_TERMS)
    if t1 is None:
        problems.append('no usable T1w image')
    if t2 is None:
        problems.append('no usable T2w image (HCPStyleData requires T2w)')

    # ---------------- spin-echo field maps ----------------
    se = {'AP': [], 'PA': []}
    for s in series:
        if not has(s['lower'], FMAP_TERMS):
            continue
        if has(s['lower'], TASK_TERMS):
            exclude('fmap', s, 'task-specific field map')
            continue
        if 'DERIVED' in s['tokens'] or s['file'].endswith('_ph'):
            exclude('fmap', s, 'derived/phase image')
            continue
        lab = pe_of('fmap', s)
        if lab:
            se[lab].append(s)
    pairs, used = [], set()
    for ap in sorted(se['AP'], key=lambda s: s['series']):
        free = [p for p in se['PA'] if p['series'] not in used]
        if not free:
            break
        pa = min(free, key=lambda p: abs(p['series'] - ap['series']))
        used.add(pa['series'])
        pairs.append((ap, pa))
    if len(se['AP']) != len(se['PA']):
        warnings.append('spin-echo field maps without an opposite-direction partner (AP %d, PA %d)'
                        % (len(se['AP']), len(se['PA'])))
    for ap, pa in pairs:
        if not ap['ees'] or not pa['ees']:
            problems.append('spin-echo pair %s/%s: EffectiveEchoSpacing missing' % (describe(ap), describe(pa)))

    def nearest_pair(series_no):
        return min(pairs, key=lambda p: abs((p[0]['series'] + p[1]['series']) / 2.0 - series_no))

    struct_se = None
    if t1 is not None and pairs:
        ap, pa = nearest_pair(t1['series'])
        struct_se = {'neg': ap['base'], 'pos': pa['base'], 'ees': ap['ees'],
                     'source': '%s + %s' % (describe(ap), describe(pa))}
    elif t1 is not None:
        warnings.append('no spin-echo pair: PreFreeSurfer runs without readout distortion correction')

    # ---------------- rfMRI ----------------
    bold = [s for s in series if has(s['lower'], ('bold', 'rfmri', 'fmri', 'rest'))
            and not has(s['lower'], FMAP_TERMS + SKIP_TERMS)]
    is_sbref = lambda s: 'sbref' in s['lower'] or s['lower'].endswith('_sb')
    sbrefs = [s for s in bold if is_sbref(s)]
    runs = []
    for s in sorted((b for b in bold if not is_sbref(b)), key=lambda b: b['series']):
        if 'rest' not in s['lower'] or has(s['lower'], TASK_TERMS):
            exclude('bold', s, 'task fMRI, not resting state')
            continue
        if 'DERIVED' in s['tokens']:
            exclude('bold', s, 'DERIVED series')
            continue
        if s['vols'] < MIN_BOLD_VOLUMES:
            exclude('bold', s, 'aborted run (%d volumes < %d)' % (s['vols'], MIN_BOLD_VOLUMES))
            continue
        lab = pe_of('bold', s)
        if lab is None:
            continue
        stem = SBREF_SUFFIX.sub('', s['lower'])
        cand = [r for r in sbrefs if SBREF_SUFFIX.sub('', r['lower']) == stem and r['series'] < s['series']]
        if not cand:
            exclude('bold', s, 'no matching SBRef')
            continue
        sb = max(cand, key=lambda r: r['series'])
        if PE_LABEL.get(sb['pe']) != lab:
            problems.append('bold %s: SBRef %s has a different phase-encoding direction'
                            % (describe(s), describe(sb)))
            continue
        runs.append({'s': s, 'sbref': sb, 'dir': lab})
    used_sb = set(r['sbref']['series'] for r in runs)
    for r in sbrefs:
        if r['series'] not in used_sb:
            exclude('bold', r, 'SBRef not matched to any kept run')
    if runs and not pairs:
        for r in runs:
            exclude('bold', r['s'], 'no spin-echo AP/PA pair for distortion correction')
        warnings.append('BOLD present but no SE field-map pair; rfMRI excluded')
        runs = []
    fmri_runs, count = [], {'AP': 0, 'PA': 0}
    for r in runs:
        count[r['dir']] += 1
        ap, pa = nearest_pair(r['s']['series'])
        fmri_runs.append({'name': 'rfMRI_REST%d_%s' % (count[r['dir']], r['dir']),
                          'tcs': r['s']['base'], 'sbref': r['sbref']['base'],
                          'se_ap': ap['base'], 'se_pa': pa['base'], 'ees': r['s']['ees'],
                          'source': describe(r['s'])})
    fmri_ees = None
    if fmri_runs:
        vals = set(round(float(x['ees']), 9) for x in fmri_runs if x['ees'])
        if any(not x['ees'] for x in fmri_runs):
            problems.append('rfMRI EffectiveEchoSpacing missing')
        elif len(vals) > 1:
            problems.append('rfMRI runs have different EffectiveEchoSpacing %s' % sorted(vals))
        else:
            fmri_ees = vals.pop()

    # ---------------- dMRI ----------------
    dwi = {'AP': [], 'PA': []}
    for s in series:
        if not has(s['lower'], ('dwi', 'dmri', 'diffusion')) or 'sbref' in s['lower']:
            continue
        if s['nbval'] is None:
            if 'DERIVED' in s['tokens'] or s['vols'] > 1:
                exclude('dwi', s, 'no bval/bvec (derived map)')
            continue
        if 'DERIVED' in s['tokens']:
            exclude('dwi', s, 'DERIVED series')
            continue
        if not s['has_bvec'] or s['nbval'] != s['vols']:
            problems.append('dwi %s: bval/bvec missing or count %s != volumes %d'
                            % (describe(s), s['nbval'], s['vols']))
            continue
        if s['vols'] < MIN_DWI_VOLUMES:
            exclude('dwi', s, 'truncated run (%d volumes < %d)' % (s['vols'], MIN_DWI_VOLUMES))
            continue
        lab = pe_of('dwi', s)
        if lab:
            dwi[lab].append(s)
    dmri = []
    if dwi['AP'] or dwi['PA']:
        if len(dwi['AP']) != len(dwi['PA']):
            warnings.append('dMRI AP/PA series counts differ (AP %d, PA %d); diffusion skipped'
                            % (len(dwi['AP']), len(dwi['PA'])))
            for s in dwi['AP'] + dwi['PA']:
                exclude('dwi', s, 'unpaired AP/PA diffusion set')
        else:
            for k, (ap, pa) in enumerate(zip(sorted(dwi['AP'], key=lambda s: s['series']),
                                             sorted(dwi['PA'], key=lambda s: s['series'])), 1):
                dmri.append({'set': 'set%d' % k, 'ap': ap['base'], 'pa': pa['base'],
                             'ees': ap['ees'] if ap['ees'] == pa['ees'] else None,
                             'source': '%s + %s' % (describe(ap), describe(pa))})
    dmri_ees = None
    if dmri:
        vals = set(round(float(x['ees']), 9) for x in dmri if x['ees'])
        if any(not x['ees'] for x in dmri):
            problems.append('dMRI EffectiveEchoSpacing missing or AP/PA differ')
        elif len(vals) > 1:
            problems.append('dMRI sets have different EffectiveEchoSpacing %s' % sorted(vals))
        else:
            dmri_ees = vals.pop()

    result = {
        't1': t1 and t1['base'], 't1_source': t1 and describe(t1),
        't1_dwell': t1 and t1['dwell'], 't1_dwell_source': t1 and t1['dwell_src'],
        't2': t2 and t2['base'], 't2_source': t2 and describe(t2),
        't2_dwell': t2 and t2['dwell'], 't2_dwell_source': t2 and t2['dwell_src'],
        'struct_se': struct_se,
        'fmri_runs': fmri_runs, 'fmri_echospacing_sec': fmri_ees,
        'dmri_sets': dmri, 'dmri_echospacing_sec': dmri_ees,
        'excluded': excluded, 'warnings': warnings, 'problems': problems}
    tmp = out_path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(result, f, indent=1)
    os.replace(tmp, out_path)

    print('T1: %s dwell=%s (%s)' % (result['t1_source'], result['t1_dwell'], result['t1_dwell_source']))
    print('T2: %s dwell=%s (%s)' % (result['t2_source'], result['t2_dwell'], result['t2_dwell_source']))
    print('Structural SE: %s' % (struct_se and struct_se['source']))
    for r in fmri_runs:
        print('fMRI %s <- %s (SE %s / %s)' % (r['name'], r['source'],
                                             os.path.basename(r['se_ap']), os.path.basename(r['se_pa'])))
    for d in dmri:
        print('dMRI %s <- %s' % (d['set'], d['source']))
    for e in excluded:
        print('EXCLUDED %s %s: %s' % (e['kind'], e['file'], e['reason']))
    for w in warnings:
        print('WARNING %s' % w)
    for p in problems:
        print('PROBLEM %s' % p)
    return 3 if problems else 0


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('usage: hcp_select_inputs.py NIFTI_DIR OUT_JSON')
    sys.exit(main(sys.argv[1], sys.argv[2]))

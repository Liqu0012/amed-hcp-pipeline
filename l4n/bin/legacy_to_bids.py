#!/usr/bin/env python3
"""Adapt preserved, selected NIfTI inputs; never link writable JSON to old results.

Only missing structural DwellTime is filled from the recorded selector result.
Official bids2hcp.sh remains responsible for HCP input selection and validation.
"""
import argparse
import hashlib
import json
import pathlib
import re


def adapt(source, destination, session):
    source, destination = pathlib.Path(source), pathlib.Path(destination)
    selection = json.loads((source / 'selection/input_selection.json').read_text())
    label = hashlib.sha256(session.encode()).hexdigest()[:16]
    sub, ses = 'sub-BMB' + label, 'ses-HARP' + label
    root = destination / sub / ses
    changes, mappings = [], []

    def put(old, folder, suffix, dwell=None):
        old = source / old
        image, sidecar = pathlib.Path(str(old) + '.nii.gz'), pathlib.Path(str(old) + '.json')
        if not image.is_file() or not sidecar.is_file():
            raise ValueError('Missing image/JSON: ' + str(old))
        metadata = json.loads(sidecar.read_text())
        if dwell is not None and metadata.get('DwellTime') is None:
            if not isinstance(dwell, (int, float)) or dwell <= 0:
                raise ValueError('No verified structural DwellTime: ' + str(old))
            metadata['DwellTime'] = dwell
            changes.append({'source': str(sidecar), 'field': 'DwellTime', 'value': dwell,
                            'basis': 'preserved selection/input_selection.json'})
        target = root / folder / (sub + '_' + ses + '_' + suffix)
        target.parent.mkdir(parents=True, exist_ok=True)
        link = pathlib.Path(str(target) + '.nii.gz')
        if not link.exists():
            link.symlink_to(image.resolve())
        pathlib.Path(str(target) + '.json').write_text(json.dumps(metadata, indent=2))
        for ext in ('.bval', '.bvec'):
            original = pathlib.Path(str(old) + ext)
            link = pathlib.Path(str(target) + ext)
            if original.is_file() and not link.exists():
                link.symlink_to(original.resolve())
        mappings.append({'source': str(image), 'bids': str(target) + '.nii.gz'})

    put('T1w_MPR', 'anat', 'T1w', selection.get('t1_dwell'))
    put('T2w_SPC', 'anat', 'T2w', selection.get('t2_dwell'))
    fields = {}
    for f in sorted(source.glob('SpinEchoFieldMap_*.json')):
        m = json.loads(f.read_text())
        key = (m.get('SeriesNumber'), m.get('PhaseEncodingDirection'))
        if key[0] is None or key[1] not in ('j', 'j-'):
            raise ValueError('Unconfirmed field-map series/PE: ' + str(f))
        if key not in fields:
            fields[key] = f.stem
    if not fields:
        raise ValueError('No SE field map: official BMB structural processing requires it')
    for (series, pe), stem in fields.items():
        put(stem, 'fmap', 'acq-series%s_dir-%s_epi' % (series, 'AP' if pe == 'j-' else 'PA'))
    bolds = sorted(source.glob('rfMRI_REST*_AP.nii.gz')) + sorted(source.glob('rfMRI_REST*_PA.nii.gz'))
    for f in bolds:
        match = re.fullmatch(r'rfMRI_REST(\d+)_(AP|PA)\.nii\.gz', f.name)
        if not match:
            continue
        run, pe = match.groups()
        stem = f.name[:-7]
        prefix = 'task-rest_dir-%s_run-%s_' % (pe, run)
        put(stem, 'func', prefix + 'bold')
        put(stem + '_SBRef', 'func', prefix + 'sbref')
    for i, f in enumerate(sorted(source.glob('dMRI_*_AP.nii.gz')), 1):
        stem = f.name[:-10]
        for pe in ('AP', 'PA'):
            put(stem + '_' + pe, 'dwi', 'acq-dir%s_dir-%s_dwi' % (i, pe))
    provenance = {'original_session': session, 'bids_subject': sub, 'bids_session': ses,
                  'hcp_generated_subject': sub[4:] + '_' + ses[4:], 'mappings': mappings,
                  'metadata_derivations': changes}
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'identity_mapping.json').write_text(json.dumps(provenance, indent=2))
    return provenance


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('source'); p.add_argument('destination'); p.add_argument('session')
    a = p.parse_args()
    result = adapt(a.source, a.destination, a.session)
    print(result['bids_subject'], result['bids_session'], result['hcp_generated_subject'])

#!/usr/bin/env python3
"""Rebase only generated CSV file paths after RawData is moved to its final ID."""
import csv
import json
import pathlib
import sys


def rebase(rawdata, mapping_root):
    rawdata, mapping_root = pathlib.Path(rawdata), pathlib.Path(mapping_root)
    filename = rawdata / 'Seriesinfo.csv'
    with filename.open(newline='') as stream:
        rows = list(csv.reader(stream))
    column = rows[0].index('NIFTI in RawData')
    changes = []
    for row in rows[1:]:
        if len(row) <= column:
            continue
        old = row[column]
        try:
            relative = pathlib.Path(old).relative_to(mapping_root)
        except ValueError:
            continue
        if len(relative.parts) < 3 or relative.parts[1] != 'RawData':
            continue
        new = rawdata.joinpath(*relative.parts[2:])
        if not new.is_file():
            raise ValueError('Cannot rebase missing RawData file: ' + str(new))
        row[column] = str(new)
        changes.append({'old': old, 'new': str(new)})
    if changes:
        temp = filename.with_suffix('.csv.paths.tmp')
        with temp.open('w', newline='') as stream:
            csv.writer(stream, lineterminator='\n').writerows(rows)
        temp.replace(filename)
        (rawdata / 'metadata_path_rebases.json').write_text(json.dumps(changes, indent=2))
    return changes


if __name__ == '__main__':
    print(json.dumps(rebase(sys.argv[1], sys.argv[2])))

#!/usr/bin/env python3
"""Verify every .stage2_complete subject before feeding it to stage 3.

Several subjects were attempted in more than one job, so presence of a file
is not enough -- an interrupted run can leave a stale, short or mismatched
output behind. The checks below tie the corrected 4-D series back to the
gradient table and to eddy's own per-volume parameter file, which is what
would actually break PostEddy / tensor fitting downstream:

  volumes(eddy_unwarped_images) == entries(Pos_Neg.bvals)
                                == columns(eddy_rotated_bvecs)
                                == rows(eddy_parameters)
                                == entries(index.txt)

plus the presence of the outlier report and a sane file size, and that the
corrected series is newer than its input (i.e. not a leftover).
"""
import glob
import gzip
import os
import struct
import sys
from collections import Counter

ROOT = os.environ.get("AMED_ROOT", "/data/juntendodb/amedhcp")
OUT = os.path.join(ROOT, "output")


def nvols(path):
    with gzip.open(path, "rb") as f:
        h = f.read(348)
    d = struct.unpack_from("<8h", h, 40)
    return d[4] if d[0] >= 4 else 1


def ncols(path):
    n = 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                n = max(n, len(line.split()))
    return n


def nrows(path):
    with open(path, encoding="utf-8") as f:
        return sum(1 for line in f if line.strip())


def nwords(path):
    with open(path, encoding="utf-8") as f:
        return len(f.read().split())


problems = Counter()
bad = []
ok = []

for marker in sorted(glob.glob(os.path.join(OUT, "*", ".stage2_complete"))):
    s = os.path.basename(os.path.dirname(marker))
    e = os.path.join(OUT, s, "Diffusion", "eddy")
    img = os.path.join(e, "eddy_unwarped_images.nii.gz")
    why = []
    try:
        if not os.path.exists(img):
            why.append("no eddy_unwarped_images")
        elif os.path.getsize(img) < 50 * 1024 * 1024:
            why.append("eddy image suspiciously small (%.0f MB)" % (os.path.getsize(img) / 1e6))
        else:
            v = nvols(img)
            src = os.path.join(e, "Pos_Neg.nii.gz")
            if os.path.exists(src) and os.path.getmtime(img) < os.path.getmtime(src):
                why.append("eddy image older than its input")
            checks = {
                "Pos_Neg.bvals": nwords(os.path.join(e, "Pos_Neg.bvals")),
                "eddy_rotated_bvecs": ncols(os.path.join(e, "eddy_unwarped_images.eddy_rotated_bvecs")),
                "eddy_parameters": nrows(os.path.join(e, "eddy_unwarped_images.eddy_parameters")),
                "index.txt": nwords(os.path.join(e, "index.txt")),
            }
            for name, n in checks.items():
                if n != v:
                    why.append("%s=%d vs %d volumes" % (name, n, v))
        for f in ("eddy_unwarped_images.eddy_outlier_report",
                  "eddy_unwarped_images.eddy_movement_rms"):
            if not os.path.exists(os.path.join(e, f)):
                why.append("missing " + f)
    except Exception as exc:
        why.append("check failed: %s" % exc)

    if why:
        bad.append((s, why))
        for w in why:
            problems[w.split("=")[0].split("(")[0].strip()] += 1
    else:
        ok.append(s)

print("stage2_complete subjects checked: %d" % (len(ok) + len(bad)))
print("  PASS %d" % len(ok))
print("  FAIL %d" % len(bad))
if problems:
    print("\nproblem types:")
    for k, n in problems.most_common():
        print("  %-44s %d" % (k, n))
if bad:
    print("\nfirst 10 failures:")
    for s, why in bad[:10]:
        print("  %-34s %s" % (s, "; ".join(why)))

dest = os.path.join(ROOT, "manifests", "stage3_ready.txt")
with open(dest, "w", encoding="utf-8") as f:
    for s in ok:
        f.write(s + "\n")
print("\nverified list -> %s (%d subjects)" % (dest, len(ok)))

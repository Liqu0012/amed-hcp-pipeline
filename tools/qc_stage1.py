#!/usr/bin/env python3
"""Verify every .stage1_complete subject actually has usable FreeSurfer /
PostFreeSurfer output, not just an exit code of 0 from each step.

Checks, per subject:
  - T1w/<subj>/scripts/recon-all.log ends with "finished without error"
  - T1w/<subj>/mri/aparc+aseg.mgz exists and is a plausible size (not truncated)
  - MNINonLinear/fsaverage_LR32k/<subj>.{L,R}.midthickness.32k_fs_LR.surf.gii
    exist and are a plausible size -- this is PostFreeSurfer's final surface
    output and what stage 3's fMRISurface step consumes directly.
"""
import glob
import os
from collections import Counter

ROOT = os.environ.get("AMED_ROOT", "/data/juntendodb/amedhcp")
OUT = os.path.join(ROOT, "output")

MIN_ASEG = 200 * 1024
MIN_SURF = 50 * 1024

problems = Counter()
bad = []
ok = []

for marker in sorted(glob.glob(os.path.join(OUT, "*", ".stage1_complete"))):
    s = os.path.basename(os.path.dirname(marker))
    sub_out = os.path.join(OUT, s)
    why = []

    log = os.path.join(sub_out, "T1w", s, "scripts", "recon-all.log")
    if not os.path.exists(log):
        why.append("missing recon-all.log")
    else:
        with open(log, encoding="utf-8", errors="replace") as f:
            tail = f.read()[-2000:]
        if "finished without error" not in tail:
            why.append("recon-all did not report clean finish")

    aseg = os.path.join(sub_out, "T1w", s, "mri", "aparc+aseg.mgz")
    if not os.path.exists(aseg):
        why.append("missing aparc+aseg.mgz")
    elif os.path.getsize(aseg) < MIN_ASEG:
        why.append("aparc+aseg.mgz suspiciously small (%.0f KB)" % (os.path.getsize(aseg) / 1024))

    for hemi in ("L", "R"):
        surf = os.path.join(sub_out, "MNINonLinear", "fsaverage_LR32k",
                             "%s.%s.midthickness.32k_fs_LR.surf.gii" % (s, hemi))
        if not os.path.exists(surf):
            why.append("missing %s.midthickness.32k_fs_LR.surf.gii" % hemi)
        elif os.path.getsize(surf) < MIN_SURF:
            why.append("%s surf.gii suspiciously small" % hemi)

    if why:
        bad.append((s, why))
        for w in why:
            problems[w.split("(")[0].strip()] += 1
    else:
        ok.append(s)

print("stage1_complete subjects checked: %d" % (len(ok) + len(bad)))
print("  PASS %d" % len(ok))
print("  FAIL %d" % len(bad))
if problems:
    print("\nproblem types:")
    for k, n in problems.most_common():
        print("  %-55s %d" % (k, n))
if bad:
    print("\nfirst 20 failures:")
    for s, why in bad[:20]:
        print("  %-40s %s" % (s, "; ".join(why)))

dest = os.path.join(ROOT, "manifests", "stage1_qc_fail.txt")
with open(dest, "w", encoding="utf-8") as f:
    for s, why in bad:
        f.write(s + "\t" + "; ".join(why) + "\n")
print("\nfailure list -> %s (%d subjects)" % (dest, len(bad)))

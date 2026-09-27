#!/usr/bin/env python3
"""Verify every .stage3_complete subject actually has usable MSMAll output,
not just an exit code of 0 from the last pipeline step.

Checks, per subject:
  - MNINonLinear/Results/REST_ALL_MSMAll/REST_ALL_MSMAll_Atlas_hp0_clean_vn.dtseries.nii
    exists and is a plausible size (the final MSMAll-registered, ICA-FIX-cleaned
    dense timeseries -- what any downstream functional analysis actually reads).
  - Both hemispheres' final MSMAll sphere registration surfaces exist and are
    a plausible size (MNINonLinear/fsaverage_LR32k/<subj>.{L,R}.sphere.
    MSMAll_InitialReg_2_d40_WRN.32k_fs_LR.surf.gii) -- confirms MSMAll's own
    registration step actually completed, not just PostFix/ICAFIX before it.
"""
import glob
import os
from collections import Counter

ROOT = os.environ.get("AMED_ROOT", "/data/juntendodb/amedhcp")
OUT = os.path.join(ROOT, "output")

MIN_DTSERIES = 50 * 1024 * 1024
MIN_SPHERE = 100 * 1024

problems = Counter()
bad = []
ok = []

def num_fmri_runs(sub_out):
    results = os.path.join(sub_out, "MNINonLinear", "Results")
    if not os.path.isdir(results):
        return 0
    return len([d for d in os.listdir(results)
                if os.path.isdir(os.path.join(results, d))
                and not d.startswith("REST_ALL")])


for marker in sorted(glob.glob(os.path.join(OUT, "*", ".stage3_complete"))):
    s = os.path.basename(os.path.dirname(marker))
    sub_out = os.path.join(OUT, s)
    why = []

    # MSMAll needs >=2 fMRI runs to concatenate (this pipeline's multi-run FIX
    # design); subjects with 0 or 1 run legitimately skip FIX/PostFix/MSMAll
    # entirely (see run_stage3_hcp_only.sbatch's own "skipping" log lines) --
    # nothing to check for them.
    if num_fmri_runs(sub_out) < 2:
        ok.append(s)
        continue

    dt = os.path.join(sub_out, "MNINonLinear", "Results", "REST_ALL_MSMAll",
                       "REST_ALL_MSMAll_Atlas_hp0_clean_vn.dtseries.nii")
    if not os.path.exists(dt):
        why.append("missing REST_ALL_MSMAll_Atlas_hp0_clean_vn.dtseries.nii")
    elif os.path.getsize(dt) < MIN_DTSERIES:
        why.append("dtseries suspiciously small (%.1f MB)" % (os.path.getsize(dt) / 1e6))

    for hemi in ("L", "R"):
        sph = os.path.join(sub_out, "MNINonLinear", "fsaverage_LR32k",
                            "%s.%s.sphere.MSMAll_InitialReg_2_d40_WRN.32k_fs_LR.surf.gii" % (s, hemi))
        if not os.path.exists(sph):
            why.append("missing %s MSMAll sphere reg" % hemi)
        elif os.path.getsize(sph) < MIN_SPHERE:
            why.append("%s MSMAll sphere reg suspiciously small" % hemi)

    if why:
        bad.append((s, why))
        for w in why:
            problems[w.split("(")[0].strip()] += 1
    else:
        ok.append(s)

print("stage3_complete subjects checked: %d" % (len(ok) + len(bad)))
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

dest = os.path.join(ROOT, "manifests", "stage3_qc_fail.txt")
with open(dest, "w", encoding="utf-8") as f:
    for s, why in bad:
        f.write(s + "\t" + "; ".join(why) + "\n")
print("\nfailure list -> %s (%d subjects)" % (dest, len(bad)))

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

Also checks, for any subject with a diffusion output (independent of the
fMRI checks above -- a subject can have DWI with 0 or 1 fMRI runs too):
  - T1w/Diffusion/{data.nii.gz,bvals,bvecs} exist and their volume counts
    agree with each other. This is PostEddy's output, not eddy's own (see
    tools/qc_stage2.py for that) -- it re-derives pass/fail after
    --combine-data-flag has done whatever it does to the volume count, so
    a flag that silently drops or duplicates volumes, or a bvals/bvecs
    write that falls out of sync with the actual data, shows up here
    rather than being caught only by chance downstream. It does NOT check
    whether volumes that get merged/averaged together (flag=1) actually
    represent the same diffusion encoding -- that requires comparing the
    *raw*, pre-merge per-volume gradient tables (see the "PostEddy's
    AP/PA combine flag" section of the README), which this pass has no
    way to reconstruct from the merged output alone.
"""
import glob
import gzip
import os
import struct
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


def nvols_nifti(path):
    with gzip.open(path, "rb") as f:
        h = f.read(348)
    d = struct.unpack_from("<8h", h, 40)
    return d[4] if d[0] >= 4 else 1


def nwords(path):
    with open(path, encoding="utf-8") as f:
        return len(f.read().split())


def ncols(path):
    n = 0
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                n = max(n, len(line.split()))
    return n


def check_diffusion(sub_out, s, why):
    diff_dir = os.path.join(sub_out, "T1w", "Diffusion")
    data = os.path.join(diff_dir, "data.nii.gz")
    if not os.path.isdir(diff_dir) or not os.path.exists(data):
        return  # no DWI for this subject, or PostEddy hasn't produced it -- not this check's concern
    try:
        v = nvols_nifti(data)
        checks = {
            "bvals": nwords(os.path.join(diff_dir, "bvals")),
            "bvecs": ncols(os.path.join(diff_dir, "bvecs")),
        }
        for name, n in checks.items():
            if n != v:
                why.append("Diffusion/%s=%d vs %d volumes in data.nii.gz" % (name, n, v))
    except Exception as exc:
        why.append("diffusion check failed: %s" % exc)


for marker in sorted(glob.glob(os.path.join(OUT, "*", ".stage3_complete"))):
    s = os.path.basename(os.path.dirname(marker))
    sub_out = os.path.join(OUT, s)
    why = []

    check_diffusion(sub_out, s, why)

    # MSMAll needs >=2 fMRI runs to concatenate (this pipeline's multi-run FIX
    # design); subjects with 0 or 1 run legitimately skip FIX/PostFix/MSMAll
    # entirely (see run_stage3_hcp_only.sbatch's own "skipping" log lines) --
    # nothing more to check for them.
    if num_fmri_runs(sub_out) < 2:
        if why:
            bad.append((s, why))
            for w in why:
                problems[w.split("(")[0].strip()] += 1
        else:
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

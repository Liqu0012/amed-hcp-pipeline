#!/usr/bin/env python3
"""Cross-tab the stage1 scope: cohort (patient vs BMB/TS control) x protocol."""
import glob
import os

ROOT = os.environ.get("AMED_ROOT", "/data/juntendodb/amedhcp")
OUT = os.path.join(ROOT, "output")

rows = []
for lst in sorted(glob.glob(os.path.join(ROOT, "manifests/subject_lists/stage1_node?.tsv"))
                  + glob.glob(os.path.join(ROOT, "manifests/subject_lists/stage1_tail?.tsv"))):
    tag = os.path.basename(lst)[7:-4]
    for line in open(lst, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line.strip():
            continue
        archive, subj = line.split("\t")[:2]
        cohort = "TS(control)" if "/BMB_" in archive else "patient"
        if "_HARP_" in subj:
            proto = "HARP"
        elif "_CRHD_" in subj:
            proto = "CRHD"
        elif "_SRPB_" in subj:
            proto = "SRPB"
        else:
            proto = "?"
        done = os.path.exists(os.path.join(OUT, subj, ".stage1_complete"))
        rows.append((tag, cohort, proto, done))

cells = {}
for tag, cohort, proto, done in rows:
    k = (cohort, proto)
    t, d = cells.get(k, (0, 0))
    cells[k] = (t + 1, d + (1 if done else 0))

print("%-13s %-6s %8s %8s %8s" % ("cohort", "proto", "total", "done", "left"))
for k in sorted(cells):
    t, d = cells[k]
    print("%-13s %-6s %8d %8d %8d" % (k[0], k[1], t, d, t - d))

# the in-scope set for this question: everything not deferred
act_t = act_d = 0
for (cohort, proto), (t, d) in cells.items():
    if proto in ("CRHD", "SRPB"):
        continue
    act_t += t
    act_d += d
print()
print("ACTIVE (HARP protocol, both cohorts): total=%d done=%d left=%d" % (act_t, act_d, act_t - act_d))

# per running list, so we can see which job finishes when
per = {}
for tag, cohort, proto, done in rows:
    if proto in ("CRHD", "SRPB"):
        continue
    t, d = per.get(tag, (0, 0))
    per[tag] = (t + 1, d + (1 if done else 0))
print()
print("%-8s %8s %8s %8s" % ("list", "active", "done", "left"))
for tag in sorted(per):
    t, d = per[tag]
    print("%-8s %8d %8d %8d" % (tag, t, d, t - d))

#!/usr/bin/env python3
import argparse
import glob
import json
import os
import re
import shlex
import sys


def resolve_dwell_time(meta):
    """Return (dwell_time_seconds, source).

    Some anonymized DICOM exports lose the Siemens CSA field dcm2niix reads
    DwellTime from, while PixelBandwidth and BaseResolution survive. For
    Siemens, dwell = 1 / (PixelBandwidth * BaseResolution * 2) with 2x
    readout oversampling, and the scanner stores it rounded to 100 ns;
    reproducing that rounding matches dcm2niix's value exactly for every
    series where DwellTime is present. PreFreeSurfer's readout distortion
    correction fails with an empty --t1samplespacing otherwise.
    """
    dwell = meta.get("DwellTime")
    if dwell is not None:
        return dwell, "json"
    bandwidth = meta.get("PixelBandwidth")
    base_resolution = meta.get("BaseResolution")
    if str(meta.get("Manufacturer", "")).lower().startswith("siemens") and bandwidth and base_resolution:
        dwell_ns = round(1e9 / (float(bandwidth) * float(base_resolution) * 2), -2)
        return dwell_ns / 1e9, "derived_pixelbandwidth"
    return None, "missing"


def load_series(raw_dir):
    series = []
    for json_path in glob.glob(os.path.join(raw_dir, "*.json")):
        with open(json_path, encoding="utf-8") as f:
            meta = json.load(f)
        nii_path = json_path[:-5] + ".nii.gz"
        if not os.path.exists(nii_path):
            continue
        desc = str(meta.get("SeriesDescription", ""))
        dwell_time, dwell_source = resolve_dwell_time(meta)
        series.append({
            "series": int(meta.get("SeriesNumber", -1)),
            "description": desc,
            "protocol": str(meta.get("ProtocolName", "")),
            "phase_encoding": str(meta.get("PhaseEncodingDirection", "")),
            "effective_echo_spacing": meta.get("EffectiveEchoSpacing"),
            "total_readout_time": meta.get("TotalReadoutTime"),
            "repetition_time": meta.get("RepetitionTime"),
            "echo_time": meta.get("EchoTime"),
            "dwell_time": dwell_time,
            "dwell_time_source": dwell_source,
            "image_type": [str(x).upper() for x in (meta.get("ImageType") or [])],
            "json": json_path,
            "nifti": nii_path,
        })
    return sorted(series, key=lambda x: (x["series"], x["description"]))


DERIVED_DIFFUSION_TAGS = ("TRACEW", "ADC", "EADC", "FA", "COLFA", "EXP")


def is_derived_diffusion(item):
    """True for scanner-computed diffusion maps (trace-weighted, ADC, FA, ...).

    These carry ImageType[0] == "DERIVED" and are finished images, not raw
    diffusion-weighted volumes: they cannot be fed to topup/eddy or to any
    tensor/FOD fit. They also come off a different readout than the HCP-style
    DWI series (JTD: 0.000248181 s vs 0.000619994 s), so including them made
    the echo-spacing set ambiguous, which silently disabled diffusion for 576
    completed subjects.
    """
    itype = item.get("image_type") or []
    if "DERIVED" in itype:
        return True
    return any(tag in itype for tag in DERIVED_DIFFUSION_TAGS)


def has_any(text, terms):
    text = text.lower()
    return any(term in text for term in terms)


def direction_label(item):
    desc = item["description"].upper()
    if re.search(r"(^|_)AP($|_)", desc):
        return "AP"
    if re.search(r"(^|_)PA($|_)", desc):
        return "PA"
    return {"j-": "AP", "j": "PA", "i-": "LR", "i": "RL"}.get(
        item["phase_encoding"], item["phase_encoding"] or "UNKNOWN"
    )


def compact(item):
    return {k: item[k] for k in (
        "series", "description", "protocol", "phase_encoding",
        "effective_echo_spacing", "total_readout_time", "repetition_time",
        "echo_time", "dwell_time", "dwell_time_source", "image_type", "json", "nifti"
    )}


def container_path(path):
    # The stage scripts bind-mount $AMED_ROOT to /work inside the container
    # (see pipeline/*.sbatch); rewrite host-side paths to match so HCP_*
    # variables in subject.env are valid from inside apptainer exec.
    prefix = os.environ.get("AMED_ROOT", "/data/juntendodb/amedhcp")
    if path and path.startswith(prefix + "/"):
        return "/work" + path[len(prefix):]
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("raw_dir")
    parser.add_argument("--output")
    args = parser.parse_args()
    raw_dir = os.path.abspath(args.raw_dir)
    output = args.output or os.path.join(raw_dir, "subject_manifest.json")
    series = load_series(raw_dir)

    # Siemens: t1_mpr / t2_spc (MPRAGE / SPACE, dcm2niix's literal
    # abbreviations). GE: fspgr, cube -- verified against all 331 unique
    # SeriesDescriptions in the cohort with zero false positives. bravo
    # (GE T1) and vista (Philips T2) do not occur in this cohort but are
    # included defensively. Deliberately NOT included: bare "mprage" and
    # "space", which also match several 3-4mm low-res reference scans in
    # this same cohort (mpr_mprage_3mm_axi, t1_space1315A_*_w3x3, etc.) --
    # see this function's docstring for the exact series names.
    T1_TERMS = ("t1w", "t1_mpr", "bravo", "fspgr")
    T2_TERMS = ("t2w", "t2_spc", "cube", "vista")
    t1 = [x for x in series if has_any(x["description"], T1_TERMS) and "scout" not in x["description"].lower()]
    t2 = [x for x in series if has_any(x["description"], T2_TERMS) and "scout" not in x["description"].lower()]
    bold_all = [x for x in series if has_any(x["description"], ("bold", "rfmri"))]
    bold = [x for x in bold_all if "sbref" not in x["description"].lower()]
    sbref = [x for x in bold_all if "sbref" in x["description"].lower()]
    fmap = [x for x in series if has_any(x["description"], ("sefield", "spinechofieldmap"))]
    dwi_all = [x for x in series
               if has_any(x["description"], ("dmri", "dwi", "diffusion"))
               and not is_derived_diffusion(x)]
    dwi = [x for x in dwi_all if "sbref" not in x["description"].lower()]

    fmap_by_dir = {}
    for item in fmap:
        fmap_by_dir.setdefault(direction_label(item), []).append(item)
    fmap_pairs = []
    for neg, pos in zip(fmap_by_dir.get("AP", []), fmap_by_dir.get("PA", [])):
        fmap_pairs.append({"negative": neg, "positive": pos, "midpoint": (neg["series"] + pos["series"]) / 2})

    run_counter = {}
    functional = []
    for item in bold:
        direction = direction_label(item)
        run_counter[direction] = run_counter.get(direction, 0) + 1
        rest_match = re.search(r"REST_?(\d+)", item["description"].upper())
        run_number = int(rest_match.group(1)) if rest_match else run_counter[direction]
        candidates = [x for x in sbref if direction_label(x) == direction]
        scout = min(candidates, key=lambda x: abs(x["series"] - item["series"])) if candidates else None
        pair = min(fmap_pairs, key=lambda x: abs(x["midpoint"] - item["series"])) if fmap_pairs else None
        functional.append({
            "name": f"REST{run_number}_{direction}",
            "direction": direction,
            "timeseries": compact(item),
            "sbref": compact(scout) if scout else None,
            "spin_echo_negative": compact(pair["negative"]) if pair else None,
            "spin_echo_positive": compact(pair["positive"]) if pair else None,
        })

    diffusion = []
    for item in dwi:
        base = item["nifti"][:-7]
        bval, bvec = base + ".bval", base + ".bvec"
        diffusion.append({
            "direction": direction_label(item),
            "image": compact(item),
            "bval": bval if os.path.exists(bval) else None,
            "bvec": bvec if os.path.exists(bvec) else None,
        })

    result = {
        "subject": os.path.basename(raw_dir),
        "raw_dir": raw_dir,
        "t1w": [compact(x) for x in t1],
        "t2w": [compact(x) for x in t2],
        "functional": functional,
        "diffusion": diffusion,
        "spin_echo_fieldmaps": [compact(x) for x in fmap],
    }
    with open(output, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, sort_keys=True)

    env_path = os.path.join(raw_dir, "subject.env")
    env = {
        "HCP_SUBJECT": result["subject"],
        "HCP_T1": "@".join(container_path(x["nifti"]) for x in result["t1w"]),
        "HCP_T2": "@".join(container_path(x["nifti"]) for x in result["t2w"]),
        "HCP_T1_DWELL": str(result["t1w"][0]["dwell_time"] if result["t1w"] and result["t1w"][0]["dwell_time"] is not None else ""),
        "HCP_T2_DWELL": str(result["t2w"][0]["dwell_time"] if result["t2w"] and result["t2w"][0]["dwell_time"] is not None else ""),
        "HCP_FMRI_COUNT": str(len(functional)),
    }

    if t1 and fmap_pairs:
        structural_pair = min(fmap_pairs, key=lambda x: abs(x["midpoint"] - t1[0]["series"]))
        env["HCP_STRUCT_FMAP_NEG"] = container_path(structural_pair["negative"]["nifti"])
        env["HCP_STRUCT_FMAP_POS"] = container_path(structural_pair["positive"]["nifti"])
        env["HCP_STRUCT_FMAP_ECHO"] = str(structural_pair["negative"].get("effective_echo_spacing") or "")
    else:
        env["HCP_STRUCT_FMAP_NEG"] = "NONE"
        env["HCP_STRUCT_FMAP_POS"] = "NONE"
        env["HCP_STRUCT_FMAP_ECHO"] = ""

    for index, run in enumerate(functional):
        prefix = f"HCP_FMRI_{index}_"
        env[prefix + "NAME"] = run["name"]
        env[prefix + "TCS"] = container_path(run["timeseries"]["nifti"])
        env[prefix + "SCOUT"] = container_path(run["sbref"]["nifti"]) if run["sbref"] else "NONE"
        env[prefix + "FMAP_NEG"] = container_path(run["spin_echo_negative"]["nifti"]) if run["spin_echo_negative"] else "NONE"
        env[prefix + "FMAP_POS"] = container_path(run["spin_echo_positive"]["nifti"]) if run["spin_echo_positive"] else "NONE"
        env[prefix + "ECHO"] = str(run["timeseries"].get("effective_echo_spacing") or "")
        env[prefix + "UNWARP"] = run["timeseries"].get("phase_encoding") or ""

    pos = [x for x in diffusion if x["direction"] in ("PA", "RL")]
    neg = [x for x in diffusion if x["direction"] in ("AP", "LR")]
    env["HCP_DWI_POS"] = "@".join(container_path(x["image"]["nifti"]) for x in pos)
    env["HCP_DWI_NEG"] = "@".join(container_path(x["image"]["nifti"]) for x in neg)
    dwi_echoes = sorted({round(float(x["image"]["effective_echo_spacing"]), 9) for x in diffusion if x["image"].get("effective_echo_spacing") is not None})
    env["HCP_DWI_ECHO"] = str(dwi_echoes[0]) if len(dwi_echoes) == 1 else ""
    if diffusion and len(dwi_echoes) != 1:
        descs = [x["image"]["description"] for x in diffusion]
        print("WARNING: ambiguous diffusion echo spacing %s across %s; HCP_DWI_ECHO left empty" % (dwi_echoes, descs), file=sys.stderr)
    env["HCP_DWI_PE_DIR"] = "2" if diffusion and all(x["image"]["phase_encoding"].startswith("j") for x in diffusion) else ""

    with open(env_path, "w", encoding="utf-8") as f:
        f.write("# Generated from DICOM JSON metadata; do not edit manually.\n")
        for key, value in env.items():
            f.write(f"{key}={shlex.quote(str(value))}\n")

    print(f"subject={result['subject']}")
    print(f"t1w={len(t1)} t2w={len(t2)} functional={len(functional)} diffusion={len(diffusion)} fieldmaps={len(fmap)}")
    for label, items in (("t1w", t1), ("t2w", t2)):
        if items:
            print(f"{label}_dwell={items[0]['dwell_time']} source={items[0]['dwell_time_source']}")
    for run in functional:
        print(f"fmri={run['name']} series={run['timeseries']['series']} sbref={run['sbref']['series'] if run['sbref'] else 'NONE'} fmap={run['spin_echo_negative']['series'] if run['spin_echo_negative'] else 'NONE'}/{run['spin_echo_positive']['series'] if run['spin_echo_positive'] else 'NONE'}")
    for run in diffusion:
        print(f"dwi={run['direction']} series={run['image']['series']} gradients={bool(run['bval'] and run['bvec'])}")


if __name__ == "__main__":
    main()

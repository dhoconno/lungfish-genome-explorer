#!/usr/bin/env python3
"""Prepared anchored API comparison; requires frozen selective-history API."""
from __future__ import annotations
import argparse, json, platform, time
from pathlib import Path
from primalscheme3.core.config import Config
from primalscheme3.panel.coverage_discovery import build_variant_catalog
from primalscheme3.panel.coverage_types import Target

SHARED = "CAACGGCGGACTTTATTGTATCTCC"
HIGH = "AATCGGCCGACTGTACGCGA"
NORMAL = "CATGCTCATTAGGTATATCTTTCAATAAGTTGCA"

def make_target() -> Target:
    rows = (SHARED + "ATATATATAT" + HIGH, NORMAL + "ATATATATAT" + HIGH)
    width = len(rows[0]); cells = tuple(tuple(row.rjust(width, "-")) for row in rows)
    ref = "".join(x for x in cells[0] if x not in ("", "-")); mapping=[]; pos=0
    for cell in cells[0]:
        mapping.append(pos if cell not in ("", "-") else None); pos += cell not in ("", "-")
    indexes = tuple(i for i, value in enumerate(mapping) if value is not None)
    return Target("selective-anchor", 0, 0, ("row-0", "row-1"), cells, ref, len(ref), tuple(mapping), indexes + (width,))

def run(mode: str, output: Path) -> dict:
    target = make_target(); config = Config(amplicon_size=54, amplicon_size_min=50, amplicon_size_max=65, ncores=1)
    started = time.time()
    # Align this reviewed history-policy keyword with the frozen Task1/2 API before execution.
    catalog = build_variant_catalog((target,), config, length_mode="all",
        indexes=([len(SHARED)], [len(SHARED) + 10]), history_policy=mode)
    if not catalog.families: raise RuntimeError("probe fixture produced no families")
    projection = {"sites": [(s.id,s.target_id,s.strand,s.sequence,s.reference_footprint,s.accepting_profile_ids) for s in catalog.sites],
                  "families": [(f.id,f.target_id,f.forward_site_ids,f.reverse_site_ids,f.anchor_pair) for f in catalog.families]}
    result = {"mode":mode,"catalog_digest":catalog.semantic_digest,"site_count":len(catalog.sites),
              "family_count":len(catalog.families),"scientific_projection":projection,
              "wall_seconds":time.time()-started,"python":platform.python_version(),
              "fixture":"generated-known-nonempty-family","source":"test_variant_discovery::test_hybrid_family_retains_short_member"}
    output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n"); return result

def main() -> None:
    ap=argparse.ArgumentParser(); ap.add_argument("--output-root",type=Path,required=True); args=ap.parse_args()
    args.output_root.mkdir(parents=True, exist_ok=True); results=[run(m,args.output_root/f"{m}.json") for m in ("compact","full")]
    (args.output_root/"probe-receipt.json").write_text(json.dumps({"tool":"selective-history-a1-anchor-probe","argv":__import__("sys").argv,"results":results,"status":"prepared-not-executed"},indent=2,sort_keys=True)+"\n")

if __name__ == "__main__": main()

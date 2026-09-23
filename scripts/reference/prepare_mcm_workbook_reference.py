#!/usr/bin/env python3
"""Prepare an MCM MiSeq reference from the curated Report_format workbook.

Join by the biological allele label, never by spreadsheet row position. Require
agreement with both FASTA haplotype suffixes and the independent per-haplotype
sheet. Preserve complete supplied sequences and all collapsed allele aliases.
"""
import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import shlex
import shutil
import sys
import time
import traceback

import openpyxl

VERSION = "1.0.0"
GROUPS = {"A haplo": "A", "E haplo": "E", "B haplo": "B",
          "DRB haplo": "DR", "DQA/B haplo": "DQ", "DPA/B haplo": "DP"}


def descriptor(path):
    data = path.read_bytes()
    return {"path": str(path.resolve()), "sha256": hashlib.sha256(data).hexdigest(), "sizeBytes": len(data)}


def readable_label(header):
    value = re.sub(r"_(?:M[1-7])+$", "", header).replace("Mafa-", "")
    return "/".join(re.sub(r"_([0-9W])", r"*\1", part, count=1) for part in value.split("/"))


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def prepare(workbook_path, fasta_path, output):
    records = {}
    for line in fasta_path.read_text().splitlines():
        if line.startswith(">"):
            header = line[1:]
            if header in records:
                raise ValueError(f"Duplicate FASTA header: {header}")
            records[header] = ""
        elif line.strip():
            records[header] += line.strip().upper()
    if not records or any(not seq or set(seq) - set("ACGT") for seq in records.values()):
        raise ValueError("Empty reference or invalid DNA sequence")
    reverse = lambda seq: seq.translate(str.maketrans("ACGT", "TGCA"))[::-1]
    if len({min(seq, reverse(seq)) for seq in records.values()}) != len(records):
        raise ValueError("Strand-equivalent duplicate sequences require review")
    by_label = {readable_label(header): header for header in records}
    if len(by_label) != len(records):
        raise ValueError("Readable target names are not unique")

    workbook = openpyxl.load_workbook(workbook_path, data_only=True)
    independent_memberships = {}
    excluded = []
    for row_number, row in enumerate(workbook["MCM_Alleles_Per_Hap-2026"].iter_rows(min_row=3, values_only=True), 3):
        for n in range(1, 8):
            hit = row[4 + (n - 1) * 4]
            if isinstance(hit, str) and hit.startswith("Mafa-"):
                label = readable_label(hit)
                if label not in by_label:
                    excluded.append({"sheet": "MCM_Alleles_Per_Hap-2026", "row": row_number,
                                     "hit": hit, "reason": "No supplied FASTA target; not included or inferred"})
                    continue
                independent_memberships.setdefault(label, set()).add(f"M{n}")

    mapped = []
    corrections = []
    seen = set()
    for row_number, row in enumerate(workbook["Report_format"].values, 1):
        if row_number < 3 or not row[3]:
            continue
        if not row[4]:
            # The shifted DQB block ends with a redundant hit-only row.
            corrections.append({"sheet": "Report_format", "row": row_number,
                                "action": "Ignore hit-only row; target is represented by its named row", "originalHit": row[3]})
            continue
        label = row[4].replace(" ", "")
        if label not in by_label or label in seen:
            raise ValueError(f"Missing or duplicated readable label at row {row_number}: {label}")
        seen.add(label)
        header = by_label[label]
        haps = re.findall(r"M[1-7]", str(row[6]))
        marked = [f"M{n}" for n in range(1, 8) if row[6 + n]]
        suffix_haps = re.findall(r"M[1-7]", header.rsplit("_", 1)[-1])
        if not haps or haps != marked or haps != suffix_haps:
            raise ValueError(f"Haplotype membership disagreement at row {row_number}: {label}")
        if set(haps) != independent_memberships.get(label):
            raise ValueError(f"Per-haplotype sheet disagrees at row {row_number}: {label}")
        if readable_label(row[3]) != label:
            corrections.append({"sheet": "Report_format", "row": row_number,
                                "action": "Join by Simplified name, corroborated by FASTA and per-haplotype sheet",
                                "originalHit": row[3], "resolvedHit": header})
        group = GROUPS[row[0]]
        mapped.append({"name": label, "displayName": row[4], "originalHeader": header,
                       "reportRow": row_number, "locus": row[1].replace("Mafa-", "MHC-"),
                       "haplotypeGroup": "MHC-" + group, "haplotypes": haps,
                       "sequence": records[header]})
    if seen != set(by_label):
        raise ValueError(f"Unrepresented FASTA targets: {set(by_label) - seen}")

    definition = {"id": "mcm-mhc-miseq-20260922", "assayID": "MHC-exon2-miSeq",
                  "displayName": "MCM MHC MiSeq haplotypes — 22 September 2026",
                  "speciesName": "Mauritian cynomolgus macaque", "speciesCode": "MCM", "prefix": "MHC",
                  "schemaVersion": 1, "lastModified": "2026-09-22T00:00:00Z",
                  "changeNote": "All Report_format associations; readable diagnostic names; DQB rows reconciled by allele identity against the FASTA and per-haplotype sheet. All listed markers required; no primary-marker subset inferred.",
                  "locusDefinitions": []}
    for group in GROUPS.values():
        locus = "MHC-" + group
        haplotypes = []
        for n in range(1, 8):
            names = [r["name"] for r in mapped if r["haplotypeGroup"] == locus and f"M{n}" in r["haplotypes"]]
            if not names:
                raise ValueError(f"No evidence for M{n}{group}")
            haplotypes.append({"name": f"M{n}{group}", "diagnosticAlleles": names,
                               "minimumMatches": len(names), "evidenceWeights": {name: 1.0 for name in names}})
        definition["locusDefinitions"].append({"locus": locus, "sourceLocus": locus, "haplotypes": haplotypes})
    with (output / "reference.fasta").open("w") as handle:
        for r in mapped:
            alleles = r["name"].replace("/", ",")
            handle.write(f'>{r["name"]}|alleles={alleles}|source_loci={r["locus"]}|haplotype_groups={r["haplotypeGroup"]}|haplotypes={",".join(r["haplotypes"])}|length={len(r["sequence"])}\n{r["sequence"]}\n')
    indistinguishable = []
    for locus in definition["locusDefinitions"]:
        evidence_sets = {}
        for haplotype in locus["haplotypes"]:
            evidence_sets.setdefault(tuple(sorted(haplotype["diagnosticAlleles"])), []).append(haplotype["name"])
        indistinguishable.extend(names for names in evidence_sets.values() if len(names) > 1)
    write_json(output / "haplotype-definition.json", definition)
    write_json(output / "source-reconciliation.json", {"corrections": corrections, "excludedUnsequencedHits": excluded,
        "identicalEvidenceHaplotypes": indistinguishable, "targets": [
        {k: v for k, v in r.items() if k != "sequence"} | {"sequenceSHA256": hashlib.sha256(r["sequence"].encode()).hexdigest()}
        for r in mapped]})
    with (output / "Allele and haplotype names.csv").open("w") as handle:
        writer = csv.writer(handle)
        writer.writerow(["Allele", "Haplotype group", "Haplotypes", "Source row", "Original FASTA header"])
        writer.writerows((r["displayName"], r["haplotypeGroup"], ", ".join(r["haplotypes"]), r["reportRow"], r["originalHeader"]) for r in mapped)
    (output / "README.md").write_text(
        "# MCM MHC MiSeq reference — 22 September 2026\n\n"
        f"{len(mapped)} distinct supplied amplicons; 42 haplotypes in six groups. All sequences and collapsed aliases are preserved.\n\n"
        "The Report_format sheet supplies readable names, order, groups, and memberships. Every membership is checked against the FASTA header and MCM_Alleles_Per_Hap-2026 sheet. The shifted DQB hit column is reconciled by Simplified name; the redundant final hit-only row is omitted. The original workbook is unchanged. See source-reconciliation.json for exact source rows.\n\n"
        "Deterministic rule: use all workbook associations, with equal evidence weights and all listed markers required. This is a complete-association definition, not the older primary-marker-only definition. Missing or low-support markers can prevent a call. Shared targets remain ambiguous; names separated by / describe one sequence target, not separately measured alleles.\n\n"
        + "Identical evidence sets: " + "; ".join(" / ".join(names) for names in indistinguishable) + ". The existing matcher may report both names when their evidence matches. These targets cannot distinguish the alternatives, and two matching names do not establish that both haplotypes are present.\n\n"
        "Workbook-only hits without supplied sequences are excluded and listed in source-reconciliation.json. No sequence is inferred for those hits.\n\n"
        "Genotyping-only must be selected to suppress haplotype calling. The existence of definitions in this reference does not imply that haplotyping was requested.\n\n"
        "provenance.json records the exact command, runtime, options, input/output checksums and sizes, status, timing, and stderr. The enclosing bundle has additional canonical CLI provenance for its final stored payload.\n")
    return {"referenceCount": len(mapped), "haplotypeCount": 42, "reconciledRows": len(corrections)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workbook", type=Path, required=True)
    parser.add_argument("--fasta", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    start = time.monotonic()
    argv = [sys.executable, str(Path(__file__).resolve()), *sys.argv[1:]]
    provenance = {"tool": "prepare-mcm-workbook-reference", "version": VERSION,
                  "startedAt": datetime.now(timezone.utc).isoformat(), "argv": argv, "command": shlex.join(argv),
                  "options": {"workbook": str(args.workbook.resolve()), "fasta": str(args.fasta.resolve()),
                              "output": str(output), "associations": "all-workbook", "minimumMatches": "all-listed",
                              "evidenceWeight": 1.0, "sequenceTransformation": "none", "DQBJoin": "readable-allele-identity"},
                  "runtime": {"python": sys.version, "executable": sys.executable, "openpyxl": openpyxl.__version__, "platform": platform.platform()},
                  "inputs": [descriptor(p) for p in [args.workbook, args.fasta, Path(__file__)]],
                  "exitStatus": 1, "stderr": ""}
    try:
        sources = output / "sources"
        sources.mkdir()
        for path in [args.workbook, args.fasta, Path(__file__)]:
            shutil.copy2(path, sources / path.name)
        provenance["counts"] = prepare(args.workbook, args.fasta, output)
        provenance["exitStatus"] = 0
    except Exception:
        provenance["stderr"] = traceback.format_exc()
        print(provenance["stderr"], file=sys.stderr)
    provenance["wallTimeSeconds"] = time.monotonic() - start
    provenance["outputs"] = [descriptor(p) for p in sorted(output.rglob("*")) if p.is_file()]
    write_json(output / "provenance.json", provenance)
    print(json.dumps(provenance.get("counts", {})))
    return provenance["exitStatus"]


if __name__ == "__main__":
    raise SystemExit(main())

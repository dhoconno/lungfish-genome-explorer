#!/usr/bin/env python3
"""Evaluation-only prompt lab for de novo macaque MHC haplotyping."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shlex
import sys
import time
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from openpyxl import load_workbook


TOOL_NAME = "macaque-mhc-prompt-lab"
TOOL_VERSION = "2026-06-20.1"
REPORT_LOCI = ["MHC-A", "MHC-B", "MHC-DRB", "MHC-DQA", "MHC-DQB", "MHC-DPA", "MHC-DPB"]
FULL_RESULT_SHEETS = ["Full Sequencing Results 1", "Full Sequencing Results 2"]
DEFAULT_SNPRC_WORKBOOK = Path("/Users/dho/Downloads/30783_SNPRC22_MHC_Genotype_Report_31Dec24.xlsx")
DEFAULT_PROMPT = Path("scripts/analysis/prompts/generalist_macaque_mhc_haplotyping_v1.md")
DEFAULT_OUTPUT_ROOT = Path("outputs/macaque-mhc-prompt-lab")
TRUTH_ROW_RE = re.compile(r"^MHC-(A|B|DRB|DQA|DQB|DPA|DPB)\s+Haplotype\s+([12])$", re.IGNORECASE)
GENOTYPE_PREFIX_RE = re.compile(r"^\d+_(Mamu-[A-Za-z0-9*]+)")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_record(path: Path, role: str) -> dict[str, Any]:
    return {
        "path": str(path.resolve()),
        "role": role,
        "sha256": sha256_file(path),
        "sizeBytes": path.stat().st_size,
    }


def clean(value: Any) -> str:
    if value is None:
        return ""
    text = str(value).strip()
    if text.endswith(".0") and text[:-2].isdigit():
        return text[:-2]
    return text


def int_or_none(value: Any) -> int | None:
    if value is None or value == "":
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value) if value.is_integer() else None
    text = str(value).replace(",", "").strip()
    if not text:
        return None
    try:
        return int(float(text))
    except ValueError:
        return None


def locus_from_genotype(genotype: str) -> tuple[str, str]:
    match = GENOTYPE_PREFIX_RE.match(genotype)
    source = match.group(1) if match else genotype.split("_", 1)[0]
    upper = source.upper()
    if upper.startswith("MAMU-A") or upper.startswith("MAMU-AG") or upper.startswith("MAMU-F") or upper.startswith("MAMU-G"):
        return ("MHC-A", source)
    if upper.startswith("MAMU-B") or upper.startswith("MAMU-I") or upper.startswith("MAMU-J") or upper.startswith("MAMU-K") or upper.startswith("MAMU-S") or upper.startswith("MAMU-V"):
        return ("MHC-B", source)
    if upper.startswith("MAMU-DRB"):
        return ("MHC-DRB", source)
    if upper.startswith("MAMU-DQA"):
        return ("MHC-DQA", source)
    if upper.startswith("MAMU-DQB"):
        return ("MHC-DQB", source)
    if upper.startswith("MAMU-DPA"):
        return ("MHC-DPA", source)
    if upper.startswith("MAMU-DPB"):
        return ("MHC-DPB", source)
    if upper.startswith("MAMU-E"):
        return ("context", source)
    return ("context", source)


def is_genotype_label(label: str) -> bool:
    return bool(re.match(r"^\d+_Mamu-", label))


def sample_columns(ws) -> list[int]:
    cols = []
    for col in range(4, ws.max_column + 1):
        first = clean(ws.cell(1, col).value)
        second = clean(ws.cell(2, col).value)
        if first or second:
            cols.append(col)
    return cols


def metadata_for_column(ws, col: int) -> dict[str, Any]:
    row1_label = clean(ws.cell(1, 1).value).lower().replace(" ", "_")
    row2_label = clean(ws.cell(2, 1).value).lower().replace(" ", "_")
    row1 = clean(ws.cell(1, col).value)
    row2 = clean(ws.cell(2, col).value)
    if row1_label in {"client_id", "clientid"} and row2_label in {"gs_id", "gsid"}:
        client_id, gs_id = row1, row2
    elif row1_label in {"gs_id", "gsid"} and row2_label in {"client_id", "clientid"}:
        gs_id, client_id = row1, row2
    else:
        client_id, gs_id = row1, row2
    mapped_reads = int_or_none(ws.cell(3, col).value)
    return {"client_id": client_id, "gs_id": gs_id or client_id, "mapped_reads": mapped_reads}


def row_value(row: tuple[Any, ...], index: int) -> Any:
    return row[index] if index < len(row) else None


def sample_column_indexes(row1: tuple[Any, ...], row2: tuple[Any, ...]) -> list[int]:
    cols = []
    for index in range(3, max(len(row1), len(row2))):
        first = clean(row_value(row1, index))
        second = clean(row_value(row2, index))
        if first or second:
            cols.append(index)
    return cols


def metadata_for_column_values(row1: tuple[Any, ...], row2: tuple[Any, ...], row3: tuple[Any, ...], index: int) -> dict[str, Any]:
    row1_label = clean(row_value(row1, 0)).lower().replace(" ", "_")
    row2_label = clean(row_value(row2, 0)).lower().replace(" ", "_")
    first_value = clean(row_value(row1, index))
    second_value = clean(row_value(row2, index))
    if row1_label in {"client_id", "clientid"} and row2_label in {"gs_id", "gsid"}:
        client_id, gs_id = first_value, second_value
    elif row1_label in {"gs_id", "gsid"} and row2_label in {"client_id", "clientid"}:
        gs_id, client_id = first_value, second_value
    else:
        client_id, gs_id = first_value, second_value
    mapped_reads = int_or_none(row_value(row3, index))
    return {"client_id": client_id, "gs_id": gs_id or client_id, "mapped_reads": mapped_reads}


def normalize_truth_locus(raw: str) -> str:
    return "MHC-" + raw.upper()


def extract_sheet(ws) -> tuple[list[dict[str, Any]], dict[str, dict[str, list[str]]], list[dict[str, Any]]]:
    samples = []
    truth: dict[str, dict[str, list[str]]] = defaultdict(lambda: {locus: ["", ""] for locus in REPORT_LOCI})
    observations = []
    rows = ws.iter_rows(values_only=True)
    row1 = tuple(next(rows, ()))
    row2 = tuple(next(rows, ()))
    row3 = tuple(next(rows, ()))
    columns = sample_column_indexes(row1, row2)
    sample_meta_by_col = {col: metadata_for_column_values(row1, row2, row3, col) for col in columns}
    for meta in sample_meta_by_col.values():
        if meta["gs_id"]:
            samples.append({"gs_id": meta["gs_id"], "client_id": meta["client_id"], "sheet": ws.title, "mapped_reads": meta["mapped_reads"]})

    for row_number, row_values in enumerate(rows, start=4):
        row_values = tuple(row_values)
        label = clean(row_value(row_values, 0))
        if not label:
            continue
        truth_match = TRUTH_ROW_RE.match(label)
        if truth_match:
            locus = normalize_truth_locus(truth_match.group(1))
            slot = int(truth_match.group(2)) - 1
            for col, meta in sample_meta_by_col.items():
                sample_id = meta["gs_id"]
                if sample_id:
                    truth[sample_id][locus][slot] = clean(row_value(row_values, col))
            continue
        if not is_genotype_label(label):
            continue
        report_locus, source_locus = locus_from_genotype(label)
        if report_locus == "context":
            continue
        for col, meta in sample_meta_by_col.items():
            reads = int_or_none(row_value(row_values, col))
            if reads is None or reads <= 0 or not meta["gs_id"]:
                continue
            mapped = meta["mapped_reads"]
            observations.append({
                "sample_id": meta["gs_id"],
                "client_id": meta["client_id"],
                "report_locus": report_locus,
                "source_locus": source_locus,
                "genotype": label,
                "reads": reads,
                "sheet": ws.title,
                "row": row_number,
                "sample_mapped_reads": mapped,
                "read_fraction": round(reads / mapped, 6) if mapped else None,
            })
    return samples, dict(truth), observations


def extract_workbook(workbook_path: Path) -> dict[str, Any]:
    wb = load_workbook(workbook_path, read_only=True, data_only=True)
    all_samples: dict[str, dict[str, Any]] = {}
    truth: dict[str, dict[str, list[str]]] = {}
    observations: list[dict[str, Any]] = []
    for sheet_name in FULL_RESULT_SHEETS:
        if sheet_name not in wb.sheetnames:
            continue
        sheet_samples, sheet_truth, sheet_observations = extract_sheet(wb[sheet_name])
        for sample in sheet_samples:
            all_samples[sample["gs_id"]] = sample
        for sample_id, calls in sheet_truth.items():
            truth[sample_id] = calls
        observations.extend(sheet_observations)
    samples = [all_samples[key] for key in sorted(all_samples)]
    prompt_input = {
        "schema_version": 1,
        "dataset": workbook_path.name,
        "instructions": {
            "truth_blinded": True,
            "report_loci": REPORT_LOCI,
            "hidden_truth_source": "human-curated haplotype rows are excluded from prompt input",
        },
        "samples": samples,
        "observations": sorted(observations, key=lambda row: (row["sample_id"], row["report_locus"], row["genotype"])),
    }
    return {"samples": samples, "truth_calls": truth, "prompt_input": prompt_input}


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def runtime_identity() -> dict[str, Any]:
    return {
        "python": sys.version.split()[0],
        "platform": platform.platform(),
        "executable": sys.executable,
        "condaPrefix": os.environ.get("CONDA_PREFIX"),
        "container": os.environ.get("container"),
    }


def resolved_extract_options(workbook: Path, output_dir: Path) -> dict[str, Any]:
    return {
        "workbook": str(workbook),
        "outputDir": str(output_dir),
        "defaults": {
            "workbook": str(DEFAULT_SNPRC_WORKBOOK),
            "prompt": str(DEFAULT_PROMPT),
            "outputRoot": str(DEFAULT_OUTPUT_ROOT),
            "reportLoci": REPORT_LOCI,
            "fullResultSheets": FULL_RESULT_SHEETS,
        },
    }


def write_provenance(
    output_dir: Path,
    workflow: str,
    argv: list[str],
    inputs: list[Path],
    outputs: list[Path],
    started: float,
    options: dict[str, Any],
    status: str = "completed",
    stderr: str | None = None,
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "schemaVersion": 1,
        "workflowName": workflow,
        "toolName": TOOL_NAME,
        "toolVersion": TOOL_VERSION,
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "argv": argv,
        "reproducibleShellCommand": " ".join(shlex.quote(part) for part in [sys.executable, *argv]),
        "options": options,
        "runtimeIdentity": runtime_identity(),
        "inputs": [file_record(path, "input") for path in inputs if path.exists()],
        "outputs": [file_record(path, "output") for path in outputs if path.exists()],
        "exitStatus": 0 if status == "completed" else 1,
        "wallTimeSeconds": round(time.time() - started, 3),
        "stderr": stderr,
        "status": status,
    }
    write_json(output_dir / f"{workflow}.provenance.json", payload)


def command_extract(args: argparse.Namespace) -> None:
    started = time.time()
    workbook = args.workbook.resolve()
    out = args.output_dir.resolve()
    extracted = extract_workbook(workbook)
    evidence_path = out / "prompt_input.json"
    truth_path = out / "truth_calls.json"
    samples_path = out / "samples.json"
    write_json(evidence_path, extracted["prompt_input"])
    write_json(truth_path, extracted["truth_calls"])
    write_json(samples_path, extracted["samples"])
    write_provenance(
        out,
        "extract",
        sys.argv,
        [workbook],
        [evidence_path, truth_path, samples_path],
        started,
        resolved_extract_options(workbook, out),
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    extract = sub.add_parser("extract", help="Extract blinded prompt input and held-out truth from an SNPRC workbook.")
    extract.add_argument("--workbook", type=Path, default=DEFAULT_SNPRC_WORKBOOK)
    extract.add_argument("--output-dir", type=Path, required=True)
    extract.set_defaults(func=command_extract)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

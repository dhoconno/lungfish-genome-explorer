# Generalist Macaque MHC Prompt Lab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an evaluation-only prompt lab that extracts blinded genotype evidence from the SNPRC workbook, runs a new generalist macaque MHC haplotyping prompt, and scores de novo predictions against held-out human calls.

**Architecture:** Keep all prototype code outside production app and CLI paths. A standalone Python script under `scripts/analysis/` owns workbook extraction, prompt rendering, optional OpenAI invocation, output import, scoring, reports, and provenance; a separate markdown prompt file stores the generalist prompt version. Unit tests use synthetic workbooks and model outputs so no external workbook or API key is needed for correctness tests.

**Tech Stack:** Python 3 stdlib, bundled `openpyxl`, `unittest`, JSON files, Markdown prompt template, ignored `outputs/` iteration directories.

---

## File Structure

- Create: `scripts/analysis/macaque_mhc_prompt_lab.py`
  - Standalone CLI with subcommands: `extract`, `render-prompt`, `run-openai`, `import-output`, `score`, and `run-iteration`.
  - Contains focused functions for workbook extraction, prompt packaging, output validation, scoring, maximum-weight label mapping, and provenance.
- Create: `scripts/analysis/prompts/generalist_macaque_mhc_haplotyping_v1.md`
  - Versioned prompt text. It is informed by the MCM specialist style but contains no MCM M1-M7 prior and no a priori outbred haplotype definitions.
- Create: `scripts/tests/test_macaque_mhc_prompt_lab.py`
  - Synthetic workbook, prompt-input, output-validation, scoring, and provenance tests.
- Generated only, not committed: `outputs/macaque-mhc-prompt-lab/iteration-001/`
  - Contains normalized evidence, held-out truth, rendered prompt, model output, parsed predictions, score reports, discrepancy notes, and provenance sidecars.

## Task 1: Unit Test Skeleton And Synthetic Workbook Fixture

**Files:**
- Create: `scripts/tests/test_macaque_mhc_prompt_lab.py`
- Create later in Task 2: `scripts/analysis/macaque_mhc_prompt_lab.py`

- [ ] **Step 1: Write failing tests for extraction and truth blinding**

Create `scripts/tests/test_macaque_mhc_prompt_lab.py` with this initial content:

```python
import json
import tempfile
import unittest
from pathlib import Path

from openpyxl import Workbook

from scripts.analysis import macaque_mhc_prompt_lab as lab


class MacaqueMHCPromptLabTests(unittest.TestCase):
    def make_synthetic_snprc_workbook(self, root: Path) -> Path:
        path = root / "synthetic_snprc.xlsx"
        wb = Workbook()
        ws = wb.active
        ws.title = "Full Sequencing Results 1"
        ws.append(["Client ID", None, None, "44470", "44395"])
        ws.append(["GS ID", "Total", "Average", "LC1729", "LC1730"])
        ws.append(["Mapped Read Count", None, None, 1000, 1200])
        ws.append(["total_read_count", None, None, 2000, 2200])
        ws.append(["percent_reads_unmapped", None, None, 50.0, 45.4])
        ws.append(["MHC-A Haplotype 1", None, None, "A002.01", "A008.01"])
        ws.append(["MHC-A Haplotype 2", None, None, "A002.01", "A004.01"])
        ws.append(["MHC-B Haplotype 1", None, None, "B001.01", "B028.01"])
        ws.append(["MHC-B Haplotype 2", None, None, "B001.01", "B012.01"])
        ws.append(["MHC-DRB Haplotype 1", None, None, "DR09.01", "DR06.01"])
        ws.append(["MHC-DRB Haplotype 2", None, None, "DR09.01", "DR01.01"])
        ws.append(["MHC-DQA Haplotype 1", None, None, "26g2", "23_01"])
        ws.append(["MHC-DQA Haplotype 2", None, None, "26g2", "01g2"])
        ws.append(["MHC-DQB Haplotype 1", None, None, "18g3", "06g1"])
        ws.append(["MHC-DQB Haplotype 2", None, None, "18g3", "06g2"])
        ws.append(["MHC-DPA Haplotype 1", None, None, "02g1", "02g3"])
        ws.append(["MHC-DPA Haplotype 2", None, None, "02g1", "02g1"])
        ws.append(["MHC-DPB Haplotype 1", None, None, "15g", "07g1"])
        ws.append(["MHC-DPB Haplotype 2", None, None, "15g", "08_01"])
        ws.append(["Comments", "Subtotal", "# Obs.", None, None])
        ws.append(["Mamu-A Major Alleles", None, None, None, None])
        ws.append(["01_Mamu-A1_002g", 100, 1, 90, None])
        ws.append(["01_Mamu-A1_008g", 100, 1, None, 80])
        ws.append(["01_Mamu-A1_004g", 100, 1, None, 70])
        ws.append(["Mamu-B Major Alleles", None, None, None, None])
        ws.append(["03_Mamu-B_001g1", 100, 1, 75, None])
        ws.append(["03_Mamu-B_028_01_01_01", 100, 1, None, 60])
        ws.append(["03_Mamu-B_012g", 100, 1, None, 55])
        ws.append(["Mamu-DRB1 Alleles", None, None, None, None])
        ws.append(["07_Mamu-DRB1_03_03_01_01", 100, 1, 65, None])
        ws.append(["07_Mamu-DRB1_03_12_01_01", 100, 1, None, 45])
        ws.append(["Mamu-DQA Alleles", None, None, None, None])
        ws.append(["09_Mamu-DQA1_26_01", 100, 1, 100, None])
        ws.append(["09_Mamu-DQA1_23_02", 100, 1, None, 95])
        ws.append(["Mamu-DQB Alleles", None, None, None, None])
        ws.append(["10_Mamu-DQB1_18g3", 100, 1, 110, None])
        ws.append(["10_Mamu-DQB1_06g1", 100, 1, None, 105])
        ws.append(["Mamu-DPA Alleles", None, None, None, None])
        ws.append(["11_Mamu-DPA1_02g1", 100, 1, 120, 30])
        ws.append(["11_Mamu-DPA1_02g3", 100, 1, None, 90])
        ws.append(["Mamu-DPB Alleles", None, None, None, None])
        ws.append(["12_Mamu-DPB1_15g", 100, 1, 125, None])
        ws.append(["12_Mamu-DPB1_07g1", 100, 1, None, 98])
        wb.create_sheet("Full Sequencing Results 2")
        wb.save(path)
        return path

    def test_extract_blinds_truth_and_preserves_read_counts(self):
        with tempfile.TemporaryDirectory() as temp:
            workbook = self.make_synthetic_snprc_workbook(Path(temp))
            extracted = lab.extract_workbook(workbook)

        self.assertEqual([sample["gs_id"] for sample in extracted["samples"]], ["LC1729", "LC1730"])
        truth = extracted["truth_calls"]
        self.assertEqual(truth["LC1729"]["MHC-A"], ["A002.01", "A002.01"])
        self.assertEqual(truth["LC1730"]["MHC-DPB"], ["07g1", "08_01"])
        observations = extracted["prompt_input"]["observations"]
        self.assertIn(
            {
                "sample_id": "LC1729",
                "client_id": "44470",
                "report_locus": "MHC-A",
                "source_locus": "Mamu-A1",
                "genotype": "01_Mamu-A1_002g",
                "reads": 90,
                "sheet": "Full Sequencing Results 1",
                "row": 22,
                "sample_mapped_reads": 1000,
                "read_fraction": 0.09,
            },
            observations,
        )
        prompt_json = json.dumps(extracted["prompt_input"], sort_keys=True)
        self.assertNotIn("A002.01", prompt_json)
        self.assertNotIn("B001.01", prompt_json)
        self.assertNotIn("DR09.01", prompt_json)

    def test_locus_mapping_keeps_report_loci_separate(self):
        cases = {
            "01_Mamu-A1_002g": ("MHC-A", "Mamu-A1"),
            "15_Mamu-AG3_02_A1_028": ("MHC-A", "Mamu-AG3"),
            "03_Mamu-B_001g1": ("MHC-B", "Mamu-B"),
            "06_Mamu-I_01g1": ("MHC-B", "Mamu-I"),
            "07_Mamu-DRB1_03_12_01_01": ("MHC-DRB", "Mamu-DRB1"),
            "09_Mamu-DQA1_26_01": ("MHC-DQA", "Mamu-DQA1"),
            "10_Mamu-DQB1_18g3": ("MHC-DQB", "Mamu-DQB1"),
            "11_Mamu-DPA1_02g1": ("MHC-DPA", "Mamu-DPA1"),
            "12_Mamu-DPB1_15g": ("MHC-DPB", "Mamu-DPB1"),
            "13_Mamu-E_02g1": ("context", "Mamu-E"),
        }
        for genotype, expected in cases.items():
            with self.subTest(genotype=genotype):
                self.assertEqual(lab.locus_from_genotype(genotype), expected)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run tests to verify they fail because the lab module does not exist**

Run:

```bash
/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest scripts.tests.test_macaque_mhc_prompt_lab -v
```

Expected: `ImportError` or `ModuleNotFoundError` for `scripts.analysis.macaque_mhc_prompt_lab`.

- [ ] **Step 3: Commit the failing tests**

Run:

```bash
git add scripts/tests/test_macaque_mhc_prompt_lab.py
git commit -m "test: cover generalist macaque MHC prompt extraction"
```

## Task 2: Workbook Extraction Module

**Files:**
- Create: `scripts/analysis/macaque_mhc_prompt_lab.py`
- Modify: `scripts/tests/test_macaque_mhc_prompt_lab.py`

- [ ] **Step 1: Implement extraction, locus mapping, and CLI skeleton**

Create `scripts/analysis/macaque_mhc_prompt_lab.py` with these core definitions:

```python
#!/usr/bin/env python3
"""Evaluation-only prompt lab for de novo macaque MHC haplotyping."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
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


def normalize_truth_locus(raw: str) -> str:
    return "MHC-" + raw.upper()


def extract_sheet(ws) -> tuple[list[dict[str, Any]], dict[str, dict[str, list[str]]], list[dict[str, Any]]]:
    samples = []
    truth: dict[str, dict[str, list[str]]] = defaultdict(lambda: {locus: ["", ""] for locus in REPORT_LOCI})
    observations = []
    columns = sample_columns(ws)
    sample_meta_by_col = {col: metadata_for_column(ws, col) for col in columns}
    for col, meta in sample_meta_by_col.items():
        if meta["gs_id"]:
            samples.append({"gs_id": meta["gs_id"], "client_id": meta["client_id"], "sheet": ws.title, "mapped_reads": meta["mapped_reads"]})

    for row in range(1, ws.max_row + 1):
        label = clean(ws.cell(row, 1).value)
        if not label:
            continue
        truth_match = TRUTH_ROW_RE.match(label)
        if truth_match:
            locus = normalize_truth_locus(truth_match.group(1))
            slot = int(truth_match.group(2)) - 1
            for col, meta in sample_meta_by_col.items():
                sample_id = meta["gs_id"]
                if sample_id:
                    truth[sample_id][locus][slot] = clean(ws.cell(row, col).value)
            continue
        if not is_genotype_label(label):
            continue
        report_locus, source_locus = locus_from_genotype(label)
        if report_locus == "context":
            continue
        for col, meta in sample_meta_by_col.items():
            reads = int_or_none(ws.cell(row, col).value)
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
                "row": row,
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
```

- [ ] **Step 2: Add the `extract` CLI subcommand**

Append this code to `scripts/analysis/macaque_mhc_prompt_lab.py`:

```python
def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def runtime_identity() -> dict[str, Any]:
    return {
        "python": sys.version.split()[0],
        "platform": platform.platform(),
        "executable": sys.executable,
    }


def write_provenance(output_dir: Path, workflow: str, argv: list[str], inputs: list[Path], outputs: list[Path], started: float, options: dict[str, Any], status: str = "completed", stderr: str | None = None) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "schemaVersion": 1,
        "workflowName": workflow,
        "toolName": TOOL_NAME,
        "toolVersion": TOOL_VERSION,
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "argv": argv,
        "reproducibleShellCommand": " ".join(argv),
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
        {"workbook": str(workbook), "outputDir": str(out)},
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
```

- [ ] **Step 3: Run tests and make them pass**

Run:

```bash
/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest scripts.tests.test_macaque_mhc_prompt_lab -v
```

Expected: two tests pass.

- [ ] **Step 4: Run extraction against the real SNPRC workbook**

Run:

```bash
/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 scripts/analysis/macaque_mhc_prompt_lab.py extract \
  --workbook /Users/dho/Downloads/30783_SNPRC22_MHC_Genotype_Report_31Dec24.xlsx \
  --output-dir outputs/macaque-mhc-prompt-lab/iteration-001
```

Expected: `prompt_input.json`, `truth_calls.json`, `samples.json`, and `extract.provenance.json` are created under `outputs/macaque-mhc-prompt-lab/iteration-001/`.

- [ ] **Step 5: Inspect extracted counts**

Run:

```bash
/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 - <<'PY'
import json
from pathlib import Path
root = Path("outputs/macaque-mhc-prompt-lab/iteration-001")
prompt = json.loads((root / "prompt_input.json").read_text())
truth = json.loads((root / "truth_calls.json").read_text())
print("samples", len(prompt["samples"]))
print("observations", len(prompt["observations"]))
print("truth_samples", len(truth))
print("loci", sorted({row["report_locus"] for row in prompt["observations"]}))
PY
```

Expected: sample count and truth sample count are nonzero, observations are nonzero, and loci include all seven report loci.

- [ ] **Step 6: Commit extraction implementation**

Run:

```bash
git add scripts/analysis/macaque_mhc_prompt_lab.py scripts/tests/test_macaque_mhc_prompt_lab.py
git commit -m "feat: extract blinded macaque MHC prompt evidence"
```

## Task 3: Generalist Prompt Template And Prompt Rendering

**Files:**
- Create: `scripts/analysis/prompts/generalist_macaque_mhc_haplotyping_v1.md`
- Modify: `scripts/analysis/macaque_mhc_prompt_lab.py`
- Modify: `scripts/tests/test_macaque_mhc_prompt_lab.py`

- [ ] **Step 1: Add prompt-rendering test**

Add this test method to `MacaqueMHCPromptLabTests`:

```python
    def test_render_prompt_includes_generalist_rules_and_blinded_input(self):
        prompt_template = "# Prompt\n\n{{PROMPT_INPUT_JSON}}\n"
        prompt_input = {
            "schema_version": 1,
            "dataset": "synthetic.xlsx",
            "instructions": {"truth_blinded": True, "report_loci": lab.REPORT_LOCI},
            "samples": [{"gs_id": "LC1729", "client_id": "44470"}],
            "observations": [{"sample_id": "LC1729", "report_locus": "MHC-A", "genotype": "01_Mamu-A1_002g", "reads": 90}],
        }
        rendered = lab.render_prompt_text(prompt_template, prompt_input)
        self.assertIn('"truth_blinded": true', rendered)
        self.assertIn("01_Mamu-A1_002g", rendered)
        self.assertNotIn("A002.01", rendered)
```

- [ ] **Step 2: Create the prompt template**

Create `scripts/analysis/prompts/generalist_macaque_mhc_haplotyping_v1.md`:

```markdown
# Generalist Macaque MHC Haplotyping Specialist Prompt v1

You are a macaque MHC haplotyping specialist reconstructing de novo haplotypes from cohort genotype/read-count evidence. Use the MCM specialist prompt only as an example of careful evidence review. Do not assume this dataset has MCM M1-M7 haplotypes, do not assume a small fixed haplotype vocabulary, and do not assume intact MHC-A-through-MHC-DP haplotypes.

## Core Rules

- The input is blinded. Human-curated haplotype names are not supplied and must not be invented from memory.
- Define haplotypes de novo within this dataset by shared genotype patterns.
- Report these loci separately: `MHC-A`, `MHC-B`, `MHC-DRB`, `MHC-DQA`, `MHC-DQB`, `MHC-DPA`, `MHC-DPB`.
- Treat `MHC-DQA`, `MHC-DQB`, `MHC-DPA`, and `MHC-DPB` as separate report targets. DQ/DP adjacency can support interpretation, but it must not collapse these loci into a single DQ or DP call.
- MHC-A labels should include an abbreviated high-confidence A1 genotype when available because A1 alleles are biologically informative.
- MHC-B and MHC-DRB labels should use compact informative genotype-pattern names; do not assume the lowest-numbered allele is always the best biological label.
- High-read genotypes observed repeatedly across samples are stronger haplotype-defining evidence than low-read, inconsistent genotypes.
- Low-read genotypes may drop out in samples that otherwise share the same haplotype. Do not split haplotypes solely because a weak genotype is missing.
- If more than two coherent haplotype patterns are needed for one sample/locus, mark the sample/locus unresolved rather than forcing a best-two call.

## De Novo Haplotype Process

For each report locus:

1. Build genotype patterns from the observed read-count rows.
2. Identify samples that appear homozygous or near-homozygous. Use them as initial haplotype seeds.
3. Find heterozygous samples where one genotype pattern matches a seeded haplotype. Assign the remaining coherent high-read genotypes as a candidate second haplotype.
4. Add defensible candidates to the haplotype set and iterate.
5. Revisit earlier samples with the expanded haplotype set.
6. Stop when no new defensible haplotypes can be defined.
7. Mark ambiguous samples as unresolved with a short reason.

## Output JSON

Return only JSON with this shape:

```json
{
  "schema_version": 1,
  "prompt_version": "generalist_macaque_mhc_haplotyping_v1",
  "haplotype_definitions": [
    {
      "locus": "MHC-A",
      "label": "A-A1*002-H01",
      "supporting_genotypes": ["01_Mamu-A1_002g"],
      "seed_samples": ["LC1729"],
      "confidence": "high",
      "rationale": "Shared high-read genotype pattern."
    }
  ],
  "sample_calls": [
    {
      "sample_id": "LC1729",
      "locus": "MHC-A",
      "h1": "A-A1*002-H01",
      "h2": "A-A1*002-H01",
      "status": "called",
      "h1_supporting_genotypes": ["01_Mamu-A1_002g"],
      "h2_supporting_genotypes": ["01_Mamu-A1_002g"],
      "rationale": "Apparent homozygous genotype pattern."
    }
  ],
  "unresolved": [
    {
      "sample_id": "LC0000",
      "locus": "MHC-B",
      "reason": "More than two coherent genotype patterns."
    }
  ]
}
```

Allowed `confidence` values are `high`, `medium`, and `low`. Allowed `status` values are `called`, `partial`, and `unresolved`. Use `?` for unresolved h1 or h2 slots. Every `sample_calls` entry must use a sample ID and locus present in the input.

## Prompt Input

```json
{{PROMPT_INPUT_JSON}}
```
```

- [ ] **Step 3: Implement prompt rendering and `render-prompt` subcommand**

Add these functions and parser entries to `scripts/analysis/macaque_mhc_prompt_lab.py`:

```python
def render_prompt_text(prompt_template: str, prompt_input: dict[str, Any]) -> str:
    prompt_json = json.dumps(prompt_input, indent=2, sort_keys=True)
    return prompt_template.replace("{{PROMPT_INPUT_JSON}}", prompt_json)


def command_render_prompt(args: argparse.Namespace) -> None:
    started = time.time()
    iteration_dir = args.iteration_dir.resolve()
    prompt_path = args.prompt.resolve()
    prompt_input_path = iteration_dir / "prompt_input.json"
    prompt_input = json.loads(prompt_input_path.read_text(encoding="utf-8"))
    rendered = render_prompt_text(prompt_path.read_text(encoding="utf-8"), prompt_input)
    output_path = iteration_dir / "rendered_prompt.md"
    output_path.write_text(rendered, encoding="utf-8")
    write_provenance(
        iteration_dir,
        "render-prompt",
        sys.argv,
        [prompt_path, prompt_input_path],
        [output_path],
        started,
        {"iterationDir": str(iteration_dir), "prompt": str(prompt_path)},
    )
```

In `build_parser()`, add:

```python
    render = sub.add_parser("render-prompt", help="Render the generalist prompt with blinded prompt input.")
    render.add_argument("--iteration-dir", type=Path, required=True)
    render.add_argument("--prompt", type=Path, default=DEFAULT_PROMPT)
    render.set_defaults(func=command_render_prompt)
```

- [ ] **Step 4: Run prompt-rendering tests**

Run:

```bash
/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest scripts.tests.test_macaque_mhc_prompt_lab -v
```

Expected: three tests pass.

- [ ] **Step 5: Render iteration 1 prompt**

Run:

```bash
/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 scripts/analysis/macaque_mhc_prompt_lab.py render-prompt \
  --iteration-dir outputs/macaque-mhc-prompt-lab/iteration-001 \
  --prompt scripts/analysis/prompts/generalist_macaque_mhc_haplotyping_v1.md
```

Expected: `outputs/macaque-mhc-prompt-lab/iteration-001/rendered_prompt.md` and `render-prompt.provenance.json` are created.

- [ ] **Step 6: Commit prompt template and renderer**

Run:

```bash
git add scripts/analysis/macaque_mhc_prompt_lab.py scripts/analysis/prompts/generalist_macaque_mhc_haplotyping_v1.md scripts/tests/test_macaque_mhc_prompt_lab.py
git commit -m "feat: render generalist macaque MHC prompt"
```

## Task 4: Model Output Validation And Import

**Files:**
- Modify: `scripts/analysis/macaque_mhc_prompt_lab.py`
- Modify: `scripts/tests/test_macaque_mhc_prompt_lab.py`

- [ ] **Step 1: Add validation tests**

Add these test methods:

```python
    def test_validate_model_output_accepts_expected_shape(self):
        prompt_input = {
            "samples": [{"gs_id": "LC1729"}],
            "instructions": {"report_loci": ["MHC-A"]},
            "observations": [{"sample_id": "LC1729", "report_locus": "MHC-A", "genotype": "01_Mamu-A1_002g", "reads": 90}],
        }
        output = {
            "schema_version": 1,
            "prompt_version": "generalist_macaque_mhc_haplotyping_v1",
            "haplotype_definitions": [
                {"locus": "MHC-A", "label": "A-A1*002-H01", "supporting_genotypes": ["01_Mamu-A1_002g"], "seed_samples": ["LC1729"], "confidence": "high", "rationale": "seed"}
            ],
            "sample_calls": [
                {"sample_id": "LC1729", "locus": "MHC-A", "h1": "A-A1*002-H01", "h2": "A-A1*002-H01", "status": "called", "h1_supporting_genotypes": ["01_Mamu-A1_002g"], "h2_supporting_genotypes": ["01_Mamu-A1_002g"], "rationale": "called"}
            ],
            "unresolved": [],
        }
        self.assertEqual(lab.validate_model_output(output, prompt_input), [])

    def test_validate_model_output_rejects_unknown_sample_locus_and_genotype(self):
        prompt_input = {
            "samples": [{"gs_id": "LC1729"}],
            "instructions": {"report_loci": ["MHC-A"]},
            "observations": [{"sample_id": "LC1729", "report_locus": "MHC-A", "genotype": "01_Mamu-A1_002g", "reads": 90}],
        }
        output = {
            "schema_version": 1,
            "prompt_version": "generalist_macaque_mhc_haplotyping_v1",
            "haplotype_definitions": [
                {"locus": "MHC-Z", "label": "bad", "supporting_genotypes": ["missing"], "seed_samples": ["LC9999"], "confidence": "high", "rationale": "bad"}
            ],
            "sample_calls": [
                {"sample_id": "LC9999", "locus": "MHC-Z", "h1": "bad", "h2": "?", "status": "called", "h1_supporting_genotypes": ["missing"], "h2_supporting_genotypes": [], "rationale": "bad"}
            ],
            "unresolved": [],
        }
        errors = lab.validate_model_output(output, prompt_input)
        self.assertTrue(any("unknown sample" in error for error in errors))
        self.assertTrue(any("unknown locus" in error for error in errors))
        self.assertTrue(any("unknown genotype" in error for error in errors))
```

- [ ] **Step 2: Implement validation**

Add:

```python
def validate_model_output(output: dict[str, Any], prompt_input: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if output.get("schema_version") != 1:
        errors.append("schema_version must be 1")
    samples = {sample["gs_id"] for sample in prompt_input.get("samples", [])}
    loci = set(prompt_input.get("instructions", {}).get("report_loci", REPORT_LOCI))
    genotypes = {row["genotype"] for row in prompt_input.get("observations", [])}
    for index, definition in enumerate(output.get("haplotype_definitions", [])):
        locus = definition.get("locus")
        if locus not in loci:
            errors.append(f"definition {index} unknown locus {locus}")
        for sample in definition.get("seed_samples", []):
            if sample not in samples:
                errors.append(f"definition {index} unknown sample {sample}")
        for genotype in definition.get("supporting_genotypes", []):
            if genotype not in genotypes:
                errors.append(f"definition {index} unknown genotype {genotype}")
    for index, call in enumerate(output.get("sample_calls", [])):
        sample = call.get("sample_id")
        locus = call.get("locus")
        if sample not in samples:
            errors.append(f"call {index} unknown sample {sample}")
        if locus not in loci:
            errors.append(f"call {index} unknown locus {locus}")
        if call.get("status") not in {"called", "partial", "unresolved"}:
            errors.append(f"call {index} invalid status {call.get('status')}")
        for key in ("h1_supporting_genotypes", "h2_supporting_genotypes"):
            for genotype in call.get(key, []):
                if genotype not in genotypes:
                    errors.append(f"call {index} unknown genotype {genotype}")
    return errors
```

- [ ] **Step 3: Add `import-output` subcommand**

Add:

```python
def command_import_output(args: argparse.Namespace) -> None:
    started = time.time()
    iteration_dir = args.iteration_dir.resolve()
    model_output_path = args.model_output.resolve()
    prompt_input_path = iteration_dir / "prompt_input.json"
    prompt_input = json.loads(prompt_input_path.read_text(encoding="utf-8"))
    output = json.loads(model_output_path.read_text(encoding="utf-8"))
    errors = validate_model_output(output, prompt_input)
    validation_path = iteration_dir / "model_output_validation.json"
    parsed_path = iteration_dir / "parsed_model_output.json"
    write_json(validation_path, {"accepted": not errors, "errors": errors})
    if errors:
        raise SystemExit("model output validation failed: " + "; ".join(errors[:5]))
    write_json(parsed_path, output)
    write_provenance(
        iteration_dir,
        "import-output",
        sys.argv,
        [prompt_input_path, model_output_path],
        [validation_path, parsed_path],
        started,
        {"iterationDir": str(iteration_dir), "modelOutput": str(model_output_path)},
    )
```

In `build_parser()`, add:

```python
    import_output = sub.add_parser("import-output", help="Validate and import a model output JSON file.")
    import_output.add_argument("--iteration-dir", type=Path, required=True)
    import_output.add_argument("--model-output", type=Path, required=True)
    import_output.set_defaults(func=command_import_output)
```

- [ ] **Step 4: Run validation tests**

Run:

```bash
/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest scripts.tests.test_macaque_mhc_prompt_lab -v
```

Expected: five tests pass.

- [ ] **Step 5: Commit validation/import**

Run:

```bash
git add scripts/analysis/macaque_mhc_prompt_lab.py scripts/tests/test_macaque_mhc_prompt_lab.py
git commit -m "feat: validate generalist macaque MHC model output"
```

## Task 5: Concordance Scoring And Label Mapping

**Files:**
- Modify: `scripts/analysis/macaque_mhc_prompt_lab.py`
- Modify: `scripts/tests/test_macaque_mhc_prompt_lab.py`

- [ ] **Step 1: Add scoring tests**

Add:

```python
    def test_score_maps_predicted_labels_to_human_labels(self):
        truth = {
            "LC1729": {"MHC-A": ["A002.01", "A002.01"]},
            "LC1730": {"MHC-A": ["A008.01", "A004.01"]},
        }
        output = {
            "sample_calls": [
                {"sample_id": "LC1729", "locus": "MHC-A", "h1": "A-A1*002-H01", "h2": "A-A1*002-H01", "status": "called"},
                {"sample_id": "LC1730", "locus": "MHC-A", "h1": "A-A1*008-H02", "h2": "A-A1*004-H03", "status": "called"},
            ]
        }
        score = lab.score_predictions(output, truth, loci=["MHC-A"])
        self.assertEqual(score["overall"]["slot_concordance"], 1.0)
        self.assertEqual(score["overall"]["pair_concordance"], 1.0)
        self.assertEqual(score["loci"]["MHC-A"]["label_mapping"]["A-A1*002-H01"], "A002.01")

    def test_score_counts_unresolved_and_false_merge(self):
        truth = {
            "LC1": {"MHC-A": ["A001.01", "A002.01"]},
            "LC2": {"MHC-A": ["A001.01", "A003.01"]},
        }
        output = {
            "sample_calls": [
                {"sample_id": "LC1", "locus": "MHC-A", "h1": "A-shared", "h2": "?", "status": "partial"},
                {"sample_id": "LC2", "locus": "MHC-A", "h1": "A-shared", "h2": "A-shared", "status": "called"},
            ]
        }
        score = lab.score_predictions(output, truth, loci=["MHC-A"])
        self.assertGreater(score["overall"]["unresolved_rate"], 0)
        self.assertGreaterEqual(score["loci"]["MHC-A"]["false_merge_count"], 1)
```

- [ ] **Step 2: Implement scoring helpers and max-weight mapping**

Add:

```python
def call_index(output: dict[str, Any]) -> dict[tuple[str, str], dict[str, Any]]:
    return {(call.get("sample_id"), call.get("locus")): call for call in output.get("sample_calls", [])}


def label_counter(labels: list[str]) -> Counter:
    return Counter(label for label in labels if label and label != "?")


def max_weight_label_mapping(weights: dict[str, dict[str, int]]) -> dict[str, str]:
    left_labels = sorted(weights)
    right_labels = sorted({right for row in weights.values() for right, weight in row.items() if weight > 0})
    if not left_labels or not right_labels:
        return {}
    source = 0
    left_start = 1
    right_start = left_start + len(left_labels)
    sink = right_start + len(right_labels)
    graph: list[list[dict[str, Any]]] = [[] for _ in range(sink + 1)]

    def add_edge(src: int, dst: int, capacity: int, cost: int) -> None:
        forward = {"to": dst, "rev": len(graph[dst]), "cap": capacity, "cost": cost, "initial": capacity}
        reverse = {"to": src, "rev": len(graph[src]), "cap": 0, "cost": -cost, "initial": 0}
        graph[src].append(forward)
        graph[dst].append(reverse)

    for offset in range(len(left_labels)):
        add_edge(source, left_start + offset, 1, 0)
    for offset in range(len(right_labels)):
        add_edge(right_start + offset, sink, 1, 0)
    right_index = {label: offset for offset, label in enumerate(right_labels)}
    for left_offset, left in enumerate(left_labels):
        for right, weight in weights.get(left, {}).items():
            if weight > 0:
                add_edge(left_start + left_offset, right_start + right_index[right], 1, -weight)

    while True:
        dist = [10**12] * len(graph)
        prev_node = [-1] * len(graph)
        prev_edge = [-1] * len(graph)
        in_queue = [False] * len(graph)
        queue = [source]
        dist[source] = 0
        in_queue[source] = True
        for node in queue:
            in_queue[node] = False
            for edge_index, edge in enumerate(graph[node]):
                if edge["cap"] <= 0:
                    continue
                next_node = edge["to"]
                next_dist = dist[node] + edge["cost"]
                if next_dist < dist[next_node]:
                    dist[next_node] = next_dist
                    prev_node[next_node] = node
                    prev_edge[next_node] = edge_index
                    if not in_queue[next_node]:
                        queue.append(next_node)
                        in_queue[next_node] = True
        if dist[sink] >= 0 or prev_node[sink] == -1:
            break
        node = sink
        while node != source:
            edge = graph[prev_node[node]][prev_edge[node]]
            edge["cap"] -= 1
            graph[node][edge["rev"]]["cap"] += 1
            node = prev_node[node]

    mapping: dict[str, str] = {}
    for left_offset, left in enumerate(left_labels):
        node = left_start + left_offset
        for edge in graph[node]:
            if right_start <= edge["to"] < sink and edge["initial"] == 1 and edge["cap"] == 0:
                mapping[left] = right_labels[edge["to"] - right_start]
    return mapping


def mapping_weights(output: dict[str, Any], truth: dict[str, dict[str, list[str]]], locus: str) -> dict[str, dict[str, int]]:
    weights: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    calls = call_index(output)
    for sample, loci in truth.items():
        truth_labels = label_counter(loci.get(locus, []))
        call = calls.get((sample, locus))
        if not call:
            continue
        predicted_labels = label_counter([call.get("h1", "?"), call.get("h2", "?")])
        for pred_label, pred_count in predicted_labels.items():
            for truth_label, truth_count in truth_labels.items():
                weights[pred_label][truth_label] += min(pred_count, truth_count)
    return {left: dict(row) for left, row in weights.items()}


def score_predictions(output: dict[str, Any], truth: dict[str, dict[str, list[str]]], loci: list[str] | None = None) -> dict[str, Any]:
    loci = loci or REPORT_LOCI
    calls = call_index(output)
    result = {"loci": {}, "overall": {}}
    total_slots = total_slot_hits = total_pairs = total_pair_hits = unresolved = 0
    for locus in loci:
        weights = mapping_weights(output, truth, locus)
        label_mapping = max_weight_label_mapping(weights)
        locus_slots = locus_slot_hits = locus_pairs = locus_pair_hits = locus_unresolved = 0
        mapped_to_pred: dict[str, set[str]] = defaultdict(set)
        for pred, human in label_mapping.items():
            mapped_to_pred[human].add(pred)
        for sample, loci_truth in truth.items():
            truth_pair = label_counter(loci_truth.get(locus, []))
            if not truth_pair:
                continue
            call = calls.get((sample, locus))
            predicted_raw = [call.get("h1", "?"), call.get("h2", "?")] if call else ["?", "?"]
            if "?" in predicted_raw or not call or call.get("status") == "unresolved":
                locus_unresolved += 1
            predicted_pair = label_counter([label_mapping.get(label, label) for label in predicted_raw])
            slot_hits = sum((predicted_pair & truth_pair).values())
            locus_slot_hits += slot_hits
            locus_slots += 2
            locus_pair_hits += 1 if predicted_pair == truth_pair else 0
            locus_pairs += 1
        false_merge_count = sum(1 for row in weights.values() if sum(1 for value in row.values() if value > 0) > 1)
        false_split_count = sum(
            1
            for human_label in {label for row in weights.values() for label in row}
            if sum(1 for row in weights.values() if row.get(human_label, 0) > 0) > 1
        )
        result["loci"][locus] = {
            "slot_concordance": round(locus_slot_hits / locus_slots, 6) if locus_slots else None,
            "pair_concordance": round(locus_pair_hits / locus_pairs, 6) if locus_pairs else None,
            "unresolved_rate": round(locus_unresolved / locus_pairs, 6) if locus_pairs else None,
            "false_merge_count": false_merge_count,
            "false_split_count": false_split_count,
            "label_mapping": label_mapping,
            "slot_hits": locus_slot_hits,
            "slot_total": locus_slots,
            "pair_hits": locus_pair_hits,
            "pair_total": locus_pairs,
        }
        total_slots += locus_slots
        total_slot_hits += locus_slot_hits
        total_pairs += locus_pairs
        total_pair_hits += locus_pair_hits
        unresolved += locus_unresolved
    result["overall"] = {
        "slot_concordance": round(total_slot_hits / total_slots, 6) if total_slots else None,
        "pair_concordance": round(total_pair_hits / total_pairs, 6) if total_pairs else None,
        "unresolved_rate": round(unresolved / total_pairs, 6) if total_pairs else None,
        "slot_hits": total_slot_hits,
        "slot_total": total_slots,
        "pair_hits": total_pair_hits,
        "pair_total": total_pairs,
    }
    return result
```

- [ ] **Step 3: Add `score` subcommand**

Add:

```python
def markdown_score_report(score: dict[str, Any]) -> str:
    lines = ["# Generalist Macaque MHC Prompt Score", ""]
    overall = score["overall"]
    lines.append(f"- Slot concordance: {overall['slot_concordance']}")
    lines.append(f"- Pair concordance: {overall['pair_concordance']}")
    lines.append(f"- Unresolved rate: {overall['unresolved_rate']}")
    lines.append("")
    lines.append("| Locus | Slot concordance | Pair concordance | Unresolved rate | False merges | False splits |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: |")
    for locus, item in score["loci"].items():
        lines.append(f"| {locus} | {item['slot_concordance']} | {item['pair_concordance']} | {item['unresolved_rate']} | {item['false_merge_count']} | {item['false_split_count']} |")
    lines.append("")
    return "\n".join(lines)


def command_score(args: argparse.Namespace) -> None:
    started = time.time()
    iteration_dir = args.iteration_dir.resolve()
    truth_path = iteration_dir / "truth_calls.json"
    parsed_path = iteration_dir / "parsed_model_output.json"
    truth = json.loads(truth_path.read_text(encoding="utf-8"))
    output = json.loads(parsed_path.read_text(encoding="utf-8"))
    score = score_predictions(output, truth)
    score_json = iteration_dir / "score.json"
    score_md = iteration_dir / "score.md"
    write_json(score_json, score)
    score_md.write_text(markdown_score_report(score), encoding="utf-8")
    write_provenance(
        iteration_dir,
        "score",
        sys.argv,
        [truth_path, parsed_path],
        [score_json, score_md],
        started,
        {"iterationDir": str(iteration_dir)},
    )
```

In `build_parser()`, add:

```python
    score = sub.add_parser("score", help="Score parsed model output against held-out human calls.")
    score.add_argument("--iteration-dir", type=Path, required=True)
    score.set_defaults(func=command_score)
```

- [ ] **Step 4: Run scoring tests**

Run:

```bash
/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest scripts.tests.test_macaque_mhc_prompt_lab -v
```

Expected: seven tests pass.

- [ ] **Step 5: Commit scoring**

Run:

```bash
git add scripts/analysis/macaque_mhc_prompt_lab.py scripts/tests/test_macaque_mhc_prompt_lab.py
git commit -m "feat: score de novo macaque MHC haplotype calls"
```

## Task 6: Optional OpenAI Runner And Iteration Orchestration

**Files:**
- Modify: `scripts/analysis/macaque_mhc_prompt_lab.py`
- Modify: `scripts/tests/test_macaque_mhc_prompt_lab.py`

- [ ] **Step 1: Add tests for safe API-key handling and iteration orchestration**

Add:

```python
    def test_openai_payload_uses_json_prompt_and_configurable_model(self):
        payload = lab.openai_request_payload("system", "user", model="gpt-5.5", max_output_tokens=1234, reasoning_effort="medium")
        self.assertEqual(payload["model"], "gpt-5.5")
        self.assertEqual(payload["input"][0]["role"], "system")
        self.assertEqual(payload["input"][1]["content"], "user")
        self.assertEqual(payload["max_output_tokens"], 1234)
        self.assertEqual(payload["reasoning"]["effort"], "medium")

    def test_run_iteration_requires_key_only_when_running_provider(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            workbook = self.make_synthetic_snprc_workbook(root)
            iteration_dir = root / "iteration"
            lab.run_iteration(workbook=workbook, iteration_dir=iteration_dir, prompt_path=None, run_provider=False, model="gpt-5.5")
            self.assertTrue((iteration_dir / "prompt_input.json").is_file())
            self.assertTrue((iteration_dir / "rendered_prompt.md").is_file())
```

- [ ] **Step 2: Implement OpenAI payload and response extraction**

Add:

```python
def openai_request_payload(system_prompt: str, user_prompt: str, model: str, max_output_tokens: int, reasoning_effort: str | None) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "model": model,
        "input": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "max_output_tokens": max_output_tokens,
        "temperature": 0,
    }
    if reasoning_effort:
        payload["reasoning"] = {"effort": reasoning_effort}
    return payload


def extract_response_text(response: dict[str, Any]) -> str:
    if "output_text" in response and isinstance(response["output_text"], str):
        return response["output_text"]
    chunks = []
    for item in response.get("output", []):
        for content in item.get("content", []):
            if content.get("type") in {"output_text", "text"} and isinstance(content.get("text"), str):
                chunks.append(content["text"])
    if chunks:
        return "\n".join(chunks)
    raise ValueError("OpenAI response did not contain output text")
```

- [ ] **Step 3: Implement provider call using stdlib HTTP**

Add:

```python
def call_openai_responses(api_key: str, payload: dict[str, Any]) -> dict[str, Any]:
    import urllib.error
    import urllib.request

    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        "https://api.openai.com/v1/responses",
        data=data,
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"OpenAI request failed with HTTP {error.code}: {body[:2000]}") from error
```

- [ ] **Step 4: Add `run-openai` and `run-iteration` commands**

Add:

```python
def command_run_openai(args: argparse.Namespace) -> None:
    started = time.time()
    iteration_dir = args.iteration_dir.resolve()
    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        raise SystemExit("OPENAI_API_KEY is required for run-openai")
    rendered_prompt = (iteration_dir / "rendered_prompt.md").read_text(encoding="utf-8")
    payload = openai_request_payload(
        "Return only the requested JSON object. Do not include markdown.",
        rendered_prompt,
        model=args.model,
        max_output_tokens=args.max_output_tokens,
        reasoning_effort=args.reasoning_effort,
    )
    response = call_openai_responses(api_key, payload)
    raw_response_path = iteration_dir / "openai_response.json"
    model_output_path = iteration_dir / "model_output.json"
    write_json(raw_response_path, response)
    model_output_path.write_text(extract_response_text(response).strip() + "\n", encoding="utf-8")
    write_provenance(
        iteration_dir,
        "run-openai",
        sys.argv,
        [iteration_dir / "rendered_prompt.md"],
        [raw_response_path, model_output_path],
        started,
        {"iterationDir": str(iteration_dir), "model": args.model, "maxOutputTokens": args.max_output_tokens, "reasoningEffort": args.reasoning_effort},
    )


def run_iteration(workbook: Path, iteration_dir: Path, prompt_path: Path | None, run_provider: bool, model: str) -> None:
    prompt_path = prompt_path or DEFAULT_PROMPT
    command_extract(argparse.Namespace(workbook=workbook, output_dir=iteration_dir))
    command_render_prompt(argparse.Namespace(iteration_dir=iteration_dir, prompt=prompt_path))
    if run_provider:
        command_run_openai(argparse.Namespace(iteration_dir=iteration_dir, model=model, max_output_tokens=24000, reasoning_effort="medium"))
        command_import_output(argparse.Namespace(iteration_dir=iteration_dir, model_output=iteration_dir / "model_output.json"))
        command_score(argparse.Namespace(iteration_dir=iteration_dir))


def command_run_iteration(args: argparse.Namespace) -> None:
    run_iteration(args.workbook.resolve(), args.iteration_dir.resolve(), args.prompt.resolve(), args.run_provider, args.model)
```

In `build_parser()`, add:

```python
    run_openai = sub.add_parser("run-openai", help="Call OpenAI Responses API with rendered_prompt.md.")
    run_openai.add_argument("--iteration-dir", type=Path, required=True)
    run_openai.add_argument("--model", default="gpt-5.5")
    run_openai.add_argument("--max-output-tokens", type=int, default=24000)
    run_openai.add_argument("--reasoning-effort", default="medium")
    run_openai.set_defaults(func=command_run_openai)

    run_iteration = sub.add_parser("run-iteration", help="Extract, render, optionally run provider, import, and score one iteration.")
    run_iteration.add_argument("--workbook", type=Path, default=DEFAULT_SNPRC_WORKBOOK)
    run_iteration.add_argument("--iteration-dir", type=Path, required=True)
    run_iteration.add_argument("--prompt", type=Path, default=DEFAULT_PROMPT)
    run_iteration.add_argument("--model", default="gpt-5.5")
    run_iteration.add_argument("--run-provider", action="store_true")
    run_iteration.set_defaults(func=command_run_iteration)
```

- [ ] **Step 5: Run all prompt lab tests**

Run:

```bash
/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 -m unittest scripts.tests.test_macaque_mhc_prompt_lab -v
```

Expected: nine tests pass.

- [ ] **Step 6: Commit runner/orchestration**

Run:

```bash
git add scripts/analysis/macaque_mhc_prompt_lab.py scripts/tests/test_macaque_mhc_prompt_lab.py
git commit -m "feat: orchestrate generalist macaque MHC prompt iterations"
```

## Task 7: Run Iteration 1 And Review Performance

**Files:**
- Generated only: `outputs/macaque-mhc-prompt-lab/iteration-001/*`
- Modify prompt only if iterating: `scripts/analysis/prompts/generalist_macaque_mhc_haplotyping_v1.md`

- [ ] **Step 1: Build the iteration package**

Run:

```bash
/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 scripts/analysis/macaque_mhc_prompt_lab.py run-iteration \
  --workbook /Users/dho/Downloads/30783_SNPRC22_MHC_Genotype_Report_31Dec24.xlsx \
  --iteration-dir outputs/macaque-mhc-prompt-lab/iteration-001 \
  --prompt scripts/analysis/prompts/generalist_macaque_mhc_haplotyping_v1.md \
  --model gpt-5.5
```

Expected: extraction and prompt rendering complete without contacting a provider.

- [ ] **Step 2: Run the model if API access is available**

Run:

```bash
OPENAI_API_KEY="$OPENAI_API_KEY" /Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 scripts/analysis/macaque_mhc_prompt_lab.py run-openai \
  --iteration-dir outputs/macaque-mhc-prompt-lab/iteration-001 \
  --model gpt-5.5 \
  --reasoning-effort medium \
  --max-output-tokens 24000
```

Expected with API access: `openai_response.json`, `model_output.json`, and `run-openai.provenance.json` are created. Expected without API access: command exits with `OPENAI_API_KEY is required for run-openai`; stop and report the blocker.

- [ ] **Step 3: Import model output**

Run:

```bash
/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 scripts/analysis/macaque_mhc_prompt_lab.py import-output \
  --iteration-dir outputs/macaque-mhc-prompt-lab/iteration-001 \
  --model-output outputs/macaque-mhc-prompt-lab/iteration-001/model_output.json
```

Expected: `parsed_model_output.json`, `model_output_validation.json`, and `import-output.provenance.json` are created.

- [ ] **Step 4: Score model output**

Run:

```bash
/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 scripts/analysis/macaque_mhc_prompt_lab.py score \
  --iteration-dir outputs/macaque-mhc-prompt-lab/iteration-001
```

Expected: `score.json`, `score.md`, and `score.provenance.json` are created.

- [ ] **Step 5: Summarize iteration 1 performance**

Run:

```bash
/Users/dho/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 - <<'PY'
import json
from pathlib import Path
score = json.loads(Path("outputs/macaque-mhc-prompt-lab/iteration-001/score.json").read_text())
print(json.dumps(score["overall"], indent=2, sort_keys=True))
for locus, item in score["loci"].items():
    print(locus, item["slot_concordance"], item["pair_concordance"], item["unresolved_rate"], item["false_merge_count"], item["false_split_count"])
PY
```

Expected: prints overall slot concordance, pair concordance, unresolved rate, and per-locus scores.

- [ ] **Step 6: Decide next iteration**

If slot concordance is below 0.90, inspect `score.md`, `parsed_model_output.json`, and representative discordant samples. Update only `scripts/analysis/prompts/generalist_macaque_mhc_haplotyping_v1.md`, increment the visible prompt version text to `v2`, and rerun Task 7 with `iteration-002`.

- [ ] **Step 7: Commit prompt changes only after a useful iteration**

If the prompt changes because the score review identifies a concrete prompt weakness, run:

```bash
git add scripts/analysis/prompts/generalist_macaque_mhc_haplotyping_v1.md
git commit -m "prompt: refine generalist macaque MHC haplotyping rules"
```

## Self-Review Checklist

- Spec coverage: The plan extracts blinded genotype evidence, holds out human calls, creates a new generalist prompt, validates structured output, scores against held-out truth, records provenance, and supports iteration.
- Non-goals: No app UI, CLI production commands, presets, or production workflow code are touched.
- Provenance: Each generated evaluation step writes a provenance JSON with argv, options, runtime, inputs, outputs, checksums, exit status, and wall time.
- Testability: Unit tests use synthetic data and do not require external workbooks or API keys.
- Remaining execution risk: Provider execution requires `OPENAI_API_KEY`; without it, extraction/rendering can complete but concordance scoring is blocked until a model output JSON is supplied.

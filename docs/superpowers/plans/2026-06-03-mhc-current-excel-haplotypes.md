# MHC Current Workbook Haplotype Decoration

> **For:** Codex executing implementation in `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/mhc-current-excel-haplotypes`
> **Goal:** Preserve the raw generated workbook as the primary artifact, and produce a client-ready decorated `current.xlsx` workbook for MCM haplotyping runs.
> **Design:** `docs/superpowers/specs/2026-06-03-mhc-current-excel-haplotypes-design.md`

## Overview

The MHC genotyping workflow already writes a primary Excel workbook and copies it to `artifacts/workbooks/current.xlsx`. That copy must remain byte-for-byte identical when haplotyping is not performed.

For MCM haplotyping runs, replace the current workbook copy step with a decorated workbook generation step. The primary workbook remains the raw/generated report. The decorated `current.xlsx` should use the example report structure:

1. `Interpretation Guide`
2. `MHC Alleles Per MHC Haplotype`
3. `Abbreviated Haplotypes`
4. `Full Sequencing Results 1`
5. `Custom Sort`

The decorated workbook must include haplotype assignments and use the existing MCM Budde haplotype color scheme. It must have provenance that points at the final stored `artifacts/workbooks/current.xlsx`.

## Constraints

- Do not change the no-haplotyping behavior: `current.xlsx` stays a naked copy of the primary workbook.
- Scope decorated workbook generation to MCM definition sets only.
- Do not implement InRh/rhesus decoration in this change.
- Use `apply_patch` for manual edits.
- Add tests before production code changes.
- Preserve or improve provenance for the new scientific workbook artifact.

## Files To Change

- `Tests/LungfishWorkflowTests/ONTBarcodeDemuxGenotypingPipelineTests.swift`
- `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift`

## Phase 1: Add Failing Report-Script Unit Test

Add a test in `Tests/LungfishWorkflowTests/ONTBarcodeDemuxGenotypingPipelineTests.swift` near the existing report-script tests.

Test name:

```swift
func testReportScriptWritesMCMClientCurrentWorkbook() throws
```

Test setup:

- Use `writeReportScript(to:)` to emit the embedded Python report script.
- Create minimal synthetic inputs in a temporary directory:
  - `genotypes.csv`
  - `samples.csv`
  - `stats.json`
  - `reference.fasta`
  - `barcodes.csv`
  - `haplotypes.json`
  - `haplotype-definition.json`
  - a placeholder `primary.xlsx`
- Invoke the script with a new `--client-current-workbook` flag.

Expected command shape:

```swift
try runPython([
    scriptURL.path,
    "--client-current-workbook",
    "--genotypes-csv", genotypesCSV.path,
    "--samples-csv", samplesCSV.path,
    "--stats-json", statsJSON.path,
    "--reference-fasta", referenceFASTA.path,
    "--barcode-definitions", barcodesCSV.path,
    "--output-xlsx", currentWorkbook.path,
    "--provenance-json", provenanceJSON.path,
    "--analysis-name", "barcode08-mhc",
    "--run-name", "barcode08-mhc",
    "--haplotype-analysis-json", haplotypesJSON.path,
    "--haplotype-definition-json", definitionJSON.path,
    "--primary-workbook", primaryWorkbook.path
])
```

Initial expected failure:

- Python argparse rejects `--client-current-workbook`.

Add a Python inspection helper similar to `inspectHaplotypeWorkbook(_:)`:

```swift
private func inspectMCMClientCurrentWorkbook(_ url: URL) throws -> [String: AnyHashable]
```

Use `openpyxl` and JSON output to assert:

- Sheet names are exactly:
  - `Interpretation Guide`
  - `MHC Alleles Per MHC Haplotype`
  - `Abbreviated Haplotypes`
  - `Full Sequencing Results 1`
  - `Custom Sort`
- `Abbreviated Haplotypes` contains a row for sample `DW472`.
- That row has whole-animal `Haplotype 1 == "M1"` and `Haplotype 2 == "M2"`.
- `Full Sequencing Results 1` contains row labels `MHC-A Haplotype 1` and `MHC-A Haplotype 2`.
- Sample `DW472` has `M1A` and `M2A` on those two full-result rows.
- `MHC Alleles Per MHC Haplotype` includes M1/M2 allele definitions from the definition JSON.
- At least one haplotype cell has a non-default fill.
- The sidecar provenance JSON contains `outputWorkbook` ending in `current.xlsx`.

## Phase 2: Implement Python Client Current Workbook Mode

Modify the embedded Python `reportScript` inside `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift`.

### Argparse

Add:

```python
parser.add_argument("--client-current-workbook", action="store_true")
parser.add_argument("--haplotype-definition-json", type=Path)
parser.add_argument("--primary-workbook", type=Path)
```

### Load Haplotype Definition

Add:

```python
def load_haplotype_definition(path: Path | None) -> dict:
    if not path:
        return {}
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)
```

Support both likely definition shapes:

- `{"loci": [{"name": "...", "haplotypes": [...]}]}`
- `{"haplotypes": [...]}` with per-haplotype allele/locus data

Keep extraction defensive: missing fields produce empty tables, not crashes.

### Haplotype Style Helpers

Mirror `Sources/LungfishCore/Genotype/HaplotypeColorToken.swift` Budde MCM colors:

```python
MCM_HAPLOTYPE_STYLES = {
    "M1": {"fill": "000000", "font": "FFFFFF"},
    "M2": {"fill": "FF0000", "font": "FFFFFF"},
    "M3": {"fill": "0070C0", "font": "FFFFFF"},
    "M4": {"fill": "00B050", "font": "FFFFFF"},
    "M5": {"fill": "FFFF00", "font": "000000"},
    "M6": {"fill": "A6A6A6", "font": "000000"},
    "M7": {"fill": "7030A0", "font": "FFFFFF"},
}
```

Helpers:

```python
def mcm_family(value) -> str | None
def haplotype_style_key(value) -> str | None
def apply_haplotype_cell_style(cell, value, styles) -> None
```

Style direct cell values rather than relying on conditional formatting.

### Workbook Builders

Add:

```python
def build_mcm_client_current_workbook(...):
    wb = Workbook()
    # Create sheets in required order.
    return wb
```

Internal sheet helpers:

- `write_interpretation_guide(ws)`
- `write_mcm_alleles_per_haplotype(ws, haplotype_definition)`
- `write_abbreviated_haplotypes(ws, sample_order, sample_map, stats, calls_by_sample_locus, styles)`
- `write_full_sequencing_results(ws, sample_order, sample_map, stats, genotype_rows, calls_by_sample_locus, styles)`
- `write_custom_sort(ws, sample_order, sample_map, stats, calls_by_sample_locus, styles)`

Formatting expectations:

- Freeze panes:
  - `Abbreviated Haplotypes`: `D2`
  - `Full Sequencing Results 1`: `D21`
  - `Custom Sort`: `D2`
- Bold headers and row labels.
- Set usable column widths.
- Use fills/fonts for haplotype cells.
- Keep comments/status visible for `ERR:` or missing haplotype calls.

Haplotype rows:

- Per-locus values come from `haplotype1` and `haplotype2` in the haplotype analysis JSON.
- Whole-animal haplotypes are:
  - Same family across available loci: `M1`, `M2`, etc.
  - Mixed families across loci: `recM1M3` in locus order, de-duplicated.
  - Missing/empty/error-only: `?`

### Main Dispatch

In `main()`, dispatch before comparison/generic workbook generation:

```python
if args.client_current_workbook:
    haplotype_definition = load_haplotype_definition(args.haplotype_definition_json)
    wb = build_mcm_client_current_workbook(...)
    audit_rows = 0
elif args.comparison_workbook:
    wb, audit_rows = build_template_workbook(...)
else:
    wb = build_generic_workbook(...)
    audit_rows = 0
```

Update `write_provenance(...)` to include:

- `mode: "mcm-client-current"`
- `primaryWorkbook` when supplied
- `haplotypeDefinitionJson` when supplied
- `outputWorkbook` equal to the final `current.xlsx` path

## Phase 3: Add Failing Full Pipeline Test

Add:

```swift
func testRunCreatesDecoratedCurrentWorkbookForMCMHaplotypingAndKeepsPrimaryRaw() async throws
```

Base the setup on the existing full pipeline/provenance MCM haplotyping test.

Assertions:

- `manifest.primaryWorkbook.path` points at the primary report.
- `manifest.currentWorkbook.path` points at `artifacts/workbooks/current.xlsx`.
- Primary and current workbook bytes differ.
- Current workbook has the five client report sheets.
- Primary workbook still has the existing generated report sheets, including `Haplotype Calls`.
- Workbook revision for current has label `Initial decorated MCM current workbook`.
- Workbook revision has a provenance path for the current workbook generation sidecar.
- Canonical provenance includes:
  - current workbook output path/role
  - current workbook provenance sidecar output
  - haplotype analysis JSON input
  - haplotype definition snapshot input
  - a current workbook generation step with argv and exit status

This test should fail initially because Swift still copies the primary workbook to current.

## Phase 4: Wire Swift Pipeline Integration

Modify `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift`.

### Request Paths

Add a derived path to the request type near existing workbook/provenance paths:

```swift
public var currentWorkbookProvenanceURL: URL {
    outputDirectory
        .appendingPathComponent("artifacts", isDirectory: true)
        .appendingPathComponent("workbooks", isDirectory: true)
        .appendingPathComponent("current-workbook-provenance.json")
}
```

### Haplotype Definition Snapshot URL

Refactor the existing snapshot writer to expose the path:

```swift
private func haplotypeDefinitionSnapshotURL(in supportDirectory: URL) -> URL
```

Then have `writeHaplotypeDefinitionSnapshot(...)` return or reuse that URL.

### Current Workbook Creation

Replace `createInitialCurrentWorkbookCopy(for:)` with a mode-aware helper:

```swift
private func createInitialCurrentWorkbook(
    for request: ONTBarcodeDemuxGenotypingRequest,
    supportDirectory: URL,
    reportScriptURL: URL,
    reportPythonURL: URL,
    referenceFASTAURL: URL,
    barcodeDefinitionsURL: URL,
    haplotypeAnalysis: HaplotypeAnalysisResult?,
    haplotypeDefinitionURL: URL?
) async throws -> WorkbookCopyResult
```

Behavior:

- If haplotyping is absent or definition set is not MCM, call the existing copy behavior.
- If haplotyping is present and definition species is MCM:
  - Ensure `artifacts/workbooks` exists.
  - Run the embedded report script via the resolved Python executable.
  - Pass `--client-current-workbook`.
  - Write to `request.currentWorkbookURL`.
  - Write sidecar provenance to `request.currentWorkbookProvenanceURL`.
  - Return `WorkbookCopyResult` with:
    - `revisionRole: .initialCurrentCopy`
    - `label: "Initial decorated MCM current workbook"`
    - `provenancePath` set to the relative sidecar path
    - checksums and size for final `current.xlsx`
    - argv, stderr, status, wall time captured for top-level provenance

### Provenance

Extend `WorkbookCopyResult` to carry:

```swift
let toolName: String
let toolVersion: String?
let arguments: [String]
let exitStatus: Int32
let stderr: String
let creationMode: String
```

Update top-level provenance writers to include those fields for the current workbook step.

Add the current workbook sidecar to output provenance only when it exists:

```swift
if let provenanceURL = workbookCopy.provenanceURL {
    outputs.append(WorkflowProvenance.FileRecord(path: provenanceURL.path, role: "current-report-provenance", ...))
}
```

Keep no-haplotyping behavior compatible: the manifest still points at a copied current workbook and tests must continue to prove equality.

## Phase 5: Verification

Run targeted and regression checks:

```bash
swift test --filter ONTBarcodeDemuxGenotypingPipelineTests/testReportScriptWritesMCMClientCurrentWorkbook
swift test --filter ONTBarcodeDemuxGenotypingPipelineTests/testRunCreatesDecoratedCurrentWorkbookForMCMHaplotypingAndKeepsPrimaryRaw
swift test --filter ONTBarcodeDemuxGenotypingPipelineTests
swift test --filter GenotypeViewportExcelExportTests
git diff --check
swift build --product lungfish-cli
```

Build the requested debug app after tests pass:

```bash
bash scripts/build-app.sh --configuration debug --log-dir build/logs
```

Report the resulting debug app path, expected to be:

```text
build/Debug/Lungfish.app
```

## Phase 6: Commit

Commit the implementation on branch `codex/mhc-current-excel-haplotypes` after verification:

```bash
git status --short
git add Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift Tests/LungfishWorkflowTests/ONTBarcodeDemuxGenotypingPipelineTests.swift docs/superpowers/plans/2026-06-03-mhc-current-excel-haplotypes.md
git commit -m "Decorate MCM current workbook with haplotypes"
```

# BAM Primer Trim and `.lungfishprimers` Bundles — Design Spec

**Date:** 2026-04-24
**Status:** Draft for review
**Scope:** Spec 2 of 3 in the "From reads to variants" documentation program
**Related specs:** Spec 1 (`2026-04-24-repo-rename-lungfish-genome-explorer-design.md`), Spec 3 (`2026-04-24-reads-to-variants-chapter-artifacts-design.md`)

---

## 1. Context

The Lungfish Genome Explorer supports variant calling with three callers today: LoFreq, iVar, and Medaka. iVar is the canonical amplicon variant caller, but it expects its input BAM to have had primer sequences removed *at the alignment stage* (not at the read stage). The variant calling dialog currently gates the Run button on a user-attested checkbox: "This BAM has already been primer-trimmed for iVar." This is a documentation footgun in practice, because Lungfish exposes primer trimming only at the FASTQ stage today, and FASTQ-stage trimming is a minority practice in viral-amplicon pipelines. Most real workflows (ARTIC fieldbioinformatics, viralrecon, nf-core/viralrecon) trim at the BAM stage, using `ivar trim` against the alignment coordinates. Without first-class support for this, the product cannot host the straightforward viral-amplicon workflow that genomic-epidemiology users expect.

This spec introduces two coupled capabilities:

1. A new BAM Analysis operation — **Primer-trim BAM** — exposed as a button in the BAM bundle's Inspector *Analysis* section (same surface as the existing "Call Variants…" button), which opens a dialog that runs `ivar trim` against the currently open BAM using a project-local primer scheme and emits a sorted, indexed, provenance-tagged BAM.
2. A new bundle type — **`.lungfishprimers`** — that treats a primer scheme as a first-class citizen of the project alongside reference sequences and sequencing datasets. The bundle carries the scheme's BED, its primer sequences in FASTA, and arbitrary attachments (panel PDFs, provenance notes). One canonical bundle, `QIASeqDIRECT-SARS2.lungfishprimers`, ships built-in as a reference implementation and as a test fixture.

## 2. Goals and non-goals

### Goals

- Expose `ivar trim` as a first-class BAM Analysis operation, surfaced as a button in the BAM Inspector's Analysis section alongside "Call Variants…", with a dialog that mirrors the existing `BAMVariantCallingDialog` design pattern.
- Define the `.lungfishprimers` bundle shape, with both BED (authoritative for trimming) and FASTA (authoritative for sequence-level work) as peer artifacts.
- Support multiple equivalent reference accessions in one bundle (e.g., `MN908947.3` and `NC_045512.2` for SARS-CoV-2), with byte-identical-sequence verification at bundle-build time and on-the-fly BED header rewriting at use time.
- Ship `QIASeqDIRECT-SARS2.lungfishprimers` as a built-in scheme and as a test fixture.
- Update the BAM variant calling dialog so that when the selected BAM's provenance records a Lungfish-run primer trim, the `ivarPrimerTrimConfirmed` checkbox is auto-checked-and-disabled with a "Primer-trimmed by Lungfish on YYYY-MM-DD" caption. User-attested trims still work as today.
- Add an Import Center flow that imports a `.bed` (plus optional FASTA and attachments) as a new `.lungfishprimers` bundle into the project's `Primer Schemes/` folder.
- Add a `Primer Schemes/` group to the sidebar with a dedicated inspector.

### Non-goals

- Pre-bundling additional primer schemes (ARTIC v3, v4.1, Midnight, etc.). Bundles enable this; only the canonical QIASeq bundle ships in this spec.
- FASTA-based primer QC operations (primer-dimer detection, scheme-vs-variant mismatch analysis, BLAST of primers against reads). The bundle makes these possible; this spec does not build them.
- A primer-scheme catalog UI backed by a remote index. Built-in schemes are read-only assets in `Resources/`.
- Adapter-based (FASTQ-level) primer trimming changes. The existing FASTQ primer-trim operation is untouched.
- Automated detection of "is this BAM from an amplicon panel?" The user picks the scheme.

## 3. Architecture fit

### 3.1 Runner

`NativeToolRunner` (actor) already wraps `ivar` for variant calling. `ivar trim` is one additional subcommand path, following the same invocation and progress-reporting conventions. No new process-management surface is introduced.

### 3.2 Surfacing: Analysis section of the BAM Inspector

The existing "Call Variants…" button lives in the BAM Inspector's Analysis section, rendered by `ReadStyleSection.variantCallingSection` in `Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift`. The new Primer-trim operation is surfaced by a sibling `primerTrimSection` in the same file, immediately above the variant-calling section (the workflow reads top-down: primer-trim, then call variants). The section contains:

- A short caption describing the operation ("Trim amplicon primers from the alignment before variant calling.").
- A secondary caption that explains when to use it ("Required for iVar variant calling on amplicon-sequenced BAMs; recommended for any amplicon panel.") or a disabled-state caption matching the existing pattern.
- A "Primer-trim BAM…" button that opens the new dialog.
- The button is disabled when no alignment track is loaded, in the same way the "Call Variants…" button is disabled.

The Inspector's `viewModel` gains `onPrimerTrimRequested: (() -> Void)?` alongside the existing `onCallVariantsRequested`. The callback is wired from `InspectorViewController` to present the new dialog, mirroring the existing `BAMVariantCallingDialogPresenter.present(…)` wiring at line 1639 of `InspectorViewController.swift`.

### 3.3 Catalog

`BAMVariantCallingCatalog.swift` is the precedent for pack-gated tool availability: a `Sendable` struct that reports items for a dialog's picker gated on a plugin pack's readiness. A parallel `BAMPrimerTrimCatalog.swift` mirrors its shape and reuses the existing `variant-calling` pack (iVar is already part of that pack). Its output is consumed by the Primer-trim dialog's picker. If `variant-calling` is not ready, the dialog's Run button is disabled with a "Requires Variant Calling Pack" caption; additionally, the Inspector's Primer-trim button itself may be disabled with a disabled-state caption when the pack isn't ready, matching the existing Variant Calling pattern.

### 3.4 Dialog

The existing `BAMVariantCallingDialog` is split into four files: `Dialog`, `DialogState`, `DialogPresenter`, and `ToolPanes`. The new `BAMPrimerTrimDialog` follows the same split verbatim, so the codebase stays regular. The dialog's inputs:

- **Primer scheme picker** (required): lists built-in schemes first, then project-local `.lungfishprimers` bundles, then a Browse button for filesystem-import. Mirrors `ReferenceSequencePickerView`.
- **Advanced options** (progressive disclosure, matching the existing advanced-options pattern): minimum read length after trim, quality threshold, sliding window width, offset. Defaults match `ivar trim`'s upstream defaults.
- **Output location**: derivatives folder of the source BAM bundle, same pattern as variant calling outputs.

### 3.5 Bundle shape

```
<name>.lungfishprimers/
  manifest.json
  primers.bed                 # required; authoritative for trimming
  primers.fasta               # optional but strongly preferred
  PROVENANCE.md               # required; source citation
  attachments/                # optional
    <arbitrary files>
```

### 3.6 Manifest

```json
{
  "schema_version": 1,
  "name": "QIASeqDIRECT-SARS2",
  "display_name": "QIASeq Direct SARS-CoV-2",
  "description": "QIAGEN QIASeq Direct SARS-CoV-2 amplicon panel.",
  "organism": "Severe acute respiratory syndrome coronavirus 2",
  "reference_accessions": [
    { "accession": "MN908947.3", "canonical": true },
    { "accession": "NC_045512.2", "equivalent": true }
  ],
  "primer_count": 0,
  "amplicon_count": 0,
  "source": "QIAGEN Sciences LLC",
  "source_url": "https://…",
  "version": "1.0",
  "created": "2026-04-24T00:00:00Z",
  "imported": "2026-04-24T00:00:00Z",
  "attachments": [
    { "path": "attachments/qiaseq-direct-panel-spec.pdf", "description": "…" }
  ]
}
```

`primer_count` and `amplicon_count` are computed at bundle-build time and stored, so the inspector can render them without re-parsing the BED. `canonical` on a reference accession means "the BED's column 1 matches this string literally." `equivalent` means "byte-identical sequence under a different name." A bundle has exactly one canonical accession and zero or more equivalents.

### 3.7 Reference-name resolution at use time

When the user runs primer-trim against a BAM, the app:

1. Reads the BAM header to extract its `@SQ SN:` reference name.
2. Consults the primer bundle's `reference_accessions` list.
3. If the BAM's reference name matches the canonical accession, the BED is used as-is.
4. If it matches an equivalent, the BED is written to a temp file with column 1 rewritten from canonical → equivalent, and the temp file is handed to `ivar trim`.
5. If no match is found, the dialog reports a clear error and blocks Run.

This is a single code path — `PrimerSchemeResolver.resolve(bundle:targetReferenceName:) -> URL` — with unit tests for each case.

### 3.8 Bundle-build-time verification

Bundles declare equivalence only when the sequences are byte-identical. A `scripts/build-primer-bundle.swift` tool (or equivalent) used to author canonical bundles:

- Takes the BED, the FASTA (or path to derive from reference), the manifest template.
- For each declared equivalent accession, fetches the sequence from NCBI and SHA256-hashes it.
- Refuses to emit the bundle if any equivalent's hash differs from the canonical's.
- Computes `primer_count` and `amplicon_count` from the BED and writes them into the manifest.

This runs at bundle authoring time, not at import or use time. It catches the case where NCBI silently revises a reference while we still treat it as equivalent.

### 3.9 Import Center

A new "Import Primer Scheme" entry. Sub-flows:

1. **BED + FASTA + attachments** (most common): user picks BED, optionally FASTA, optionally attachments, confirms the reference accession (parsed from BED's column 1; user can mark equivalents manually), and names the bundle. App writes `<name>.lungfishprimers` into `Primer Schemes/` and emits a validation report. If FASTA is missing, the app offers to derive it from the reference; the derived FASTA is labeled `"derived": true` in the manifest.
2. **Pre-built bundle import**: user drops a `.lungfishprimers` directory (or zipped form). App validates the manifest against the schema, copies into the project.
3. *(Not implemented in this spec)* Remote catalog import.

Validation at import:
- BED row count ≥ 1.
- If FASTA present, every BED row has a matching FASTA record by primer name (warn, don't block).
- Manifest conforms to `schema_version: 1`.
- `PROVENANCE.md` present and non-empty.

### 3.10 Project folder

New top-level folder: `Primer Schemes/`. Sits alongside `Reference Sequences/` and `Downloads/`. Added to:

- Sidebar scanner (`isInternalSidecarFile` audit for any false positives).
- Sidebar group labels.
- Project folder creation logic when a new project is created.

### 3.11 Built-in schemes

New resource folder `Resources/PrimerSchemes/` containing `QIASeqDIRECT-SARS2.lungfishprimers/`. Discovered by the picker via a `BuiltInPrimerSchemeService` that enumerates the bundled resource. Built-in schemes:

- Are read-only (the picker copies on selection, same as other built-in assets).
- Appear at the top of the picker, grouped "Built-in," and listed separately from project-local schemes.
- Identified by manifest `source == "built-in"` (or by being discovered under `Resources/`; implementation detail).

### 3.12 Provenance

The primer-trimmed BAM's sidecar metadata records:

```json
{
  "operation": "primer-trim",
  "primer_scheme": {
    "bundle_name": "QIASeqDIRECT-SARS2",
    "bundle_source": "built-in",
    "bundle_version": "1.0",
    "canonical_accession": "MN908947.3"
  },
  "source_bam": "<relative path to source BAM>",
  "ivar_version": "<version string>",
  "ivar_trim_args": ["-q", "20", "-m", "30", ...],
  "timestamp": "2026-04-24T12:34:56Z"
}
```

The BAM variant calling dialog reads this sidecar when a BAM is selected and flips `ivarPrimerTrimConfirmed` to a checked-disabled state with a caption when `operation == "primer-trim"` is present.

## 4. The canonical bundle: `QIASeqDIRECT-SARS2.lungfishprimers`

This bundle is both a product deliverable (shipped built-in) and a test fixture (under `Tests/Fixtures/primerschemes/`). To avoid duplication, it lives once at `Resources/PrimerSchemes/QIASeqDIRECT-SARS2.lungfishprimers/` and is referenced from the test target via Swift Package Manager resource access, or symlinked under `Tests/Fixtures/primerschemes/` if SPM permits. Final placement decision deferred to implementation (Swift Package Manager's resource-handling rules take precedence over the spec).

### 4.1 Contents

- `manifest.json` — populated with QIAGEN provenance, `reference_accessions` listing `MN908947.3` (canonical) and `NC_045512.2` (equivalent), `primer_count`, `amplicon_count`.
- `primers.bed` — QIAGEN's published QIASeq Direct SARS-CoV-2 primer coordinates against `MN908947.3`.
- `primers.fasta` — per-primer FASTA records with names matching BED column 4. If QIAGEN's public documentation publishes these sequences, they are authoritative. If not, the FASTA is derived from the reference at the declared coordinates and labeled `"derived": true` in the manifest.
- `PROVENANCE.md` — cites QIAGEN's documentation URL, date retrieved, note that users should verify against current QIAGEN documentation before production use, and licensing note (primer coordinates on a public reference genome are not themselves copyrightable; any bundled PDF is included only if its license permits redistribution).
- `attachments/` — optional; a panel specification PDF if QIAGEN's license permits redistribution. If not, the `PROVENANCE.md` includes a link instead of bundling.

### 4.2 Authoring

A one-time script run during implementation, using `scripts/build-primer-bundle.swift`:

1. Fetches `MN908947.3` and `NC_045512.2` from NCBI, verifies SHA256 equivalence.
2. Assembles the manifest, BED, FASTA, PROVENANCE.
3. Writes the bundle to `Resources/PrimerSchemes/`.
4. Runs the integration test that exercises the full "import → primer-trim → iVar call" flow against a fixture BAM, as acceptance.

The script is committed so that the bundle can be rebuilt deterministically from source inputs.

### 4.3 Licensing and provenance

`PROVENANCE.md` is explicit about:

- QIAGEN as the scheme designer.
- URL and retrieval date for the coordinates.
- A disclaimer that primer coordinates on a public reference genome describe publicly derivable facts and are not themselves a copyrightable artifact, but that panel documentation may be subject to QIAGEN's terms and is linked rather than bundled where licensing is unclear.
- A user-facing note: "Before using in a regulated workflow, verify against QIAGEN's current published coordinates."

## 5. Testing

### 5.1 Unit tests

- `BAMPrimerTrimCatalogTests`: availability states (pack-ready, pack-disabled), sidebar item construction.
- `BAMPrimerTrimDialogStateTests`: validation (can't Run without scheme, can't Run without output destination), advanced options round-trip.
- `PrimerSchemeBundleTests`: manifest parsing, schema-version handling, malformed-manifest rejection.
- `PrimerSchemeResolverTests`: canonical match, equivalent match (with on-the-fly rewrite), no-match error.
- `PrimerSchemeImportTests`: BED-only import (with derived FASTA), BED+FASTA import, pre-built bundle import, each failure mode.

### 5.2 Integration tests

- `PrimerTrimIntegrationTests`: fixture BAM + canonical QIASeq bundle → run trim → assert output BAM is sorted, indexed, and carries correct provenance.
- `PrimerTrimThenIVarTests`: same trim as above, then `ivar variants` against the trimmed BAM, assert that the variant calling dialog (via `DialogState`) reports `ivarPrimerTrimConfirmed` as auto-confirmed.
- `PrimerSchemeEquivalentAccessionTests`: a BAM mapped against `NC_045512.2` is trimmed with a QIASeq bundle whose BED is authored against `MN908947.3`; assert the resolver rewrites correctly and `ivar trim` succeeds.

### 5.3 UI tests

- `PrimerTrimXCUITests`: open BAM → Inspector's Analysis section shows a "Primer-trim BAM…" button → click it → dialog opens → pick built-in scheme → run → observe result in the sidebar's Analyses group.
- `VariantCallingAutoConfirmXCUITests`: with a primer-trimmed BAM selected, open variant calling dialog, pick iVar, observe the `ivarPrimerTrimConfirmed` checkbox is auto-checked-and-disabled with the expected caption.

## 6. Risks

- **iVar trim output is not coordinate-sorted by default.** The operation runs `samtools sort` + `samtools index` after `ivar trim` and fails loudly if either step fails. Separate test asserting output is sorted.
- **Primer BED naming conventions vary widely in the wild.** Column 4 (primer name) and column 6 (strand) are especially inconsistent. The resolver must be permissive on ingest and reject with a clear message for malformed rows rather than producing garbage. A separate test covers three common real-world BED variants.
- **Sidebar scanning false positives.** Adding `Primer Schemes/` touches sidebar scanning logic, which has been a source of subtle bugs historically (see MEMORY notes). The sidebar tests cover: `.lungfishprimers` appears in the sidebar, `.bed` files *inside* a `.lungfishprimers` bundle do not appear as independent items, `isInternalSidecarFile` behavior is unchanged for unrelated types.
- **Reference-sequence equivalence drift.** A future NCBI revision of `NC_045512.2` could diverge from `MN908947.3`. The build-time hash check catches this when the bundle is rebuilt; there is no runtime defense. The bundle `manifest.json` records the hashes observed at build time so a future audit can re-verify.
- **License ambiguity around QIAGEN materials.** Resolved by linking rather than bundling where license is unclear; `PROVENANCE.md` is authoritative for the provenance of every file in the bundle.

## 7. Worktree strategy

Track 1 lives in its own worktree off `main`, named `track1-bam-primer-trim`. The work does not require launching the app (tests use `NativeToolRunner` directly, and XCUI tests run via `xcodebuild test` without needing the Java-backed tool runtime). The previously-documented "cannot run app from worktree due to missing JRE dylibs" constraint has been reported fixed; as a first step in implementation, verify this by running one Java-backed tool (BBTools or Clumpify) from within the worktree and reporting the result. If the constraint is truly fixed, the worktree has no restrictions; if it is not, report back and work out a fallback.

## 8. Out of scope, explicitly

- Additional built-in primer schemes beyond QIASeq Direct.
- Sample-prep metadata wizards that map kit → BED automatically.
- BLAST or sequence-level QC operations that use the bundle's FASTA.
- A remote primer-scheme catalog.
- FASTQ-level primer trimming changes.
- Automated "is this BAM an amplicon panel?" detection.

## 9. Follow-ups (captured, not built here)

- Ship additional built-in bundles for ARTIC v3, v4.1, and Midnight 1200 once QIASeq is proven.
- Primer-QC operations on `.lungfishprimers` bundles themselves (primer-dimer scan, mismatch analysis against the reference), surfaced either as bundle-level Inspector actions or as a Primer Schemes sidebar action menu.
- A "reveal equivalent accessions" affordance in the primer-scheme inspector.
- UI for editing a bundle's manifest post-import (currently read-only; advanced users edit the JSON directly).

## 10. "Done" criteria

- Primer-trim BAM operation appears in the BAM Inspector's Analysis section as a "Primer-trim BAM…" button, gated on the `variant-calling` pack as expected.
- `BAMPrimerTrimDialog` opens, allows scheme selection from built-in + project-local + filesystem, and runs `ivar trim` producing a sorted, indexed BAM.
- Output BAM carries provenance metadata per §3.11.
- BAM variant calling dialog auto-confirms the primer-trim checkbox when selecting a Lungfish-trimmed BAM.
- `QIASeqDIRECT-SARS2.lungfishprimers` ships in `Resources/PrimerSchemes/`, validates, is discoverable from the picker, and passes the end-to-end integration test.
- Import Center can import an arbitrary BED (+ optional FASTA + attachments) into a project-local `.lungfishprimers` bundle.
- `Primer Schemes/` group appears in the sidebar; scheme inspector renders manifest, BED table, FASTA list, and attachments.
- All unit, integration, and UI tests pass.
- `swift build` and `swift test` pass in the worktree.

# Filtered Primer Orders Implementation Plan

> **For agentic workers:** Use subagent-driven-development for the bounded writer and UI tasks; root owns integration and verifies both before completion.

**Goal:** Export the Inspector's displayed PrimalScheme oligos directly as a traceable project-owned order, including the supplied IDT template and a metadata worksheet.

**Architecture:** Capture immutable selected IDs, display settings, compatibility counts and source manifest when opening the order sheet. Resolve against a freshly verified analysis during export. Publish a generic `primer-order` analysis directory atomically into the originating project's Analyses folder, then reopen it through the existing viewport and Inspector conventions.

**Tech Stack:** Swift, SwiftUI/AppKit, FoundationXML, native cancellable ZIP tools, existing Lungfish provenance and Operations APIs. Artifact-tool inspects and renders XLSX for development verification only.

**Spec:** User request in current task: export only displayed oligos, populate supplied `opoolsentrysample.xlsx`, optional order metadata on a second worksheet, project-owned outputs.

## Global constraints

- Original saved analysis and full ordering sheet remain unchanged.
- No design, ranking, deduplication, inferred synthesis settings or purchase submission.
- Saved oligos retain their exact 5′–3′ sequence; identical pool numbers in independent schemes remain distinct.
- Empty selections and unresolved active compatibility filters block capture.
- Project path/identity, write state and operation cancellation are rechecked at atomic publication.
- All scientific artifacts retain final-path provenance, input/output hashes and sizes, exact commands/options and runtime/time/status.

## Tasks

- [x] `PrimerOrderExportModels.swift` and `PrimerAnalysisDisplayState.swift`: frozen selection/draft and export eligibility; changing display after capture must not alter the draft.
- [x] `PrimerOrderExportService.swift`: exact ID/filter membership revalidation, retained byte-identical source evidence, export metadata, checksum inventory, provenance and exclusive publication. Tests reject stale/duplicate/missing IDs, verify exact rows, all final descriptors and source immutability.
- [x] `PrimerOrderSheetWriter.swift`, bundled sanitized template, `Package.swift`: produce `primer-order.xlsx` with Sheet1 and Order metadata, `IDT-oPools.xlsx` with only Sheet1, plus detailed CSV. Preserve supplied instructions and formatting, clear every sample entry, store literal XML text, protect CSV against formula injection. Tests inspect XML and round-trip rows, pool separation and metadata.
- [ ] Inspector section and `PrimerOrderExportView.swift`: global export action with frozen count, name, blank optional researcher/project/order reference/notes, pool breakdown, compact preview and fixed project destination. Tests verify frozen forwarding, disabled states and render the form.
- [ ] MainSplit integration and `PrimerOrderResultView.swift`: Operations lifecycle, project guards, successful result links/table; generic analysis sidebar routing, Inspector provenance/files without new scientific bundle semantics.
- [x] Run focused XCTest suite including native saved human/macaque MHC fixture exports. Inspect and render generated workbook sheets with artifact-tool; verify counts, sequences, no sample rows and final evidence hashes.
Completion gate: expert review, local commit and portable Debug build through the release coordinator; verify the resulting app and packaged CLI. Do not launch/quit an application or replace the main checkout.

## Verification commands

```sh
swift test --jobs 4 --filter 'PrimerOrder|PrimerAnalysisDisplay|PrimerAnalysisExport|AnalysisResultDisplayRoute'
python3 .codex/skills/releasing-lungfish/scripts/validate.py --repo-root "$PWD"
python3 scripts/release/release.py debug --portable --jobs 4
```

Manual native fixture verification uses `LUNGFISH_PRIMER_ORDER_FIXTURES` pointing at `.build/primer-range-validation`, retaining outputs under `.build/primer-order-validation` for workbook rendering.

## Verification evidence

- 57 focused XCTest cases passed, zero failures/skips, covering selection freeze, pending filters, stale/corrupt sources, no-overwrite/cancellation, publication provenance, project routing, Inspector state, worksheet contracts and native human/macaque saved results.
- Human A fixture: 37 of 38 oligos exported. Macaque DQ fixture: 73 of 198 exported. The 60% display setting exercised filtering and is not an assay recommendation. Source files remained byte-identical.
- Independent artifact-tool XLSX imports verified both vendor sheets and second-sheet identities against order.json for all selected records. Template, metadata, identity-table and app review/result renders were inspected.
- The external reader caught a missing worksheet namespace; a saved-file namespace regression now covers it. Long identifiers use wider metadata columns and measured row heights.
- Architecture and scientific-semantics review completed; canonical envelope sharing and per-command final-path provenance were checked.
- Release skill validator passed before the Debug packaging gate.

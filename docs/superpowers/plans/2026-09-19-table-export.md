# Scientific Table Export Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` to implement this bounded export subtask. Steps use checkbox syntax for tracking. All compilation and test execution belongs to the coordinating Sol Medium builder; this investigator has performed no builds.

**Goal:** Export all matching rows or the selected rows from the variant Calls/Genotypes, Annotations, and Samples drawer tables as real Excel workbooks or CSV, while retaining existing TSV/JSON and reproducibility provenance.

**Architecture:** Capture an immutable, typed table snapshot independently of NSTableView presentation, then render it with a shared Foundation-based table writer and publish the data plus provenance atomically. Reuse the existing native OOXML/system-zip workbook implementation in `TwelveSResultExportWorkflow.swift`; do not route ordinary variant exports through the genotype-specific Python schema. Extract a frozen query request from existing drawer filtering so all-matching export runs the same predicates without display caps.

**Tech Stack:** Swift 6.2, AppKit, Foundation, SQLite, existing `/usr/bin/zip`, `ScientificFileExportProvenance`, retained selection replay.

**Spec:** User request in this task, item 1, plus user-supplied AGENTS.md scientific provenance requirements. “All rows” means all matches of the current table query, including rows beyond its display limit; this assumption may be updated if the user answers the coordinator's pending scope question.

## Global Constraints

- Preserve all existing uncommitted changes; the current checkout already contains variant field, selection, metadata, and inspector work.
- No package dependency, conda installation, network access, or new runtime requirement for CSV/XLSX export.
- Native macOS save sheet, cancelable background collection/rendering, explicit errors, and no successful partial output.
- Every scientific output gets tool/workflow identity and version, actual workflow invocation, resolved defaults/options, source/output paths, checksums and sizes, runtime identity, exit status and elapsed time. Data and provenance publish together.
- Keep genotype-specific `GenotypeExcelExportService` untouched. Limit other-list UI adoption to the four drawer table modes in this change; publish a reusable writer for later list views.
- Default columns are the user's visible columns in their current order. Preserve those IDs separately from labels and record them in provenance. Do not deduplicate columns by human-readable title.

## Existing Evidence and Gaps

`AnnotationTableDrawerView+Export.swift` already offers Visible/Selected CSV/TSV/JSON. It records indexes before NSSavePanel but rereads the mutable tab, table columns and row arrays afterward. A tab/filter/sort change while the sheet is open can therefore export different records. It uses `cellValueString`, adding coordinate grouping separators, abbreviated lengths, one-decimal QUAL and rounded genotype allele balance. JSON export suppresses serialization errors and substitutes an empty document. All work and input hashing run synchronously in the sheet completion. CSV escaping misses carriage returns and formula-like text. Existing all-visible scope cannot retrieve undisplayed matches.

`AnnotationTableDrawerView+Filtering.swift` applies region/chromosome/gene list/query/track/sample/chip/token/column/bookmark/impact filters and display truncation. `fetchVariantsAdaptive` also has a `maxDisplayCount * 40` ceiling. Neither that helper nor `searchIndex.allResults` is an all-export source. Annotation queries can deliberately display no rows above a limit; that must not disable all-matching export. The Genotypes tab currently expands only `displayedAnnotations`, so its all-matching export must expand the uncapped variant query before applying sample/genotype predicates.

`VariantFormatOverlaySnapshot.projectedInfo` injects single-sample iVar FORMAT values without replacing true INFO. All-query exports must use the captured overlay and include its `sourceIdentities` files among source descriptors; bypassing it loses current displayed DP/AF/ALT_FREQ values. Calls and genotypes must carry track-qualified row identity because SQLite IDs collide across tracks.

`TwelveSResultExportWorkflow.swift:412` contains private `writeWorkbook` and the OOXML helper family around line 693. It packages using `/usr/bin/zip` and requires no external installation. Extract/reuse that implementation; add explicit typed cells rather than its current string-to-number guessing. Preserve TwelveS serialization through a compatibility adapter and run its existing tests if changing its file.

`ScientificFileExportProvenance.writeAtomically` already provides payload-plus-sidecar rollback. `RetainedSelectionExportSnapshot` retains exact bytes plus selection metadata and provides a real `/bin/cp` replay command, but currently replaces scientific sources with replay inputs when publishing. Add an opt-in way to preserve original source descriptors as well as retained inputs for this export, without changing existing callers' behavior accidentally.

## Review Focus

1. A capped or empty-on-cap table still exports every matching record, with identical filters and sort order; Task 2 owns a beyond-limit fixture.
2. Changing tab/sort/selection while NSSavePanel is open cannot change the requested output; Task 3 owns immutable capture tests.
3. Gene names, long IDs, leading zeroes, multiallelic vectors, phased GT, and missing values retain scientific meaning; Task 1 owns typed archive/delimited tests.
4. Cancellation, SQLite timeout and provenance failure never publish a successful truncated table or destroy an existing destination; Tasks 2 and 3 own failure tests.
5. iVar projection and cross-track ID collisions survive both selected and all matching exports; Tasks 2 and 3 own fixtures.

## Ownership and Order

Export implementer owns the new writer/service/snapshot/query files, `AnnotationTableDrawerView+Export.swift`, and narrow integration additions to the drawer. Coordinate before modifying already-dirty `AnnotationTableDrawerView.swift`, `+Filtering.swift`, `+TableView.swift`, or `AnnotationSearchIndex.swift`. The hover/selection implementers must not edit the export extension. Retain `cellValueString` because other tests and UI logic call it; stop using it for scientific serialization.

### Task 1: Shared typed CSV/TSV/JSON/XLSX writer

**Files:**

- Create `Sources/LungfishWorkflow/Exports/ScientificTableWriter.swift`.
- Create `Tests/LungfishWorkflowTests/ScientificTableWriterTests.swift`.
- Modify `Sources/LungfishWorkflow/TwelveS/TwelveSResultExportWorkflow.swift` only for a compatibility wrapper if extracting its helpers; preserve its workflow/publication logic.
- Existing regression tests: `Tests/LungfishWorkflowTests/TwelveSResultExportWorkflowTests.swift`.

**Interfaces:**

```swift
public enum ScientificTableCell: Codable, Sendable, Equatable {
    case text(String), integer(Int64), number(Double), boolean(Bool), empty
}
public struct ScientificTableColumn: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
}
public enum ScientificTableFormat: String, Codable, Sendable {
    case csv, tsv, json, xlsx
}
public struct ScientificTableData: Codable, Sendable {
    public let name: String
    public let columns: [ScientificTableColumn]
    public let rows: [[ScientificTableCell]]
}
public enum ScientificTableWriter {
    public static func write(_ table: ScientificTableData,
        format: ScientificTableFormat, to url: URL,
        shouldCancel: @Sendable () -> Bool = { false }) throws
}
```

- [ ] Add tests with concrete cells `.text("SEPT1")`, `.text("00123")`, `.text("9007199254740993")`, `.text("=1+1")`, `.text("1|0")`, `.integer(29409)`, `.number(0.999628)`, `.empty`, and `.text("a,\"b\"\r\nc")`. Assert exact decimal strings with no grouping/rounding, escaped CR/LF/quotes, and no formula element in XLSX. Decode JSON by column IDs/order, not a dictionary keyed by title.
- [ ] Extract native workbook packaging/helpers from the TwelveS implementation into the writer. Make XLSX `.text` always `t="inlineStr"`, `.integer/.number` numeric, `.boolean` boolean, `.empty` blank. Never infer a text cell's type from `Double(text)`. Header cells are text with bold style, freeze the top row, enable autofilter, and set useful bounded widths.

```swift
// Core encoding rules; use XML escaping for content and attributes.
switch cell {
case .text(let value):
    return "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
case .integer(let value):
    return "<c r=\"\(reference)\"><v>\(value)</v></c>"
case .number(let value):
    guard value.isFinite else { throw WriterError.nonFiniteNumber }
    return "<c r=\"\(reference)\"><v>\(value)</v></c>"
case .boolean(let value):
    return "<c r=\"\(reference)\" t=\"b\"><v>\(value ? 1 : 0)</v></c>"
case .empty: return "<c r=\"\(reference)\"/>"
}
```

- [ ] Validate rectangular rows; XLSX has at most 16,384 columns and 1,048,576 total rows including the header, and at most 32,767 UTF-16 units in one text cell. Reject over-limit output with an actionable “Use CSV” error instead of truncating. Reject invalid XML scalar content instead of dropping scientific characters silently. Escape tabs/newlines/ampersands/less-than correctly. Textual identifiers over Excel's 15-digit precision remain text; reject or encode oversized integer cells as explicit text with a documented rule.
- [ ] CSV/TSV escape delimiter, double quote, CR and LF. Protect formula-like *text* beginning with `=`, `+`, `-`, `@`, tab or CR (including dangerous prefix after leading whitespace) using an apostrophe and record the policy; never alter typed negative numbers. Do not claim CSV prevents Excel date/name coercion: XLSX is the type-preserving option. Preserve raw original text in retained JSON snapshot. UTF-8 output and one header row are the resolved defaults.
- [ ] Write incrementally with cancellation checks per row/chunk. Run `/usr/bin/zip` using argument arrays, no shell; capture stderr without pipe deadlock and terminate on cancellation. Package to a unique temporary file, then hand that file to publication. Ensure system zip does not append an unexpected `.zip` extension to the provenance staging filename.
- [ ] Ask the Sol builder to run `swift test --filter ScientificTableWriterTests` and, if extraction changes TwelveS, `swift test --filter TwelveSResultExportWorkflowTests`. XLSX tests inspect archive members and XML cell types using `/usr/bin/unzip`; no openpyxl installation is necessary.

### Task 2: Immutable scientific row capture and complete query scope

**Files:**

- Create `Sources/LungfishApp/Services/AnnotationTableExportSnapshot.swift`.
- Create `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+ExportCapture.swift`.
- Create `Sources/LungfishApp/Services/AnnotationTableExportQuery.swift` if the frozen query runner does not fit cleanly with existing drawer query context.
- Modify narrow frozen-query construction seams in `AnnotationTableDrawerView+Filtering.swift` and `+Genotypes.swift`.
- Add throwing query counterparts to `Sources/LungfishIO/Bundles/VariantDatabase+Query.swift` and annotation database query code only where needed to distinguish completion from interrupted/failed enumeration; leave UI's existing nonthrowing wrappers compatible.
- Create `Tests/LungfishAppTests/AnnotationTableExportSnapshotTests.swift` and `AnnotationTableExportQueryTests.swift`.

**Interfaces:**

```swift
enum AnnotationTableExportScope: String, Codable, Sendable {
    case allMatching, selected
}
struct AnnotationTableExportSnapshot: Codable, Sendable {
    let table: ScientificTableData
    let tab: String // annotations, variants, genotypes, samples
    let scope: AnnotationTableExportScope
    let rowIdentities: [String] // track:rowID; genotype also includes sample
    let sourceURLs: [URL]
    let queryDescription: [String: String] // exact resolved predicates and sort
    let coordinateConventions: [String: String]
}
```

- [ ] Make selected capture operate on values/identities and columns captured on MainActor before presenting the sheet. Calls/annotations use existing `SearchResult` values; samples and genotypes use their value rows. Do not retain indexes as the export contract. Include ordered stable column IDs independently of their labels.
- [ ] Map scientific cells directly: Calls/GT position is `start + 1` (1-based); annotations Start is `start` and End is `end` (0-based half-open); Size is full integer `end - start`, never “1.3 kb”. QUAL uses the full stored Double, missing/negative sentinel becomes empty. DP/GQ/sample counts are integers, AB/AF are full precision numbers when schema says scalar numeric. GT/AD/REF/ALT/chromosome/name/source/track IDs are text. INFO Number=A/R/G or comma vectors remain text. Unknown annotation attributes and sample metadata remain text; do not guess type from spelling. Add `(0-based)`/`(1-based)` and `(exclusive)` to coordinate headers, and record the convention by column ID in provenance.
- [ ] Preserve current consequence/coding feature/amino-acid strings using the existing annotation resolver, capturing required annotation/reference sources. Preserve missing versus zero. Capture the FORMAT overlay once; preserve original INFO preference and single-sample-only projection. Genotype all-query expansion should use the same track-qualified variant identity and captured overlay as Calls, without altering multi-sample site INFO semantics.
- [ ] Extract the existing filtering request into an immutable Sendable request consumed by display and export. Capture all actual resolved predicates: text/advanced query, merged types, chips, smart tokens, genotype/sample filters, active gene regions, chromosome/viewport/allowed-reference scope, hidden tracks/samples, bookmarks, column clauses, sort descriptors and overlay. The export path removes display `prefix`/max-count policy only. Do not replay text through a simpler SQL query and omit postfilters.
- [ ] Fetch all candidates using a real uncapped/complete query path, apply the same postfilters and sort, and verify completion. Prefer bounded pages on dedicated DB connections; if a bounded full-array approach is chosen for this Debug iteration, derive its fetch limit from actual source counts, check overflow, and never use `maxDisplayCount`, its 40x fallback, or an arbitrary million-row cap. Throw on prepare/step errors and timeout. Existing query wrappers that return partial rows after SQLITE_INTERRUPT are not safe export contracts. Cancellation is failure, not an empty successful table.
- [ ] Samples export every filtered sample row. Genotypes expand the all-matching Calls query across captured visible samples, then apply the same genotype filters and sort. Avoid accidental double-application of genotype free text as a variant-only SQL name predicate.
- [ ] Test a cap of 2 against 5 matching rows and at least one late matching postfiltered/projected record; all scope exports every match, selected scope only selected identities. Add identical row IDs across two tracks, hidden tracks, allowed annotation chromosomes, an iVar FORMAT-only DP/ALT_FREQ fixture, empty allowed scope, genotype expansion, and cancel/timeout fixtures. Add the mutation test: capture, replace/sort live table, assert captured values remain unchanged.
- [ ] Ask Sol builder for `swift test --filter AnnotationTableExportSnapshotTests` and `swift test --filter AnnotationTableExportQueryTests`, plus existing variant projection/filter/track identity suites touched by extraction.

### Task 3: Native export UI, background publication and provenance

**Files:**

- Modify `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView+Export.swift`.
- Modify `Sources/LungfishApp/Views/Viewer/ViewerFilePanelFactory.swift` only for reusable panel parameters.
- Create `Sources/LungfishApp/Services/AnnotationTableExportService.swift`.
- Modify `Sources/LungfishApp/Services/RetainedSelectionExportSnapshot.swift` narrowly to preserve original source descriptors when requested, or use an equivalent local publisher without changing other callers.
- Create `Tests/LungfishAppTests/AnnotationTableExportServiceTests.swift` and `AnnotationTableExportInterfaceTests.swift`.
- Update `Tests/LungfishAppTests/ScientificFileExportProvenanceTests.swift` only if its source-text assertion needs to follow the extracted owner.

**Interfaces:**

```swift
enum AnnotationTableExportService {
    static func export(snapshot: AnnotationTableExportSnapshot,
        format: ScientificTableFormat, outputURL: URL,
        shouldCancel: @Sendable () -> Bool) throws
}
```

- [ ] Use an “Export…” entry with two clearly named scope groups: “All Matching Rows…” and “Selected Rows (N)…”, formats “Excel Workbook (.xlsx)”, “CSV”, “TSV”, “JSON”. Disable Selected only if the active data source has no selected rows. All Matching remains available when display is capped. Add help text “All matching rows includes results beyond the table display limit. Current filters and column order are used.” Keep the scope menu available from existing export toolbar button; give the button a meaningful accessibility label/help.
- [ ] Capture values or the immutable complete-query request before NSSavePanel. Use `ViewerFilePanelFactory.tableExportPanel`, real xlsx UTType, valid extension and default `variants-selected.xlsx`/`annotations-all-matching.csv`. Set `panel.prompt = "Export"`; respect panel Cancel without creating files. Avoid appending another extension after overwrite approval; panel content type must agree with final URL.
- [ ] After save approval, show a small progress sheet with indeterminate progress plus Cancel. Collect/query/render/hash on a background task. Keep one export in flight for the drawer, with a cancellation token retained until final completion. Disable duplicate export action. MainActor only updates UI. Closing the source window cancels pre-publication work; state changes cannot alter frozen data. Check cancellation before starting the atomic publication; once publishing starts, finish/rollback transaction deterministically.
- [ ] Build durable retained input metadata containing typed rows, selected stable identities, exact columns, sort, predicates, resolved defaults, coordinate conventions and FORMAT projection sources. Retain the exact rendered payload for a valid byte replay command. Use the existing atomic publisher with both retained replay inputs and original scientific source URLs/descriptors. Do not advertise a nonexistent `lungfish-cli` subcommand as replay. Workflow invocation can be `Lungfish.app export-annotation-table --tab ... --scope ... --format ... --output ...`; durable replay is the existing `/bin/cp` retained-payload command and explicitly says it replays export bytes, not upstream analysis.
- [ ] Record writer/app version, source and output checksums/sizes, source provenance links, actual system zip path/argv and runtime where applicable, filters, sort, row count, column IDs, numeric/missing/formula policies, coordinate convention and output format. `startedAt` precedes collection; completion occurs after rendering. No temporary output path becomes the final output descriptor.
- [ ] On cancellation discard retained staging inputs unless recovery ownership requires retaining them. On any writer/provenance failure keep existing destination and its sidecar intact and show the actual error. Show successful row count/output filename after completion; no blocking success dialog needed.
- [ ] Service tests validate output bytes plus decodable provenance, original input checksums, final stored paths, exact selected identities/query metadata, durable replay byte equality, and rollback of preexisting data/sidecar on induced publication failure. Interface tests verify menu formats/scopes for all four modes, no selected-row fallback to all, capture before panel mutation, and no output on Cancel.
- [ ] Ask Sol builder to run `swift test --filter AnnotationTableExportServiceTests`, `swift test --filter AnnotationTableExportInterfaceTests`, `swift test --filter ScientificFileExportProvenanceTests` and `swift test --filter ViewerFilePanelFactoryTests`.

## Integration Acceptance

- [ ] With the same reference/iVar example as the screenshot, select one and several variants and export CSV/XLSX; AF `0.999628` stays full precision, position `29409` is numeric with explicit 1-based header, and annotations retain precise boundaries/length.
- [ ] Export All Matching when the display is capped and verify count against a complete query. Repeat with Annotations and Genotypes; do not rely on displayed row count as the expected count.
- [ ] Open workbook with an available existing spreadsheet viewer or inspect OOXML archive if Excel/Numbers is unavailable; ensure IDs/genes are strings and headers/freeze/autofilter are usable. Do not install software.
- [ ] Cancel a large export, change tab while the save sheet is present, and induce invalid destination/provenance failure. Confirm responsive UI and no partial successful files.
- [ ] Audit `BatchTableView`, metagenomics export entry points, and the new service for reusable concepts only. Existing other-domain exports keep their data semantics; do not mass-rewrite them in this Debug fix.
- [ ] Coordinator integrates this with hover, viewport and multi-selection changes; Sol Medium runs the requested Debug build and records the application path. This export plan does not own signing, packaging, or release publication.

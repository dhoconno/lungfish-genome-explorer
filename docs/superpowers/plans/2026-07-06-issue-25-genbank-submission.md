# Issue #25 — Create NCBI GenBank Submissions From LGE Bundles — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.
> **Read `docs/superpowers/specs/2026-07-06-weekly-issues-master-spec.md` first.** This is the largest issue; it is self-contained and can run in parallel with the others.

**Goal:** A user can produce a GenBank-ready submission package from an LGE assembly/consensus bundle: an annotated flat file plus the NCBI-facing artifacts they need to submit, via both GUI and a `lungfish genbank prepare` CLI command.

**Scope decision (from research):** LGE already has a working `GenBankWriter`, a `GenBankFormatExporter`, an `NCBIBioSampleExporter` (writes BioSample submission TSV), and an NCBI-aware `FASTQSampleMetadata` model. It has NO `table2asn`/`.sqn` submission-file support and NO automated NCBI API client. Building an OAuth-based auto-submitter is large, brittle, and undesirable for labs that require manual review. **Therefore this plan implements OFFLINE FILE PREPARATION** — produce the exact files a user uploads via NCBI's web portals — not automated submission. A future issue can layer automation on top.

**Architecture:** Add a `GenBankSubmissionService` (in `LungfishWorkflow`, so both app and CLI can call it) that takes a sequence source (assembly contigs / consensus FASTA or an imported `GenomicDocument`), its annotations, and sample metadata, and emits a submission folder:
```
<name>-genbank-submission/
  sequence.fasta              # raw sequence(s)
  sequence.gb                 # annotated GenBank flat file (via existing GenBankWriter)
  source_modifiers.src        # NCBI source-modifier table (organism, isolate, host, country, collection_date, ...)
  biosample.tsv               # NCBI BioSample submission template (via existing NCBIBioSampleExporter)
  feature_table.tbl           # NCBI 5-column feature table (from annotations) [optional if annotations present]
  manifest.json               # provenance: tool versions, source bundle, generation date
  README.txt                  # plain-text submission instructions
```
The service is an `OperationCenter`-tracked operation in the GUI and an `AsyncParsableCommand` in the CLI. We reuse `GenBankWriter`, `NCBIBioSampleExporter`, `GFF3Reader`/annotation models, and `FASTQSampleMetadata`; we ADD a `.src` source-modifier writer and a `.tbl` feature-table writer (small, well-specified formats).

**Tech Stack:** Swift 6.2, ArgumentParser (CLI), XCTest, SwiftUI (a submission dialog).

## Global Constraints

- Build/test/serialization/green-bar per master spec §1.3–§1.4.
- CLI parity is intrinsic here (the CLI command is a first-class deliverable).
- The GUI operation uses `OperationCenter.shared` (`LungfishKit`): `update` + `log`, terminating `.complete`/`.fail`.
- Do not put a `LungfishApp` type into `LungfishWorkflow`/kernel (layering rule).
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Acceptance criteria

1. Given an assembly/consensus bundle + optional annotations + sample metadata, the service produces the submission folder above with valid `sequence.fasta`, `sequence.gb`, `source_modifiers.src`, `biosample.tsv`, and `manifest.json`; `feature_table.tbl` when annotations are present.
2. `source_modifiers.src` is a valid NCBI source-modifier TSV with a `Sequence_ID` column and the standard source qualifiers populated from metadata.
3. `feature_table.tbl` is a valid NCBI 5-column feature table for the provided annotations.
4. `lungfish genbank prepare --sequence <fasta> [--annotations <gff/gb>] [--sample-metadata <csv>] --organism <name> --output <dir>` produces the folder; `lungfish genbank validate <folder>` sanity-checks it.
5. A GUI menu action ("Prepare GenBank Submission…") runs the same service on the selected bundle with a metadata form, tracked in OperationCenter.
6. Suite is GREEN, with format-writer unit tests and an end-to-end fixture test.

## Key building blocks (reuse — do NOT rebuild)

- `Sources/LungfishIO/Formats/GenBank/GenBankReader.swift` — `GenBankWriter` (~955–1050), `GenBankRecord`, `LocusInfo` (~797–870).
- `Sources/LungfishIO/Registry/BuiltInFormats.swift` — `GenBankFormatExporter` (~117–174), `FASTAFormatExporter` (~35–71).
- `Sources/LungfishIO/Formats/FASTQ/NCBIBioSampleExporter.swift` — BioSample TSV writer (packages `Pathogen.cl.1.0` / `Pathogen.env.1.0`).
- `Sources/LungfishIO/Formats/FASTQ/FASTQSampleMetadata.swift` — NCBI-aware metadata (`organism`, `collectionDate`, `geoLocName`, `host`, `isolationSource`, `customFields`, …).
- `Sources/LungfishCore/Models/{Sequence,SequenceAnnotation,GenomicDocument,SampleMetadataStore}.swift` — data models.
- `Sources/LungfishWorkflow/Assembly/AssemblyResult.swift` — assembly output (`contigsPath`, …).
- `Sources/LungfishIO/Formats/GFF/GFF3Reader.swift` — annotation parsing/`GFF3Writer`.
- `Sources/LungfishCLI/Commands/BundleCommand.swift` — subcommand pattern to mirror.

---

### Task 1: NCBI source-modifier (`.src`) writer

**Files:**
- Create: `Sources/LungfishIO/Formats/NCBI/SourceModifierTableWriter.swift`
- Test: `Tests/LungfishIOTests/SourceModifierTableWriterTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct SourceModifier: Sendable {
      public var sequenceID: String
      public var organism: String?
      public var isolate: String?
      public var host: String?
      public var country: String?          // NCBI "country" / geo_loc_name
      public var collectionDate: String?   // ISO 8601 or GenBank date
      public var isolationSource: String?
      public var extra: [String: String]   // any additional qualifier columns
  }
  public enum SourceModifierTableWriter {
      /// Writes an NCBI source-modifier table (tab-separated, one header row,
      /// one row per sequence). First column header is "Sequence_ID".
      public static func makeTable(_ modifiers: [SourceModifier]) -> String
      public static func write(_ modifiers: [SourceModifier], to url: URL) throws
  }
  ```

**Format reference:** NCBI source-modifier tables are TSV. Column 1 header MUST be `Sequence_ID` (or `SeqID`). Remaining columns are qualifier names (e.g. `organism`, `isolate`, `host`, `country`, `collection_date`, `isolation_source`). Only include columns for which at least one row has a value. Escape nothing beyond tab/newline stripping in cell values.

- [ ] **Step 1: Write the failing test.**

```swift
import XCTest
@testable import LungfishIO

final class SourceModifierTableWriterTests: XCTestCase {
    func testTableHasSequenceIDHeaderAndPopulatedColumns() {
        let mods = [
            SourceModifier(sequenceID: "seq1", organism: "Influenza A virus", isolate: "A/WI/01/2026",
                           host: "Homo sapiens", country: "USA: Wisconsin", collectionDate: "2026-01-15",
                           isolationSource: "nasopharyngeal swab", extra: [:])
        ]
        let table = SourceModifierTableWriter.makeTable(mods)
        let lines = table.split(separator: "\n", omittingEmptySubsequences: false)
        let header = lines[0].split(separator: "\t").map(String.init)
        XCTAssertEqual(header.first, "Sequence_ID")
        XCTAssertTrue(header.contains("organism"))
        XCTAssertTrue(header.contains("collection_date"))
        let row = lines[1].split(separator: "\t").map(String.init)
        XCTAssertEqual(row.first, "seq1")
        XCTAssertTrue(row.contains("Influenza A virus"))
    }

    func testOmitsColumnsWithNoValues() {
        let mods = [SourceModifier(sequenceID: "s", organism: "X", isolate: nil, host: nil,
                                   country: nil, collectionDate: nil, isolationSource: nil, extra: [:])]
        let table = SourceModifierTableWriter.makeTable(mods)
        XCTAssertFalse(table.contains("host"))   // no host value anywhere → column omitted
        XCTAssertTrue(table.contains("organism"))
    }
}
```

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement `SourceModifierTableWriter.swift`.** Build the ordered set of columns that have at least one non-nil value across rows (fixed order: organism, isolate, host, country, collection_date, isolation_source, then sorted `extra` keys), emit header `Sequence_ID` + those, then one row per modifier with empty cells for missing values. `write(_:to:)` writes UTF-8.

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Commit** `feat(ncbi): add source-modifier (.src) table writer`.

---

### Task 2: NCBI 5-column feature-table (`.tbl`) writer

**Files:**
- Create: `Sources/LungfishIO/Formats/NCBI/FeatureTableWriter.swift`
- Test: `Tests/LungfishIOTests/FeatureTableWriterTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum FeatureTableWriter {
      /// NCBI 5-column feature table (.tbl). One `>Feature <SeqID>` block per
      /// sequence, then per annotation: start\tend\ttype, and continuation
      /// lines `\t\t\tqualifier\tvalue`.
      public static func makeTable(sequenceID: String, annotations: [SequenceAnnotation]) -> String
      public static func write(sequenceID: String, annotations: [SequenceAnnotation], to url: URL) throws
  }
  ```

**Format reference:** NCBI `.tbl`:
```
>Feature seq1
1	1002	gene
			gene	NP
1	1002	CDS
			product	nucleoprotein
			protein_id	seq1_NP
```
Columns are tab-separated. For minus-strand features, start > end (swap). Multi-interval features emit the first interval on the type line and subsequent intervals as bare `start\tend` lines before qualifiers.

- [ ] **Step 1: Write the failing test.**

```swift
import XCTest
@testable import LungfishIO
@testable import LungfishCore

final class FeatureTableWriterTests: XCTestCase {
    func testSingleCDSFeature() {
        let ann = SequenceAnnotation.testCDS(name: "NP", start: 1, end: 1002, strand: .forward, product: "nucleoprotein")
        let tbl = FeatureTableWriter.makeTable(sequenceID: "seq1", annotations: [ann])
        XCTAssertTrue(tbl.hasPrefix(">Feature seq1"))
        XCTAssertTrue(tbl.contains("1\t1002\tCDS"))
        XCTAssertTrue(tbl.contains("\t\t\tproduct\tnucleoprotein"))
    }

    func testMinusStrandSwapsCoordinates() {
        let ann = SequenceAnnotation.testCDS(name: "X", start: 10, end: 50, strand: .reverse, product: "p")
        let tbl = FeatureTableWriter.makeTable(sequenceID: "s", annotations: [ann])
        XCTAssertTrue(tbl.contains("50\t10\tCDS"))
    }
}
```
Add a `SequenceAnnotation.testCDS(...)` test helper (or construct via the real initializer — read `SequenceAnnotation.swift` for `type`, `intervals`, `strand`, `qualifiers`).

- [ ] **Step 2: Run — expect FAIL.**

- [ ] **Step 3: Implement `FeatureTableWriter.swift`.** Emit `>Feature <seqID>`, then per annotation map `SequenceAnnotation.type` to a GenBank feature key (gene/CDS/rRNA/tRNA/misc_feature), write `start\tend\ttype` (swap for reverse strand), additional intervals as bare coordinate lines, then qualifiers as `\t\t\t<key>\t<value>` (product, gene, note, protein_id, etc., derived from the annotation's `qualifiers`/`name`/`note`).

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Commit** `feat(ncbi): add 5-column feature table (.tbl) writer`.

---

### Task 3: `GenBankSubmissionService` (orchestrator, in LungfishWorkflow)

**Files:**
- Create: `Sources/LungfishWorkflow/Submission/GenBankSubmissionService.swift`
- Test: `Tests/LungfishWorkflowTests/GenBankSubmissionServiceTests.swift`

**Interfaces:**
- Consumes: `GenBankWriter`, `NCBIBioSampleExporter`, `SourceModifierTableWriter` (T1), `FeatureTableWriter` (T2), `Sequence`/`SequenceAnnotation`/`GenomicDocument`, `FASTQSampleMetadata`.
- Produces:
  ```swift
  public struct GenBankSubmissionInput: Sendable {
      public var sequences: [Sequence]
      public var annotationsBySequence: [String: [SequenceAnnotation]]   // keyed by sequence id/name
      public var metadata: [String: FASTQSampleMetadata]                 // keyed by sequence id
      public var submissionName: String
      public var sourceBundlePath: URL?
  }
  public struct GenBankSubmissionResult: Sendable {
      public var outputDirectory: URL
      public var fastaURL: URL
      public var genbankURL: URL
      public var sourceModifiersURL: URL
      public var bioSampleURL: URL
      public var featureTableURL: URL?
      public var manifestURL: URL
  }
  public enum GenBankSubmissionService {
      public static func prepare(_ input: GenBankSubmissionInput,
                                 outputParent: URL,
                                 progress: (@Sendable (Double, String) -> Void)?) async throws -> GenBankSubmissionResult
  }
  ```

- [ ] **Step 1: Write the failing end-to-end test.** Using the SARS-CoV-2 fixture (`Tests/Fixtures/sarscov2/` FASTA + GFF3), build an input with one sequence + its annotations + minimal metadata (organism "Severe acute respiratory syndrome coronavirus 2", collection date, country), call `prepare`, and assert every promised file exists and is non-empty, that `sequence.gb` round-trips through `GenBankReader` to at least one record, and that `source_modifiers.src` header starts with `Sequence_ID`.

```swift
func testPrepareProducesAllSubmissionFiles() async throws {
    let input = GenBankSubmissionInput(/* built from fixtures */)
    let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let result = try await GenBankSubmissionService.prepare(input, outputParent: out, progress: nil)
    let fm = FileManager.default
    for url in [result.fastaURL, result.genbankURL, result.sourceModifiersURL, result.bioSampleURL, result.manifestURL] {
        XCTAssertTrue(fm.fileExists(atPath: url.path), "missing \(url.lastPathComponent)")
    }
    // .gb must be parseable back:
    let records = try GenBankReader(/* url: result.genbankURL */).read()
    XCTAssertGreaterThan(records.count, 0)
}
```
(Adjust `GenBankReader` construction to its real API.)

- [ ] **Step 2: Run — expect FAIL** (service missing).

- [ ] **Step 3: Implement `prepare`.** Create the output dir; write `sequence.fasta` (reuse FASTA exporter); build `GenBankRecord`s from sequences+annotations and write `sequence.gb` (reuse `GenBankWriter`/`GenBankFormatExporter` conversion); build `[SourceModifier]` from metadata and write `source_modifiers.src` (T1); write `biosample.tsv` via `NCBIBioSampleExporter`; if any sequence has annotations, write `feature_table.tbl` (T2, per sequence, concatenated or one file with multiple `>Feature` blocks); write `manifest.json` (submission name, generation date passed in — do NOT call `Date()` inside a place that must be deterministic for tests; accept a `generatedAt` or stamp after), tool versions, source bundle path; write `README.txt` with submission instructions. Emit `progress` at each stage. Keep this type free of any `LungfishApp` dependency.

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Commit** `feat(genbank): add GenBankSubmissionService offline prep`.

---

### Task 4: CLI — `lungfish genbank prepare` / `validate`

**Files:**
- Create: `Sources/LungfishCLI/Commands/GenBankCommand.swift`
- Modify: `Sources/LungfishCLI/LungfishCLI.swift` (register `GenBankCommand.self` in `subcommands`)
- Test: `Tests/LungfishCLITests/GenBankCommandTests.swift`

**Interfaces:**
- Consumes: `GenBankSubmissionService` (T3); annotation loading (`GFF3Reader`/`GenBankReader`); metadata loading (CSV → `FASTQSampleMetadata`).
- Produces: `lungfish genbank prepare ...` and `lungfish genbank validate <dir>`.

- [ ] **Step 1: Write the failing test.** Invoke the command's `run()` (or a testable inner function) with fixture paths and a temp `--output`, assert exit success and that the output folder contains the expected files. For `validate`, point it at a folder missing `sequence.gb` and assert a non-zero/validation-error result.

- [ ] **Step 2: Run — expect FAIL** (command missing).

- [ ] **Step 3: Implement `GenBankCommand`.**
  ```swift
  struct GenBankCommand: AsyncParsableCommand {
      static let configuration = CommandConfiguration(
          commandName: "genbank",
          abstract: "Prepare NCBI GenBank submission packages from LGE sequences.",
          subcommands: [Prepare.self, Validate.self])
  }
  ```
  `Prepare`: `@Option --sequence` (FASTA/GenBank), `@Option --annotations` (GFF3/GenBank, optional), `@Option --sample-metadata` (CSV, optional), `@Option --organism`, plus `--isolate/--host/--country/--collection-date` conveniences, `@Option --output`, `@OptionGroup globalOptions`. Load sequences+annotations, build `GenBankSubmissionInput`, call `GenBankSubmissionService.prepare`, print the produced paths. `Validate`: check the folder has the required files and that `sequence.gb` parses; print a report.

- [ ] **Step 4: Run — expect PASS.** Manual: `.build/debug/lungfish-cli genbank prepare --sequence Tests/Fixtures/sarscov2/... --organism "..." --output <tmp>` then `... genbank validate <tmp>`.

- [ ] **Step 5: Commit** `feat(cli): add lungfish genbank prepare/validate`.

---

### Task 5: GUI — "Prepare GenBank Submission…" action + metadata form

**Files:**
- Create: `Sources/LungfishApp/Views/GenBank/GenBankSubmissionSheet.swift` (a dialog collecting organism/isolate/host/country/collection date + output location)
- Modify: `Sources/LungfishApp/App/AppDelegate+*.swift` — add the menu action + operation (place under the appropriate Tools/File menu; coordinate with issue #26 if that landed — add it as a top-level Tools item or under an "Export/Submit" grouping)
- Modify: `Sources/LungfishApp/App/MainMenu.swift` — add the menu item

**Interfaces:**
- Consumes: `GenBankSubmissionService` (T3); the currently-selected assembly/consensus bundle; `OperationCenter.shared`.
- Produces: a user flow that gathers metadata, runs the service off the main thread as an OperationCenter operation, and reveals the output folder.

- [ ] **Step 1: Add the sheet.** Build `GenBankSubmissionSheet` (SwiftUI or AppKit, matching sibling dialogs; per master spec UI conventions ~480–520px). Fields: organism (required), isolate, host, country, collection date, BioSample package (clinical/environmental), output location (default the project's folder). Prefill from the bundle's existing `SampleMetadataSection`/`FASTQSampleMetadata` if present.

- [ ] **Step 2: Add the menu action + operation.** A `@objc func prepareGenBankSubmission(_:)` that: resolves the selected sequence source (assembly contigs materialized to FASTA via `AssemblyResult`, or the loaded `GenomicDocument`), presents the sheet, and on confirm starts an OperationCenter operation:
  ```swift
  let opID = OperationCenter.shared.begin(type: .export /* or a genbankSubmission type */, title: "Prepare GenBank submission")
  Task.detached { [input, outputParent] in
      do {
          let result = try await GenBankSubmissionService.prepare(input, outputParent: outputParent) { p, msg in
              DispatchQueue.main.async { MainActor.assumeIsolated {
                  _ = OperationCenter.shared.update(id: opID, progress: p, detail: msg)
                  OperationCenter.shared.log(id: opID, level: .info, message: msg)
              } }
          }
          DispatchQueue.main.async { MainActor.assumeIsolated {
              OperationCenter.shared.complete(id: opID, detail: "Submission prepared")
              NSWorkspace.shared.activateFileViewerSelecting([result.outputDirectory])
          } }
      } catch {
          DispatchQueue.main.async { MainActor.assumeIsolated {
              OperationCenter.shared.fail(id: opID, detail: "Submission prep failed", errorMessage: error.localizedDescription)
          } }
      }
  }
  ```
  (Match the real `OperationCenter.begin/update/complete/fail` signatures from existing call sites. Follow the background→MainActor dispatch rule in master spec §1.6 exactly.)

- [ ] **Step 3: Build** → succeeds.

- [ ] **Step 4: GUI verification (required).** Launch `.build/debug/Lungfish` via computer-use. Open/assemble a consensus or assembly bundle, invoke "Prepare GenBank Submission…", fill the form, run it, and confirm the output folder opens in Finder with all files. Open `sequence.gb` and `source_modifiers.src` to confirm they look right. Screenshot the sheet and the resulting folder.

- [ ] **Step 5: Commit** `feat(genbank): GUI action to prepare GenBank submission`.

---

### Task 6: Documentation

**Files:** `docs/user-manual/**` (a short "Submitting to GenBank" section) — obey docs prose rules (no em dashes; bullet caps 5 items / 2 levels).

- [ ] **Step 1:** Write a concise section: what the feature produces, the CLI command, the GUI action, and the manual NCBI upload steps (which portal each file goes to). Keep to the prose rules.
- [ ] **Step 2:** If the manual has a `features.yaml` inventory (`docs/user-manual/features.yaml`), add the GenBank submission feature entry (the code-cartographer format).
- [ ] **Step 3: Commit** `docs: document GenBank submission preparation`.

---

### Final verification

- [ ] `swift build/test --package-path <worktree> --skip-update` → clean + GREEN, including the writer unit tests and the end-to-end service test.
- [ ] CLI: `genbank prepare` then `genbank validate` on the fixture succeeds; paste output into issue #25.
- [ ] GUI: screenshots of the sheet and the produced folder attached to issue #25.
- [ ] Confirm `.gb` and `.src` open cleanly (spot-check against NCBI format docs).

## Self-review checklist

- Spec coverage: `.src` writer (T1), `.tbl` writer (T2), orchestrating service (T3), CLI (T4), GUI (T5), docs (T6) → all criteria mapped. Automated NCBI submission is explicitly OUT of scope with rationale.
- No placeholders: both format writers have concrete format references and tests; the service enumerates every output file.
- Type consistency: `GenBankSubmissionInput`/`Result`/`prepare`, `SourceModifier`/`SourceModifierTableWriter`, `FeatureTableWriter` named identically across tasks.
- Layering: service lives in `LungfishWorkflow`; no `LungfishApp` type leaks downward.
- Determinism: `manifest.json` timestamp is injected/stamped outside the deterministic path (no argless `Date()` where a test needs stability).

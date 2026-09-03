# MSA Viewport and Sequence Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix six reported defects in the MAFFT multiple sequence alignment viewport and the FASTA paths next to it, so a user can extract selected sequences to a bundle, choose whether MAFFT aligns all or only selected sequences, read long sequence names, export the aligned FASTA, and never see a dead control.

**Architecture:** Every user-facing action shells out to `lungfish-cli` and reports through `OperationCenter`, matching `createReferenceBundleDirectlyFromDurableFASTA` and `exportMSASelectionViaCLI`. Workflow-layer changes (name resolution, provenance) land first because the GUI depends on them; view changes follow; the dead-control audit is last and independent.

**Tech Stack:** Swift 6.2, macOS 26, AppKit + SwiftUI, `@Observable` + `@MainActor`, strict concurrency, SwiftPM, XCTest + swift-testing, ViewInspector for SwiftUI view tests.

**Spec:** `docs/superpowers/specs/2026-09-03-msa-viewport-and-extraction-design.md`

## Global Constraints

- Swift `>=6.2,<7`; macOS deployment target 26.0; arm64 only.
- Build and test with `--package-path` and `--skip-update`; never `cd` out of the worktree. `swift` has no `-C` flag.
- **Serialize all swift invocations.** SwiftPM holds one `.build/.lock` per checkout. Never run a build while another agent may be building.
- Never `Task { @MainActor in }` from a GCD background context. Use `DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { … } }`.
- Never `%s` in `String(format:)` with a Swift String.
- Every operation calls **both** `OperationCenter.shared.update()` and `.log()`.
- Menu ellipses use U+2026 (`…`), never three periods.
- Accent colour is Lungfish Orange `#D47B3A`; use `Color.lungfishOrangeFallback` in SwiftUI.
- If a test module SIGSEGVs in `outlined init with copy` after a struct gains a stored property, the fix is `rm .build/arm64-apple-macosx/debug.yaml .build/arm64-apple-macosx/debug/description.json` then rebuild. It is not a code bug.
- Green bar means XCTest failures are empty and swift-testing failures are zero. `FileSystemWatcherTests` failing in a full run is a known environmental flake on this machine.

## File Structure

**Workflow layer (Tasks 1-3)**
- `Sources/LungfishWorkflow/MSA/MSASequenceSelection.swift` — new. The tiered name resolver, pure and testable, with no I/O.
- `Sources/LungfishWorkflow/MSA/MSAAlignmentRunRequest.swift` — add `includedSequenceNames`.
- `Sources/LungfishWorkflow/MSA/MAFFTAlignmentPipeline.swift` — filter in `stageInputFASTA`, emit `--sequence` in `defaultWrapperArgv`, warn on gapped input.

**CLI layer (Task 4)**
- `Sources/LungfishCLI/Commands/AlignCommand.swift` — `--sequence` option.

**GUI: alignment scope (Tasks 5-6)**
- `Sources/LungfishApp/Services/CLIMSAAlignmentRunner.swift` — pass the flags.
- `Sources/LungfishKit/MSASequenceScopePicker.swift` — new. The radio group, modelled on `MultiBundleRunModePicker`.
- `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift` — scope state and counts.
- `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift` — render the picker.
- `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` — pass durable source and names instead of only a staged temp bundle.

**GUI: extraction menus (Tasks 7-8)**
- `Sources/LungfishKit/FASTASequenceActionMenuBuilder.swift` — `createBundleMenuTitle`.
- `Sources/LungfishApp/Views/Viewer/ChromosomeNavigatorView.swift` — multi-select and the new menu item.
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift` — wire the callback.

**GUI: viewport fixes (Tasks 9-10)**
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift` — the MSA branch and the state guard.
- The eleven `hideXView()` teardown sites.
- `Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift` — resizable gutter.

**GUI: export sheet (Tasks 11-12)**
- `Sources/LungfishApp/Views/Viewer/MSAAlignmentExportSheet.swift` — new. Destination and format sheet.
- `Sources/LungfishApp/Views/Viewer/ViewerViewController+MSAExport.swift` — new. The three destination legs.
- `Sources/LungfishApp/Views/Sidebar/SidebarItem.swift` — `canExportAlignment`.
- `Sources/LungfishApp/Views/Sidebar/SidebarViewController+MenuDelegate.swift` — the sidebar item.

**Dead controls (Task 13)**
- `Sources/LungfishApp/Views/Inspector/InspectorViewModel.swift` — tab filtering.
- `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift` — drawer tab gating.
- `Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift` — live handlers, variable-site buttons.

---

### Task 1: Tiered sequence-name resolver

The single most important correctness piece. `parseFASTA` keeps the whole
header line as the record name, so `>MT192765.1 Severe acute respiratory
syndrome…` has a `name` of that entire string. Matching only on it would make
`--sequence MT192765.1` match nothing for nearly every real FASTA.

**Files:**
- Create: `Sources/LungfishWorkflow/MSA/MSASequenceSelection.swift`
- Test: `Tests/LungfishWorkflowTests/MSA/MSASequenceSelectionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `public enum MSASequenceSelection`
  - `public struct MSASequenceSelectionError: Error, Equatable` with cases
    `unmatched([String])` and `ambiguous(name: String, matches: [String])`
  - `public static func resolve(requestedNames: [String], records: [(name: String, sourceFile: String)], sanitize: (String) -> String) throws -> Set<Int>`
    returning the indices of records to keep.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import LungfishWorkflow

final class MSASequenceSelectionTests: XCTestCase {
    private func sanitize(_ value: String) -> String {
        let replaced = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
        let cleaned = replaced.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return cleaned.isEmpty ? "sequence" : cleaned
    }

    private let records: [(name: String, sourceFile: String)] = [
        ("MT192765.1 Severe acute respiratory syndrome coronavirus 2", "a.fasta"),
        ("OK091006.1 Influenza A virus segment 4", "a.fasta"),
        ("plain_name", "b.fasta"),
    ]

    func testMatchesExactRawName() throws {
        let kept = try MSASequenceSelection.resolve(
            requestedNames: ["MT192765.1 Severe acute respiratory syndrome coronavirus 2"],
            records: records,
            sanitize: sanitize
        )
        XCTAssertEqual(kept, [0])
    }

    func testMatchesFirstTokenAccession() throws {
        let kept = try MSASequenceSelection.resolve(
            requestedNames: ["MT192765.1"], records: records, sanitize: sanitize
        )
        XCTAssertEqual(kept, [0])
    }

    func testMatchesSanitizedDisplayLabel() throws {
        let kept = try MSASequenceSelection.resolve(
            requestedNames: ["OK091006.1_Influenza_A_virus_segment_4"],
            records: records,
            sanitize: sanitize
        )
        XCTAssertEqual(kept, [1])
    }

    func testReportsEveryUnmatchedNameTogether() {
        XCTAssertThrowsError(
            try MSASequenceSelection.resolve(
                requestedNames: ["nope", "plain_name", "also_missing"],
                records: records,
                sanitize: sanitize
            )
        ) { error in
            XCTAssertEqual(
                error as? MSASequenceSelectionError,
                .unmatched(["nope", "also_missing"])
            )
        }
    }

    func testAmbiguousRequestIsAnErrorNotASilentMultiInclude() {
        let duplicated: [(name: String, sourceFile: String)] = [
            ("SEQ1 first copy", "a.fasta"),
            ("SEQ1 second copy", "b.fasta"),
        ]
        XCTAssertThrowsError(
            try MSASequenceSelection.resolve(
                requestedNames: ["SEQ1"], records: duplicated, sanitize: sanitize
            )
        ) { error in
            guard case .ambiguous(let name, let matches)? = error as? MSASequenceSelectionError else {
                return XCTFail("expected .ambiguous, got \(error)")
            }
            XCTAssertEqual(name, "SEQ1")
            XCTAssertEqual(matches, ["SEQ1 first copy (a.fasta)", "SEQ1 second copy (b.fasta)"])
        }
    }

    func testEarlierTierWinsOverLaterTier() throws {
        // "alpha" is BOTH an exact raw name (index 1) and the first token of
        // index 0. Tier 1 must win, so only index 1 is kept.
        let tricky: [(name: String, sourceFile: String)] = [
            ("alpha beta gamma", "a.fasta"),
            ("alpha", "a.fasta"),
        ]
        let kept = try MSASequenceSelection.resolve(
            requestedNames: ["alpha"], records: tricky, sanitize: sanitize
        )
        XCTAssertEqual(kept, [1])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --skip-update --filter MSASequenceSelectionTests`
Expected: FAIL, `cannot find 'MSASequenceSelection' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
// MSASequenceSelection.swift - Tiered name resolution for MSA input subsetting
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum MSASequenceSelectionError: Error, Equatable, LocalizedError {
    case unmatched([String])
    case ambiguous(name: String, matches: [String])

    public var errorDescription: String? {
        switch self {
        case .unmatched(let names):
            let list = names.joined(separator: ", ")
            return "No sequence matched --sequence \(list). Names may be a full FASTA header, an accession, or the label shown in the alignment."
        case .ambiguous(let name, let matches):
            return "--sequence \(name) matched more than one record: \(matches.joined(separator: ", ")). Use a full header to disambiguate."
        }
    }
}

public enum MSASequenceSelection {
    /// Resolves requested names to record indices using ordered tiers. The
    /// first tier that matches a given requested name wins, so an exact raw
    /// header always beats a token match on a different record.
    public static func resolve(
        requestedNames: [String],
        records: [(name: String, sourceFile: String)],
        sanitize: (String) -> String
    ) throws -> Set<Int> {
        var kept: Set<Int> = []
        var unmatched: [String] = []

        // Tier keys, cheapest first. Tier 4 (finalLabel with its _2
        // disambiguator) is computed here so callers need not replicate the
        // pipeline's de-duplication.
        var seen: [String: Int] = [:]
        var finalLabels: [String] = []
        for record in records {
            let base = sanitize(record.name)
            let occurrence = seen[base, default: 0] + 1
            seen[base] = occurrence
            finalLabels.append(occurrence == 1 ? base : "\(base)_\(occurrence)")
        }

        for requested in requestedNames {
            let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let tiers: [[Int]] = [
                records.indices.filter { records[$0].name == trimmed },
                records.indices.filter { sanitize(records[$0].name) == trimmed },
                records.indices.filter { firstToken(records[$0].name) == trimmed },
                records.indices.filter { finalLabels[$0] == trimmed },
            ]

            guard let hits = tiers.first(where: { !$0.isEmpty }) else {
                unmatched.append(trimmed)
                continue
            }
            if hits.count > 1 {
                throw MSASequenceSelectionError.ambiguous(
                    name: trimmed,
                    matches: hits.map { "\(records[$0].name) (\(records[$0].sourceFile))" }
                )
            }
            kept.insert(hits[0])
        }

        if !unmatched.isEmpty {
            throw MSASequenceSelectionError.unmatched(unmatched)
        }
        return kept
    }

    static func firstToken(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? value
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --skip-update --filter MSASequenceSelectionTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/MSA/MSASequenceSelection.swift Tests/LungfishWorkflowTests/MSA/MSASequenceSelectionTests.swift
git commit -m "feat: tiered name resolver for MSA sequence subsetting"
```

---

### Task 2: Carry the selection on the run request

**Files:**
- Modify: `Sources/LungfishWorkflow/MSA/MSAAlignmentRunRequest.swift:94-142`
- Test: `Tests/LungfishWorkflowTests/MSA/MAFFTAlignmentPipelineTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `MSAAlignmentRunRequest.includedSequenceNames: [String]?`, a new
  **last** init parameter defaulting to `nil`. Placing it last keeps all
  eleven existing call sites source-compatible.

- [ ] **Step 1: Write the failing test**

Append to `MAFFTAlignmentPipelineTests`:

```swift
func testIncludedSequenceNamesDefaultsToNilAndRoundTripsThroughCodable() throws {
    let project = URL(fileURLWithPath: "/workspace/Project.lungfish")
    let plain = MSAAlignmentRunRequest(
        tool: .mafft,
        inputSequenceURLs: [project.appendingPathComponent("in.fasta")],
        projectURL: project,
        outputBundleURL: nil,
        name: "Aligned",
        threads: nil
    )
    XCTAssertNil(plain.includedSequenceNames)

    let subset = MSAAlignmentRunRequest(
        tool: .mafft,
        inputSequenceURLs: [project.appendingPathComponent("in.fasta")],
        projectURL: project,
        outputBundleURL: nil,
        name: "Aligned",
        threads: nil,
        includedSequenceNames: ["seqA", "seqB"]
    )
    let data = try JSONEncoder().encode(subset)
    let decoded = try JSONDecoder().decode(MSAAlignmentRunRequest.self, from: data)
    XCTAssertEqual(decoded.includedSequenceNames, ["seqA", "seqB"])

    // A payload written before this field existed must still decode.
    let legacy = try JSONEncoder().encode(plain)
    var object = try XCTUnwrap(
        JSONSerialization.jsonObject(with: legacy) as? [String: Any]
    )
    object.removeValue(forKey: "includedSequenceNames")
    let trimmed = try JSONSerialization.data(withJSONObject: object)
    let legacyDecoded = try JSONDecoder().decode(MSAAlignmentRunRequest.self, from: trimmed)
    XCTAssertNil(legacyDecoded.includedSequenceNames)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path . --skip-update --filter testIncludedSequenceNamesDefaultsToNil`
Expected: FAIL, `extra argument 'includedSequenceNames' in call`.

- [ ] **Step 3: Add the property**

In `MSAAlignmentRunRequest`, add the stored property after
`allowFASTQAssemblyInputs`:

```swift
    public let allowFASTQAssemblyInputs: Bool
    /// Names of the input records to align. `nil` aligns every record.
    /// Resolved through `MSASequenceSelection.resolve`, so an entry may be a
    /// full FASTA header, an accession, or the sanitized display label.
    public let includedSequenceNames: [String]?
```

Add the init parameter **last**, and assign it last:

```swift
        allowFASTQAssemblyInputs: Bool = false,
        includedSequenceNames: [String]? = nil
    ) {
```

```swift
        self.allowFASTQAssemblyInputs = allowFASTQAssemblyInputs
        self.includedSequenceNames = includedSequenceNames
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path . --skip-update --filter testIncludedSequenceNamesDefaultsToNil`
Expected: PASS.

If the test module SIGSEGVs in `outlined init with copy`, that is the stale
incremental object described in Global Constraints. Remove
`.build/arm64-apple-macosx/debug.yaml` and
`.build/arm64-apple-macosx/debug/description.json`, rebuild, and re-run. Do not
change the code.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/MSA/MSAAlignmentRunRequest.swift Tests/LungfishWorkflowTests/MSA/MAFFTAlignmentPipelineTests.swift
git commit -m "feat: carry an optional sequence include-list on the MSA run request"
```

---

### Task 3: Filter, record, and warn in the pipeline

Three linked changes in one task because they share a test fixture and none is
independently shippable: without the provenance change a subset run records a
command that re-runs on everything.

**Files:**
- Modify: `Sources/LungfishWorkflow/MSA/MAFFTAlignmentPipeline.swift:275-355` (`stageInputFASTA`), `:510-545` (`defaultWrapperArgv`)
- Test: `Tests/LungfishWorkflowTests/MSA/MAFFTAlignmentPipelineTests.swift`

**Interfaces:**
- Consumes: `MSASequenceSelection.resolve` (Task 1),
  `MSAAlignmentRunRequest.includedSequenceNames` (Task 2).
- Produces: filtered staging; `--sequence` flags in the canonical argv; a
  `gappedInput` warning string.

- [ ] **Step 1: Write the failing tests**

```swift
func testStageInputFASTAKeepsOnlyTheRequestedSequences() async throws {
    let workspace = try makeWorkspace()
    let input = workspace.appendingPathComponent("many.fasta")
    let project = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
    try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
    try """
    >MT192765.1 first record
    ACGT
    >OK091006.1 second record
    ACGA
    >AB000001.1 third record
    ACGC
    """.write(to: input, atomically: true, encoding: .utf8)

    let request = MSAAlignmentRunRequest(
        tool: .mafft,
        inputSequenceURLs: [input],
        projectURL: project,
        outputBundleURL: nil,
        name: "Subset",
        threads: nil,
        includedSequenceNames: ["MT192765.1", "AB000001.1"]
    )
    let staged = workspace.appendingPathComponent("staged.fasta")
    let result = try await MAFFTAlignmentPipeline()
        .testingStageInputFASTA([input], to: staged, request: request)

    XCTAssertEqual(result.recordCount, 2)
    let text = try String(contentsOf: staged, encoding: .utf8)
    XCTAssertTrue(text.contains("MT192765.1_first_record"))
    XCTAssertTrue(text.contains("AB000001.1_third_record"))
    XCTAssertFalse(text.contains("OK091006.1"))
}

func testStageInputFASTAReportsTooFewSequencesDistinctlyFromNoMatch() async throws {
    let workspace = try makeWorkspace()
    let input = workspace.appendingPathComponent("many.fasta")
    let project = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
    try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
    try ">a first\nACGT\n>b second\nACGA\n".write(to: input, atomically: true, encoding: .utf8)

    func request(_ names: [String]) -> MSAAlignmentRunRequest {
        MSAAlignmentRunRequest(
            tool: .mafft, inputSequenceURLs: [input], projectURL: project,
            outputBundleURL: nil, name: "S", threads: nil, includedSequenceNames: names
        )
    }
    let staged = workspace.appendingPathComponent("staged.fasta")

    // One valid name: too few, not "no match".
    do {
        _ = try await MAFFTAlignmentPipeline()
            .testingStageInputFASTA([input], to: staged, request: request(["a"]))
        XCTFail("expected an error")
    } catch let error as MAFFTAlignmentPipelineError {
        XCTAssertEqual(error, .singleSequenceInput)
    }

    // A name that matches nothing must say so, not claim too few sequences.
    do {
        _ = try await MAFFTAlignmentPipeline()
            .testingStageInputFASTA([input], to: staged, request: request(["zzz"]))
        XCTFail("expected an error")
    } catch let error as MSASequenceSelectionError {
        XCTAssertEqual(error, .unmatched(["zzz"]))
    }
}

func testStageInputFASTAWarnsWhenInputIsAlreadyAligned() async throws {
    let workspace = try makeWorkspace()
    let input = workspace.appendingPathComponent("aligned.fasta")
    let project = workspace.appendingPathComponent("Project.lungfish", isDirectory: true)
    try fileManager.createDirectory(at: project, withIntermediateDirectories: true)
    try ">a\nAC-GT\n>b\nAC-GA\n".write(to: input, atomically: true, encoding: .utf8)

    let request = MSAAlignmentRunRequest(
        tool: .mafft, inputSequenceURLs: [input], projectURL: project,
        outputBundleURL: nil, name: "S", threads: nil
    )
    let staged = workspace.appendingPathComponent("staged.fasta")
    let result = try await MAFFTAlignmentPipeline()
        .testingStageInputFASTA([input], to: staged, request: request)

    XCTAssertTrue(
        result.warnings.contains { $0.contains("already contain gaps") },
        "expected a realign-an-alignment warning, got \(result.warnings)"
    )
}

func testWrapperArgvRecordsTheSequenceSubsetSoTheRunReproduces() throws {
    let project = URL(fileURLWithPath: "/workspace/Project.lungfish")
    let input = project.appendingPathComponent("in.fasta")
    let request = MSAAlignmentRunRequest(
        tool: .mafft, inputSequenceURLs: [input], projectURL: project,
        outputBundleURL: nil, name: "Subset", threads: nil,
        includedSequenceNames: ["seqA", "seqB"]
    )
    let argv = MAFFTAlignmentPipeline.testingDefaultWrapperArgv(
        request: request,
        outputBundleURL: project.appendingPathComponent("Out.lungfishmsa", isDirectory: true)
    )
    XCTAssertEqual(argv.filter { $0 == "--sequence" }.count, 2)
    XCTAssertTrue(argv.contains("seqA"))
    XCTAssertTrue(argv.contains("seqB"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --skip-update --filter MAFFTAlignmentPipelineTests`
Expected: FAIL, `value of type 'MAFFTAlignmentPipeline' has no member 'testingStageInputFASTA'`.

- [ ] **Step 3: Implement**

Add test seams next to the private methods in `MAFFTAlignmentPipeline`:

```swift
    func testingStageInputFASTA(
        _ inputURLs: [URL],
        to stagedInputURL: URL,
        request: MSAAlignmentRunRequest
    ) async throws -> StagedInputResult {
        try await stageInputFASTA(inputURLs, to: stagedInputURL, request: request)
    }

    static func testingDefaultWrapperArgv(
        request: MSAAlignmentRunRequest,
        outputBundleURL: URL
    ) -> [String] {
        MAFFTAlignmentPipeline().defaultWrapperArgv(request: request, outputBundleURL: outputBundleURL)
    }
```

In `stageInputFASTA`, collect every record across every input file **before**
filtering, so a name living in the second file is not a false negative. Replace
the `for inputURL in inputURLs` body's per-record loop with a two-pass shape:

```swift
        // Pass 1: read every input's records, keeping their origin.
        var pending: [(record: (name: String, sequence: String, quality: [UInt8]?),
                       inputURL: URL,
                       sequenceFormat: SequenceFormat,
                       annotations: [MultipleSequenceAlignmentBundle.SourceAnnotationInput])] = []
        for inputURL in inputURLs {
            // … existing resolution, format switch and parse, unchanged …
            let annotationsBySequence = try await sourceAnnotationsBySequence(for: inputURL, records: records)
            for record in records {
                pending.append((record, inputURL, sequenceFormat, annotationsBySequence[record.name, default: []]))
            }
        }

        // Warn before filtering: a gapped input means the user is realigning
        // an alignment, which MAFFT treats as residues and silently mangles.
        if pending.contains(where: { $0.record.sequence.contains("-") }) {
            warnings.append("Input sequences already contain gaps. Realigning an existing alignment produces unreliable results; remove gaps before aligning.")
        }

        // Pass 2: subset if requested.
        if let requested = request.includedSequenceNames {
            let keep = try MSASequenceSelection.resolve(
                requestedNames: requested,
                records: pending.map { ($0.record.name, $0.inputURL.lastPathComponent) },
                sanitize: sanitizedLabel
            )
            let excluded = pending.indices.filter { !keep.contains($0) }.map { pending[$0].record.name }
            pending = pending.indices.filter { keep.contains($0) }.map { pending[$0] }
            warnings.append("Aligned \(pending.count) of \(pending.count + excluded.count) input sequences.")
            if !excluded.isEmpty {
                warnings.append("Excluded: \(excluded.joined(separator: ", ")).")
            }
        }
```

Then run the existing labelling and accumulation loop over `pending` instead of
over `records`, unchanged in behaviour.

In `defaultWrapperArgv`, before the closing `return argv`:

```swift
        for name in request.includedSequenceNames ?? [] {
            argv += ["--sequence", name]
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --skip-update --filter MAFFTAlignmentPipelineTests`
Expected: PASS, including the eight pre-existing tests in that file.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishWorkflow/MSA/MAFFTAlignmentPipeline.swift Tests/LungfishWorkflowTests/MSA/MAFFTAlignmentPipelineTests.swift
git commit -m "feat: subset MAFFT input by sequence name, with provenance and a gapped-input warning"
```

---

### Task 4: Expose `--sequence` on the CLI

**Files:**
- Modify: `Sources/LungfishCLI/Commands/AlignCommand.swift:28-96` and `:255-283`
- Test: `Tests/LungfishCLITests/AlignCommandTests.swift`

**Interfaces:**
- Consumes: `MSAAlignmentRunRequest.includedSequenceNames` (Task 2).
- Produces: `lungfish-cli align mafft --sequence <name>` (repeatable).

- [ ] **Step 1: Write the failing test**

```swift
func testMAFFTCommandPassesRepeatedSequenceFlagsIntoTheRequest() async throws {
    let project = URL(fileURLWithPath: "/workspace/Project.lungfish")
    let input = project.appendingPathComponent("input.fasta")
    let command = try AlignCommand.MAFFTSubcommand.parse([
        "mafft", input.path,
        "--project", project.path,
        "--sequence", "MT192765.1",
        "--sequence", "OK091006.1",
        "--format", "json",
    ])
    XCTAssertEqual(command.sequences, ["MT192765.1", "OK091006.1"])

    // `makeRequestForTesting()` is the seam that exposes the built request
    // without running MAFFT. The runtime seam is `executeForTesting`.
    let request = try command.makeRequestForTesting()
    XCTAssertEqual(request.includedSequenceNames, ["MT192765.1", "OK091006.1"])
    XCTAssertEqual(request.wrapperArgv.filter { $0 == "--sequence" }.count, 2)
    XCTAssertTrue(request.wrapperArgv.contains("MT192765.1"))
}

func testMAFFTCommandOmitsIncludedNamesWhenNoSequenceFlagIsGiven() throws {
    let project = URL(fileURLWithPath: "/workspace/Project.lungfish")
    let command = try AlignCommand.MAFFTSubcommand.parse([
        "mafft", project.appendingPathComponent("input.fasta").path,
        "--project", project.path,
    ])
    XCTAssertTrue(command.sequences.isEmpty)
    XCTAssertNil(try command.makeRequestForTesting().includedSequenceNames)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path . --skip-update --filter AlignCommandTests`
Expected: FAIL, unknown option `--sequence`.

- [ ] **Step 3: Implement**

Add the option after `allowFASTQAssemblyInputs`:

```swift
        @Option(
            name: .customLong("sequence"),
            help: "Align only this sequence. Repeatable. Accepts a full FASTA header, an accession, or the label shown in the alignment."
        )
        var sequences: [String] = []
```

In `makeRequest()`, pass it, converting empty to nil so a plain run records no
selection:

```swift
                allowFASTQAssemblyInputs: allowFASTQAssemblyInputs,
                includedSequenceNames: sequences.isEmpty ? nil : sequences
```

`canonicalArgv` already delegates to `defaultWrapperArgv`, which Task 3 taught
to emit the flags, so nothing further is needed for provenance.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path . --skip-update --filter AlignCommandTests`
Expected: PASS.

- [ ] **Step 5: Verify end to end against the real fixture**

```bash
swift build --package-path . --skip-update --product lungfish-cli
```

```bash
rm -rf /tmp/msa-subset && mkdir -p /tmp/msa-subset && cp -R "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish" /tmp/msa-subset/Proj && rm -rf "/tmp/msa-subset/Proj/Multiple Sequence Alignments" && .build/arm64-apple-macosx/debug/lungfish-cli align mafft "/tmp/msa-subset/Proj/Inputs/sars-cov-2-genomes.fasta" --project /tmp/msa-subset/Proj --name Subset --sequence sarscov2_fixture_A_source --sequence sarscov2_fixture_C_short_deletion && grep -c '^>' "/tmp/msa-subset/Proj/Multiple Sequence Alignments/Subset.lungfishmsa/alignment/primary.aligned.fasta"
```

Expected: `2`. The five-genome fixture aligned down to the two named records.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishCLI/Commands/AlignCommand.swift Tests/LungfishCLITests/AlignCommandTests.swift
git commit -m "feat: add repeatable --sequence to align mafft"
```

---

### Task 5: Pass the selection through the GUI runner

**Files:**
- Modify: `Sources/LungfishApp/Services/CLIMSAAlignmentRunner.swift:61-109`
- Modify: `Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:1370-1436` (the `runMAFFTAlignment` call site)
- Test: `Tests/LungfishAppTests/CLIMSAAlignmentRunnerTests.swift`

**Interfaces:**
- Consumes: `--sequence` (Task 4).
- Produces: `CLIMSAAlignmentRunner.buildArguments(… includedSequenceNames: [String]? = nil)`, defaulted so existing call sites still compile.

- [ ] **Step 1: Write the failing test**

```swift
func testBuildArgumentsEmitsOneSequenceFlagPerIncludedName() {
    let args = CLIMSAAlignmentRunner.buildArguments(
        inputURLs: [URL(fileURLWithPath: "/tmp/in.fasta")],
        projectURL: URL(fileURLWithPath: "/tmp/Project.lungfish"),
        outputURL: nil,
        name: "Subset",
        strategy: "auto",
        outputOrder: "input",
        threads: nil,
        extraArguments: [],
        includedSequenceNames: ["seqA", "seqB"]
    )
    XCTAssertEqual(args.filter { $0 == "--sequence" }.count, 2)
    let seqAIndex = try? XCTUnwrap(args.firstIndex(of: "seqA"))
    XCTAssertNotNil(seqAIndex)
    XCTAssertEqual(args[(seqAIndex ?? 1) - 1], "--sequence")
}

func testBuildArgumentsOmitsSequenceFlagsWhenNoSelection() {
    let args = CLIMSAAlignmentRunner.buildArguments(
        inputURLs: [URL(fileURLWithPath: "/tmp/in.fasta")],
        projectURL: URL(fileURLWithPath: "/tmp/Project.lungfish"),
        outputURL: nil, name: nil, strategy: "auto", outputOrder: "input",
        threads: nil, extraArguments: []
    )
    XCTAssertFalse(args.contains("--sequence"))
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path . --skip-update --filter CLIMSAAlignmentRunnerTests`
Expected: FAIL, `extra argument 'includedSequenceNames' in call`.

- [ ] **Step 3: Implement**

Add the parameter last in `buildArguments`, before the closing paren:

```swift
        extraArguments: [String],
        includedSequenceNames: [String]? = nil
    ) -> [String] {
```

Emit the flags immediately before `args += ["--format", "json"]`, so the
`--format` terminator stays last:

```swift
        for name in includedSequenceNames ?? [] {
            args += ["--sequence", name]
        }
        args += ["--format", "json"]
```

At the `runMAFFTAlignment` call site, forward the request's field:

```swift
            extraArguments: request.extraArguments,
            includedSequenceNames: request.includedSequenceNames
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path . --skip-update --filter CLIMSAAlignmentRunnerTests`
Expected: PASS, including the six pre-existing tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Services/CLIMSAAlignmentRunner.swift Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift Tests/LungfishAppTests/CLIMSAAlignmentRunnerTests.swift
git commit -m "feat: forward the MSA sequence selection through the GUI runner"
```

---

### Task 6: The "Sequences to align" scope picker

**Files:**
- Create: `Sources/LungfishKit/MSASequenceScopePicker.swift`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationDialogState.swift:38-60` and `:831-855`
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQOperationToolPanes.swift:606-611`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift:2712-2741`
- Test: `Tests/LungfishAppTests/FASTQOperationsCatalogTests.swift`, `Tests/LungfishAppTests/FASTQOperationToolPanesSourceTests.swift`

**Interfaces:**
- Consumes: `MSAAlignmentRunRequest.includedSequenceNames` (Task 2).
- Produces:
  - `public enum MSASequenceScope: String, CaseIterable, Sendable { case all, selected }`
  - `public struct MSASequenceScopePicker: View` with
    `init(allCount: Int, selectedCount: Int, selection: Binding<MSASequenceScope>)`
  - `public static func isVisible(allCount: Int, selectedCount: Int) -> Bool`
  - `public static func rowStates(allCount: Int, selectedCount: Int) -> [RowState]`
  - `public static func summaryText(allCount: Int, selectedCount: Int) -> String`
  - On the dialog state: `var mafftSequenceScope: MSASequenceScope`,
    `var mafftAllSequenceCount: Int`, `var mafftSelectedSequenceNames: [String]`

- [ ] **Step 1: Write the failing tests**

Create `Tests/LungfishKitTests/MSASequenceScopePickerTests.swift`:

```swift
import XCTest
@testable import LungfishKit

final class MSASequenceScopePickerTests: XCTestCase {
    func testPickerIsHiddenWithoutARealChoice() {
        // No selection at all: nothing to choose between.
        XCTAssertFalse(MSASequenceScopePicker.isVisible(allCount: 12, selectedCount: 0))
        // Selection is the whole file: still not a choice.
        XCTAssertFalse(MSASequenceScopePicker.isVisible(allCount: 12, selectedCount: 12))
        // Unknown total, e.g. the staged-temp fallback.
        XCTAssertFalse(MSASequenceScopePicker.isVisible(allCount: 0, selectedCount: 4))
    }

    func testPickerIsVisibleForAProperSubset() {
        XCTAssertTrue(MSASequenceScopePicker.isVisible(allCount: 12, selectedCount: 4))
    }

    func testRowTitlesCarryTheCounts() {
        let rows = MSASequenceScopePicker.rowStates(allCount: 12, selectedCount: 4)
        XCTAssertEqual(rows.map(\.title), ["All sequences (12)", "Selected sequences (4)"])
    }

    func testSummaryTextReplacesThePickerWhenThereIsNoChoice() {
        XCTAssertEqual(
            MSASequenceScopePicker.summaryText(allCount: 12, selectedCount: 0),
            "Aligning all 12 sequences."
        )
        XCTAssertEqual(
            MSASequenceScopePicker.summaryText(allCount: 0, selectedCount: 4),
            "Aligning the 4 sequences you selected."
        )
    }
}
```

Append to `FASTQOperationsCatalogTests`:

```swift
func testMAFFTRequestCarriesSelectedNamesOnlyWhenScopeIsSelected() throws {
    let project = repositoryRoot()
        .appendingPathComponent(".build", isDirectory: true)
        .appendingPathComponent("Project.lungfish", isDirectory: true)
    let input = project.appendingPathComponent("input.fasta")
    let state = FASTQOperationDialogState(
        initialCategory: .alignment,
        selectedInputURLs: [input],
        projectURL: project
    )
    state.mafftAllSequenceCount = 12
    state.mafftSelectedSequenceNames = ["seqA", "seqB"]

    state.mafftSequenceScope = .all
    state.prepareForRun()
    XCTAssertNil(try XCTUnwrap(state.pendingMSAAlignmentRequest).includedSequenceNames)

    state.mafftSequenceScope = .selected
    state.prepareForRun()
    XCTAssertEqual(
        try XCTUnwrap(state.pendingMSAAlignmentRequest).includedSequenceNames,
        ["seqA", "seqB"]
    )
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --skip-update --filter "MSASequenceScopePickerTests|testMAFFTRequestCarriesSelectedNames"`
Expected: FAIL, `cannot find 'MSASequenceScopePicker' in scope`.

- [ ] **Step 3: Write the picker**

Model it on `MultiBundleRunModePicker`, including the pure `rowStates` seam and
the accessibility identifiers. Note the deliberate difference: this picker has
no locked-row concept, because a row the user cannot ever enable is noise.
Either there is a real choice and both rows are live, or the picker is replaced
by one line of text.

```swift
// MSASequenceScopePicker.swift - "Sequences to align" scope selector
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import SwiftUI

public enum MSASequenceScope: String, CaseIterable, Sendable {
    case all
    case selected
}

public struct MSASequenceScopePicker: View {
    let allCount: Int
    let selectedCount: Int
    @Binding var selection: MSASequenceScope

    public init(allCount: Int, selectedCount: Int, selection: Binding<MSASequenceScope>) {
        self.allCount = allCount
        self.selectedCount = selectedCount
        self._selection = selection
    }

    /// Visible only when both scopes are meaningful and different: a known
    /// total, a non-empty selection, and a selection smaller than the total.
    public nonisolated static func isVisible(allCount: Int, selectedCount: Int) -> Bool {
        allCount > 0 && selectedCount > 0 && selectedCount < allCount
    }

    public struct RowState: Equatable, Sendable {
        public let scope: MSASequenceScope
        public let title: String
        public let caption: String
    }

    public nonisolated static func rowStates(allCount: Int, selectedCount: Int) -> [RowState] {
        [
            RowState(
                scope: .all,
                title: "All sequences (\(allCount))",
                caption: "Every sequence in the source file."
            ),
            RowState(
                scope: .selected,
                title: "Selected sequences (\(selectedCount))",
                caption: "Only the sequences selected in the viewport."
            ),
        ]
    }

    /// Shown in place of the picker when there is no choice to make.
    public nonisolated static func summaryText(allCount: Int, selectedCount: Int) -> String {
        if selectedCount > 0 && (allCount == 0 || selectedCount == allCount) {
            return "Aligning the \(selectedCount) sequences you selected."
        }
        return "Aligning all \(allCount) sequences."
    }

    public var body: some View {
        if Self.isVisible(allCount: allCount, selectedCount: selectedCount) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sequences to align")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.lungfishSecondaryText)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.rowStates(allCount: allCount, selectedCount: selectedCount), id: \.scope) { row in
                        Button {
                            selection = row.scope
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: selection == row.scope ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(Color.lungfishOrangeFallback)
                                    .imageScale(.medium)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title).font(.system(size: 12))
                                    Text(row.caption)
                                        .font(.caption)
                                        .foregroundStyle(Color.lungfishSecondaryText)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mafft-sequence-scope-\(row.scope.rawValue)")
                        .accessibilityAddTraits(selection == row.scope ? .isSelected : [])
                    }
                }
            }
        } else {
            Text(Self.summaryText(allCount: allCount, selectedCount: selectedCount))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("mafft-sequence-scope-summary")
        }
    }
}
```

- [ ] **Step 4: Wire the dialog state**

In `FASTQOperationDialogState`, add stored properties next to the other MAFFT
state and initialise them in `init` to `.all`, `0`, and `[]`:

```swift
    var mafftSequenceScope: MSASequenceScope = .all
    var mafftAllSequenceCount: Int = 0
    var mafftSelectedSequenceNames: [String] = []
```

In `makeMSAAlignmentRequest()`, pass the names only when the scope is selected
and the list is non-empty:

```swift
            allowFASTQAssemblyInputs: mafftAllowFASTQAssemblyInputs,
            includedSequenceNames: (mafftSequenceScope == .selected && !mafftSelectedSequenceNames.isEmpty)
                ? mafftSelectedSequenceNames
                : nil
```

In `FASTQOperationToolPanes`, render it as the first control in the `.mafft`
case, above the existing `MultiBundleRunModePicker`:

```swift
            case .mafft:
                MSASequenceScopePicker(
                    allCount: state.mafftAllSequenceCount,
                    selectedCount: state.mafftSelectedSequenceNames.count,
                    selection: $state.mafftSequenceScope
                )

                MultiBundleRunModePicker(
```

- [ ] **Step 5: Preserve the counts on the way into the dialog**

`presentFASTAOperationDialog` currently stages the selection to a temp bundle,
which destroys the original record count. Change it to prefer the durable
source when there is exactly one FASTA source, so the dialog can offer a real
choice. Keep the staging path as the fallback.

In `ViewerViewController.presentFASTAOperationDialog`, before the staging
block:

```swift
        let durableSources = fastaExportSourceURLs()
        let selectedIDs = FASTAOperationCatalog.selectedIdentifiers(in: records.joined(separator: ""))
        if durableSources.count == 1,
           FASTAOperationCatalog.inputSequenceFormat(for: durableSources[0]) == .fasta,
           selectedIDs.count == records.count,
           let totalCount = try? FASTAOperationCatalog.recordCount(in: durableSources[0]),
           totalCount > selectedIDs.count {
            AppDelegate.shared?.showFASTQOperationsDialog(
                view,
                initialCategory: initialCategory,
                initialToolID: initialToolID,
                preferredInputURLs: [durableSources[0]],
                mafftAllSequenceCount: totalCount,
                mafftSelectedSequenceNames: selectedIDs
            )
            return
        }
```

Add the two defaulted parameters to `showFASTQOperationsDialog` and to
`FASTQOperationsDialogPresenter.present`, assigning them onto the state right
after `state.selectTool(initialToolID)`. Default them to `0` and `[]` so every
other caller is unaffected.

Add the `recordCount` helper to `FASTAOperationCatalog`:

```swift
    static func recordCount(in url: URL) throws -> Int {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").reduce(into: 0) { count, line in
            if line.hasPrefix(">") { count += 1 }
        }
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path . --skip-update --filter "MSASequenceScopePickerTests|FASTQOperationsCatalogTests"`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LungfishKit/MSASequenceScopePicker.swift Sources/LungfishApp/Views/FASTQ Sources/LungfishApp/Views/Viewer/ViewerViewController.swift Sources/LungfishApp/Views/Shared/FASTAOperationCatalog.swift Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift Tests/LungfishKitTests/MSASequenceScopePickerTests.swift Tests/LungfishAppTests/FASTQOperationsCatalogTests.swift
git commit -m "feat: explicit all-vs-selected scope for MAFFT alignment"
```

---

### Task 7: Rename the extraction menu items

**Files:**
- Modify: `Sources/LungfishKit/FASTASequenceActionMenuBuilder.swift:5-33` and `:62-117`
- Modify: `Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:1364-1402`
- Test: `Tests/LungfishKitTests/` (create `FASTASequenceActionMenuBuilderTests.swift` if absent; otherwise extend)

**Interfaces:**
- Consumes: nothing.
- Produces: `FASTASequenceActionHandlers.createBundleMenuTitle: String` and
  `.exportMenuTitle: String`, both defaulted.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import AppKit
@testable import LungfishKit

@MainActor
final class FASTASequenceActionMenuBuilderTests: XCTestCase {
    func testDefaultTitlesNameTheExtractionAction() {
        let items = FASTASequenceActionMenuBuilder.buildItems(
            selectionCount: 3,
            handlers: FASTASequenceActionHandlers(
                onCopy: {}, onExport: {}, onCreateBundle: {}
            )
        )
        let titles = items.map(\.title)
        XCTAssertTrue(titles.contains("Extract to New Bundle…"))
        XCTAssertTrue(titles.contains("Export FASTA…"))
        XCTAssertFalse(titles.contains("Create Bundle…"))
    }

    func testMSACanvasOverridesBothTitlesForABlockSelection() {
        let items = FASTASequenceActionMenuBuilder.buildItems(
            selectionCount: 3,
            handlers: FASTASequenceActionHandlers(
                onCopy: {},
                onExport: {},
                onCreateBundle: {},
                createBundleMenuTitle: "Extract Selection to New Bundle…",
                exportMenuTitle: "Export Selected Residues…"
            )
        )
        let titles = items.map(\.title)
        XCTAssertTrue(titles.contains("Extract Selection to New Bundle…"))
        XCTAssertTrue(titles.contains("Export Selected Residues…"))
    }

    func testEllipsesAreTheSingleCharacterForm() {
        let items = FASTASequenceActionMenuBuilder.buildItems(
            selectionCount: 1,
            handlers: FASTASequenceActionHandlers(onCopy: {}, onExport: {}, onCreateBundle: {})
        )
        for title in items.map(\.title) where title.hasSuffix("…") {
            XCTAssertFalse(title.contains("..."), "\(title) must use U+2026")
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path . --skip-update --filter FASTASequenceActionMenuBuilderTests`
Expected: FAIL, `extra argument 'createBundleMenuTitle'`.

- [ ] **Step 3: Implement**

Add two properties to `FASTASequenceActionHandlers`, following the existing
`blastMenuTitle` precedent, and add matching defaulted init parameters **after**
the existing ones so no call site breaks:

```swift
    public var createBundleMenuTitle: String = "Extract to New Bundle…"
    public var exportMenuTitle: String = "Export FASTA…"
```

In `buildItems`, replace the two hard-coded titles with
`handlers.exportMenuTitle` and `handlers.createBundleMenuTitle`.

In the MSA canvas's `selectionContextMenu()`, pass the overrides:

```swift
                onCreateBundle: { [weak self] in self?.createBundleFromSelectedSequences() },
                createBundleMenuTitle: "Extract Selection to New Bundle…",
                exportMenuTitle: "Export Selected Residues…",
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path . --skip-update --filter FASTASequenceActionMenuBuilderTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishKit/FASTASequenceActionMenuBuilder.swift Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift Tests/LungfishKitTests/FASTASequenceActionMenuBuilderTests.swift
git commit -m "feat: name the sequence extraction menu items for what they do"
```

---

### Task 8: Extract selected sequences from the reference-bundle viewport

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/ChromosomeNavigatorView.swift:179-192`, `:355-376`, `:404-435`
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift:426-440`
- Test: `Tests/LungfishAppTests/` (create `ChromosomeNavigatorSelectionTests.swift`)

**Interfaces:**
- Consumes: `createReferenceBundle(from:suggestedName:)`, already on
  `ViewerViewController`.
- Produces: `ChromosomeNavigatorView.onExtractSelectedSequencesRequested: (([ChromosomeInfo]) -> Void)?`
  and `func testingSelectRows(_ rows: [Int])`, `func testingContextMenuTitles(clickedRow: Int) -> [String]`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import AppKit
import LungfishCore
@testable import LungfishApp

@MainActor
final class ChromosomeNavigatorSelectionTests: XCTestCase {
    private func makeNavigator() -> ChromosomeNavigatorView {
        let navigator = ChromosomeNavigatorView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        navigator.chromosomes = [
            ChromosomeInfo(name: "seg1", length: 1741),
            ChromosomeInfo(name: "seg2", length: 1497),
            ChromosomeInfo(name: "seg3", length: 982),
        ]
        return navigator
    }

    func testMultipleRowsCanBeSelected() {
        let navigator = makeNavigator()
        navigator.testingSelectRows([0, 2])
        XCTAssertEqual(navigator.testingSelectedChromosomeNames, ["seg1", "seg3"])
    }

    func testExtractItemIsFirstAndSeparatedFromTheCopyItems() {
        let navigator = makeNavigator()
        navigator.onExtractSelectedSequencesRequested = { _ in }
        navigator.testingSelectRows([0, 1])
        let titles = navigator.testingContextMenuTitles(clickedRow: 0)
        XCTAssertEqual(titles.first, "Extract to New Bundle…")
        XCTAssertEqual(titles.dropFirst().first, "")  // separator
        XCTAssertTrue(titles.contains("Copy Name"))
    }

    func testExtractItemIsAbsentWhenNoHandlerIsWired() {
        let navigator = makeNavigator()
        navigator.testingSelectRows([0])
        XCTAssertFalse(navigator.testingContextMenuTitles(clickedRow: 0).contains("Extract to New Bundle…"))
    }

    func testRightClickOutsideTheSelectionTargetsTheClickedRowAlone() {
        let navigator = makeNavigator()
        navigator.onExtractSelectedSequencesRequested = { _ in }
        navigator.testingSelectRows([0, 1])
        _ = navigator.testingContextMenuTitles(clickedRow: 2)
        XCTAssertEqual(navigator.testingSelectedChromosomeNames, ["seg3"])
    }

    func testHandlerReceivesEverySelectedChromosome() {
        let navigator = makeNavigator()
        var received: [String] = []
        navigator.onExtractSelectedSequencesRequested = { received = $0.map(\.name) }
        navigator.testingSelectRows([0, 2])
        navigator.testingInvokeContextMenuItem(titled: "Extract to New Bundle…", clickedRow: 0)
        XCTAssertEqual(received, ["seg1", "seg3"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --skip-update --filter ChromosomeNavigatorSelectionTests`
Expected: FAIL, no member `testingSelectRows`.

- [ ] **Step 3: Implement**

Enable multi-selection:

```swift
        tableView.allowsMultipleSelection = true
```

Add the callback next to the delegate property:

```swift
    /// Invoked with every selected chromosome when the user asks to extract
    /// them. A `nil` handler omits the menu item entirely.
    public var onExtractSelectedSequencesRequested: (([ChromosomeInfo]) -> Void)?
```

Guard navigation so a range selection does not navigate somewhere arbitrary.
In `tableViewSelectionDidChange`, before calling the delegate:

```swift
        // Shift- or command-click extends the selection; navigating on every
        // such change would fire the primary action N times and jump the
        // viewport somewhere the user did not click.
        guard tableView.selectedRowIndexes.count == 1 else { return }
```

In `menuNeedsUpdate`, reconcile the selection first, then build:

```swift
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < displayedChromosomes.count else { return }

        // Right-clicking outside the current selection targets that row alone,
        // matching FASTACollectionViewController.reconcileContextMenuSelection.
        if !tableView.selectedRowIndexes.contains(clickedRow) {
            tableView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        if let handler = onExtractSelectedSequencesRequested {
            let selected = selectedChromosomes()
            let extractItem = NSMenuItem(
                title: "Extract to New Bundle\u{2026}",
                action: #selector(extractSelectedChromosomes(_:)),
                keyEquivalent: ""
            )
            extractItem.target = self
            extractItem.isEnabled = !selected.isEmpty
            _ = handler
            menu.addItem(extractItem)
            menu.addItem(.separator())
        }

        let chromosome = displayedChromosomes[clickedRow]
        // … existing Copy Name / Copy Length / separator / Show in Inspector,
        // unchanged, with Show in Inspector disabled when more than one row is
        // selected because it inspects a single chromosome …
    }

    private func selectedChromosomes() -> [ChromosomeInfo] {
        tableView.selectedRowIndexes.compactMap { row in
            guard row >= 0, row < displayedChromosomes.count else { return nil }
            return displayedChromosomes[row]
        }
    }

    @objc private func extractSelectedChromosomes(_ sender: Any?) {
        let selected = selectedChromosomes()
        guard !selected.isEmpty else { return }
        onExtractSelectedSequencesRequested?(selected)
    }
```

Add the test seams:

```swift
    func testingSelectRows(_ rows: [Int]) {
        tableView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    var testingSelectedChromosomeNames: [String] { selectedChromosomes().map(\.name) }

    func testingContextMenuTitles(clickedRow: Int) -> [String] {
        let menu = NSMenu()
        testingClickedRow = clickedRow
        menuNeedsUpdate(menu)
        return menu.items.map(\.title)
    }

    func testingInvokeContextMenuItem(titled title: String, clickedRow: Int) {
        let menu = NSMenu()
        testingClickedRow = clickedRow
        menuNeedsUpdate(menu)
        guard let item = menu.items.first(where: { $0.title == title }),
              let action = item.action else { return }
        NSApp.sendAction(action, to: item.target, from: item)
    }
```

`tableView.clickedRow` is -1 outside a real click, so add a
`private var testingClickedRow: Int?` and read
`testingClickedRow ?? tableView.clickedRow` in `menuNeedsUpdate`.

Wire it in `configureChromosomeNavigator`, immediately after
`navigator.delegate = self`. The closure must be `[weak self]`: the controller
owns the view, which stores the closure.

```swift
        navigator.onExtractSelectedSequencesRequested = { [weak self] chromosomes in
            guard let self else { return }
            let names = chromosomes.map(\.name)
            self.createReferenceBundleFromChromosomeNames(
                names,
                suggestedName: names.count == 1 ? names[0] : "selected-sequences"
            )
        }
```

Add that method to `ViewerViewController+BundleDisplay`, modelled exactly on
`createReferenceBundleDirectlyFromDurableFASTA`, running
`extract contigs --contigs <bundle genome fasta> --contig <name>… --bundle
--project-root <p> --bundle-name <n> --quiet` through `LungfishCLIRunner`,
starting an `OperationCenter` operation of type `.bundleBuild`, setting a
cancel callback, and completing with the parsed bundle URL. Call both
`OperationCenter.shared.update` and `.log` during the run.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --skip-update --filter ChromosomeNavigatorSelectionTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Viewer/ChromosomeNavigatorView.swift Sources/LungfishApp/Views/Viewer/ViewerViewController+BundleDisplay.swift Tests/LungfishAppTests/ChromosomeNavigatorSelectionTests.swift
git commit -m "feat: extract selected sequences to a bundle from the reference viewport"
```

---

### Task 9: Stop the MSA viewport overdrawing the parent drawer

Read this before starting, or you will verify a fix against a symptom that
install ordering already masks. There are **twelve** sites that set
`annotationDrawerView?.isHidden = false`. **Eleven are inside `hideXView()`
teardown functions**; only `displayBundleSequence` is a display path.
`hideForNativeAlignmentTreeBundle` calls those teardowns and *then* hides the
drawer, so the install itself is already correct. The live bug is a teardown
running **after** an MSA is installed, which unhides the drawer underneath it.

Do **not** re-target the MSA view's bottom constraint. A hidden view still
participates in Auto Layout but draws and hit-tests nothing, so once the drawer
stays hidden the MSA correctly fills the height. Re-targeting would leave a
dead band of empty parent view under the alignment.

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController.swift` (add the computed property)
- Modify: `Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift:36-56`
- Modify: the eleven teardown sites listed below
- Test: `Tests/LungfishAppTests/BundleViewerTests.swift`

The eleven teardown sites:
`+TwelveS.swift:202`, `+CzId.swift:64`, `+Genotype.swift:87`,
`+MHCReferenceBundle.swift:74`, `+Assembly.swift:174`,
`ViewerViewController.swift:1698`, `+EsViritu.swift:271`,
`+TaxTriage.swift:257`, `+NaoMgs.swift:200`, `+Nvd.swift:232`,
`+Taxonomy.swift:516`. Plus the one display path, `+BundleDisplay.swift:204`.

**Interfaces:**
- Consumes: nothing.
- Produces: `ViewerViewController.isNativeBundleViewportInstalled: Bool` and
  `func revealAnnotationDrawerUnlessNativeBundleInstalled()`.

- [ ] **Step 1: Write the failing tests**

```swift
func testParentDrawerStaysHiddenWhenATeardownRunsAfterAnMSAIsInstalled() async throws {
    let vc = ViewerViewController()
    _ = vc.view
    let bundleURL = try makeMultipleSequenceAlignmentBundle()

    try await vc.displayMultipleSequenceAlignmentBundle(at: bundleURL)
    XCTAssertTrue(vc.isNativeBundleViewportInstalled)
    XCTAssertEqual(vc.annotationDrawerView?.isHidden, true)

    // A stale teardown from another viewport must not unhide the drawer
    // underneath the alignment. This is the actual reported defect.
    vc.hideTaxonomyView()
    vc.hideNaoMgsView()
    vc.hideAssemblyView()
    vc.hideFASTACollectionView()

    XCTAssertEqual(
        vc.annotationDrawerView?.isHidden, true,
        "a teardown unhid the parent drawer under the MSA viewport"
    )
}

func testParentDrawerIsRevealedAgainOnceTheNativeBundleIsTornDown() async throws {
    let vc = ViewerViewController()
    _ = vc.view
    let bundleURL = try makeMultipleSequenceAlignmentBundle()
    try await vc.displayMultipleSequenceAlignmentBundle(at: bundleURL)

    vc.hideAlignmentTreeBundleViews()
    XCTAssertFalse(vc.isNativeBundleViewportInstalled)

    vc.hideTaxonomyView()
    XCTAssertEqual(vc.annotationDrawerView?.isHidden, false)
}

func testTogglingTheAnnotationDrawerIsANoOpUnderAnMSA() async throws {
    let vc = ViewerViewController()
    _ = vc.view
    let bundleURL = try makeMultipleSequenceAlignmentBundle()
    try await vc.displayMultipleSequenceAlignmentBundle(at: bundleURL)

    vc.toggleAnnotationDrawer()
    XCTAssertEqual(vc.annotationDrawerView?.isHidden, true)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --skip-update --filter "testParentDrawerStaysHidden|testParentDrawerIsRevealed|testTogglingTheAnnotationDrawer"`
Expected: FAIL, no member `isNativeBundleViewportInstalled`.

- [ ] **Step 3: Implement**

Add to `ViewerViewController`:

```swift
    /// True while a native bundle viewport owns the viewer area. Those
    /// viewports fill the whole view and carry their own drawers, so the
    /// parent annotation drawer must stay hidden underneath them.
    public var isNativeBundleViewportInstalled: Bool {
        multipleSequenceAlignmentViewController != nil
            || phylogeneticTreeViewController != nil
            || genotypeResultViewController != nil
            || twelveSAmpliconResultViewController != nil
    }

    /// Reveals the parent annotation drawer unless a native bundle viewport
    /// is installed. Every teardown path calls this instead of setting
    /// `isHidden` directly, so a teardown running after a native install
    /// cannot unhide the drawer under it.
    func revealAnnotationDrawerUnlessNativeBundleInstalled() {
        guard !isNativeBundleViewportInstalled else { return }
        annotationDrawerView?.isHidden = false
    }
```

Replace all twelve `annotationDrawerView?.isHidden = false` statements with
`revealAnnotationDrawerUnlessNativeBundleInstalled()`.

In `toggleAnnotationDrawer`, add an MSA branch alongside the taxonomy and
TaxTriage branches that already exist there, immediately after the TaxTriage
branch:

```swift
        // A native bundle viewport has no annotations for the parent drawer to
        // show, and the MSA carries its own.
        if isNativeBundleViewportInstalled {
            return
        }
```

Verify the exact property names for the genotype and 12S controllers before
compiling; grep for `genotypeResultViewController` and
`twelveSAmpliconResultViewController` on `ViewerViewController`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --skip-update --filter BundleViewerTests`
Expected: PASS, including the four pre-existing MSA tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Viewer
git commit -m "fix: keep the parent annotation drawer hidden under a native bundle viewport"
```

---

### Task 10: Resizable MSA name gutter

**Files:**
- Modify: `Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:26-40`, `:655-766`, `:1084`, `:1325`, `:2408-2440`
- Test: `Tests/LungfishAppTests/BundleViewerTests.swift`

`rowGutterWidth` feeds exactly **two** width constraints, the corner header at
`:734` and the row gutter at `:749`. The two other reads, at `:1084` and
`:1325`, are arithmetic. There is no third constraint to find.

**Interfaces:**
- Consumes: nothing.
- Produces: on the MSA view controller,
  `func testingSetGutterWidth(_ width: CGFloat)`,
  `var testingGutterWidth: CGFloat`, and the `UserDefaults` key
  `"msaRowGutterWidth"`.

- [ ] **Step 1: Write the failing tests**

```swift
func testGutterWidthClampsToTheReadableRange() async throws {
    let controller = MultipleSequenceAlignmentViewController()
    _ = controller.view
    try await controller.displayBundle(at: makeMultipleSequenceAlignmentBundle())

    controller.testingSetGutterWidth(40)
    XCTAssertEqual(controller.testingGutterWidth, 160, "must not go below the readable floor")

    controller.testingSetGutterWidth(5000)
    XCTAssertEqual(controller.testingGutterWidth, 640)

    controller.testingSetGutterWidth(300)
    XCTAssertEqual(controller.testingGutterWidth, 300)
}

func testGutterWidthPersistsAcrossControllers() async throws {
    UserDefaults.standard.removeObject(forKey: "msaRowGutterWidth")
    defer { UserDefaults.standard.removeObject(forKey: "msaRowGutterWidth") }

    let first = MultipleSequenceAlignmentViewController()
    _ = first.view
    try await first.displayBundle(at: makeMultipleSequenceAlignmentBundle())
    first.testingSetGutterWidth(320)

    let second = MultipleSequenceAlignmentViewController()
    _ = second.view
    try await second.displayBundle(at: makeMultipleSequenceAlignmentBundle())
    XCTAssertEqual(second.testingGutterWidth, 320)
}

func testVisibleMatrixWidthTracksTheLiveGutterWidth() async throws {
    let controller = MultipleSequenceAlignmentViewController()
    _ = controller.view
    controller.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 600)
    try await controller.displayBundle(at: makeMultipleSequenceAlignmentBundle())

    let before = controller.testingEffectiveVisibleMatrixWidth
    controller.testingSetGutterWidth(controller.testingGutterWidth + 100)
    XCTAssertEqual(
        controller.testingEffectiveVisibleMatrixWidth, before - 100, accuracy: 0.5,
        "Fit Columns would miscompute if this still read the old constant"
    )
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --skip-update --filter "testGutterWidth|testVisibleMatrixWidth"`
Expected: FAIL, no member `testingSetGutterWidth`.

- [ ] **Step 3: Implement**

Replace the constant with a stored property and hold both constraints:

```swift
    private static let gutterWidthDefaultsKey = "msaRowGutterWidth"
    private static let minimumGutterWidth: CGFloat = 160
    private static let maximumGutterWidth: CGFloat = 640

    private var gutterWidth: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: "msaRowGutterWidth")
        return stored > 0 ? CGFloat(stored) : MSAAlignmentCanvasMetrics.rowGutterWidth
    }()
    private var cornerHeaderWidthConstraint: NSLayoutConstraint?
    private var rowGutterWidthConstraint: NSLayoutConstraint?
```

In `configureCanvas`, capture both constraints instead of activating anonymous
ones, using `gutterWidth` in place of the constant. Keep `:1084` and `:1325`
reading `gutterWidth`.

Add the setter, which clamps, persists, and updates both constraints without
recomputing the matrix layout:

```swift
    private func setGutterWidth(_ width: CGFloat) {
        let clamped = min(max(width, Self.minimumGutterWidth), Self.maximumGutterWidth)
        guard clamped != gutterWidth else { return }
        gutterWidth = clamped
        cornerHeaderWidthConstraint?.constant = clamped
        rowGutterWidthConstraint?.constant = clamped
        UserDefaults.standard.set(Double(clamped), forKey: Self.gutterWidthDefaultsKey)
        rowGutterView.needsDisplay = true
        cornerHeaderView.needsDisplay = true
    }

    func testingSetGutterWidth(_ width: CGFloat) { setGutterWidth(width) }
    var testingGutterWidth: CGFloat { gutterWidth }
    var testingEffectiveVisibleMatrixWidth: CGFloat { effectiveVisibleMatrixWidth() }
```

Add an 8-point handle straddling the painted divider, 4 points each side, as a
sibling in `canvasContainer` pinned to the gutter's trailing edge. Give it a
`.cursorUpdate` tracking area rather than `mouseEntered`, or the cursor sticks
when the view scrolls under a stationary pointer:

```swift
private final class MSAGutterResizeHandleView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .cursorUpdate, .inVisibleRect],
            owner: self
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        // Track the drag locally so only the two width constants change per
        // mouse-moved event; the matrix layout is left alone until mouse-up.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            onDrag?(convert(next.locationInWindow, from: nil).x)
        }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? { "Sequence name column divider" }
}
```

Wire `onDrag` to `setGutterWidth(gutterWidth + deltaX)` and `onDoubleClick` to
size to the widest visible label, capped at the maximum.

In `drawRowLabel`, switch the name field's truncation to `.byTruncatingMiddle`,
since accession suffixes carry meaning, and set a tooltip carrying the full
name so truncation at the minimum width is still recoverable.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --skip-update --filter BundleViewerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift Tests/LungfishAppTests/BundleViewerTests.swift
git commit -m "feat: make the MSA sequence-name gutter resizable and persistent"
```

---

### Task 11: Aligned-FASTA export sheet

**Files:**
- Create: `Sources/LungfishApp/Views/Viewer/MSAAlignmentExportSheet.swift`
- Test: `Tests/LungfishAppTests/MSAAlignmentExportSheetTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum MSAExportDestination: String, CaseIterable, Identifiable { case bundle, file, clipboard }`
    with `label`, `primaryButtonTitle`
  - `enum MSAExportLayout: String, CaseIterable, Identifiable { case aligned, unaligned }`
  - `struct MSAAlignmentExportConfiguration { destination; layout; format: String; scope: MSAExportScope; name: String }`
  - `enum MSAExportScope { case entireAlignment, selectedRows }`
  - `static func cliArguments(for:bundleURL:outputURL:rows:columns:) -> [String]`
  - `static func isClipboardAvailable(estimatedBytes: Int) -> Bool` with a 5 MB cap

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import LungfishApp

final class MSAAlignmentExportSheetTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/tmp/a.lungfishmsa")
    private let outputURL = URL(fileURLWithPath: "/tmp/out.fasta")

    func testAlignedBundleLegProducesAnAlignmentBundleNotAReference() {
        let args = MSAAlignmentExportSheet.cliArguments(
            for: .init(destination: .bundle, layout: .aligned, format: "aligned-fasta",
                       scope: .entireAlignment, name: "Subset"),
            bundleURL: bundleURL, outputURL: outputURL, rows: nil, columns: nil
        )
        XCTAssertEqual(Array(args.prefix(2)), ["msa", "extract"])
        XCTAssertTrue(args.contains("--output-kind"))
        XCTAssertTrue(args.contains("msa"), "aligned bundle must stay a .lungfishmsa; 'reference' ungaps")
        XCTAssertFalse(args.contains("reference"))
    }

    func testUnalignedBundleLegProducesAReferenceBundle() {
        let args = MSAAlignmentExportSheet.cliArguments(
            for: .init(destination: .bundle, layout: .unaligned, format: "fasta",
                       scope: .entireAlignment, name: "Subset"),
            bundleURL: bundleURL, outputURL: outputURL, rows: nil, columns: nil
        )
        XCTAssertTrue(args.contains("reference"))
    }

    func testFileAndClipboardLegsUseExportWithTheChosenFormat() {
        for destination in [MSAExportDestination.file, .clipboard] {
            let args = MSAAlignmentExportSheet.cliArguments(
                for: .init(destination: destination, layout: .aligned, format: "aligned-fasta",
                           scope: .entireAlignment, name: "x"),
                bundleURL: bundleURL, outputURL: outputURL, rows: nil, columns: nil
            )
            XCTAssertEqual(Array(args.prefix(2)), ["msa", "export"])
            XCTAssertTrue(args.contains("aligned-fasta"))
        }
    }

    func testFileLegCarriesTheOtherAlignmentFormats() {
        for format in ["phylip", "nexus", "clustal", "stockholm", "a2m", "a3m"] {
            let args = MSAAlignmentExportSheet.cliArguments(
                for: .init(destination: .file, layout: .aligned, format: format,
                           scope: .entireAlignment, name: "x"),
                bundleURL: bundleURL, outputURL: outputURL, rows: nil, columns: nil
            )
            XCTAssertTrue(args.contains(format))
        }
    }

    func testSelectedRowsScopePassesRowsAndEntireAlignmentDoesNot() {
        let selected = MSAAlignmentExportSheet.cliArguments(
            for: .init(destination: .file, layout: .aligned, format: "aligned-fasta",
                       scope: .selectedRows, name: "x"),
            bundleURL: bundleURL, outputURL: outputURL, rows: "r1,r2", columns: "10-40"
        )
        XCTAssertTrue(selected.contains("--rows"))
        XCTAssertTrue(selected.contains("r1,r2"))

        let entire = MSAAlignmentExportSheet.cliArguments(
            for: .init(destination: .file, layout: .aligned, format: "aligned-fasta",
                       scope: .entireAlignment, name: "x"),
            bundleURL: bundleURL, outputURL: outputURL, rows: "r1,r2", columns: "10-40"
        )
        XCTAssertFalse(entire.contains("--rows"))
    }

    func testClipboardIsUnavailableAboveTheCap() {
        XCTAssertTrue(MSAAlignmentExportSheet.isClipboardAvailable(estimatedBytes: 4_000_000))
        XCTAssertFalse(MSAAlignmentExportSheet.isClipboardAvailable(estimatedBytes: 6_000_000))
    }

    func testDestinationLabelsMatchTheClassifierDialogVocabulary() {
        XCTAssertEqual(MSAExportDestination.bundle.label, "Save as Bundle")
        XCTAssertEqual(MSAExportDestination.file.label, "Save to File…")
        XCTAssertEqual(MSAExportDestination.clipboard.label, "Copy to Clipboard")
        XCTAssertEqual(MSAExportDestination.bundle.primaryButtonTitle, "Create Bundle")
        XCTAssertEqual(MSAExportDestination.file.primaryButtonTitle, "Save")
        XCTAssertEqual(MSAExportDestination.clipboard.primaryButtonTitle, "Copy")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --skip-update --filter MSAAlignmentExportSheetTests`
Expected: FAIL, cannot find `MSAAlignmentExportSheet`.

- [ ] **Step 3: Implement**

Build the argument mapping on top of the two existing, already-tested builders,
`CLIMSAActionCommandBuilder.buildExtractArguments` and `buildExportArguments`.
The bundle leg maps aligned to `--output-kind msa` and unaligned to
`reference`; the file and clipboard legs use `--output-format`. Pass `rows` and
`columns` only when the scope is `.selectedRows`.

The SwiftUI sheet follows `ClassifierExtractionDialog`: 480 points wide, a
destination radio list whose clipboard row is **disabled with a tooltip** when
over the cap rather than refusing after the user commits, a layout picker
labelled `Aligned FASTA (keep gaps)` and `Unaligned FASTA (remove gaps)`, a
format picker shown only for the file destination, and a scope control shown
only when a multi-row selection exists. The primary button title comes from the
destination. Under the bundle destination, caption the result type: aligned
writes a `.lungfishmsa` whose consensus and variable sites are properties of
the subset, unaligned writes a `.lungfishref`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --skip-update --filter MSAAlignmentExportSheetTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Viewer/MSAAlignmentExportSheet.swift Tests/LungfishAppTests/MSAAlignmentExportSheetTests.swift
git commit -m "feat: alignment export sheet with bundle, file, and clipboard destinations"
```

---

### Task 12: Run the export, and reach it from both menus

**Files:**
- Create: `Sources/LungfishApp/Views/Viewer/ViewerViewController+MSAExport.swift`
- Modify: `Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:1364-1402`
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarItem.swift:137-232`
- Modify: `Sources/LungfishApp/Views/Sidebar/SidebarViewController+MenuDelegate.swift:61-142`
- Test: `Tests/LungfishAppTests/SidebarBundleCapabilityTests.swift`

**Interfaces:**
- Consumes: `MSAAlignmentExportSheet` (Task 11).
- Produces: `SidebarBundleCapabilities.canExportAlignment: Bool`;
  `ViewerViewController.exportMSAAlignmentViaCLI(_:)`.

- [ ] **Step 1: Write the failing tests**

```swift
func testOnlyTheAlignmentBundleAdvertisesAlignmentExport() {
    XCTAssertTrue(SidebarItemType.multipleSequenceAlignmentBundle.bundleCapabilities.canExportAlignment)
    for type in [SidebarItemType.referenceBundle, .mhcReferenceBundle, .fastqBundle,
                 .phylogeneticTreeBundle, .genotypeResultBundle] {
        XCTAssertFalse(
            type.bundleCapabilities.canExportAlignment,
            "\(type) must not advertise an action its exporter cannot perform"
        )
    }
}

func testAlignmentExportDoesNotReuseTheSequenceExportCapability() {
    // canExportSequences routes to a loader that only understands a
    // .lungfishref manifest, so the MSA must not borrow it.
    XCTAssertFalse(SidebarItemType.multipleSequenceAlignmentBundle.bundleCapabilities.canExportSequences)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --skip-update --filter SidebarBundleCapabilityTests`
Expected: FAIL, no member `canExportAlignment`.

- [ ] **Step 3: Implement**

Add `canExportAlignment` to `SidebarBundleCapabilities` with a `false` default,
and set it true only in the `.multipleSequenceAlignmentBundle` arm. That enum's
switch is deliberately exhaustive with no `default:`, so the compiler will
point at every arm needing a value.

In `populateContextMenu`, add `Export Alignment…` in **its own** `if` block,
not nested inside the `canExportSequences` branch. The file's own coupling note
explains why that nesting is an accident to avoid:

```swift
        let alignmentItems = items.filter { $0.type.bundleCapabilities.canExportAlignment }
        if items.count == 1, let sole = alignmentItems.first, let url = sole.url {
            let exportAlignment = NSMenuItem(
                title: "Export Alignment\u{2026}",
                action: #selector(contextMenuExportAlignment(_:)),
                keyEquivalent: ""
            )
            exportAlignment.target = self
            exportAlignment.representedObject = url
            menu.addItem(exportAlignment)
            menu.addItem(.separator())
        }
```

Add `Export Alignment…` to the MSA canvas menu after the extraction items and
before a separator preceding `Build Tree with IQ-TREE…`, so selection-scoped
exports, document-scoped exports, and analysis actions are visually grouped.

Write `exportMSAAlignmentViaCLI` modelled on `exportMSASelectionViaCLI`. The
clipboard leg's concurrency is the part to get right:

```swift
        Task.detached {
            do {
                _ = try await runner.run(arguments: args, operationID: opID)
                let data = try Data(contentsOf: tempURL)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                guard MSAAlignmentExportSheet.isClipboardAvailable(estimatedBytes: data.count) else {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            _ = OperationCenter.shared.fail(
                                id: opID,
                                detail: "Alignment too large for the clipboard",
                                errorMessage: "The alignment is \(data.count / 1_048_576) MB. Save it to a file instead."
                            )
                        }
                    }
                    return
                }
                let text = String(decoding: data, as: UTF8.self)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(text, forType: .string)
                        OperationCenter.shared.log(id: opID, level: .info, message: "Copied the aligned FASTA to the clipboard.")
                        _ = OperationCenter.shared.complete(id: opID, detail: "Copied aligned FASTA", bundleURLs: [])
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        _ = OperationCenter.shared.fail(
                            id: opID, detail: error.localizedDescription,
                            errorMessage: error.localizedDescription
                        )
                    }
                }
            }
        }
```

Read the file and check the size inside the detached task, off the main actor,
and hop back carrying only the string. Never `Task { @MainActor in }` there.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --skip-update --filter SidebarBundleCapabilityTests`
Expected: PASS.

- [ ] **Step 5: Verify the destinations end to end**

```bash
swift build --package-path . --skip-update --product lungfish-cli && M=$(ls -d /tmp/msa-subset/Proj/Multiple\ Sequence\ Alignments/*.lungfishmsa | head -1) && .build/arm64-apple-macosx/debug/lungfish-cli msa export "$M" --output-format aligned-fasta --output /tmp/msa-subset/aligned.fasta --force && grep -v '^>' /tmp/msa-subset/aligned.fasta | tr -cd '-' | wc -c
```

Expected: a non-zero gap count, proving the aligned leg keeps gaps.

- [ ] **Step 6: Commit**

```bash
git add Sources/LungfishApp/Views/Viewer/ViewerViewController+MSAExport.swift Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift Sources/LungfishApp/Views/Sidebar Tests/LungfishAppTests/SidebarBundleCapabilityTests.swift
git commit -m "feat: export an MSA alignment to a bundle, a file, or the clipboard"
```

---

### Task 13: Remove the dead controls

Four dead surfaces, all confirmed against the source.

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/InspectorViewModel.swift:33-63`
- Modify: `Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift` (the `setAnnotations` path)
- Modify: `Sources/LungfishApp/Views/Viewer/MultipleSequenceAlignmentViewController.swift:1364-1402`, `:607-615`
- Test: `Tests/LungfishAppTests/MultipleSequenceAlignmentDocumentSectionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: no new API.

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
func testAIAssistantTabIsHiddenUnlessTheSettingIsOn() {
    let model = InspectorViewModel()
    model.contentMode = .genomics

    let original = AppSettings.shared.aiSearchEnabled
    defer { AppSettings.shared.aiSearchEnabled = original }

    AppSettings.shared.aiSearchEnabled = false
    XCTAssertFalse(model.availableTabs.contains(.ai))

    AppSettings.shared.aiSearchEnabled = true
    XCTAssertTrue(model.availableTabs.contains(.ai))
}

@MainActor
func testAnalysisTabIsHiddenForAnAlignmentDocument() {
    let model = InspectorViewModel()
    model.contentMode = .genomics
    XCTAssertTrue(model.availableTabs.contains(.analysis))

    model.documentSectionViewModel.multipleSequenceAlignmentDocument =
        MultipleSequenceAlignmentDocumentState(title: "a", subtitle: "b", summary: "c")
    XCTAssertFalse(
        model.availableTabs.contains(.analysis),
        "the Analysis tab asks the user to import a BAM, which an alignment bundle never has"
    )
}

@MainActor
func testSelectedTabFallsBackWhenTheActiveTabDisappears() {
    let model = InspectorViewModel()
    model.contentMode = .genomics
    let original = AppSettings.shared.aiSearchEnabled
    defer { AppSettings.shared.aiSearchEnabled = original }

    AppSettings.shared.aiSearchEnabled = true
    model.selectedTab = .ai
    AppSettings.shared.aiSearchEnabled = false
    model.reconcileSelectedTab()
    XCTAssertEqual(model.selectedTab, .bundle)
}
```

Construct `MultipleSequenceAlignmentDocumentState` with its real initialiser;
read `Sections/MultipleSequenceAlignmentDocumentSection.swift:16-40` first and
copy the signature.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path . --skip-update --filter MultipleSequenceAlignmentDocumentSectionTests`
Expected: FAIL, the AI tab is present and Analysis is not filtered.

- [ ] **Step 3: Implement**

In `availableTabs`, replace the `.genomics` arm:

```swift
        case .genomics:
            var tabs: [InspectorTab] = [.bundle, .selectedItem, .view]
            // An alignment bundle has no BAM, and the Analysis tab's empty
            // state asks the user to import one.
            if documentSectionViewModel.multipleSequenceAlignmentDocument == nil {
                tabs.append(.analysis)
            }
            tabs.append(.provenance)
            // Selecting the assistant tab with AI off raises a modal alert and
            // leaves an empty pane, so hide it until a provider is configured.
            if AppSettings.shared.aiSearchEnabled {
                tabs.append(.ai)
            }
            return tabs
```

Add the reconciler and call it wherever `contentMode` or the MSA document
changes, so the content switch never renders a tab the picker no longer lists:

```swift
    func reconcileSelectedTab() {
        guard !availableTabs.contains(selectedTab) else { return }
        selectedTab = availableTabs.first ?? .bundle
    }
```

In `AnnotationTableDrawerView.setAnnotations`, disable the Variants and Samples
segments. That path is what the MSA uses, and the existing gating lives only in
`setSearchIndex`, which an alignment never calls, which is why Samples today
offers Import Metadata, Download Template, Add Sample Field, and Sample Groups
against nothing:

```swift
        // The legacy in-memory path has no variant or sample tables behind it.
        tabControl.setEnabled(false, forSegment: 1)
        tabControl.setEnabled(false, forSegment: 2)
        if activeTab != .annotations {
            activeTab = .annotations
            tabControl.selectedSegment = 0
        }
```

Fix the tab control's accessibility label, which omits Samples:

```swift
        tabControl.setAccessibilityLabel("Switch between annotations, variants, and samples")
```

In the MSA canvas menu, restore the live handler and comment the two that stay
nil so a later reader does not "fix" them:

```swift
                // Deliberately nil: BLAST of aligned rows would query gapped
                // sequence, and realigning an alignment is a different
                // operation from aligning sequences.
                onBlast: nil,
                onAlignWithMAFFT: nil,
                onRunOperation: { [weak self] in self?.runOperationOnSelectedSequences() }
```

Disable the variable-site buttons when there are none, rather than silently
flipping the site mode as a side effect, and give them the accessibility
identifiers they alone lack:

```swift
        previousVariableButton.isEnabled = columnSummaries.contains(where: \.variable)
        nextVariableButton.isEnabled = previousVariableButton.isEnabled
        previousVariableButton.setAccessibilityIdentifier("multiple-sequence-alignment-previous-variable-button")
        nextVariableButton.setAccessibilityIdentifier("multiple-sequence-alignment-next-variable-button")
```

Relabel the Inspector's low-support slider to say what it measures, since the
code computes conservation among non-gap residues only:

```swift
            Text("Low support (of non-gap residues)")
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --package-path . --skip-update --filter "MultipleSequenceAlignmentDocumentSectionTests|InspectorProvenanceTabTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/Views/Inspector Sources/LungfishApp/Views/Viewer
git commit -m "fix: remove the dead AI, Analysis, and drawer tabs from the alignment inspector"
```

---

### Task 14: Full-suite gate and GUI verification

**Files:** none modified. This task proves the branch.

- [ ] **Step 1: Run the unit tier**

Run: `bash scripts/full-suite-gate.sh --tier unit`
Expected: green. A run is green when XCTest failures are empty and
swift-testing failures are zero. `FileSystemWatcherTests` failing only inside a
full run is the known environmental flake on this machine; it must pass when
run alone.

- [ ] **Step 2: Run the integration tier**

Run: `bash scripts/full-suite-gate.sh --tier integration`
Expected: green.

- [ ] **Step 3: Build the Debug app**

```bash
python3 scripts/release/release.py debug
```

Expected: `build/Debug/Lungfish Debug.app`, ad-hoc signed, bundle id
`com.lungfish.browser.debug`.

- [ ] **Step 4: Prepare a fresh test project**

```bash
rm -rf /tmp/lge-msa-walkthrough && mkdir -p /tmp/lge-msa-walkthrough && cp -R "Tests/Fixtures/alignment/sarscov2-mafft-e2e.lungfish" /tmp/lge-msa-walkthrough/Proj && rm -rf "/tmp/lge-msa-walkthrough/Proj/Multiple Sequence Alignments"
```

- [ ] **Step 5: Drive the GUI**

Launch the Debug app with `LUNGFISH_STORAGE_ROOT=/tmp/lge-msa-walkthrough` and
`LUNGFISH_CONDA_ROOT="$HOME/.lungfish/conda"`. Never point the conda root at a
fresh temp directory: MAFFT would appear missing and the Update Tools sheet
would block the run.

Request Computer Use access for **"Lungfish Debug"** specifically. A grant for
the installed Lungfish does not cover it. If an installed copy is running, both
answer to "Lungfish"; disambiguate by pid.

Verify each reported defect, capturing a screenshot for each:

1. Open the project, select the five-genome FASTA, select three sequences,
   right-click, and confirm `Extract to New Bundle…` appears and produces a
   bundle holding exactly three sequences.
2. With the same three selected, choose `Align with MAFFT…` and confirm the
   dialog shows `All sequences (5)` and `Selected sequences (3)`. Run with
   selected and confirm the alignment has three rows.
3. Confirm the drawer is not overdrawn: the Annotations, Variants, and Samples
   tab bar must be either fully visible or fully absent, never painted over.
4. Drag the name-column divider and confirm full identifiers become readable
   and the width survives reopening the bundle.
5. Right-click the alignment and export to each of a bundle, a file, and the
   clipboard. Confirm the file retains gaps.
6. Confirm the Inspector shows no Assistant tab and no Analysis tab, and that
   the drawer's Variants and Samples segments are disabled.

- [ ] **Step 6: Record the results**

Write `docs/reports/2026-09-03-msa-viewport-verification.md` with one section
per defect, each stating what was done, what was observed, and the screenshot
path. Report failures plainly rather than describing intent.

```bash
git add docs/reports/2026-09-03-msa-viewport-verification.md
git commit -m "docs: MSA viewport GUI verification results"
```

---

## Self-Review

**Spec coverage.** Item A is Task 7. Item B is Task 8. Item C is Tasks 1-6.
Item D is Task 9. Item E is Task 10. Item F is Tasks 11-12. Item G is Task 13.
The spec's testing section is covered by the per-task tests plus Task 14. The
spec's provenance requirement is Task 3, and its realign-an-alignment warning
is Task 3.

**Placeholder scan.** No TBDs. Every code step carries real code. Three places
deliberately instruct the implementer to read an existing signature before
copying it, because inventing it here would be worse than pointing at the
source of truth: `executeForTesting` in Task 4, the genotype and 12S controller
property names in Task 9, and `MultipleSequenceAlignmentDocumentState`'s
initialiser in Task 13.

**Type consistency.** `includedSequenceNames` is the single name used from
Task 2 onward. `MSASequenceSelection.resolve` is defined in Task 1 and consumed
only in Task 3. `MSASequenceScope` and `MSASequenceScopePicker` are defined in
Task 6 and used nowhere earlier. `canExportAlignment` is defined and consumed
in Task 12. `isNativeBundleViewportInstalled` is defined and consumed in
Task 9.

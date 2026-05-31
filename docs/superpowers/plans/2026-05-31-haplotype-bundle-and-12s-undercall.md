# Haplotype Bundle Consolidation + 12S Undercall Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the 12S amplicon matcher so reads containing an exact reference core inside retained flanking sequence are counted as exact matches (Track B), and make every haplotype/genotype definition a project-only `.lungfishmhcref` bundle with a required reference FASTA, managed from a single home (Track A).

**Architecture:** Two independent tracks on disjoint files. Track B hardens `TwelveSAmpliconReadClassifier`'s exact-embedded matching (LungfishWorkflow). Track A collapses `HaplotypeDefinitionScope` to project-only, removes built-in/global definition sources, adds a required reference-FASTA picker to the editor, and strips duplicate CRUD surfaces (LungfishIO + LungfishWorkflow + LungfishApp + LungfishCLI). Both are TDD with frequent commits.

**Tech Stack:** Swift 6.2, SwiftPM, macOS 26 Tahoe. Modules: LungfishCore, LungfishIO, LungfishWorkflow, LungfishApp, LungfishCLI. `@Observable` + `@MainActor` + strict concurrency. XCTest.

**Worktree (all commands run here):** `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix` on branch `codex/haplotype-bundle-12s-fix`.

**Build/test conventions:**
- Build: `swift build --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix`
- Test (filtered): `swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix --filter <Suite>/<test>`
- Git: `git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix <cmd>`
- Never use `swift -C`; always `--package-path`. SwiftPM serializes on `.build/.lock`, so do not run two builds concurrently.

---

## Important factual corrections (verified against current source)

These override assumptions in the two design specs:

1. **There is NO CLI command literally named `mhc-reference-bundle`.** MHC bundles are built by `haplotypes bundle-create` in `Sources/LungfishCLI/Commands/HaplotypeDefinitionsCommand.swift`. It resolves *already-managed* definition IDs (it does not parse a raw JSON def inline). So the example-bundle step must first `haplotypes import <def.json> --scope project`, then `haplotypes bundle-create --definition <id> --reference-fasta <fa> --output <bundle>`. (`bundle-save` does decode a JSON def via `JSONDecoder().decode(GenotypeHaplotypeDefinitionSet.self,...)`.)
2. **`HaplotypeDefinitionCommandService` lives in `Sources/LungfishWorkflow/ONTGenotyping/HaplotypeDefinitionCommandService.swift`** (not LungfishApp/Services).
3. **`TwelveSReferenceRecord` is declared in `Sources/LungfishWorkflow/TwelveS/TwelveSReferenceIndex.swift`**, and `displayName:` is a **required** init param.
4. **The 12S classification enum is `TwelveSReadClassification`** (declared at the top of `TwelveSAmpliconReadClassifier.swift`): `.exact(targetID:indelCount:)`, `.ambiguous(targetIDs:)`, `.unresolved`. All member names referenced in the spec's test code (`loadResult` → `TwelveSAmpliconResultBundleData`, `.targetRows`, `.readFate.exactMatchReads`, `.readFate.unresolvedReads`, `.unresolvedSequences`, `targetRow.count(forSample:)`, `targetRow.target.displayName`) are verified correct.
5. **12S `WorkflowLibraryItem` (`twelveSAmpliconMatchingItem`) currently declares NO capabilities** (defaults to `[]`). Track A assigns it `.workflowOperations`.
6. **Two separate haplotype-CRUD surfaces exist:** (a) the manager window `HaplotypeDefinitionManagerWindowController.swift` (uses the command service; has Duplicate-to-Global; editor sheet has no FASTA picker), and (b) `GenotypeResultViewController.swift`'s Audit-lens "Haplotype Definitions" section (uses a raw `HaplotypeDefinitionStore`, hardcodes `GenotypeHaplotypeDefinitionRegistry.builtIn`, has "New empty definition…"/"Clone…"/"Use"/"Edit…"/"Delete"). Removing built-ins/global touches both, plus the CLI scope parsers and `Tests/LungfishIOTests/GenotypeHaplotypeRegistryTests.swift` (18 built-in references).

---

## File Structure

**Track B (12S) — files touched:**
- Modify: `Sources/LungfishWorkflow/TwelveS/TwelveSAmpliconReadClassifier.swift` (harden `exactMatches(in:)` / exact-embedded scan; `classify` ordering already correct)
- Test: `Tests/LungfishWorkflowTests/TwelveSAmpliconMatchingWorkflowTests.swift` (add 4 tests)
- No changes expected: `TwelveSAmpliconMatchingWorkflow.swift`, `FastqTwelveSMatchSubcommand.swift` (only if a regression test isolates a propagation bug)

**Track A (haplotype) — files touched:**
- Modify: `Sources/LungfishIO/Bundles/HaplotypeDefinitionLibrary.swift` (collapse scope, delete `builtInRecords`/`globalRecords`)
- Modify: `Sources/LungfishIO/Bundles/HaplotypeDefinitionStore.swift` (remove `.builtIn` branch at :317)
- Delete-as-live-source: `Sources/LungfishIO/Bundles/BuiltInGenotypeHaplotypeDefinitions.swift` (remove `GenotypeHaplotypeDefinitionRegistry.builtIn` live registry; keep file empty or delete)
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/HaplotypeDefinitionCommandService.swift` (remove `.builtIn`/`.global` guards & paths; bundle-only writes)
- Modify: `Sources/LungfishCLI/Commands/HaplotypeDefinitionsCommand.swift` (scope parsers drop built-in/global; deprecate bare-def producers)
- Modify: `Sources/LungfishCLI/Commands/FastqGenotypingSubcommand.swift`, `FastqONTBarcodeGenotypingSubcommand.swift` (scope refs)
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/HaplotypeDefinitionManagerWindowController.swift` (required FASTA picker in editor; remove Duplicate-to-Global; bundle-only save)
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState.swift` + `WorkflowOperationsDialog.swift` (remove scope picker for built-in/global)
- Modify: `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift` (strip CRUD audit section; keep read-only "Definition: <name>")
- Modify: `Sources/LungfishApp/Services/WorkflowLibrary.swift` (assign 12S `.workflowOperations` capability)
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift` (scope ref)
- Test: `Tests/LungfishIOTests/GenotypeHaplotypeRegistryTests.swift` (rewrite the 18 built-in references), `Tests/LungfishWorkflowTests/HaplotypeDefinitionCommandServiceTests.swift`, add a new `HaplotypeDefinitionLibraryTests` for project-only behavior

**Example bundles (NOT committed):**
- Create: `scripts/examples/notebook_to_lungfish_haplotypes.py` (notebook dicts → `GenotypeHaplotypeDefinitionSet` JSON) — committed as a tool
- Output artifacts to `~/Downloads/*.lungfishmhcref` — NOT committed

---

# TRACK B — 12S Flanked Exact Match Undercall Fix

Do Track B first: it is fully isolated, smaller, and the spec supplies verbatim tests. The classifier already runs `exactMatches(in:)` before indel search and short-circuits on a unique exact hit (verified). The bug is that the exact-embedded window scan is too strict for real Hilo reads. The fix: make `exactMatches(in:)` find an exact reference core embedded anywhere internal to the read, requiring only `>= minimumSoftClipBases` flanking bases on each side, regardless of flanking content.

### Task B1: Add the 4 Hilo-derived tests (expect failures)

**Files:**
- Test: `Tests/LungfishWorkflowTests/TwelveSAmpliconMatchingWorkflowTests.swift`

- [ ] **Step 1: Add the four test methods**

Append these four methods inside the existing `final class TwelveSAmpliconMatchingWorkflowTests: XCTestCase` (imports `@testable import LungfishIO` / `LungfishWorkflow` already present). Paste verbatim:

```swift
func testClassifiesHiloCowAndPigFlankedExactReads() throws {
    let cowCore = "ACTATGCTTAGCCCTAAACACAGATAATTACATAAACAAAATTATTCGCCAGAGTACTACTAGCAACAGCTTAAAACTCAAAGGACTTGGCGGTGCTTTATATCCTT"
    let pigCore = "ACTATGCCTAGCCCTAAACCCAAATAGTTACATAACAAAACTATTCGCCAGAGTACTACTCGCAACTGCCTAAAACTCAAAGGACTTGGCGGTGCTTCACATCCAC"
    let prefix = "ACTGGGATTAGATACCCC"
    let suffix = "CTAGAGGAGCCTGTTCTA"

    let cow = TwelveSReferenceRecord(
        targetID: "domestic cattle (Bos taurus)|seq_sha256=b4bc31d676a16759",
        displayName: "domestic cattle (Bos taurus)",
        sequence: cowCore
    )
    let pig = TwelveSReferenceRecord(
        targetID: "pig (Sus scrofa)|seq_sha256=f59a31cf5675f344",
        displayName: "pig (Sus scrofa)",
        sequence: pigCore
    )
    let classifier = TwelveSAmpliconReadClassifier(
        references: [cow, pig],
        minimumSoftClipBases: 1,
        maximumIndelBases: 3
    )

    XCTAssertEqual(
        classifier.classify(readSequence: prefix + cowCore + suffix),
        .exact(targetID: cow.targetID, indelCount: 0)
    )
    XCTAssertEqual(
        classifier.classify(readSequence: prefix + pigCore + suffix),
        .exact(targetID: pig.targetID, indelCount: 0)
    )
}

func testClassifiesExactCoreWhenFlankingSequenceHasErrors() throws {
    let cowCore = "ACTATGCTTAGCCCTAAACACAGATAATTACATAAACAAAATTATTCGCCAGAGTACTACTAGCAACAGCTTAAAACTCAAAGGACTTGGCGGTGCTTTATATCCTT"
    let cow = TwelveSReferenceRecord(
        targetID: "domestic cattle (Bos taurus)|seq_sha256=b4bc31d676a16759",
        displayName: "domestic cattle (Bos taurus)",
        sequence: cowCore
    )
    let classifier = TwelveSAmpliconReadClassifier(
        references: [cow],
        minimumSoftClipBases: 1,
        maximumIndelBases: 3
    )

    XCTAssertEqual(
        classifier.classify(readSequence: "ACTGGGATTAGATACCCC" + cowCore + "CCAGAGGAGCCTGTTCTA"),
        .exact(targetID: cow.targetID, indelCount: 0)
    )
}

func testHiloExactCoreStillRequiresConfiguredSoftClipAtBothEnds() throws {
    let pigCore = "ACTATGCCTAGCCCTAAACCCAAATAGTTACATAACAAAACTATTCGCCAGAGTACTACTCGCAACTGCCTAAAACTCAAAGGACTTGGCGGTGCTTCACATCCAC"
    let pig = TwelveSReferenceRecord(
        targetID: "pig (Sus scrofa)|seq_sha256=f59a31cf5675f344",
        displayName: "pig (Sus scrofa)",
        sequence: pigCore
    )
    let classifier = TwelveSAmpliconReadClassifier(
        references: [pig],
        minimumSoftClipBases: 1,
        maximumIndelBases: 3
    )

    XCTAssertEqual(classifier.classify(readSequence: pigCore + "CTAGAGGAGCCTGTTCTA"), .unresolved)
    XCTAssertEqual(classifier.classify(readSequence: "ACTGGGATTAGATACCCC" + pigCore), .unresolved)
}

func testWorkflowCountsHiloFlankedCowAndPigReadsInsteadOfLeavingThemUnresolved() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TwelveSHiloRegression-\(UUID().uuidString)", isDirectory: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let cowCore = "ACTATGCTTAGCCCTAAACACAGATAATTACATAAACAAAATTATTCGCCAGAGTACTACTAGCAACAGCTTAAAACTCAAAGGACTTGGCGGTGCTTTATATCCTT"
    let pigCore = "ACTATGCCTAGCCCTAAACCCAAATAGTTACATAACAAAACTATTCGCCAGAGTACTACTCGCAACTGCCTAAAACTCAAAGGACTTGGCGGTGCTTCACATCCAC"
    let prefix = "ACTGGGATTAGATACCCC"
    let suffix = "CTAGAGGAGCCTGTTCTA"

    let referenceURL = root.appendingPathComponent("reference.fa")
    try """
    >domestic cattle (Bos taurus)|locus=12S|len=107|n_refs=161|n_species=7|primer_pairs=12S_vert_F_x_12S_vert_R
    \(cowCore)
    >pig (Sus scrofa)|locus=12S|len=106|n_refs=204|n_species=1|primer_pairs=12S_vert_F_x_12S_vert_R
    \(pigCore)
    """.write(to: referenceURL, atomically: true, encoding: .utf8)

    let fastqURL = root.appendingPathComponent("hilo.fastq")
    try """
    @cow1
    \(prefix)\(cowCore)\(suffix)
    +
    \(String(repeating: "I", count: prefix.count + cowCore.count + suffix.count))
    @cow2
    \(prefix)\(cowCore)\(suffix)
    +
    \(String(repeating: "I", count: prefix.count + cowCore.count + suffix.count))
    @pig1
    \(prefix)\(pigCore)\(suffix)
    +
    \(String(repeating: "I", count: prefix.count + pigCore.count + suffix.count))
    @pig2
    \(prefix)\(pigCore)\(suffix)
    +
    \(String(repeating: "I", count: prefix.count + pigCore.count + suffix.count))
    @pig3
    \(prefix)\(pigCore)\(suffix)
    +
    \(String(repeating: "I", count: prefix.count + pigCore.count + suffix.count))
    """.write(to: fastqURL, atomically: true, encoding: .utf8)

    let result = try await TwelveSAmpliconMatchingWorkflow(
        chimeraReviewer: TwelveSNoOpChimeraReviewer()
    ).run(
        TwelveSAmpliconMatchingConfiguration(
            inputFASTQs: [fastqURL],
            referenceFASTA: referenceURL,
            outputDirectory: root.appendingPathComponent("out", isDirectory: true),
            outputName: "hilo-regression",
            minimumSoftClipBases: 1,
            maximumIndelBases: 3,
            runChimeraReview: false
        )
    )

    let loaded = try TwelveSAmpliconResultBundle.loadResult(from: result.bundleURL)
    let cowRow = try XCTUnwrap(loaded.targetRows.first { $0.target.displayName == "domestic cattle (Bos taurus)" })
    let pigRow = try XCTUnwrap(loaded.targetRows.first { $0.target.displayName == "pig (Sus scrofa)" })

    XCTAssertEqual(cowRow.count(forSample: "hilo"), 2)
    XCTAssertEqual(pigRow.count(forSample: "hilo"), 3)
    XCTAssertEqual(loaded.readFate.exactMatchReads, 5)
    XCTAssertEqual(loaded.readFate.unresolvedReads, 0)
    XCTAssertTrue(loaded.unresolvedSequences.isEmpty)
}
```

- [ ] **Step 2: Run the new tests to confirm they fail**

Run:
```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix \
  --filter TwelveSAmpliconMatchingWorkflowTests/testClassifiesHiloCowAndPigFlankedExactReads
```
Expected: at least one of the four fails (likely the cow/pig flanked tests return `.unresolved` instead of `.exact`). If they unexpectedly all PASS, STOP — the classifier already behaves correctly and the bug is build-specific; in that case mark Track B's implementation tasks as verify-only and proceed to the workflow + Hilo verification in Phase B-Verify, but DO NOT skip the manual Hilo re-run.

- [ ] **Step 3: Commit the failing tests**

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix add Tests/LungfishWorkflowTests/TwelveSAmpliconMatchingWorkflowTests.swift
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix commit -m "$(cat <<'EOF'
test: add Hilo-derived 12S flanked exact-match regression tests

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task B2: Harden the exact-embedded match path

**Files:**
- Modify: `Sources/LungfishWorkflow/TwelveS/TwelveSAmpliconReadClassifier.swift`

Current `exactMatches(in:)` (lines ~136-173) slides each reference-length window only over `firstStart = minimumSoftClipBases … lastStart = (read.count - minimumSoftClipBases) - length`, and (per the bug) does not reliably find a real embedded core. The required behavior (spec §"Required Behavior" 1-4): a read containing exactly one reference target as an *internal substring* with `>= minimumSoftClipBases` bases before AND after the substring must classify as `.exact(...indelCount: 0)`; multiple distinct targets at the exact tier ⇒ `.ambiguous`. Flanking content is irrelevant.

- [ ] **Step 1: Replace `exactMatches(in:)` with a correctness-first bounded exact-substring scan**

Read the file first. Replace the body of `private func exactMatches(in read: [UInt8]) -> [String]` so it, for each reference target, searches for the target's byte sequence as a contiguous substring of `read` such that the match start index `>= minimumSoftClipBases` and the match end index `<= read.count - minimumSoftClipBases` (i.e. at least `minimumSoftClipBases` bytes remain on each side). Collect the set of target IDs that match at least one valid internal position. Return them (caller sorts/decides unique-vs-ambiguous). Use a direct bounded scan rather than the rolling-hash window if the existing hash logic is what fails the tests.

Reference implementation to adopt (matches the verified types — `references: [TwelveSReferenceRecord]`, each with `.target.sequence` bytes via the index; if the classifier stores `indexedReferences`, reuse those byte arrays):

```swift
private func exactMatches(in read: [UInt8]) -> [String] {
    // A read must have room for at least one base of flank on each side.
    guard minimumSoftClipBases >= 0 else { return [] }
    let lowerBound = minimumSoftClipBases
    let upperBound = read.count - minimumSoftClipBases
    guard upperBound > lowerBound else { return [] }

    var matchedTargetIDs = Set<String>()
    for reference in indexedReferences {
        let pattern = reference.sequence   // [UInt8], uppercased at construction
        let m = pattern.count
        guard m > 0, m <= upperBound - lowerBound else { continue }
        // Valid match starts: start >= lowerBound AND start + m <= upperBound.
        let firstStart = lowerBound
        let lastStart = upperBound - m
        guard lastStart >= firstStart else { continue }
        var start = firstStart
        scan: while start <= lastStart {
            var k = 0
            while k < m {
                if read[start + k] != pattern[k] { break }
                k += 1
            }
            if k == m {
                matchedTargetIDs.insert(reference.targetID)
                break scan   // one internal hit per reference is enough
            }
            start += 1
        }
    }
    return Array(matchedTargetIDs)
}
```

NOTE: confirm the actual member names while editing — the exploration found the classifier iterates `indexedReferences[...]` with `.target` and `.targetID` in `classify`. If the per-reference byte array is exposed as `reference.target.sequenceBytes` (or similar) rather than `reference.sequence`, use the real accessor; the byte comparison logic is unchanged. Do not change `classify`'s ordering (exact-before-indel is already correct) or the indel fallback.

- [ ] **Step 2: Run the classifier tests**

Run:
```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix \
  --filter TwelveSAmpliconMatchingWorkflowTests/testClassifiesHiloCowAndPigFlankedExactReads
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix \
  --filter TwelveSAmpliconMatchingWorkflowTests/testClassifiesExactCoreWhenFlankingSequenceHasErrors
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix \
  --filter TwelveSAmpliconMatchingWorkflowTests/testHiloExactCoreStillRequiresConfiguredSoftClipAtBothEnds
```
Expected: all three PASS. `testHilo...RequiresConfiguredSoftClip...` proves the boundary: a core flush against either end (no flank on that side) returns `.unresolved` because `start (== 0) < minimumSoftClipBases` or `start + m (== read.count) > upperBound`.

- [ ] **Step 3: Run the workflow-level regression test**

Run:
```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix \
  --filter TwelveSAmpliconMatchingWorkflowTests/testWorkflowCountsHiloFlankedCowAndPigReadsInsteadOfLeavingThemUnresolved
```
Expected: PASS (cow=2, pig=3, exactMatchReads=5, unresolvedReads=0, no unresolved sequences). If it fails on count propagation (not classification), and only then, inspect `classifyInputs(...)` lines ~279-293 in `TwelveSAmpliconMatchingWorkflow.swift` — but the verified flow already routes `.exact` into `countsByTarget`, so a classifier-only fix should suffice.

- [ ] **Step 4: Run the full 12S + CLI suites for regressions**

Run:
```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix \
  --filter TwelveSAmpliconMatchingWorkflowTests
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix \
  --filter FastqTwelveSMatchSubcommandTests
```
Expected: all PASS, including the pre-existing `testClassifiesBothEndSoftClippedExactTargetMatch`, `testRequiresSoftClipAtBothEnds`, `testRejectsSubstitutionButAcceptsIndelOnlyAlignment`, and the indel-tie tests.

- [ ] **Step 5: Commit the fix**

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix add Sources/LungfishWorkflow/TwelveS/TwelveSAmpliconReadClassifier.swift
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix commit -m "$(cat <<'EOF'
fix: count 12S reads with exact reference core inside retained flanking

Harden TwelveSAmpliconReadClassifier exact-embedded matching to find an
exact reference target as an internal substring with >= minimumSoftClipBases
flanking bases on each side, regardless of flanking content. Fixes the Hilo
cow/pig undercall where primary targets sat at 0 despite exact cores present
in unresolved reads.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

# TRACK A — Haplotype Definition Bundle Consolidation

Track A is larger and touches UI. It splits into: data-model collapse (A1-A3), command-service + CLI (A4-A5), editor FASTA picker (A6), strip duplicate CRUD (A7), capability wiring (A8). Do them in order — later UI tasks depend on the collapsed model compiling.

### Task A1: New behavioral test for project-only library

**Files:**
- Test: `Tests/LungfishWorkflowTests/HaplotypeDefinitionLibraryTests.swift` (create) — or add to an existing LungfishIOTests file if the library is IO-module-testable; `HaplotypeDefinitionLibrary` is in LungfishIO, so put the test in `Tests/LungfishIOTests/HaplotypeDefinitionLibraryProjectScopeTests.swift`.

- [ ] **Step 1: Write the failing test**

Create `Tests/LungfishIOTests/HaplotypeDefinitionLibraryProjectScopeTests.swift`:

```swift
import Foundation
import XCTest
@testable import LungfishIO

final class HaplotypeDefinitionLibraryProjectScopeTests: XCTestCase {
    func testRecordsReturnsOnlyProjectBundleRecords() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HaploLib-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: projectRoot) }
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)

        let library = HaplotypeDefinitionLibrary(projectRoot: projectRoot)
        // A fresh project with no .lungfishmhcref bundle has zero live definitions.
        XCTAssertTrue(library.records().isEmpty)
        // Every returned record (when present) is project-scoped with a reference FASTA.
        for record in library.records() {
            XCTAssertEqual(record.scope, .project)
            XCTAssertNotNil(record.referenceFASTAURL)
        }
    }

    func testHaplotypeDefinitionScopeHasOnlyProjectCase() {
        XCTAssertEqual(HaplotypeDefinitionScope.allCases, [.project])
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run:
```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix \
  --filter HaplotypeDefinitionLibraryProjectScopeTests
```
Expected: FAIL to compile (`.allCases` still contains `.builtIn`, `.global`) or assertion failure (built-in records returned). This is the red state.

- [ ] **Step 3: Commit the failing test**

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix add Tests/LungfishIOTests/HaplotypeDefinitionLibraryProjectScopeTests.swift
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix commit -m "$(cat <<'EOF'
test: assert haplotype library is project-bundle-only

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task A2: Collapse `HaplotypeDefinitionScope` to `.project` only

**Files:**
- Modify: `Sources/LungfishIO/Bundles/HaplotypeDefinitionLibrary.swift:3-23` (enum), `:86-119` (`records`), `:144-164` (`mergedRegistry`), `:166-175` (`store(for:)`), delete `builtInRecords()` (:192-203) and `globalRecords()` (:205-207)

- [ ] **Step 1: Reduce the enum to a single case**

Read `HaplotypeDefinitionLibrary.swift` first. Replace the enum (lines ~3-23) with:

```swift
public enum HaplotypeDefinitionScope: String, Codable, CaseIterable, Sendable {
    case project

    public var displayName: String {
        switch self {
        case .project: return "Project"
        }
    }

    public var precedence: Int {
        switch self {
        case .project: return 0
        }
    }
}
```

- [ ] **Step 2: Delete `builtInRecords()` and `globalRecords()`; make `records(...)` project-bundle-only**

Delete the `private func builtInRecords()` (≈:192-203) and `private func globalRecords()` (≈:205-207) entirely. Rewrite `records(includeReferenceBundles:)` (≈:86-119) so it returns only `projectMHCReferenceBundleRecords()` (the `includeReferenceBundles` flag becomes vestigial — keep the parameter with a default of `true` for source compatibility, but always include bundle records). Concretely the new body is:

```swift
public func records(includeReferenceBundles: Bool = true) -> [HaplotypeDefinitionRecord] {
    _ = includeReferenceBundles  // retained for source compat; project bundles are the only source
    let records = projectMHCReferenceBundleRecords()
    // No shadowing across scopes anymore; keep deterministic sort by id.
    return records.sorted { $0.id < $1.id }
}
```

Update `activeRecords(...)` (≈:121-142) to drop any `scope` filtering that referenced `.builtIn`/`.global` (project is the only scope). Update `mergedRegistry(includeReferenceBundles:)` (≈:144-164): remove the `GenotypeHaplotypeDefinitionRegistry.builtIn` merge at :146 — start from an empty registry and fold in the project bundle definition sets. Update `store(for:)` (≈:166-175): remove the `.builtIn`→nil and `.global`→globalRoot branches; `.project` returns the project store; if `projectRoot == nil`, return nil.

- [ ] **Step 3: Remove the global-store root**

Remove `defaultGlobalRoot()` (≈:76-84) and the `public let globalRoot: URL` stored property (≈:66) plus its init assignment (≈:68-74). Update the initializer signature to `public init(projectRoot: URL?)`. (If other modules call `HaplotypeDefinitionLibrary(projectRoot:globalRoot:)`, Task A4/A5/A7 will fix those call sites; for now make the IO module compile.)

- [ ] **Step 4: Build the IO module target**

Run:
```bash
swift build --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix --target LungfishIO 2>&1 | tail -40
```
Expected: LungfishIO compiles (it may still reference `GenotypeHaplotypeDefinitionRegistry.builtIn` in `HaplotypeDefinitionStore.swift:317` and `BuiltInGenotypeHaplotypeDefinitions.swift` — those are fixed in Task A3, so a failure pointing only at those two files is expected; a failure anywhere else means this task is incomplete).

- [ ] **Step 5: Commit (WIP — module not yet green)**

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix add Sources/LungfishIO/Bundles/HaplotypeDefinitionLibrary.swift
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix commit -m "$(cat <<'EOF'
refactor: collapse HaplotypeDefinitionScope to project-only

Remove built-in and global scopes from the library; records() now returns
only project .lungfishmhcref bundle records. Removes the per-user global
store root. Built-in registry removal follows.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task A3: Remove the compiled-in built-in registry as a live source

**Files:**
- Modify: `Sources/LungfishIO/Bundles/BuiltInGenotypeHaplotypeDefinitions.swift` (remove `GenotypeHaplotypeDefinitionRegistry.builtIn`)
- Modify: `Sources/LungfishIO/Bundles/HaplotypeDefinitionStore.swift:317` (remove `.builtIn` reference)
- Modify: `Tests/LungfishIOTests/GenotypeHaplotypeRegistryTests.swift` (18 references — rewrite/remove)

- [ ] **Step 1: Decide retain-vs-delete for the built-in data, then act**

The macaque diagnostic-allele data in `BuiltInGenotypeHaplotypeDefinitions.swift` is superseded as a *live* source by the project bundles built from the notebook (Track A example bundles). Per design decision #2 (project-only) and #4 (provenance-only migration), this data must NOT be a live `GenotypeHaplotypeDefinitionRegistry.builtIn`. Delete the `static let builtIn` extension (lines ~4-13) and the three compiled-in `public static let` sets it referenced. If nothing else in the file remains referenced, delete the whole file and remove it from any explicit source list (SwiftPM globs `Sources/**`, so just deleting the file is sufficient). Confirm with a grep that nothing else imports those `static let` names.

- [ ] **Step 2: Fix `HaplotypeDefinitionStore.swift:317`**

Read around `HaplotypeDefinitionStore.swift:317`. It references `GenotypeHaplotypeDefinitionRegistry.builtIn`. Remove that branch (likely a "don't shadow built-in" or "seed from built-in" path). The store now only manages project on-disk definitions; delete the built-in seed/shadow logic.

- [ ] **Step 3: Rewrite the registry test file**

`Tests/LungfishIOTests/GenotypeHaplotypeRegistryTests.swift` has 18 references to `GenotypeHaplotypeDefinitionRegistry.builtIn` — it is the regression harness for the built-in sets. Since built-ins are removed, this harness is obsolete. Replace its contents with tests that exercise `GenotypeHaplotypeDefinitionRegistry` and `GenotypeHaplotypeDefinitionSet` *Codable round-tripping and K-of-N matching* using an INLINE fixture definition set (not the removed built-ins). Minimum coverage to retain: (a) a `GenotypeHaplotypeDefinitionSet` encodes and decodes losslessly; (b) `GenotypeHaplotypeDefinition.effectiveMinimumMatches` clamps correctly (1 when `minimumMatches == 0`, count when nil, value when in-range); (c) an empty registry (`GenotypeHaplotypeDefinitionRegistry(assays: [], defaultDefinitionSetID: nil)`) has no definition sets. Build the inline fixture from a small 1-locus 2-haplotype set so the file no longer depends on any removed symbol.

- [ ] **Step 4: Build IO + run IO tests**

Run:
```bash
swift build --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix --target LungfishIO 2>&1 | tail -40
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix \
  --filter HaplotypeDefinitionLibraryProjectScopeTests
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix \
  --filter GenotypeHaplotypeRegistryTests
```
Expected: LungfishIO compiles; both test suites PASS (including `testHaplotypeDefinitionScopeHasOnlyProjectCase` and `testRecordsReturnsOnlyProjectBundleRecords`).

- [ ] **Step 5: Commit**

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix add -A
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix commit -m "$(cat <<'EOF'
refactor: remove compiled-in built-in haplotype registry as a live source

Delete GenotypeHaplotypeDefinitionRegistry.builtIn and the macaque sets it
held; rewrite the registry tests to cover Codable round-trip and K-of-N
matching with inline fixtures. Project .lungfishmhcref bundles are now the
only definition source.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task A4: Make `HaplotypeDefinitionCommandService` bundle-only

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/HaplotypeDefinitionCommandService.swift`

The service has bare-def writers (`saveDefinition(_:scope:...)` :179, `importDefinition(...)` :117, `duplicateDefinition(...)` :465, `deleteDefinition(...)` :522) all guarding `scope != .builtIn`, plus bundle writers (`saveDefinition(_:inMHCReferenceBundle:...)` :211, `replaceReferenceFASTA(...)` :313, two `createMHCReferenceBundle(...)` :388/:426). Init takes `globalRoot:`.

- [ ] **Step 1: Update init and remove `.builtIn`/`.global` guards**

Read the file. Change `init(projectRoot:globalRoot:)` (≈:25-31) to `init(projectRoot: URL?)` (drop `globalRoot`). Since `HaplotypeDefinitionScope` now has only `.project`, remove every `guard scope != .builtIn else { throw .cannotWriteBuiltIn }` (≈:123, :185, :474, :527) — they are dead (the only case is `.project`). Keep the methods themselves. Remove the `.cannotWriteBuiltIn` error case from `HaplotypeDefinitionCommandServiceError` (≈:829-862) if it is now unused (grep first; the CLI may reference it).

- [ ] **Step 2: Keep bundle writers; leave bare-def writers as thin wrappers**

Do NOT delete `saveDefinition(_:scope:...)`/`importDefinition`/`duplicateDefinition`/`deleteDefinition` outright — the CLI `save`/`import`/`duplicate`/`delete` subcommands call them and the design keeps a project store under the hood for definitions embedded in bundles. Instead ensure they operate only against the project store (`store(for: .project)`). The bundle writers (`saveDefinition(inMHCReferenceBundle:)`, `replaceReferenceFASTA`, `createMHCReferenceBundle`) are unchanged.

- [ ] **Step 3: Build LungfishWorkflow**

Run:
```bash
swift build --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix --target LungfishWorkflow 2>&1 | tail -40
```
Expected: compiles, OR fails only at `ONTBarcodeDemuxGenotypingPipeline.swift` scope refs (fixed in this task's step 4).

- [ ] **Step 4: Fix `ONTBarcodeDemuxGenotypingPipeline.swift` scope refs**

Read `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift` lines ~22, 44, 88 (`haplotypeDefinitionScope: HaplotypeDefinitionScope?`). With one scope case these are still type-valid; just ensure any `switch` over scope or `.global`/`.builtIn` literal is removed. If the param is only ever `.project` or nil now, leave the signature but delete any branch handling removed cases.

- [ ] **Step 5: Run command-service tests**

Run:
```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix \
  --filter HaplotypeDefinitionCommandServiceTests
```
Expected: PASS. The test at `:251` references `HaplotypeDefinitionScope.builtIn.rawValue` — update it to `.project.rawValue` (or delete that assertion) as part of this step.

- [ ] **Step 6: Commit**

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix add -A
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix commit -m "$(cat <<'EOF'
refactor: make HaplotypeDefinitionCommandService project-only

Drop globalRoot and the built-in write guards now that scope is project-only;
bundle writers unchanged.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task A5: Update CLI scope parsers and genotyping subcommands

**Files:**
- Modify: `Sources/LungfishCLI/Commands/HaplotypeDefinitionsCommand.swift` (`parseScope`/`parseOptionalScope`/`parseRequiredScope` ≈:475-496; `--scope` options; subcommand wiring)
- Modify: `Sources/LungfishCLI/Commands/FastqGenotypingSubcommand.swift` (≈:106-107, :134, :189, :194), `FastqONTBarcodeGenotypingSubcommand.swift` (≈:91-92, :119, :172, :177)

- [ ] **Step 1: Collapse the scope vocabulary**

Read `HaplotypeDefinitionsCommand.swift`. In `parseScope`/`parseOptionalScope`/`parseRequiredScope` (≈:475-496) remove the `"built-in"`/`"global"`/`"all"` cases; accept only `"project"` (and treat absent as `.project`). Any `--scope` option help text should say "project (only supported scope)". Remove the `init(projectRoot:globalRoot:)` call sites — construct `HaplotypeDefinitionCommandService(projectRoot:)` and `HaplotypeDefinitionLibrary(projectRoot:)` without `globalRoot`/`--global-root`. Remove the `--global-root` option from any subcommand that declared it (`bundle-create` had it).

- [ ] **Step 2: Fix genotyping subcommands**

In `FastqGenotypingSubcommand.swift` and `FastqONTBarcodeGenotypingSubcommand.swift`, the `--haplotype-scope` (or similar) references and `HaplotypeDefinitionScope` uses collapse to project-only. Remove `--global-root` and any scope-selection flag that only made sense with multiple scopes; genotyping already consumes a `.lungfishmhcref` bundle path directly.

- [ ] **Step 3: Build LungfishCLI**

Run:
```bash
swift build --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix --target LungfishCLI 2>&1 | tail -40
```
Expected: compiles.

- [ ] **Step 4: Run CLI haplotype + genotyping tests**

Run:
```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix \
  --filter HaplotypeDefinitions
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix \
  --filter FastqGenotypingSubcommand
```
Expected: PASS (update any test asserting built-in/global scope strings).

- [ ] **Step 5: Commit**

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix add -A
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix commit -m "$(cat <<'EOF'
refactor: CLI haplotype scope is project-only

Drop built-in/global/all from scope parsers, remove --global-root; genotyping
consumes the project .lungfishmhcref bundle.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task A6: Add a required Reference FASTA picker to the editor

**Files:**
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/HaplotypeDefinitionManagerWindowController.swift` (`newDraft` ≈:94-105; editor sheet host ≈:481-497; `saveDraft` ≈:203-234; remove Duplicate-to-Global ≈:610, :518-521; `service` ctor ≈:378-380)
- Reuse: `Sources/LungfishApp/Views/Shared/ReferenceSequencePickerView.swift`

The editor sheet hosts `GenotypeHaplotypeDefinitionEditor`. The "New haplotype definition" draft sets `referenceFASTAURL: nil`. The fix: a new definition must pick a reference FASTA before Save, and Save always writes a `.lungfishmhcref` bundle (via `createMHCReferenceBundle`), never a bare def.

- [ ] **Step 1: Make the editor sheet require a reference FASTA**

Read the controller. Add to the editor sheet UI (the SwiftUI view hosted at ≈:481-497) a Reference FASTA row using `ReferenceSequencePickerView(projectURL: projectURL, selectedReferenceURL: $selectedReferenceURL)` bound to a new `@State private var selectedReferenceURL: URL?` (or a field on the draft). When editing an existing bundle, prefill from `draft.referenceFASTAURL`. Disable the Save button while `selectedReferenceURL == nil`.

- [ ] **Step 2: Make Save always produce a bundle**

Rewrite `saveDraft(_:)` (≈:203-234) so:
- For a NEW definition (no `referenceBundleURL`): call `service.createMHCReferenceBundle(records:referenceFASTA:outputURL:name:defaultDefinitionID:forceOverwrite:argv:)` (or the `definitionIDs:` overload after a transient project save) writing into the project's `Reference Sequences/` (or the project's haplotype bundle location) with the chosen `selectedReferenceURL`. The bare-def `service.saveDefinition(_:scope:...)` path is no longer reachable from the editor.
- For an EXISTING bundle: keep `service.saveDefinition(draft.definition, inMHCReferenceBundle: bundleURL, changeNote:, argv:)`; if the user changed the FASTA, also call `service.replaceReferenceFASTA(inMHCReferenceBundle:with:argv:)`.

- [ ] **Step 3: Remove Duplicate-to-Global and global affordances**

Delete the "Duplicate to Global" button (≈:610), the Import>Global menu entries (≈:518-521), and the `globalRoot` fallback in the toolbar "New" scope (≈:513). Update `service` construction (≈:378-380) to `HaplotypeDefinitionCommandService(projectRoot: projectURL)`.

- [ ] **Step 4: Build the app target**

Run:
```bash
swift build --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix --target LungfishApp 2>&1 | tail -50
```
Expected: compiles (or fails only at `GenotypeResultViewController.swift`/`WorkflowOperationDialogState.swift` scope refs fixed in A7/A8).

- [ ] **Step 5: Commit**

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix add Sources/LungfishApp/Views/WorkflowOperations/HaplotypeDefinitionManagerWindowController.swift
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix commit -m "$(cat <<'EOF'
feat: require a reference FASTA in the haplotype definition editor

New definitions pick a reference FASTA and save as a project .lungfishmhcref
bundle; remove Duplicate-to-Global and global affordances from the manager.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task A7: Strip duplicate CRUD from the genotype analysis view; keep read-only definition label

**Files:**
- Modify: `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift` (audit section ≈:1479, :1518-1727; built-in refs :1535, :1644, :1664)
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState.swift` (scope picker ≈:63, :96, :186-222, :405-485, :762) + `WorkflowOperationsDialog.swift` (≈:465-496)

- [ ] **Step 1: Replace the audit CRUD section with a read-only label**

Read the relevant region of `GenotypeResultViewController.swift`. Remove `makeHaplotypeDefinitionsRow()` (≈:1518-1566), `makeHaplotypeDefinitionRow(...)` (≈:1568-1627), and the handlers `handleUseHaplotypeDefinition`/`handleCloneHaplotypeDefinition`/`handleViewHaplotypeDefinition`/`handleDeleteHaplotypeDefinition`/`handleNewHaplotypeDefinition`/`handleEditHaplotypeDefinition` (≈:1629-1727). Replace the section registration at ≈:1479 with a single read-only row: `addAuditSection(title: "Haplotype Definition", contents: [makeActiveHaplotypeDefinitionRow()])` where `makeActiveHaplotypeDefinitionRow()` renders one line "Definition: <name>" from the result's recorded/active definition name (provenance-only; show the recorded name even if no live bundle matches). Keep dropout/read-filter threshold controls untouched (they are analysis-level). Remove the now-dead `haplotypeDefinitionStore` property and the `GenotypeHaplotypeDefinitionRegistry.builtIn` references (:1535, :1644, :1664).

- [ ] **Step 2: Remove the scope picker from the workflow operation dialog**

In `WorkflowOperationDialogState.swift`, remove `selectedHaplotypeDefinitionScope`/`haplotypeScopeOptions`/`setHaplotypeDefinitionScope(_:)` and the `GenotypeHaplotypeDefinitionRegistry.builtIn` ref at :762. In `WorkflowOperationsDialog.swift` remove the scope picker UI (≈:465-496). Definition selection is now by project bundle, not by scope.

- [ ] **Step 3: Build the app target green**

Run:
```bash
swift build --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix --target LungfishApp 2>&1 | tail -50
```
Expected: compiles (only A8 capability wiring remains).

- [ ] **Step 4: Commit**

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix add -A
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix commit -m "$(cat <<'EOF'
refactor: single home for haplotype definitions

Strip definition CRUD from the genotype analysis view (read-only "Definition:
<name>" remains) and remove the scope picker from the workflow operation
dialog. The Tools menu manager window is the sole CRUD surface.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task A8: Assign workflow capabilities and verify menu gating

**Files:**
- Modify: `Sources/LungfishApp/Services/WorkflowLibrary.swift` (`twelveSAmpliconMatchingItem` ≈:131-138)
- Test: `Tests/LungfishAppTests/ImportCenterMenuTests.swift` (capability-gating; extend)

- [ ] **Step 1: Give 12S its real capability**

In `WorkflowLibrary.swift`, add `capabilities: [.workflowOperations]` to the `twelveSAmpliconMatchingItem` initializer (it currently passes none). Leave `ontGenotypingItem` as `[.workflowOperations, .haplotypeDefinitions]` (already correct). Do NOT change the kept-both-notifications resolution.

- [ ] **Step 2: Extend the capability-gating test**

Read `Tests/LungfishAppTests/ImportCenterMenuTests.swift`. Add/extend an assertion that: with only 12S enabled, `WorkflowFeatureAvailability.current(...)` has `hasWorkflowOperations == true` and `hasHaplotypeDefinitions == false`; with ONT genotyping enabled, both are true. (Use the existing test's enablement-store setup pattern.)

- [ ] **Step 3: Run the app test suite for menu + haplotype**

Run:
```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix \
  --filter ImportCenterMenuTests
```
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix add -A
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix commit -m "$(cat <<'EOF'
feat: declare 12S workflow-operations capability for menu gating

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

# EXAMPLE BUNDLES (verification artifacts — NOT committed)

### Task X1: Notebook-to-Lungfish conversion script

**Files:**
- Create: `scripts/examples/notebook_to_lungfish_haplotypes.py` (committed tool)

The notebook (`/Users/dho/Downloads/mhc_genotyper_for_github.ipynb`) defines `indian_rhesus` and `mcm` dicts: `<dict>['PREFIX']` plus `<dict>['MHC_<LOCUS>_HAPLOTYPES'] = {'<haplotype>': [<diagnostic alleles>]}` for loci A, B, DPA, DPB, DQA, DQB, DRB. Convert each to a `GenotypeHaplotypeDefinitionSet` JSON matching the verified schema:

```
GenotypeHaplotypeDefinitionSet:
  id, assayID, displayName, speciesName, speciesCode, prefix,
  locusDefinitions: [ { locus, sourceLocus, haplotypes: [ { name, diagnosticAlleles: [String], colorTokenIndex?, minimumMatches? } ] } ],
  schemaVersion?, lastModified?, changeNote?
```

- [ ] **Step 1: Write the converter**

Create `scripts/examples/notebook_to_lungfish_haplotypes.py`. It must: read the .ipynb JSON, exec the two dict-defining code cells in a restricted namespace to obtain `mcm` and `indian_rhesus`, then for each emit a `GenotypeHaplotypeDefinitionSet` dict with:
- `id` = e.g. `"MHC-exon2-miSeq.mauritian-cynomolgus-macaques"` (MCM) / `"MHC-exon2-miSeq.indian-rhesus-macaques"` (Inrh)
- `assayID` = `"MHC-exon2-miSeq"`, `displayName` = human label, `speciesName`/`speciesCode` = e.g. `"Mauritian cynomolgus macaque"`/`"MCM"` and `"Indian rhesus macaque"`/`"Mamu"`, `prefix` = the dict's `PREFIX`
- `locusDefinitions`: one per `MHC_<LOCUS>_HAPLOTYPES` key; `locus` = `"MHC-<LOCUS>"`, `sourceLocus` = `<LOCUS>`; `haplotypes`: one per dict entry, `name` = haplotype key, `diagnosticAlleles` = the allele list (split any `|`/`,` alternation tokens into separate entries only if the Lungfish K-of-N matcher expects flat alleles — otherwise keep the token verbatim; default: keep verbatim and set `minimumMatches` = list length for strict-all)
- omit `colorTokenIndex` (defaulted from name), omit `minimumMatches` to mean "all required" OR set it explicitly to the list length

Write each set to `~/Downloads/<name>.haplotypes.json`. Accept `--out-dir` (default `~/Downloads`). Print the loci count and haplotype counts per locus for sanity.

- [ ] **Step 2: Run the converter**

Run:
```bash
python3 /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix/scripts/examples/notebook_to_lungfish_haplotypes.py \
  --notebook /Users/dho/Downloads/mhc_genotyper_for_github.ipynb --out-dir ~/Downloads
```
Expected: writes `~/Downloads/mcm.haplotypes.json` and `~/Downloads/indian-rhesus.haplotypes.json`, each reporting 7 loci (A, B, DPA, DPB, DQA, DQB, DRB).

- [ ] **Step 3: Commit the script (tool only, not artifacts)**

```bash
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix add scripts/examples/notebook_to_lungfish_haplotypes.py
git -C /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix commit -m "$(cat <<'EOF'
chore: add notebook-to-Lungfish haplotype definition converter

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### Task X2: Build the two `.lungfishmhcref` bundles to ~/Downloads via the CLI

**Files:** none committed (artifacts to `~/Downloads`)

- [ ] **Step 1: Validate the generated defs**

Run (build the CLI first if needed):
```bash
swift build --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix --product lungfish-cli 2>&1 | tail -5
CLI=/Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix/.build/debug/lungfish-cli
"$CLI" haplotypes validate ~/Downloads/mcm.haplotypes.json
"$CLI" haplotypes validate ~/Downloads/indian-rhesus.haplotypes.json
```
Expected: both validate as well-formed `GenotypeHaplotypeDefinitionSet` (7 loci each).

- [ ] **Step 2: Import each def into a throwaway project, then bundle-create**

Because `bundle-create` resolves managed def IDs (it does not read a raw JSON inline), import first:
```bash
PROJ=$(mktemp -d)
"$CLI" haplotypes import ~/Downloads/mcm.haplotypes.json --scope project --project "$PROJ"
"$CLI" haplotypes bundle-create \
  --definition MHC-exon2-miSeq.mauritian-cynomolgus-macaques \
  --reference-fasta "/Users/dho/Downloads/MCM_MHC-all_mRNA-MiSeq_singles-RENAME_20Jun16.fasta" \
  --output ~/Downloads/MCM.lungfishmhcref \
  --name "MCM MHC (MiSeq)" \
  --project "$PROJ" --force

PROJ2=$(mktemp -d)
"$CLI" haplotypes import ~/Downloads/indian-rhesus.haplotypes.json --scope project --project "$PROJ2"
"$CLI" haplotypes bundle-create \
  --definition MHC-exon2-miSeq.indian-rhesus-macaques \
  --reference-fasta "/Users/dho/Downloads/26128_ipd-mhc-mamu-2021-07-09.miseq.RWv4.fasta" \
  --output ~/Downloads/IndianRhesus.lungfishmhcref \
  --name "Indian Rhesus MHC (MiSeq)" \
  --project "$PROJ2" --force
```
NOTE: confirm the exact `--definition` ID matches what the converter emitted; if `bundle-create` cannot resolve by ID, fall back to `bundle-save ~/Downloads/<def>.json --bundle <bundle>` after creating an empty bundle, or to a transient `save`. Adjust to the real resolved ID printed by `haplotypes list --project "$PROJ"`.

- [ ] **Step 3: Confirm bundle structure**

Run:
```bash
"$CLI" haplotypes list --project <(dirname ~/Downloads/MCM.lungfishmhcref) 2>/dev/null || true
unzip -l ~/Downloads/MCM.lungfishmhcref 2>/dev/null || ls -laR ~/Downloads/MCM.lungfishmhcref
ls -laR ~/Downloads/IndianRhesus.lungfishmhcref
```
Expected: each bundle contains a manifest (with `schemaVersion`+`kind`), `reference.fa` (or the FASTA), and `haplotypes/*.json` with the 7 loci. These artifacts are for the user's manual GUI import — do NOT commit them.

---

# VERIFICATION PHASE

### Task V1: Full suite green + both products build

- [ ] **Step 1: Full test suite**

Run:
```bash
swift test --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix 2>&1 | tail -40
```
Expected: all pass. Known-flaky exceptions allowed: `testSRASearch` (NCBI SRA reachability) and `GenBankReaderTests.testReadKF015279` (depends on a local un-checked-in file). Any other failure blocks.

- [ ] **Step 2: Build app + CLI**

Run:
```bash
swift build --package-path /Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix 2>&1 | tail -10
```
Expected: clean build of all targets.

### Task V2: Manual Hilo 12S re-run (real-data acceptance)

- [ ] **Step 1: Re-run the Hilo sample with the rebuilt CLI**

Run (the original provenance command, into a fresh output name so old/new are auditable):
```bash
CLI=/Users/dho/Documents/lungfish-genome-explorer/.worktrees/haplotype-bundle-12s-fix/.build/debug/lungfish-cli
"$CLI" fastq 12s-match \
  "/Users/dho/Downloads/12S.lungfish/Imports/HI_Hilo_WWTP_20260511__12S_F09_S69_L001.lungfishfastq" \
  --reference "/Users/dho/Downloads/12S.lungfish/Reference Sequences/MIDORI-12S.lungfish12sref" \
  --output-dir "/tmp/hilo-12s-verify" \
  --output-name HI_Hilo_WWTP_20260511__12S_F09_S69_L001-flanked-fix \
  --threads 14 --force
```

- [ ] **Step 2: Confirm the undercall is fixed**

Inspect `/tmp/hilo-12s-verify/.../sample-target-counts.tsv`, `read-fate.json`, `unresolved-sequences.tsv`, `.lungfish-provenance.json`. Acceptance (spec §"Manual Verification"):
- Cattle row `domestic cattle (Bos taurus)|seq_sha256=b4bc31d676a16759` increases from 0 to **≥ 1425**.
- Pig row `pig (Sus scrofa)|seq_sha256=f59a31cf5675f344` increases from 0 to **≥ 1057**.
- `read-fate.json` exact-match reads increase and unresolved reads decrease by **≥ 2482**.
- The old `unresolved_1`/`unresolved_2` sequences no longer appear in `unresolved-sequences.tsv`.
- Provenance shows a distinct tool version/build from the old `0.5.0-alpha8 (1)` bundle.
Totals should approach the collaborator's 1513 cow / 1063 pig; residual gaps explained by reference variants/ambiguity, not by the primary core staying unresolved.

### Task V3: GUI fidelity check (Computer Use)

- [ ] **Step 1: Launch the app and verify the new FASTA picker + single-home**

Per the binding GUI-testing rule (code audits do not count), launch `.build/debug/Lungfish`, open Tools > Haplotype Definitions…, create a new definition, and confirm: (a) a required Reference FASTA picker is present and Save is disabled until a FASTA is chosen; (b) the genotype analysis view and Inspector no longer show definition CRUD (Inspector shows read-only "Definition: <name>"); (c) import one of the `~/Downloads/*.lungfishmhcref` bundles into a project and confirm it appears. Capture screenshots.

### Task V4: Final code review + finish the branch

- [ ] **Step 1: Dispatch a final reviewer over the whole branch diff**, then use `superpowers:finishing-a-development-branch` to merge `codex/haplotype-bundle-12s-fix` into `main`, push, and clean up the worktree/branch. Confirm clean local + remote `main` with no leftover worktrees/branches/stashes.

---

## Self-Review (run by the plan author)

**Spec coverage — 12S spec:** required-behavior 1-4 → Tasks B1/B2; tests (4 verbatim) → B1; classifier hardening → B2; no new CLI flag → confirmed (Task B factual note 4); provenance distinct version → V2; manual Hilo acceptance → V2; existing tests stay green → B2 step 4. Covered.

**Spec coverage — haplotype spec:** bundle-only form → A2/A4/A6; project-only scope (remove builtIn+global, delete builtInRecords/globalRecords, remove registry.builtIn) → A2/A3; menu-as-sole-manager → A6/A7; required FASTA picker → A6; provenance-only migration (read-only Definition label) → A7 step 1; thresholds stay analysis-level → A7 step 1 (kept untouched); CLI builds bundles → A5 + X2; fold-in capability/menu + keep-both-notifications → A8 (notifications already resolved, untouched); 12S capability follow-up → A8 step 1; example bundles to ~/Downloads → X1/X2; real-data verification → V2. Covered.

**Placeholder scan:** every code step has concrete code or a concrete command; the two places that say "confirm the actual member/ID name while editing" (B2 step 1 byte-accessor; X2 step 2 def-ID) are deliberate verification guards, not placeholders — they name the exact symbol to check and the fallback.

**Type consistency:** `TwelveSReadClassification.exact(targetID:indelCount:)` used consistently; `TwelveSReferenceRecord(targetID:displayName:sequence:)` (displayName required); `loadResult → TwelveSAmpliconResultBundleData` with `.targetRows`/`.readFate.exactMatchReads`/`.readFate.unresolvedReads`/`.unresolvedSequences`/`count(forSample:)`/`target.displayName`; `HaplotypeDefinitionScope.project` the only case; `HaplotypeDefinitionCommandService(projectRoot:)`; `GenotypeHaplotypeDefinitionSet`/`GenotypeHaplotypeLocusDefinition`/`GenotypeHaplotypeDefinition(name:diagnosticAlleles:colorTokenIndex:minimumMatches:)`. Consistent across tasks.


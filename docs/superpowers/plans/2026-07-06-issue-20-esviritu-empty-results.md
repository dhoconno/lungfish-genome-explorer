# Issue #20 — EsViritu Empty Results Report As Failures — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> **Read `docs/superpowers/specs/2026-07-06-weekly-issues-master-spec.md` first** for build/test invocation, the green-bar definition, and process rules.

**Goal:** When EsViritu runs successfully but finds zero viral hits, report it as a completed operation ("no hits found"), never as a per-sample failure.

**Architecture:** The root cause is a parser that conflates "no data rows" with "corrupt/missing file": `EsVirituDetectionParser.parse` throws `.emptyFile` when the detection TSV contains only a header. We change the parser to treat a header-only (or empty) file as a valid **zero-detection** result (return `[]`), keep genuine corruption/missing-file errors as errors, then remove the now-unnecessary `(try? …) ?? []` workarounds in the app layer so the code states its intent.

**Tech Stack:** Swift 6.2, XCTest, SwiftPM.

## Global Constraints

- Build: `swift build --package-path <worktree> --skip-update`. Test: `swift test --package-path <worktree> --skip-update`. Serialize all swift invocations (single `.build/.lock`).
- Green bar = XCTest failures ⊆ the 9 known-environmental failures AND swift-testing = 0 (see master spec §1.4).
- Long-running ops use `OperationCenter.shared.update` + `.log`, terminating in `.complete`/`.fail`.
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Acceptance criteria

1. A header-only EsViritu `*.detected_virus.info.tsv` parses to `[]` (empty array), not a thrown error.
2. A genuinely missing/undecodable file still throws (distinct error).
3. A single-sample EsViritu run with zero hits ends via `OperationCenter.shared.complete(...)` with a "no viral hits detected" detail — not `.fail(...)`.
4. A batch EsViritu run records a zero-hit sample with status `ok` (not `failed`) in the batch summary TSV.
5. Suite is GREEN.

## File Structure

- **Modify:** `Sources/LungfishIO/Formats/EsViritu/EsVirituDetectionParser.swift` — change empty-file behavior.
- **Modify:** `Sources/LungfishApp/App/AppDelegate+Classification.swift` — remove `(try? …) ?? []` workarounds; ensure zero-hit path completes, not fails, in both single and batch runs.
- **Create/Extend test:** `Tests/LungfishIOTests/EsVirituDetectionParserTests.swift` (create if absent; otherwise add cases).
- **Fixture (already present):** `Tests/Fixtures/analyses/esviritu-batch-2026-01-15T15-00-00/` contains a `virusCount: 0` sample. A header-only TSV fixture may need to be added under `Tests/Fixtures/` (Task 1 shows the content).

---

### Task 1: Parser returns empty array for header-only detection file

**Files:**
- Modify: `Sources/LungfishIO/Formats/EsViritu/EsVirituDetectionParser.swift` (empty-check near lines 112–116 and 150–152 — the `detections.isEmpty { throw … .emptyFile }` guard)
- Test: `Tests/LungfishIOTests/EsVirituDetectionParserTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `EsVirituDetectionParser.parse(text:) -> [EsVirituDetection]` (existing signature) now returns `[]` for header-only input instead of throwing. `parse(url:)` returns `[]` for a header-only file, still throws for a missing/undecodable file.

**Before you start:** Open `EsVirituDetectionParser.swift` and read the full `parse(text:)` and `parse(url:)` bodies plus the `EsVirituDetectionParserError` enum. Confirm: (a) the header line is skipped during iteration, (b) the current `.emptyFile` throw fires when `detections.isEmpty`, (c) whether `parse(url:)` distinguishes "file missing / undecodable" from "file present but header-only". You will preserve the missing/undecodable error and drop the header-only error.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/LungfishIOTests/EsVirituDetectionParserTests.swift` (create the file with this scaffold if it does not exist; if it exists, add the two test methods):

```swift
import XCTest
@testable import LungfishIO

final class EsVirituDetectionParserTests: XCTestCase {
    /// The exact header EsViritu writes to `*.detected_virus.info.tsv`.
    private let header = "sample_ID\tName\tdescription\tLength\tSegment\tAccession\tAssembly\tAsm_length\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tRPKMF\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tPi\tfiltered_reads_in_sample"

    func testHeaderOnlyFileParsesToEmptyArrayNotError() throws {
        // A successful EsViritu run with zero hits writes only the header row.
        let text = header + "\n"
        let detections = try EsVirituDetectionParser.parse(text: text)
        XCTAssertEqual(detections.count, 0, "Header-only detection file must parse to zero detections, not throw")
    }

    func testCompletelyEmptyStringParsesToEmptyArray() throws {
        let detections = try EsVirituDetectionParser.parse(text: "")
        XCTAssertEqual(detections.count, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path <worktree> --skip-update --filter EsVirituDetectionParserTests`
Expected: FAIL — the parser currently throws `EsVirituDetectionParserError.emptyFile` for header-only/empty input, so `try` propagates and the assertion is never reached (XCTest reports the thrown error).

- [ ] **Step 3: Remove the empty-detections throw in `parse(text:)`**

In `EsVirituDetectionParser.swift`, find the guard that throws when no data rows were parsed. It looks like:

```swift
if detections.isEmpty {
    throw EsVirituDetectionParserError.emptyFile
}
return detections
```

Replace it with a plain return (a header-only or empty file is a valid zero-hit result):

```swift
// A header-only (or empty) detection file is a VALID result meaning
// "EsViritu ran successfully and found zero viruses" — return an empty
// array rather than signalling failure. A genuinely missing or
// undecodable file is still surfaced as an error by `parse(url:)`.
return detections
```

**Important:** Only remove the `.emptyFile` throw that fires on *zero parsed detections*. Do **not** remove any throw that fires when the file cannot be read or decoded (that is a real error). If `parse(url:)` reads the file into `Data`/`String` and throws on decode failure, leave that path intact. If `EsVirituDetectionParserError.emptyFile` is now unused elsewhere, leave the enum case defined (removing it is out of scope and risks touching unrelated call sites).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --package-path <worktree> --skip-update --filter EsVirituDetectionParserTests`
Expected: PASS (both new tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Formats/EsViritu/EsVirituDetectionParser.swift Tests/LungfishIOTests/EsVirituDetectionParserTests.swift
git commit -m "fix(esviritu): parse header-only detection file as zero hits, not error

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Zero-hit single-sample run completes (does not fail) with a clear detail

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate+Classification.swift` (single-sample EsViritu path around lines 465–707; the `(try? EsVirituDetectionParser.parse(url:)) ?? []` workaround near line 548; the completion call near line 660)

**Interfaces:**
- Consumes: `EsVirituResult.virusCount: Int` (from `Sources/LungfishWorkflow/Metagenomics/EsVirituPipeline.swift`) and `EsVirituResult.detectionURL: URL`.
- Produces: no signature changes; behavioral change only.

**Before you start:** Read the single-sample EsViritu run function end to end. Identify (a) where it parses detections, (b) where it calls `OperationCenter.shared.complete(...)` vs `.fail(...)`, and (c) whether any code path calls `.fail` when `virusCount == 0`. The pipeline itself already sets `virusCount = 0` correctly via `countDetectedViruses` (in `EsVirituPipeline.swift`), so the failure (if any) is at the app layer or was caused by the parser throw fixed in Task 1.

- [ ] **Step 1: Write the failing test**

This path is app-level and involves `OperationCenter` + AppDelegate; a full unit test is heavy. Instead add a focused test on the decision helper. If the completion-vs-failure decision is inline, first extract it into a testable pure function, then test that. Add to `Tests/LungfishAppTests/EsVirituCompletionTests.swift` (create it):

```swift
import XCTest
@testable import LungfishApp

final class EsVirituCompletionTests: XCTestCase {
    func testZeroVirusCountIsSuccessWithNoHitsDetail() {
        let outcome = EsVirituRunOutcome.make(virusCount: 0)
        XCTAssertFalse(outcome.isFailure, "Zero viral hits is a successful run, not a failure")
        XCTAssertEqual(outcome.completionDetail, "No viral hits detected")
    }

    func testPositiveVirusCountIsSuccessWithCountDetail() {
        let outcome = EsVirituRunOutcome.make(virusCount: 3)
        XCTAssertFalse(outcome.isFailure)
        XCTAssertEqual(outcome.completionDetail, "3 viruses detected")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --package-path <worktree> --skip-update --filter EsVirituCompletionTests`
Expected: FAIL with "cannot find 'EsVirituRunOutcome' in scope" (type does not exist yet).

- [ ] **Step 3: Add the `EsVirituRunOutcome` helper and use it in the single-sample path**

Create `Sources/LungfishApp/App/EsVirituRunOutcome.swift`:

```swift
import Foundation

/// Decides how an EsViritu run terminates in the OperationCenter.
/// A run that finishes with zero viral hits is a SUCCESS ("no hits"),
/// never a failure — see GitHub issue #20.
struct EsVirituRunOutcome {
    let isFailure: Bool
    let completionDetail: String

    static func make(virusCount: Int) -> EsVirituRunOutcome {
        if virusCount <= 0 {
            return EsVirituRunOutcome(isFailure: false, completionDetail: "No viral hits detected")
        }
        let noun = virusCount == 1 ? "virus" : "viruses"
        return EsVirituRunOutcome(isFailure: false, completionDetail: "\(virusCount) \(noun) detected")
    }
}
```

Then in `AppDelegate+Classification.swift`, in the single-sample EsViritu completion path:

- Replace `let detections = (try? EsVirituDetectionParser.parse(url: result.detectionURL)) ?? []` with a direct `try?`-free parse now that Task 1 makes the empty case non-throwing. Keep a `try?` only if the URL may legitimately be absent; if absent is a real error, handle it explicitly. Prefer using `result.virusCount` (already computed by the pipeline) as the source of truth for the count.
- Where the operation completes, compute `let outcome = EsVirituRunOutcome.make(virusCount: result.virusCount)` and call:
  ```swift
  OperationCenter.shared.log(id: opID, level: .info, message: outcome.completionDetail)
  OperationCenter.shared.complete(id: opID, detail: outcome.completionDetail)
  ```
- Ensure NO branch calls `OperationCenter.shared.fail(...)` solely because `virusCount == 0` or because parsing produced an empty array.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path <worktree> --skip-update --filter EsVirituCompletionTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/App/EsVirituRunOutcome.swift Sources/LungfishApp/App/AppDelegate+Classification.swift Tests/LungfishAppTests/EsVirituCompletionTests.swift
git commit -m "fix(esviritu): complete zero-hit single-sample run instead of failing

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Zero-hit sample in a batch run records status "ok"

**Files:**
- Modify: `Sources/LungfishApp/App/AppDelegate+Classification.swift` (batch EsViritu path around lines 1083–1389; the `(try? … ) ?? []` at ~line 1185; the batch-summary status write at ~lines 1225–1247)

**Interfaces:**
- Consumes: `EsVirituRunOutcome.make(virusCount:)` from Task 2; `EsVirituResult.virusCount`.
- Produces: batch summary TSV rows where a zero-hit sample has status `ok` and `virus_count` `0`.

**Before you start:** Read the batch loop. Confirm the current catch behavior: a thrown parse error inside the per-sample body is treated as a sample failure (increments failures / writes `failed`). After Task 1, header-only files no longer throw, so this is mostly defensive; but verify no explicit `if detections.isEmpty { … failed … }` exists.

- [ ] **Step 1: Write the failing test**

Add to `Tests/LungfishAppTests/EsVirituCompletionTests.swift`:

```swift
    func testBatchSummaryStatusForZeroHitsIsOk() {
        let status = EsVirituRunOutcome.batchStatus(virusCount: 0, threw: false)
        XCTAssertEqual(status, "ok")
    }

    func testBatchSummaryStatusForThrownErrorIsFailed() {
        let status = EsVirituRunOutcome.batchStatus(virusCount: 0, threw: true)
        XCTAssertEqual(status, "failed")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path <worktree> --skip-update --filter EsVirituCompletionTests`
Expected: FAIL — `batchStatus` does not exist.

- [ ] **Step 3: Add `batchStatus` and use it in the batch summary writer**

In `Sources/LungfishApp/App/EsVirituRunOutcome.swift`, add:

```swift
extension EsVirituRunOutcome {
    /// Batch summary status for a single sample. Only a genuine error (the
    /// pipeline threw or produced no result) is "failed"; zero hits is "ok".
    static func batchStatus(virusCount: Int, threw: Bool) -> String {
        threw ? "failed" : "ok"
    }
}
```

In `AppDelegate+Classification.swift`, in the batch path:
- Remove the `?? []` workaround at the detections parse (per Task 1 it no longer throws for empty).
- When writing each sample's summary row, set the status via `EsVirituRunOutcome.batchStatus(virusCount: pipelineResult.virusCount, threw: false)` on the success path, and `"failed"` only inside the `catch`.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path <worktree> --skip-update --filter EsVirituCompletionTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishApp/App/EsVirituRunOutcome.swift Sources/LungfishApp/App/AppDelegate+Classification.swift Tests/LungfishAppTests/EsVirituCompletionTests.swift
git commit -m "fix(esviritu): record zero-hit sample as ok in batch summary

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4 (OPTIONAL, recommended): Apply the same fix to Kraken2

**Files:**
- Modify: `Sources/LungfishIO/Formats/Kraken/KreportParser.swift` (empty-report throw near lines 149–150)
- Test: `Tests/LungfishIOTests/KreportParserTests.swift` (create/extend)

**Rationale:** `KreportParser` throws `KreportParserError.emptyReport` on an empty report; `ClassificationPipeline` (`Sources/LungfishWorkflow/Metagenomics/ClassificationPipeline.swift:338`) calls it without graceful handling, so an empty-but-successful Kraken2 run would also report as failure. Same class of bug as #20.

**Caution:** An empty Kraken2 `.kreport` is rarer than an empty EsViritu detection file (Kraken2 usually emits at least the `unclassified` root line). Only apply this if you can add a fixture that represents a legitimately empty report; otherwise leave `KreportParser` unchanged and note it in the issue. Do NOT change `KreportParser` behavior for a *malformed* report — only for a well-formed but zero-row one.

- [ ] **Step 1:** Write a failing test parsing a header-only/empty kreport to `[]`.
- [ ] **Step 2:** Run — expect FAIL (throws `.emptyReport`).
- [ ] **Step 3:** Replace the empty-report throw with a return of the empty result, mirroring Task 1. Verify the pipeline's downstream code tolerates an empty taxa list (no force-unwrap of "top taxon").
- [ ] **Step 4:** Run — expect PASS.
- [ ] **Step 5:** Commit `fix(kraken2): empty report parses as zero classifications, not error`.

---

### Final verification (all tasks)

- [ ] **Full build:** `swift build --package-path <worktree> --skip-update` → succeeds, no new warnings.
- [ ] **Full suite:** `swift test --package-path <worktree> --skip-update` → GREEN per master spec §1.4.
- [ ] **GUI verification (required for GUI-visible behavior):** Build `.build/debug/Lungfish`, launch it via computer-use, run EsViritu on a sample known to have no viral hits (or the fixture), and confirm the Operations panel shows a completed operation with "No viral hits detected" — not a red failure. Screenshot as evidence.
- [ ] **Update issue:** Comment on #20 summarizing the fix and linking the commits.

## Self-review checklist

- Spec coverage: parser (Task 1), single-sample completion (Task 2), batch status (Task 3), Kraken2 parity (Task 4 optional) — all acceptance criteria mapped.
- No placeholders: all test bodies and edits are concrete.
- Type consistency: `EsVirituRunOutcome.make(virusCount:)` and `.batchStatus(virusCount:threw:)` used consistently; `EsVirituResult.virusCount` is the count source.

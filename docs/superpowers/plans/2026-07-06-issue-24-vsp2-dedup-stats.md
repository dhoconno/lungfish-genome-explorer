# Issue #24 — VSP2 Provenance: Report Reads Removed During Deduplication — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.
> **Read `docs/superpowers/specs/2026-07-06-weekly-issues-master-spec.md` first.** In particular §2.1 (two VSP2 recipe representations) — this plan's Task 0 resolves that ambiguity and is a prerequisite for issues #23 and #27 too.

**Goal:** After a VSP2 import, the user can see the original read count, the deduplicated read count, and the percentage of reads removed by deduplication — in an obvious place.

**Architecture:** The recipe engine already measures per-step input/output read counts (`RecipeStepResult.inputReadCount` / `.outputReadCount`, with a computed `readsRemoved`) and persists them in bundle metadata (`IngestionMetadata.recipeApplied.stepResults`). The Inspector already renders per-step counts. The gap is (a) making sure read counts are actually measured for the dedup step during VSP2 import (the `measureReadCounts` flag must be true on that path), and (b) surfacing the **dedup-specific** original→deduplicated→percentage numbers prominently — as a dedicated "Deduplication" summary row in the Inspector, in the OperationCenter log, and in CLI output. No new measurement machinery is needed; we wire and surface what exists.

**Tech Stack:** Swift 6.2, XCTest, SwiftUI (Inspector), ArgumentParser (CLI).

## Global Constraints

- Build/test/serialization/green-bar per master spec §1.3–§1.4.
- CLI parity required (this changes user-facing provenance → CLI must expose it).
- OperationCenter `update` + `log` on the import operation.
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Acceptance criteria

1. After a VSP2 import, the persisted `recipeApplied` provenance contains a dedup step with non-nil `inputReadCount` and `outputReadCount`.
2. The Inspector's Ingestion → Recipe Applied section shows a clearly labeled **Deduplication** summary: "N reads → M reads (X.X% removed)".
3. The import operation's OperationCenter log includes a line: "Deduplication removed X.X% of reads (N → M)".
4. `lungfish` CLI import (or a `lungfish bundle info`-style command) prints the dedup original/deduplicated/percentage.
5. Suite is GREEN.

## File Structure

- **Read-only (Task 0):** `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift`, `Sources/LungfishWorkflow/Recipes/RecipeRegistry.swift`, `Sources/LungfishIO/Formats/FASTQ/ProcessingRecipe.swift`, `Sources/LungfishWorkflow/Resources/Recipes/vsp2.recipe.json`.
- **Modify:** `Sources/LungfishApp/Services/FASTQDerivativeService+RecipePipeline.swift` — ensure `measureReadCounts: true` on the VSP2 path; emit an OperationCenter log line for the dedup delta.
- **Modify:** `Sources/LungfishIO/Formats/FASTQ/FASTQMetadataStore.swift` — add a convenience accessor `RecipeAppliedInfo.deduplicationSummary` (pure, testable).
- **Modify:** `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift` — render the dedup summary row (near the existing recipe-applied subsection ~lines 1119–1227).
- **Modify:** the CLI import/info command (find via Task 0; likely `Sources/LungfishCLI/Commands/ImportCommand.swift` or `BundleCommand.swift`) — print the dedup summary.
- **Test:** `Tests/LungfishIOTests/RecipeAppliedInfoTests.swift` (create).

---

### Task 0 (SHARED PREREQUISITE): Reconcile which VSP2 recipe representation actually runs

**Why:** Two representations disagree (master spec §2.1). Issues #23, #24, #27 all need to know which one the shipping VSP2 import path executes and where the dedup step lives. Produce a short written finding that all three plans consume.

**Files (read-only):**
- `Sources/LungfishIO/Formats/FASTQ/ProcessingRecipe.swift:315` (`Illumina VSP2 Target Enrichment`, clumpify-based dedup)
- `Sources/LungfishWorkflow/Resources/Recipes/vsp2.recipe.json` (JSON v2, `fastp-dedup`)
- `Sources/LungfishWorkflow/Recipes/RecipeRegistry.swift` (`builtinRecipes()`, `loadRecipes(from:)`)
- `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift` (import orchestration; recipe application ~lines 737–877; clumpify post-step)
- `Sources/LungfishApp/Views/FASTQ/FASTQImportConfiguration.swift` (`recipeName` field passed as `--recipe`)

- [ ] **Step 1: Trace the runtime path.** Starting from where a VSP2 import is launched (the import dialog sets `FASTQImportConfiguration.recipeName = "vsp2"` or similar), follow the code to whichever recipe object is actually executed. Determine: (a) Is the executed recipe the Swift `ProcessingRecipe` from `ProcessingRecipe.swift`, or the JSON `Recipe` loaded by `RecipeRegistry`? (b) Which step performs deduplication, and with which tool (clumpify vs fastp-dedup)? (c) Does dedup run *inside* the recipe pipeline (`FASTQDerivativeService+RecipePipeline.runMaterializedRecipe`) or as the separate post-recipe compression step in `FASTQBatchImporter`?

- [ ] **Step 2: Confirm empirically.** Build `.build/debug/Lungfish` (or use the CLI import), run a VSP2 import against a small paired FASTQ fixture (e.g. `Tests/Fixtures/sarscov2/` paired reads), and inspect the persisted bundle metadata JSON (`<bundle>.lungfishfastq/*.lungfish-meta.json`) — specifically `ingestion.recipeApplied.recipeID`, `.recipeName`, and the `stepResults[]` names/tools. This tells you unambiguously which representation shipped and what the dedup step is named.

- [ ] **Step 3: Write the finding.** Create `docs/reports/2026-07-06-vsp2-recipe-reconciliation.md` (2–3 paragraphs) recording: which recipe representation runs, the ordered step list with tools as observed at runtime, where dedup happens, and whether `measureReadCounts` was true for that run (did `stepResults` have non-nil input/output counts?). **Issues #23 and #27 reference this file.** No code change in this task.

- [ ] **Step 4: Commit** the report: `docs: reconcile VSP2 recipe representation for issues #23/#24/#27`.

> The remaining tasks assume Task 0 identified the dedup step. Below, "the dedup step" means whatever Task 0 found (clumpify-based or fastp-dedup). The `RecipeStepResult` plumbing is identical either way.

---

### Task 1: Pure `deduplicationSummary` accessor on `RecipeAppliedInfo`

**Files:**
- Modify: `Sources/LungfishIO/Formats/FASTQ/FASTQMetadataStore.swift` (near `RecipeStepResult` / `RecipeAppliedInfo` ~lines 454–529)
- Test: `Tests/LungfishIOTests/RecipeAppliedInfoTests.swift`

**Interfaces:**
- Consumes: existing `RecipeStepResult { stepName: String; tool: String; inputReadCount: Int?; outputReadCount: Int?; var readsRemoved: Int? }` and `RecipeAppliedInfo { stepResults: [RecipeStepResult] }`.
- Produces:
  ```swift
  extension RecipeAppliedInfo {
      struct DeduplicationSummary: Equatable {
          let inputReads: Int
          let outputReads: Int
          var readsRemoved: Int { inputReads - outputReads }
          var percentRemoved: Double { inputReads > 0 ? Double(readsRemoved) / Double(inputReads) * 100 : 0 }
      }
      var deduplicationSummary: DeduplicationSummary? { get }
  }
  ```

**Before you start:** From Task 0 you know the dedup step's `tool` string (e.g. `"clumpify"` or `"fastp"` with a dedup label) and/or its `stepName` (e.g. contains "Deduplicate" / "duplicate"). The accessor must find the dedup step robustly. Prefer matching on a stable marker. Check whether `FASTQDerivativeOperationKind` has a `.deduplicate` case and whether `RecipeStepResult` carries the kind; if it only carries `stepName`/`tool`, match case-insensitively on `stepName.contains("dedup")` OR `stepName.contains("duplicate")`.

- [ ] **Step 1: Write the failing test**

Create `Tests/LungfishIOTests/RecipeAppliedInfoTests.swift`:

```swift
import XCTest
@testable import LungfishIO

final class RecipeAppliedInfoTests: XCTestCase {
    private func step(_ name: String, tool: String, inCount: Int?, outCount: Int?) -> RecipeStepResult {
        RecipeStepResult(
            stepName: name, tool: tool, toolVersion: nil, commandLine: nil,
            commandArguments: nil, inputReadCount: inCount, outputReadCount: outCount,
            durationSeconds: 0
        )
    }

    func testDeduplicationSummaryFromDedupStep() {
        let info = RecipeAppliedInfo(
            recipeID: "vsp2", recipeName: "VSP2", appliedDate: Date(),
            stepResults: [
                step("Deduplicate (exactPCR, subs: 0)", tool: "clumpify", inCount: 1_000_000, outCount: 720_000),
                step("Adapter + quality trim", tool: "fastp", inCount: 720_000, outCount: 715_000),
            ]
        )
        let summary = try XCTUnwrap(info.deduplicationSummary)
        XCTAssertEqual(summary.inputReads, 1_000_000)
        XCTAssertEqual(summary.outputReads, 720_000)
        XCTAssertEqual(summary.readsRemoved, 280_000)
        XCTAssertEqual(summary.percentRemoved, 28.0, accuracy: 0.001)
    }

    func testDeduplicationSummaryNilWhenNoDedupStep() {
        let info = RecipeAppliedInfo(
            recipeID: "x", recipeName: "X", appliedDate: Date(),
            stepResults: [step("Adapter trim", tool: "fastp", inCount: 100, outCount: 100)]
        )
        XCTAssertNil(info.deduplicationSummary)
    }

    func testDeduplicationSummaryNilWhenCountsMissing() {
        let info = RecipeAppliedInfo(
            recipeID: "x", recipeName: "X", appliedDate: Date(),
            stepResults: [step("Deduplicate", tool: "clumpify", inCount: nil, outCount: nil)]
        )
        XCTAssertNil(info.deduplicationSummary)
    }
}
```

> If the real `RecipeStepResult` / `RecipeAppliedInfo` initializers differ from the shapes above (extra required fields, different label), adjust the test's constructors to match the actual types you read in Task 1's "Before you start". Keep the assertions.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path <worktree> --skip-update --filter RecipeAppliedInfoTests`
Expected: FAIL — `deduplicationSummary` / `DeduplicationSummary` do not exist.

- [ ] **Step 3: Implement the accessor**

In `FASTQMetadataStore.swift`, add:

```swift
extension RecipeAppliedInfo {
    public struct DeduplicationSummary: Equatable, Sendable {
        public let inputReads: Int
        public let outputReads: Int
        public var readsRemoved: Int { inputReads - outputReads }
        public var percentRemoved: Double {
            inputReads > 0 ? Double(readsRemoved) / Double(inputReads) * 100 : 0
        }
    }

    /// The deduplication step's before/after read counts, if a dedup step ran
    /// and its counts were measured. Matches the step whose name indicates
    /// deduplication (case-insensitive "dedup"/"duplicate").
    public var deduplicationSummary: DeduplicationSummary? {
        let dedup = stepResults.first { result in
            let lower = result.stepName.lowercased()
            return lower.contains("dedup") || lower.contains("duplicate")
        }
        guard let dedup,
              let input = dedup.inputReadCount,
              let output = dedup.outputReadCount else { return nil }
        return DeduplicationSummary(inputReads: input, outputReads: output)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path <worktree> --skip-update --filter RecipeAppliedInfoTests`
Expected: PASS (all three).

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Formats/FASTQ/FASTQMetadataStore.swift Tests/LungfishIOTests/RecipeAppliedInfoTests.swift
git commit -m "feat(vsp2): add deduplicationSummary accessor to RecipeAppliedInfo

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Ensure the VSP2 dedup step is measured, and log the delta to OperationCenter

**Files:**
- Modify: `Sources/LungfishApp/Services/FASTQDerivativeService+RecipePipeline.swift` (`runMaterializedRecipe(... measureReadCounts:)` ~lines 32–256)
- Modify: the VSP2 import caller so it passes `measureReadCounts: true` (identified in Task 0 — likely `FASTQBatchImporter.swift` or the app-side derivative-service invocation).

**Interfaces:**
- Consumes: `RecipeAppliedInfo.deduplicationSummary` (Task 1); `OperationCenter.shared` (from `LungfishKit`).
- Produces: no signature change; guarantees the dedup step's counts are populated and one OperationCenter log line per import summarizing dedup.

**Before you start:** Confirm from Task 0 whether the VSP2 path already passes `measureReadCounts: true`. The recipe pipeline measures counts before/after each step only when this flag is true. If the shipping VSP2 path leaves it default/false, that is why #24 reports "not reported."

- [ ] **Step 1: Write the failing test**

Add to `Tests/LungfishIOTests/RecipeAppliedInfoTests.swift` a test for a pure formatter used by the log line (keep it unit-testable; the pipeline itself is integration-heavy):

```swift
    func testDeduplicationLogLineFormat() {
        let summary = RecipeAppliedInfo.DeduplicationSummary(inputReads: 1_000_000, outputReads: 720_000)
        let line = RecipeAppliedInfo.deduplicationLogLine(summary)
        XCTAssertEqual(line, "Deduplication removed 28.0% of reads (1,000,000 → 720,000)")
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path <worktree> --skip-update --filter RecipeAppliedInfoTests`
Expected: FAIL — `deduplicationLogLine` does not exist.

- [ ] **Step 3: Implement the formatter and wire the log + flag**

In `FASTQMetadataStore.swift` (same extension as Task 1) add:

```swift
extension RecipeAppliedInfo {
    /// Human-readable one-line summary for the OperationCenter log.
    public static func deduplicationLogLine(_ s: DeduplicationSummary) -> String {
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        let inStr = fmt.string(from: NSNumber(value: s.inputReads)) ?? "\(s.inputReads)"
        let outStr = fmt.string(from: NSNumber(value: s.outputReads)) ?? "\(s.outputReads)"
        let pct = String(format: "%.1f", s.percentRemoved)
        return "Deduplication removed \(pct)% of reads (\(inStr) → \(outStr))"
    }
}
```

Then:
- In the VSP2 import path (Task 0 location), pass `measureReadCounts: true` to `runMaterializedRecipe(...)`. If it is already true, note that in the commit body and move on.
- After the recipe completes and `RecipeAppliedInfo` is assembled, if `info.deduplicationSummary` is non-nil, emit:
  ```swift
  if let dedup = recipeApplied.deduplicationSummary {
      let line = RecipeAppliedInfo.deduplicationLogLine(dedup)
      OperationCenter.shared.log(id: importOpID, level: .info, message: line)
      _ = OperationCenter.shared.update(id: importOpID, progress: nil, detail: line)
  }
  ```
  (Match the real `update` signature — from other call sites in the codebase, `update(id:progress:detail:)`. If `progress` is non-optional there, pass the current progress value instead of `nil`.)

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --package-path <worktree> --skip-update --filter RecipeAppliedInfoTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LungfishIO/Formats/FASTQ/FASTQMetadataStore.swift Sources/LungfishApp/Services/FASTQDerivativeService+RecipePipeline.swift Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift Tests/LungfishIOTests/RecipeAppliedInfoTests.swift
git commit -m "feat(vsp2): measure dedup counts and log removal percentage during import

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

> Only `git add` the files you actually changed; drop `FASTQBatchImporter.swift` from the add list if the flag was already true and you did not edit it.

---

### Task 3: Surface the dedup summary in the Inspector

**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift` (recipe-applied subsection ~lines 1119–1227)

**Interfaces:**
- Consumes: `RecipeAppliedInfo.deduplicationSummary` (Task 1) via the bundle metadata already loaded in this view.
- Produces: a labeled row/section in the Inspector.

**Before you start:** Read the existing `recipeAppliedSubsection` (or equivalently named) that already renders per-step counts and a "Net reads removed" row. You will add a **Deduplication** row that always shows when `deduplicationSummary != nil`, above or beside the per-step breakdown, so the dedup number is obvious (the issue's complaint is that it is not).

- [ ] **Step 1: Add the Deduplication summary row.** In the subsection, after computing `info` (the `RecipeAppliedInfo`), add:

```swift
if let dedup = info.deduplicationSummary {
    let pct = String(format: "%.1f%%", dedup.percentRemoved)
    metadataRow(
        label: "Deduplication",
        value: "\(formatCount(dedup.inputReads)) → \(formatCount(dedup.outputReads)) (\(pct) removed)"
    )
}
```

Use the existing `metadataRow(label:value:)` and `formatCount(_:)` helpers already present in this file (do not reinvent them). Match the surrounding SwiftUI style.

- [ ] **Step 2: Build.** Run: `swift build --package-path <worktree> --skip-update`. Expected: succeeds.

- [ ] **Step 3: GUI verification (required).** Build and launch `.build/debug/Lungfish` via computer-use. Import a small paired FASTQ dataset with the VSP2 recipe, select the resulting bundle, open the Inspector's Document tab, and confirm the **Deduplication** row shows "N → M (X.X% removed)". Screenshot as evidence. (Per master spec §1.5, a code audit does not count.)

- [ ] **Step 4: Commit**

```bash
git add Sources/LungfishApp/Views/Inspector/Sections/DocumentSection.swift
git commit -m "feat(vsp2): show deduplication read-removal summary in Inspector

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: CLI parity — print dedup summary

**Files:**
- Modify: the CLI import or bundle-info command (locate via Task 0 / `grep -rn "recipeApplied" Sources/LungfishCLI` and `Sources/LungfishCLI/Commands/BundleCommand.swift`).

**Interfaces:**
- Consumes: `RecipeAppliedInfo.deduplicationSummary` + `deduplicationLogLine` (Tasks 1–2).
- Produces: CLI stdout line(s) reporting dedup original/deduplicated/percentage.

- [ ] **Step 1: Write a failing test.** Add a test asserting the CLI print helper renders the dedup line. If the CLI reads persisted metadata via `FASTQMetadataStore`, add a test in `Tests/LungfishCLITests/` that constructs a `RecipeAppliedInfo` with a dedup step and asserts the command's formatting function returns a string containing `"28.0%"` and `"1,000,000 → 720,000"`. Reuse `RecipeAppliedInfo.deduplicationLogLine`.

- [ ] **Step 2: Run — expect FAIL** (helper not wired into the command yet).

- [ ] **Step 3: Wire it.** In the import command's completion output (or `bundle info`), after loading `recipeApplied`, print:
  ```swift
  if let dedup = recipeApplied?.deduplicationSummary {
      print(RecipeAppliedInfo.deduplicationLogLine(dedup))
  }
  ```
  Route through the command's existing stdout mechanism (do not use `print` directly if the command uses an emitter like `ApplicationExportCLIEventEmitter`; match the local pattern).

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Manual CLI check.** `.build/debug/lungfish-cli` (or `lungfish`) import a fixture with `--recipe vsp2` and confirm the dedup line prints. Commit:

```bash
git add Sources/LungfishCLI Tests/LungfishCLITests
git commit -m "feat(vsp2): report deduplication stats in CLI import output

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Final verification

- [ ] `swift build --package-path <worktree> --skip-update` → clean.
- [ ] `swift test --package-path <worktree> --skip-update` → GREEN.
- [ ] GUI screenshot of the Inspector Deduplication row attached to issue #24.
- [ ] CLI output sample pasted into issue #24.

## Self-review checklist

- Spec coverage: measurement (Task 2), persistence (already exists; verified in Task 0), Inspector (Task 3), OperationCenter log (Task 2), CLI (Task 4) → all criteria mapped.
- No placeholders: accessor, formatter, view row, CLI print all shown as concrete code.
- Type consistency: `deduplicationSummary` / `DeduplicationSummary` / `deduplicationLogLine` names are identical across Tasks 1–4.

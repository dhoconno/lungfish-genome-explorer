# Amplicon Genotyping + 12S Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Execute the triaged findings in `docs/superpowers/reviews/2026-05-30-synthesis.md` (S-P0-1, S-P1-1..11, S-P2-1..12) so both the Amplicon Genotyping (MHC/KIR) workflow and the 12S amplicon matching workflow are correct, provenance-complete, and use one shared interface idiom wherever they perform the same operation — measured against the operation-intent matrix. Fix the one data-loss P0, complete the `.lungfishmhcref` consume path, converge the divergent operation intents, and land the reuse refactors the user opted into.

**Architecture:** The work splits into (a) shared-infrastructure prerequisites that must land first — one reference-bundle envelope (`schemaVersion`+`kind`, manifest-existence `isBundleURL`), one shared minimum-reads threshold model, one quote-aware delimited parser, one unified genotype export CLI; then (b) the UI/CLI convergences that depend on them. Every scientific action shells out to `lungfish-cli` and writes canonical `.lungfish-provenance.json` (dual `OperationCenter.update()`+`.log()` for pipeline ops; `toolName == "lungfish-cli"` for exports). UI-state convergence is tested at the display-state / view-model layer, not pixels.

**Tech Stack:** Swift 6.2, SPM, AppKit/SwiftUI, ArgumentParser, existing Lungfish provenance APIs.

---

## Conventions for every task (read once)

- **WT (worktree root):**
  `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching`
  The Bash tool defaults to the MAIN checkout. **Every `swift`/`git` command below uses `-C "$WT"`.** Treat `$WT` as that absolute path (do not rely on a shell variable surviving between Bash calls — paste the literal path).
- **Build/test runner:** `swift test --skip-update --filter <Suite>` and `swift build --skip-update`. Always `--skip-update` (offline; avoids the SRA-flake network path).
- **TDD discipline:** write the failing test first, run it and SEE it fail for the expected reason, implement the minimum, run it and SEE it pass, then commit. Never write the implementation before the red test.
- **Binding memory rules to honor in every code change:**
  - Background→MainActor: never `Task { @MainActor in }` from GCD background; never bare `DispatchQueue.main.async` touching `@MainActor` state; never `await` a `@MainActor` member from `Task.detached`. Use `DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { ... } }` or a non-detached `@MainActor` `Task`.
  - Never `%s` in `String(format:)` with Swift strings (SIGSEGV) — use `%@` / interpolation. `ArgumentParser.GlobalOptions()` direct-init crashes — use `GlobalOptions.parse([])`.
  - Provenance: pipeline ops call BOTH `OperationCenter.shared.update()` AND `.log()`. Every data-writing path writes canonical `.lungfish-provenance.json`. Replay argv uses `lungfish-cli`. Never save alignment as SAM.
  - Accent color Lungfish Orange `#D47B3A` (dark `#E8A06A`); reuse `ClassifierActionBar`, shared `BlastResultsDrawerTab`, `ReferenceSequencePickerView`, `SampleMetadataSection`.
- **Commit message footer (every commit):**
  ```
  Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
  ```
- Do NOT `git push` unless the user asks.

## Ordering rationale

P0 first (data loss). Then the three architectural prerequisites the synthesis pins (Phase-4 anchors): **S-P1-5** (shared bundle design) → **S-P1-3** (shared threshold model) → **S-P1-11** (unified export CLI), each before the UI/CLI work that consumes it (S-P1-1 reads the converged bundle; S-P1-4 routes through the unified export CLI). The remaining P1s (S-P1-2, S-P1-6, S-P1-7, S-P1-8, S-P1-9, S-P1-10) are independent and slot after. P2 reuse refactors follow (they build on the now-shared types). Phase 5 verification gates close the plan. The two Phase-5 gates (multi-bundle, `.lungfishmhcref`) are pinned to S-P0-1 and S-P1-1, so those land early.

---

## Phase 0 — P0 correctness / data loss

### Task 1: Fix multi-bundle Illumina sample-ID collision  (addresses S-P0-1)
**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift` (`resolveIlluminaSampleInputs` 832-866; `sampleID(from:)` 892-901; `prepareIlluminaInputs` 784-830; manifest `isBatch` 1872).
- Test: `Tests/LungfishWorkflowTests/ONTBarcodeDemuxGenotypingPipelineTests.swift` (sibling to `testRunIlluminaModeConsumesPreparedSampleBundlesWithoutMergingReads` ~314).

**Bug:** two input bundles whose basenames sanitize to the same ID (e.g. `Sample 1.lungfishfastq` and `Sample-1.lungfishfastq`, or `s/1` and `s_1`) both produce `sampleID == "s_1"`. They write the same `s_1.sample-prefixed.fastq` (overwrite) and prefix reads with the same `s_1|` token, so the query-prefix demux merges their reads → silent data loss and broken per-sample isolation.

- [ ] Step 1: Write the failing test. Two source bundles whose names collide must yield **distinct** sample IDs, **distinct** prefixed-FASTQ destinations, and unmerged read counts. Add to the test class:
  ```swift
  func testResolveIlluminaSampleInputsDisambiguatesCollidingSanitizedSampleIDs() async throws {
      let tmp = try makeTemporaryDirectory()           // existing helper in this suite
      defer { try? FileManager.default.removeItem(at: tmp) }
      // Two bundles whose deletingPathExtension().lastPathComponent both sanitize to "Sample_1".
      let bundleA = try makeIlluminaFastqBundle(named: "Sample 1", reads: ["rA1", "rA2"], in: tmp)
      let bundleB = try makeIlluminaFastqBundle(named: "Sample-1", reads: ["rB1"], in: tmp)
      let staging = tmp.appendingPathComponent("staging", isDirectory: true)
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

      let samples = try await ONTBarcodeDemuxGenotypingPipeline
          .resolveIlluminaSampleInputsForTesting(from: [bundleA, bundleB], stagingDirectory: staging)

      XCTAssertEqual(samples.count, 2)
      XCTAssertEqual(Set(samples.map(\.sampleID)).count, 2, "Sanitized sample IDs must be unique")
      XCTAssertEqual(Set(samples.map(\.prefixedFASTQURL)).count, 2, "Prefixed FASTQ destinations must be unique")
      // No file was overwritten: total prefixed reads == sum of inputs (2 + 1), not 1 or 2.
      XCTAssertEqual(samples.map(\.readCount).reduce(0, +), 3)
  }

  ```
  (Strategy is disambiguation — colliding IDs get a deterministic numeric suffix — NOT throwing, so a legitimate run with messy filenames still succeeds. The second `Sample 1`/`Sample-1` input becomes `Sample_1-2`. The `duplicateIlluminaSampleID` throw is only a defense-in-depth guard tested implicitly by the unique-IDs assertion above.)
  Add the two tiny helpers if absent (a `makeIlluminaFastqBundle(named:reads:in:)` that writes a `.lungfishfastq` dir containing one `reads.fastq`, and reuse the suite's temp-dir helper), and expose a test seam: `static func resolveIlluminaSampleInputsForTesting(from:stagingDirectory:) async throws -> [IlluminaSampleInput]` that forwards to the private `resolveIlluminaSampleInputs`. `IlluminaSampleInput` must be visible to the test target (it already is via `@testable import LungfishWorkflow` — confirm; if `private`, widen to `internal`).
- [ ] Step 2: Run it, expect FAIL.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter ONTBarcodeDemuxGenotypingPipelineTests/testResolveIlluminaSampleInputsDisambiguatesCollidingSanitizedSampleIDs`
  Expected failure: `XCTAssertEqual failed: ("1") is not equal to ("2")` on the unique-IDs assertion (both sanitize to `Sample_1`).
- [ ] Step 3: Implement disambiguation in `resolveIlluminaSampleInputs`. Track assigned IDs and disambiguate by appending a short stable suffix derived from the full source path when a collision occurs; never let two inputs share an ID. Sketch (replace the body's loop, keeping the existing FASTQ resolution):
  ```swift
  var samples: [IlluminaSampleInput] = []
  var assignedIDs = Set<String>()
  for url in urls.map(\.standardizedFileURL) {
      // ... existing resolvedFASTQs / fastqURL resolution unchanged ...
      let baseID = sampleID(from: url)
      let sampleID = Self.disambiguatedSampleID(baseID, existing: assignedIDs)
      assignedIDs.insert(sampleID)
      // ... use `sampleID` for prefixedFASTQURL + writeSamplePrefixedFASTQ as before ...
  }
  // Defense in depth before returning: assert uniqueness so a future regression throws, not corrupts.
  let ids = samples.map(\.sampleID)
  let firstDuplicate = ids.first { id in ids.filter { $0 == id }.count > 1 }
  guard firstDuplicate == nil else {
      throw ONTBarcodeDemuxGenotypingError.duplicateIlluminaSampleID(firstDuplicate ?? "")
  }
  return samples
  ```
  Add the helper and a new error case. Use a **deterministic numeric suffix** (no crypto dependency, no new helper, deterministic across reruns because input order is stable):
  ```swift
  private static func disambiguatedSampleID(_ base: String, existing: Set<String>) -> String {
      guard existing.contains(base) else { return base }
      var bump = 2
      var candidate = "\(base)-\(bump)"
      while existing.contains(candidate) { bump += 1; candidate = "\(base)-\(bump)" }
      return candidate
  }
  ```
  (Note: the loop in Step 3's sketch calls `disambiguatedSampleID(baseID, existing: assignedIDs)` — update the call to drop the `sourceURL:` argument. Reruns are deterministic because `urls` preserves caller order, so the first occurrence keeps the bare ID and the second becomes `<id>-2`.) Add `case duplicateIlluminaSampleID(String)` to `ONTBarcodeDemuxGenotypingError` with a `LocalizedError` message naming the colliding ID. (This case is the defense-in-depth guard; with disambiguation it should never fire, but it converts any future regression into a clear error instead of silent corruption.) Also confirm `sampleDefinitionRows` (801-802) and the manifest `samples` write in `prepareIlluminaInputs` (806-822) now carry the distinct IDs — no extra change needed there since uniqueness is guaranteed upstream.
- [ ] Step 4: Run tests, expect PASS — include the existing sibling so no regression:
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter ONTBarcodeDemuxGenotypingPipelineTests`
- [ ] Step 5: Commit.
  `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift Tests/LungfishWorkflowTests/ONTBarcodeDemuxGenotypingPipelineTests.swift && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "$(cat <<'MSG'
Fix multi-bundle Illumina sample-ID collision (S-P0-1)

Disambiguate sanitized sample IDs with a deterministic numeric suffix so two
input bundles that sanitize to the same ID no longer overwrite each other's
staged FASTQ or merge reads. Validate uniqueness before returning.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
)"`

> **Phase-5 link:** this task is the multi-bundle-gate prerequisite. Do not start the Phase-5 multi-bundle verification until Task 1 is green.

---

### Task 1b: Fix stale FastqCommand subcommand-count assertion  (pre-existing failure caused by the 12S/MHC work; found during full-suite baseline)

**Why this exists:** the 12S/MHC work registered 6 new `fastq` subcommands (`12s-match`, `12s-reference-bundle`, `12s-reference-metadata`, two 12s-export commands, `mhc-reference-bundle`), bringing `FastqCommand.configuration.subcommands.count` to **37**, but `Tests/LungfishCLITests/CLICommandTests.swift` still asserts `31`. This test is RED on the baseline and the 5-agent review missed it. (The 3 failing `WorkflowPackageManifestTests` found in the same baseline run are PRE-EXISTING and UNRELATED to amplicon/12S — they are tracked separately and are out of scope here.)

**Files:**
- Modify: `Tests/LungfishCLITests/CLICommandTests.swift` (~1249-1252: the doc comment "all 31 subcommands" and `XCTAssertEqual(subcommands.count, 31, ...)`).

- [ ] Step 1: Confirm the real count and FAIL.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter CLICommandTests/testFastqSubcommandCount`
  Expected: `XCTAssertEqual failed: ("37") is not equal to ("31")`.
- [ ] Step 2: Verify 37 is correct (not an accidental duplicate registration): read `Sources/LungfishCLI/Commands/FastqCommand.swift` `subcommands: [...]` and confirm each of the 6 new entries is a legitimate, distinct command. Only then update the expectation. (If any entry is a duplicate or stray, that is the real bug — fix the registration instead and STOP to report.)
- [ ] Step 3: Update the assertion to `37` and the doc comment from "all 31 subcommands" to "all 37 subcommands". If the test enumerates expected names, add the 6 new names too.
- [ ] Step 4: PASS.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter CLICommandTests`
- [ ] Step 5: Commit.
  `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Tests/LungfishCLITests/CLICommandTests.swift && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "$(cat <<'MSG'
Update FastqCommand subcommand count 31 -> 37 for 12S/MHC commands

The 12S/MHC work added 6 fastq subcommands but left the count assertion at
31; correct it to the actual 37 (verified each new registration is distinct).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
)"`

---

## Phase 1a — Architectural prerequisites (must precede dependent UI/CLI work)

### Task 2: Unify the reference-bundle design  (addresses S-P1-5)
**Files:**
- Create: `Sources/LungfishIO/Bundles/ReferenceBundleEnvelope.swift` (shared protocol + manifest envelope + `SourceFile` + `isBundleURL` contract + validation).
- Modify: `Sources/LungfishIO/Bundles/MHCAmpliconReferenceBundle.swift` (1-129: rename `formatVersion`→`schemaVersion`, add `kind`, make `isBundleURL` manifest-existence based, add validation).
- Modify: `Sources/LungfishIO/Bundles/TwelveSReferenceBundle.swift` (1-122: conform to the shared protocol; it already uses `schemaVersion`+`kind` and manifest-existence `isBundleURL` — make it the reference shape).
- Test: `Tests/LungfishIOTests/ReferenceBundleEnvelopeTests.swift` (new); extend `Tests/LungfishIOTests/MHCAmpliconReferenceBundleTests.swift` and `Tests/LungfishIOTests/TwelveSReferenceBundleTests.swift`.

**Divergence today:** MHC manifest field is `formatVersion` (no `kind`); 12S is `schemaVersion`+`kind`. MHC `isBundleURL` checks only the extension (line 63-65) — so a bare directory named `*.lungfishmhcref` with no manifest reports `true`, diverging from 12S/`.lungfishref` (manifest-existence). Converge on the 12S/`ReferenceBundle` shape: `schemaVersion: Int`, `kind: String`, manifest-existence `isBundleURL`, a shared `ReferenceBundleSourceFile`, and a `validate()` returning actionable errors.

- [ ] Step 1: Write the failing tests.
  - `ReferenceBundleEnvelopeTests.testMHCBundleURLRequiresManifestPresence`: create a temp `*.lungfishmhcref` directory with NO manifest → `MHCAmpliconReferenceBundle.isBundleURL(dir) == false`; write a valid manifest → `== true`.
  - `ReferenceBundleEnvelopeTests.testMHCManifestUsesSchemaVersionAndKind`: round-trip a `MHCAmpliconReferenceBundleManifest` to JSON and assert the encoded dictionary has keys `schemaVersion` and `kind == "mhc-reference"` and NO `formatVersion`.
  - `ReferenceBundleEnvelopeTests.testValidationReportsMissingFASTA`: a manifest pointing at an absent `referenceFastaPath` → `validate()` contains a `.missingFile("...")`-style error whose message names the path.
  Assertions are exact (`XCTAssertEqual(manifest.kind, "mhc-reference")`, `XCTAssertFalse(json.keys.contains("formatVersion"))`).
- [ ] Step 2: Run, expect FAIL.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter ReferenceBundleEnvelopeTests`
  Expected: compile error (new symbols) or `isBundleURL` returns `true` for a manifest-less dir — the manifest-presence assertion fails.
- [ ] Step 2b: **Audit every `isBundleURL` caller BEFORE editing (required — the count must be verified, not assumed).** Run:
  `grep -rn "MHCAmpliconReferenceBundle.isBundleURL\|TwelveSReferenceBundle.isBundleURL" "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching/Sources"`
  Record the actual call sites. For EACH, classify it as **consume-side** (inspecting an existing bundle the user selected/opened — keep the strict manifest-existence `isBundleURL`) or **produce-side** (checking a to-be-created output path before the manifest is written — must switch to the new extension-only `hasBundleExtension`). Write the classified list into the commit body so the audit is auditable. A missed produce-side caller silently breaks bundle creation, so do not skip this. (The earlier surface review estimated ~9 MHC callers, e.g. `WorkflowOperationDialogState.swift`, `HaplotypeDefinitionLibrary.swift`, `FastqGenotypingSubcommand.swift:172` (consume), `HaplotypeDefinitionCommandService.swift`, `ONTBarcodeDemuxGenotypingPipeline.swift` — treat that as a hint, not the source of truth; the grep is the source of truth.)
- [ ] Step 3: Implement.
  - New `ReferenceBundleEnvelope.swift`:
    ```swift
    public protocol ReferenceBundleManifesting: Codable, Equatable, Sendable {
        static var manifestFilename: String { get }
        static var kindIdentifier: String { get }
        var schemaVersion: Int { get }
        var kind: String { get }
        var sourceFiles: [ReferenceBundleSourceFile] { get }
    }
    public struct ReferenceBundleSourceFile: Codable, Equatable, Sendable {
        public let path: String; public let role: String; public let originalPath: String?
        public init(path: String, role: String, originalPath: String? = nil) { ... }
    }
    public enum ReferenceBundleEnvelope {
        public static func isBundleURL(_ url: URL, directoryExtension: String, manifestFilename: String) -> Bool {
            url.pathExtension.lowercased() == directoryExtension
                && FileManager.default.fileExists(atPath: url.appendingPathComponent(manifestFilename).path)
        }
    }
    public struct ReferenceBundleValidationError: Error, LocalizedError, Equatable {
        public enum Kind: Equatable { case missingFile(String); case schemaMismatch(expected: Int, found: Int); case kindMismatch(expected: String, found: String) }
        public let kind: Kind
        public var errorDescription: String? { ... }   // names the path / mismatch, no em dashes
    }
    ```
  - `MHCAmpliconReferenceBundle.swift`: rename `formatVersion`→`schemaVersion` on `MHCAmpliconReferenceBundleManifest` (keep `init(schemaVersion: Int = 1, ...)`), add `let kind: String` defaulting to `"mhc-reference"`; alias `MHCAmpliconReferenceBundleSourceFile = ReferenceBundleSourceFile` (typealias to avoid touching the builder's call sites — or migrate the builder, see below); make `isBundleURL` call `ReferenceBundleEnvelope.isBundleURL(url, directoryExtension: directoryExtension, manifestFilename: manifestFilename)`; add `static func validate(at:) throws` that checks `referenceFastaPath` exists and each `haplotypeDefinitionPaths` exists.
  - `TwelveSReferenceBundle.swift`: conform `TwelveSReferenceBundleManifest` to `ReferenceBundleManifesting`; route `isBundleURL` through the shared helper; typealias `TwelveSReferenceBundleSourceFile = ReferenceBundleSourceFile`.
  - **Migration guard:** `MHCAmpliconReferenceBundle.isBundleURL` is called in 9 sites (e.g. `WorkflowOperationDialogState.swift:227,462`, `HaplotypeDefinitionLibrary.swift:218,228`, `FastqGenotypingSubcommand.swift:172`, `HaplotypeDefinitionCommandService.swift:219,321`, `ONTBarcodeDemuxGenotypingPipeline.swift:981,1331`). Manifest-existence is STRICTER. Inspect each: any site that passes a *to-be-created* output bundle path (the builder, before writing the manifest) must switch to an extension-only check — add `static func hasBundleExtension(_:) -> Bool` and use it there; consume-side sites keep the strict `isBundleURL`. Build the whole package to surface every caller.
  - Old `formatVersion` JSON on disk: since `.lungfishmhcref` is new in this worktree (not yet shipped), no migration shim is required. State this in the commit body.
- [ ] Step 4: Run, expect PASS:
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter ReferenceBundleEnvelopeTests` then
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter MHCAmpliconReferenceBundle` and
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter TwelveSReferenceBundle`
  Also `swift build --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update` to confirm all 9 callers compile.
- [ ] Step 5: Commit.
  `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/LungfishIO/Bundles/ReferenceBundleEnvelope.swift Sources/LungfishIO/Bundles/MHCAmpliconReferenceBundle.swift Sources/LungfishIO/Bundles/TwelveSReferenceBundle.swift Tests/LungfishIOTests/ && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "$(cat <<'MSG'
Unify reference-bundle design on schemaVersion+kind envelope (S-P1-5)

One isBundleURL contract (manifest-existence), one manifest convention
(schemaVersion + kind), one SourceFile type, shared validation. .lungfishmhcref
migrates off formatVersion; new format so no on-disk migration needed.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
)"`

---

### Task 3: Converge low-abundance minimum-reads filter on a shared threshold model  (addresses S-P1-3)
**Files:**
- Create: `Sources/LungfishApp/Views/Results/Shared/MinimumReadsThreshold.swift` (the shared model both display states reference; A8 prerequisite).
- Modify: `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultDisplayState.swift` (99-140: add `minimumReads` + `activeMinimumReads`).
- Modify: `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift` (`rebuildCohortSummary` 2485-2520: drive `belowThresholdValue` from `displayState.minimumReads` instead of the hardcoded `5_000`; add per-row visibility filter using `activeMinimumReads`).
- Modify: `Sources/LungfishApp/Views/Results/TwelveS/TwelveSResultDisplayState.swift` (44-85: re-express `minimumExactReads` in terms of the shared model so both states share one definition of "active threshold").
- Test: `Tests/LungfishAppTests/GenotypeResultDisplaySectionTests.swift` (extend) and a new `Tests/LungfishAppTests/MinimumReadsThresholdTests.swift`.

**Divergence today:** 12S has editable `minimumExactReads` (live filter on target rows, CLI `--min-exact-reads`); MHC genotype hardcodes `5_000` in two spots (`GenotypeResultViewController.swift:2493,2506`) as a flag-only `belowThresholdValue`, not an editable filter and not on `GenotypeResultDisplayState`. Converge: a shared `MinimumReadsThreshold` value type; `GenotypeResultDisplayState` gains an editable `minimumReads` that (a) drives the cohort below-threshold flag and (b) hides rows below the active threshold, mirroring 12S.

- [ ] Step 1: Write the failing tests.
  - `MinimumReadsThresholdTests.testActiveThresholdIsZeroWhenDisabled`: `MinimumReadsThreshold(value: 5000, isEnabled: false).active == 0`; enabled → `== 5000`; negative clamps to 0.
  - `GenotypeResultDisplaySectionTests.testMinimumReadsFiltersRowsAndCohortFlagIsSeparate` (model-layer, no pixels): the two concerns are distinct. Default `minimumReads == 0` (no row filtering) and default `cohortFlagThreshold == 5_000` (historical flag preserved). Set `minimumReads = 5000`; assert `activeMinimumReads == 5000` and `samplesBelowFilter([("a",6000),("b",4000)]) == ["b"]`. Independently assert `samplesBelowCohortFlag([("a",6000),("b",4000)]) == ["b"]` at the default 5K, and that changing `cohortFlagThreshold` does NOT change `minimumReads`/`activeMinimumReads` (no aliasing).
  ```swift
  func testGenotypeReadThresholdsAreTwoIndependentEditableFields() {
      var s = GenotypeResultDisplayState()
      XCTAssertEqual(s.minimumReads, 0)            // row filter off by default
      XCTAssertEqual(s.activeMinimumReads, 0)
      XCTAssertEqual(s.cohortFlagThreshold, 5_000) // historical unreliable-below flag preserved, now editable
      s.minimumReads = 3_000
      XCTAssertEqual(s.activeMinimumReads, 3_000)
      XCTAssertEqual(s.cohortFlagThreshold, 5_000, "cohort flag must not alias the row filter")
  }
  ```
- [ ] Step 2: Run, expect FAIL.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter MinimumReadsThresholdTests`
  Expected: compile error — `GenotypeResultDisplayState` has no `minimumReads`.
- [ ] Step 3: Implement.
  - `MinimumReadsThreshold.swift`:
    ```swift
    struct MinimumReadsThreshold: Equatable, Sendable {
        var value: Int
        var isEnabled: Bool
        init(value: Int = 0, isEnabled: Bool = true) { self.value = max(0, value); self.isEnabled = isEnabled }
        var active: Int { isEnabled ? max(0, value) : 0 }
        func includes(reads: Int) -> Bool { reads >= active }
    }
    ```
  - `GenotypeResultDisplayState`: add TWO distinct stored fields so the concerns never alias (per plan review): (a) `var minimumReads: Int = 0` — the editable row-visibility filter (0 = no filtering, mirroring 12S where the analyst opts in); (b) `var cohortFlagThreshold: Int = 5_000` — the "calls below this are unreliable" cohort flag, now an editable field with the historical 5K default instead of a hardcoded constant. Add the matching init params/assignments (keep synthesized `Equatable` — no custom `==`). Add `var activeMinimumReads: Int { MinimumReadsThreshold(value: minimumReads).active }` and a pure helper `func samplesBelowFilter(_ reads: [(sample: String, reads: Int)]) -> [String]` returning sorted IDs with `reads < activeMinimumReads` (only when `activeMinimumReads > 0`), and `func samplesBelowCohortFlag(_ reads: [(sample: String, reads: Int)]) -> [String]` returning IDs with `reads < cohortFlagThreshold`.
  - `GenotypeResultViewController.rebuildCohortSummary`: replace both `let belowThresholdValue = 5_000` (and the `.init(... belowThresholdValue: 5_000)` empty-state) with `let belowThresholdValue = displayState.cohortFlagThreshold`, and compute the flagged set via `displayState.samplesBelowCohortFlag(...)`. The cohort flag therefore keeps its 5K default but is now user-editable, and it stays a SEPARATE concern from the `minimumReads` row-visibility filter (which defaults to 0 = show all). Do not collapse the two into one overloaded field.
  - `TwelveSResultDisplayState`: leave `minimumExactReads` as the persisted field (CLI flag depends on it) but add a computed `var minimumReadsThreshold: MinimumReadsThreshold { .init(value: minimumExactReads) }` so both surfaces share the type. No behavior change for 12S.
  - The Inspector control (editable TextField+Stepper on `GenotypeResultDisplaySection`, mirroring `TwelveSResultDisplaySection`'s "Minimum Exact Reads" 228-255) is added in Task 9 (UI convergence); this task lands the model + binding only.
- [ ] Step 4: Run, expect PASS.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter MinimumReadsThreshold` and
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter GenotypeResultDisplaySectionTests` and
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter TwelveSResultDisplaySectionTests`
- [ ] Step 5: Commit.
  `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/LungfishApp/Views/Results/Shared/MinimumReadsThreshold.swift Sources/LungfishApp/Views/Results/Genotype/GenotypeResultDisplayState.swift Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift Sources/LungfishApp/Views/Results/TwelveS/TwelveSResultDisplayState.swift Tests/LungfishAppTests/ && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "$(cat <<'MSG'
Add shared minimum-reads threshold model for genotype + 12S (S-P1-3)

GenotypeResultDisplayState gains an editable minimumReads mirroring 12S
minimumExactReads; the cohort below-threshold flag now tracks it instead of a
hardcoded 5000. Both display states reference one MinimumReadsThreshold type.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
)"`

---

### Task 4: Unify the genotype bundle-export CLI shape  (addresses S-P1-11, unblocks S-P1-4)
**Files:**
- Create: `Sources/LungfishCLI/Commands/GenotypeExportSubcommand.swift` — one `genotype export --format {xlsx,csv,tsv}` that accepts the visible/lens filter projection and the same kind of filter flags 12S exposes, mirroring `fastq 12s-export`.
- Modify: `Sources/LungfishCLI/Commands/GenotypeCommandGroup.swift` (register the new subcommand alongside the existing `export-xlsx`/`export-pivot-xlsx`/`export-labkey`).
- Modify: `Sources/LungfishCLI/Commands/GenotypeExportXlsxSubcommand.swift` (reuse its `MatrixBuilder`/`writeMinimalXLSX` — factor the workbook writer into a shared helper the new command calls; do not duplicate).
- Test: `Tests/LungfishCLITests/GenotypeExportSubcommandTests.swift` (new).

**Divergence today:** genotype has three flagless export commands (`export-xlsx`, `export-pivot-xlsx`, `export-labkey`) with no filter/lens flags; 12S has one `12s-export --export-format ... + filter flags`. The GUI export (Task 5) needs a CLI that takes the visible-rows/lens/filter projection and records `toolName == "lungfish-cli"`. Add `genotype export` taking `--bundle`, `--format`, `--output`, `--lens`, `--min-reads`, `--filter`, repeatable `--sample`, `--active-haplotype-definition`, `--force`, plus an optional `--view-projection <path-to-json>` carrying the exact visible rows + cell/row colors the viewport rendered (so the CLI reproduces the colored matrix without re-deriving it).

- [ ] Step 1: Write the failing test.
  - `testGenotypeExportWritesXlsxAndCanonicalProvenance`: build a tiny `.lungfishgenotype` fixture (reuse the helper from `GenotypeViewportExcelExportTests`/`ONTGenotypeResultBundleTests`), run the command in-process via `GenotypeExportSubcommand.parse([...])` + `run()`, assert (a) the `.xlsx` exists, (b) a sidecar `*.lungfish-provenance.json` exists, (c) `ProvenanceEnvelopeReader.load(...).toolName == "lungfish-cli"`, (d) `workflowName == "lungfish genotype export"`, (e) the output path is in `envelope.outputs`. Mirror the assertions `TwelveSAmpliconResultExportService.verifyProvenance` makes (lines 152-167).
  - `testGenotypeExportProjectionFiltersToVisibleSamples`: pass `--sample S1 --sample S2` (omitting S3) and a projection file; assert the workbook's sample columns are exactly `[S1, S2]`.
  ```swift
  func testGenotypeExportRecordsLungfishCliProvenance() async throws {
      let fixture = try makeGenotypeBundleFixture()      // helper
      let out = fixture.appendingPathComponent("out.xlsx")
      var cmd = try GenotypeExportSubcommand.parse([
          "--bundle", fixture.path, "--format", "xlsx", "--output", out.path, "--force"])
      try await cmd.run()
      let prov = out.appendingPathExtension("lungfish-provenance.json")
      let env = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: prov))
      XCTAssertEqual(env.toolName, "lungfish-cli")
      XCTAssertEqual(env.workflowName, "lungfish genotype export")
      XCTAssertEqual(env.exitStatus, 0)
  }
  ```
- [ ] Step 2: Run, expect FAIL.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter GenotypeExportSubcommandTests`
  Expected: compile error — `GenotypeExportSubcommand` does not exist.
- [ ] Step 3: Implement.
  - **Define the `--view-projection` schema first (this command is the producer; Task 5 is only the consumer).** Add a `Codable, Sendable` `GenotypeViewProjection` struct in `LungfishIO` (or `LungfishWorkflow`) capturing exactly what the viewport renders: `lens`, ordered `sampleColumns: [String]`, ordered `rows: [GenotypeViewProjectionRow]` (each with a row label + per-sample cell value + optional `cellColorHex`/`rowColorHex`), and `cellColorMode`. This is the contract Task 5 serializes and this command deserializes. Defining it here unblocks Task 5.
  - **Two distinct workbook shapes, one writer module.** The existing `export-xlsx` emits the analytical **matrix** (genotype × locus, Budde palette via `MatrixBuilder`/`writeMinimalXLSX`). The **viewport projection** is a different layout (sample columns, the colors the user sees). Factor BOTH into a `GenotypeXlsxWorkbookWriter` with two entry points — `writeMatrix(...)` (move the existing logic; keep `export-xlsx` delegating so its tests stay green) and `writeViewProjection(_ projection: GenotypeViewProjection, to:)` (new, renders sample-column layout + projection colors). Do NOT try to force the projection through the matrix builder.
  - `GenotypeExportSubcommand`: parse the flags above; for `--format xlsx` with `--view-projection` present, deserialize and call `writeViewProjection`; without it, call `writeMatrix` (full bundle). For `csv`/`tsv`, emit the projection rows (or matrix rows) delimited. Record provenance with `GenotypeExportProvenanceSupport.record(workflowName: "genotype.export", toolName: "lungfish-cli", command: ["lungfish-cli","genotype","export", ...], bundleURL:..., outputURLs:[out], ...)`. **Confirm against `Sources/LungfishCLI/Commands/GenotypeExportXlsxSubcommand.swift:84`** (the `GenotypeExportProvenanceSupport.record` signature reviewers verified: `workflowName, toolName, command, bundleURL, outputURLs, outputDirectory, optionPaths, additionalInputURLs, startedAt`). The existing `export-xlsx` passes a `"lungfish genotype export-xlsx"`-style `toolName`; the NEW command MUST pass `toolName: "lungfish-cli"` so the envelope satisfies both the binding rule and the GUI verifier's `toolName == "lungfish-cli"` check.
  - Register in `GenotypeCommandGroup.subcommands`.
- [ ] Step 4: Run, expect PASS — new suite + the existing export-xlsx suite (no regression):
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter GenotypeExportSubcommandTests` and
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter GenotypeExportLabKeySubcommandTests`
- [ ] Step 5: Commit.
  `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/LungfishCLI/Commands/GenotypeExportSubcommand.swift Sources/LungfishCLI/Commands/GenotypeCommandGroup.swift Sources/LungfishCLI/Commands/GenotypeExportXlsxSubcommand.swift Tests/LungfishCLITests/GenotypeExportSubcommandTests.swift && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "$(cat <<'MSG'
Add unified genotype export CLI with filter/lens flags (S-P1-11)

One genotype export --format {xlsx,csv,tsv} taking the visible/lens filter
projection and the same filter flags 12S exposes, recording canonical
lungfish-cli provenance. Shares the workbook writer with export-xlsx.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
)"`

---

## Phase 1b — Dependent P1 work

### Task 5: Route the genotype viewport export through the CLI  (addresses S-P1-4)
**Files:**
- Modify: `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift` (`exportExcelView(_:)` 3337-3361; `currentExportSnapshot()` 3284-3308): build the view projection, shell out to `genotype export` (Task 4), verify provenance.
- Create: `Sources/LungfishApp/Views/Results/Genotype/GenotypeViewportExportService.swift` — a CLI-backed service mirroring `TwelveSAmpliconResultExportService` (runner protocol, `verifyProvenance`).
- Modify/Delete: `Sources/LungfishApp/Views/Results/Genotype/GenotypeViewportExcelExportService.swift` — repurpose into the projection-serializer used by the CLI (`--view-projection`), or delete the in-process XLSX writer + the `lungfish-gui` argv (112-117) if the CLI fully replaces it. Decide by whether any non-export caller uses it (grep shows only `GenotypeResultViewController:3350`).
- Test: `Tests/LungfishAppTests/GenotypeViewportExcelExportTests.swift` — rewrite to assert CLI-backed provenance (`toolName == "lungfish-cli"`).

**Binding-rule violation today:** `GenotypeViewportExcelExportService.export` writes XLSX in-process and stamps `argv: ["lungfish-gui", ...]`, `toolName: "Lungfish Genome Explorer"` (lines 105-117). Every scientific GUI action must shell out to `lungfish-cli`. 12S already does this (`TwelveSAmpliconResultExportService` shells `fastq 12s-export` and verifies `envelope.toolName == "lungfish-cli"`).

- [ ] Step 1: Write the failing test. Adapt the existing `testExcelExportProvenanceRecordsVisibleSamplesAndFilterContext` (218) to the new service:
  ```swift
  func testGenotypeViewportExportShellsToCLIAndRecordsLungfishCliProvenance() throws {
      let recorder = RecordingExportRunner()    // captures arguments, then runs real CLI in-process
      let service = GenotypeViewportExportService(runner: recorder)
      let result = try service.export(snapshot: makeSnapshot(visibleSamples: ["S1","S2"]), format: .excel, to: outURL)
      XCTAssertTrue(recorder.arguments.starts(with: ["genotype", "export"]),
                    "CLI invocation must begin with `genotype export`, got \(recorder.arguments)")
      XCTAssertTrue(recorder.arguments.contains("--lens"))
      XCTAssertTrue(recorder.arguments.contains("S1") && recorder.arguments.contains("S2"),
                    "Both visible samples must be passed")
      let env = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
      XCTAssertEqual(env.toolName, "lungfish-cli")
  }
  ```
  (Use the same `LungfishCLIRunner`-style runner protocol 12S uses so the test can inject a recording runner that still produces a real provenance sidecar. The assertions are exactly: arguments start with `["genotype","export"]`, include `--lens`, and include each visible sample.)
- [ ] Step 2: Run, expect FAIL.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter GenotypeViewportExcelExportTests`
  Expected: compile error — `GenotypeViewportExportService` does not exist; old service stamps `lungfish-gui`.
- [ ] Step 3: Implement.
  - `GenotypeViewportExportService`: protocol `GenotypeViewportExportRunning { func run(arguments: [String]) throws -> LungfishCLIRunner.Output }`, default impl `LungfishCLIRunner.run`. `export(snapshot:format:to:)` builds a `GenotypeViewProjection` (the exact type Task 4 defines — visible `sampleColumns`, ordered `rows` with cell values + color hexes, `lens`, `cellColorMode`) from the snapshot, writes it to a temp JSON, builds `["genotype","export","--bundle",path,"--export-format",fmt,"--output",out,"--lens",snapshot.lens,"--view-projection",projPath,"--force"]` plus `--sample` per visible sample and `--min-reads` / `--filter` from the filter context, runs it, then verifies provenance exactly like `TwelveSAmpliconResultExportService.verifyProvenance` (require `toolName == "lungfish-cli"`, `workflowName == "lungfish genotype export"`, output path present). Clean up the temp projection via `defer`. (Depends on Task 4: the `GenotypeViewProjection` schema and the `genotype export --view-projection` consumer must exist first.) **NOTE (from Task 4 implementation): the container-format flag is `--export-format`, NOT `--format`** — `GlobalOptions` already owns `--format`, so ArgumentParser forbade reusing it. The CLI args above use `--export-format`. Task 4 also exposed `runReturningResolvedColumns()` and the projection's color hex fields (`cellColorsHex`/`rowColorHex`, `#RRGGBB`) drive a dynamic per-hex style table in the `View` sheet.
  - `exportExcelView(_:)`: replace the `GenotypeViewportExcelExportService().export(...)` call (3350) with the new service. Keep the `NSSavePanel`/`Task { @MainActor }` shape (already MainActor-correct). Surface errors via `NSAlert(error:)` as today.
  - Repurpose `GenotypeViewportExcelExportService` into the `--view-projection` serializer consumed by `genotype export`, or delete it if the shared `GenotypeXlsxWorkbookWriter` (Task 4) covers the rendering. Either way, remove the `lungfish-gui` argv.
  - **Robustness gaps to close on the producer side (from Task 4 code review):** the projection the GUI serializes MUST be self-consistent so the CLI consumer never silently mis-renders. (a) Ensure each row's `cells`/`cellColorsHex` length matches `sampleColumns` count before writing the JSON (the CLI truncates over-long rows silently); assert this in the serializer and in a test. (b) Emit color hexes already in the `#RRGGBB` form the writer's `ProjectionPalette.normalize` accepts (exactly 6 hex chars). (c) Add a test that a round-trip GUI-serialize → `genotype export --view-projection` reproduces the visible sample set and at least one cell color. These prevent GUI/CLI drift; the CLI's own malformed-JSON error message (raw `DecodingError`) is a separate minor CLI nice-to-have, not required here.
- [ ] Step 4: Run, expect PASS.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter GenotypeViewportExcelExportTests` and `swift build --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update`
- [ ] Step 5: Commit.
  `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/LungfishApp/Views/Results/Genotype/ Tests/LungfishAppTests/GenotypeViewportExcelExportTests.swift && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "$(cat <<'MSG'
Route genotype viewport export through lungfish-cli (S-P1-4)

Replace the in-process XLSX writer (lungfish-gui argv) with a CLI-backed
service that shells to `genotype export` and verifies toolName==lungfish-cli,
mirroring the 12S exporter.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
)"`

---

### Task 6: Complete the `.lungfishmhcref` consume path  (addresses S-P1-1)

> **DONE (commit `faee5118`).** Follow-up surfaced during implementation (tracked, NOT done): the sibling subcommands `FastqONTGenotypingSubcommand` and `FastqONTBarcodeGenotypingSubcommand` have the SAME consume-side gaps — `--reference` help omits `.lungfishmhcref`, and `FastqONTBarcodeGenotypingSubcommand`'s `--haplotype-definition` passes straight through with no bundle validation or auto-default. The bundle FASTA still resolves at the pipeline level for all of them, but the CLI ergonomics (help text, explicit-definition validation, auto-select) are only complete for `FastqGenotypingSubcommand`. Apply the same `resolveBundleHaplotypeDefinition` treatment to the two siblings as a follow-up task (call it Task 6b when scheduled). Also note: when a `.lungfishmhcref` is selected, its paired assay/species now take precedence over explicit `--haplotype-assay`/`--haplotype-species` flags (intended bundle-gate semantics).

**Files:**
- Modify: `Sources/LungfishCLI/Commands/FastqGenotypingSubcommand.swift` (`--reference` help 21-22; `effectiveHaplotypeDefinition`/`effectiveHaplotypeAssay`/`effectiveHaplotypeSpecies` 107-111; `defaultBundledHaplotypeDefinition` 169-176): document `.lungfishmhcref`; when the reference is a bundle AND an explicit `--haplotype-definition` is given, verify the definition exists in the bundle (consistency check) instead of silently bypassing.
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift` (`resolveReference` 979-1019 already resolves the bundle FASTA — confirm; ensure haplotype defs resolve from the same bundle).
- Modify (GUI): `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState.swift` (227, 462: when a `.lungfishmhcref` is selected, collapse the picker stack to a "From bundle: <name>" summary).
- Test: extend `Tests/LungfishWorkflowTests/ONTBarcodeDemuxGenotypingPipelineTests.swift` + add `Tests/LungfishCLITests/FastqGenotypingBundleReferenceTests.swift`.

**Gaps (synthesis "partially closed"):** the CLI already accepts a `.lungfishmhcref` as `--reference` and auto-selects the bundle's default definition (`defaultBundledHaplotypeDefinition` 169-176, used at 108-111). Remaining: (a) `--reference` help omits `.lungfishmhcref`; (b) an explicit `--haplotype-definition` bypasses the bundle with no consistency check; (c) multi-definition bundles silently use only the default; (d) the run dialog still shows the full picker stack.

- [ ] Step 1: Write the failing tests.
  - `FastqGenotypingBundleReferenceTests.testExplicitHaplotypeDefinitionMustExistInBundle`: build a `.lungfishmhcref` with definitions `[D1, D2]`; parse a command with `--reference bundle --haplotype-definition D3` → `cmd.run()` (or a pure resolver extracted from `run`) throws a validation error naming `D3` and the bundle. With `--haplotype-definition D2` → resolves to `D2` (not the default `D1`).
  - `testReferenceHelpMentionsLungfishMHCRef`: extract the `--reference` help text to a `static let referenceHelp` and assert it `contains(".lungfishmhcref")`. (Asserting on a hoisted constant is simplest; do not try to introspect ArgumentParser's rendered help.)
  ```swift
  func testReferenceHelpMentionsLungfishMHCRef() {
      XCTAssertTrue(FastqGenotypingSubcommand.referenceHelp.contains(".lungfishmhcref"))
  }
  ```
- [ ] Step 2: Run, expect FAIL.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter FastqGenotypingBundleReferenceTests`
  Expected: explicit `D3` silently used (no throw) → assertion fails; `referenceHelp` symbol missing → compile error.
- [ ] Step 3: Implement.
  - Add `static let referenceHelp = "Reference FASTA file, .lungfishref bundle, or .lungfishmhcref bundle (FASTA + paired haplotype definitions) used as the mapping target"`; use it in the `@Option` help (line 21-22).
  - In `run()` after `referenceURL` is built: if `MHCAmpliconReferenceBundle.isBundleURL(referenceURL)` and `haplotypeDefinition != nil`, verify `MHCAmpliconReferenceBundle.haplotypeDefinition(id: haplotypeDefinition!, ..., in: referenceURL) != nil`, else `throw ValidationError("Haplotype definition '\(id)' is not present in reference bundle '\(name)'. Available: \(ids).")`. When present, set `effectiveHaplotypeDefinition`/`Assay`/`Species` from THAT bundle definition (so an explicit non-default selection from a multi-definition bundle works) rather than `bundledDefaultHaplotype`.
  - Extract the resolution into a testable `static func resolveBundleHaplotypeDefinition(referenceURL:explicitID:) throws -> GenotypeHaplotypeDefinitionSet?` so the test calls it without a full pipeline run.
  - GUI: in `WorkflowOperationDialogState`, when `MHCAmpliconReferenceBundle.isBundleURL(selectedReferenceURL)` (227), set a `referenceBundleSummary = "From bundle: \(manifest.name)"` and hide the haplotype picker stack (gate the picker views on `referenceBundleSummary == nil`). Add a unit test in the dialog-state test file if one exists; otherwise assert via the state's published property.
- [ ] Step 4: Run, expect PASS.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter FastqGenotypingBundleReferenceTests` and
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter ONTBarcodeDemuxGenotypingPipelineTests`
- [ ] Step 5: Commit.
  `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/LungfishCLI/Commands/FastqGenotypingSubcommand.swift Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline.swift Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationDialogState.swift Tests/ && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "$(cat <<'MSG'
Complete .lungfishmhcref consume path for genotyping (S-P1-1)

Document .lungfishmhcref in --reference help; verify an explicit
--haplotype-definition exists in the bundle (and honor non-default
selections); collapse the run-dialog picker stack to a bundle summary.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
)"`

> **Phase-5 link:** this is the bundle-format gate prerequisite.

---

### Task 7: Ship 12S opt-in by default  (addresses S-P1-2)
**Files:**
- Modify: `Sources/LungfishApp/Services/WorkflowLibrary.swift` (`defaultEnabledWorkflowIDs` 227-230: remove `twelveSAmpliconMatchingID`).
- Modify: `Tests/LungfishAppWorkflowTests/WorkflowLibraryTests.swift` (`testFreshInstallEnablesBundledSpecializedWorkflowsAndPersistsExplicitChanges` 57-79: invert the 12S assertion).

- [ ] Step 1: Update the test to assert the intended behavior (this is the red step — it will fail against current code). Rename to `testFreshInstallEnablesONTGenotypingButLeavesTwelveSOptIn` and change line 64 from `XCTAssertTrue(store.isWorkflowEnabled(twelveS))` to `XCTAssertFalse(store.isWorkflowEnabled(twelveS))`. Add: after `store.setWorkflow(twelveS, enabled: true)` then reload, assert it persists `true` (no silent re-enable). Keep ONT-genotyping enabled-by-default assertions intact.
- [ ] Step 2: Run, expect FAIL.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter WorkflowLibraryTests/testFreshInstallEnablesONTGenotypingButLeavesTwelveSOptIn`
  Expected: `XCTAssertFalse failed` — 12S is currently on by default.
- [ ] Step 3: Implement — remove `WorkflowLibraryCatalog.twelveSAmpliconMatchingID,` from `defaultEnabledWorkflowIDs` (line 229), leaving only `FASTQOperationToolID.ontGenotyping.rawValue`.
- [ ] Step 4: Run, expect PASS.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter WorkflowLibraryTests`
- [ ] Step 5: Commit.
  `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/LungfishApp/Services/WorkflowLibrary.swift Tests/LungfishAppWorkflowTests/WorkflowLibraryTests.swift && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "$(cat <<'MSG'
Ship 12S amplicon matching opt-in by default (S-P1-2)

Remove twelveSAmpliconMatchingID from defaultEnabledWorkflowIDs so the niche
workflow is opt-in; existing explicit enablement still persists.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
)"`

---

### Task 8: Make SampleMetadataStore use the quote-aware parser  (addresses S-P1-6)
**Files:**
- Modify: `Sources/LungfishCore/Models/SampleMetadataResolver.swift` (expose the quote-aware splitter — currently `private static func split(line:delimiter:)` 256-291 inside `SampleMetadataTable`).
- Modify: `Sources/LungfishCore/Models/SampleMetadataStore.swift` (`parseCSV` 56-77: replace the naive `line.split(separator: delimiter)` at 67 and 73 with the quote-aware splitter).
- Test: `Tests/LungfishCoreTests/SampleMetadataStoreTests.swift` (extend).

**Latent bug:** `SampleMetadataStore.parseCSV` splits on the raw delimiter (lines 67, 73), so a quoted CSV field containing a comma (`"Doe, Jane"`) is mis-split → silent metadata corruption. `SampleMetadataResolver`/`SampleMetadataTable` already has a correct quote-aware `split`. Unify.

- [ ] Step 1: Write the failing test.
  ```swift
  func testParsesQuotedCommaWithinField() throws {
      let csv = "sample_id,note\nS1,\"Doe, Jane\"\nS2,plain\n"
      let store = try SampleMetadataStore(csvData: Data(csv.utf8), knownSampleIds: ["S1","S2"])
      XCTAssertEqual(store.records["S1"]?["note"], "Doe, Jane")
      XCTAssertEqual(store.records["S2"]?["note"], "plain")
  }
  ```
- [ ] Step 2: Run, expect FAIL.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter SampleMetadataStoreTests/testParsesQuotedCommaWithinField`
  Expected: `note` for S1 is `"Doe` (truncated at the embedded comma).
- [ ] Step 3: Implement. Promote the splitter to a shared `public enum DelimitedLineParser { public static func fields(in line: String, delimiter: Character) -> [String] }` in `SampleMetadataResolver.swift` (move the quote-aware body verbatim; generalize the `","` guard to the passed delimiter while keeping the tab fast-path). Point `SampleMetadataTable.split` AND `SampleMetadataStore.parseCSV` (both the header split 67 and row split 73) at it. Keep `MetadataParseError` behavior identical.
- [ ] Step 4: Run, expect PASS — both suites:
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter SampleMetadataStoreTests` and
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter SampleMetadataResolverTests`
- [ ] Step 5: Commit.
  `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/LungfishCore/Models/SampleMetadataResolver.swift Sources/LungfishCore/Models/SampleMetadataStore.swift Tests/LungfishCoreTests/SampleMetadataStoreTests.swift && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "$(cat <<'MSG'
Unify CSV/TSV parsing on the quote-aware splitter (S-P1-6)

SampleMetadataStore.parseCSV now uses the shared quote-aware DelimitedLineParser
instead of a naive split, fixing silent corruption of quoted fields containing
the delimiter.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
)"`

---

### Task 9: Fix the haplotype-manager detached task + add the genotype minimum-reads control  (addresses S-P1-7; completes S-P1-3 UI)
**Files:**
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/HaplotypeDefinitionManagerWindowController.swift` (`createMHCReferenceBundle` 304-348: replace `Task.detached`+`await MainActor.run` with the prescribed pattern + `[weak self]`).
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/GenotypeResultDisplaySection*` (add the editable "Minimum Reads" TextField+Stepper mirroring `TwelveSResultDisplaySection` 228-255, bound to `displayState.minimumReads` from Task 3).
- Test: `Tests/LungfishAppTests/GenotypeResultDisplaySectionTests.swift` (assert the section's set-minimum-reads path updates the display state and fires the change callback).

**Issue (S-P1-7, adjudicated P1):** `createMHCReferenceBundle` runs `Task.detached(priority:.userInitiated)` then `await MainActor.run { self.… }` (322-347) — it `await`s `@MainActor` members from a detached task (breaks the binding rule) and captures `self` strongly. Functionally safe today, but must follow the rule.

- [ ] Step 1: Write the failing test (UI-state layer for the S-P1-3 control). In `GenotypeResultDisplaySectionTests`, drive the section view-model's `setMinimumReads(_:)` (to be added, mirroring `TwelveSResultDisplaySectionViewModel.setMinimumExactReads` 81-84) and assert `displayState.minimumReads == 5000` and the `onDisplayStateChanged` callback fired once. (The `Task.detached` fix itself is verified by `swift build` strict-concurrency + code review, not a unit test; the test here secures the paired S-P1-3 UI control.)
  ```swift
  func testGenotypeSectionSetMinimumReadsUpdatesStateAndNotifies() {
      let vm = GenotypeResultDisplaySectionViewModel()
      var fired = 0; vm.onDisplayStateChanged = { _ in fired += 1 }
      vm.setMinimumReads(5_000)
      XCTAssertEqual(vm.displayState.minimumReads, 5_000)
      XCTAssertEqual(fired, 1)
  }
  ```
- [ ] Step 2: Run, expect FAIL.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter GenotypeResultDisplaySectionTests/testGenotypeSectionSetMinimumReadsUpdatesStateAndNotifies`
  Expected: no `setMinimumReads` on the view-model → compile error.
- [ ] Step 3: Implement.
  - `createMHCReferenceBundle`: keep the heavy `service.createMHCReferenceBundle(...)` off the main actor, but hop back via the prescribed pattern. Since the controller is `@MainActor`, the clean fix is a non-detached task:
    ```swift
    isWorking = true
    Task { [weak self] in
        guard let self else { return }
        do {
            let result = try await service.createMHCReferenceBundle(records: [record], ...)
            self.isWorking = false
            self.reload()
            self.selectedRecordID = self.records.first { $0.referenceBundleURL == result.bundleURL && $0.definitionSet.id == record.definitionSet.id }?.id ?? self.selectedRecordID
        } catch {
            self.isWorking = false
            self.errorMessage = error.localizedDescription
        }
    }
    ```
    (`Task {}` on a `@MainActor` type inherits MainActor isolation; `service` is captured as a local `let` before the task, and `createMHCReferenceBundle` is the suspension point. No `Task.detached`, no `await MainActor.run`, `[weak self]` present.) If `service` is not `Sendable`, capture only the value-typed inputs and re-derive `service` inside, or hop the heavy work into the command-service actor.
  - Add the editable "Minimum Reads" control to the genotype Inspector section + the `setMinimumReads(_:)` view-model method (clamp `>= 0`, fire `onDisplayStateChanged`), bound exactly like 12S's control. Wire the controller to call `rebuildCohortSummary()` + re-filter rows on change.
- [ ] Step 4: Run, expect PASS, and confirm strict-concurrency build:
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter GenotypeResultDisplaySectionTests` and `swift build --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update`
- [ ] Step 5: Commit.
  `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/LungfishApp/Views/WorkflowOperations/HaplotypeDefinitionManagerWindowController.swift Sources/LungfishApp/Views/Inspector/Sections/ Sources/LungfishApp/Views/Results/Genotype/ Tests/LungfishAppTests/GenotypeResultDisplaySectionTests.swift && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "$(cat <<'MSG'
Fix haplotype-manager detached task + add genotype minimum-reads control (S-P1-7, S-P1-3)

Replace Task.detached + await MainActor.run with a MainActor-inherited Task and
[weak self]. Add the editable Minimum Reads Inspector control mirroring 12S,
bound to the shared threshold model.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
)"`

---

### Task 10: Normalize replay argv to `lungfish-cli` and pick one MHC bundle-create subcommand  (addresses S-P1-8)
**Files:**
- Modify: `Sources/LungfishApp/Views/WorkflowOperations/HaplotypeDefinitionManagerWindowController.swift` (argv at 135, 156, 183, 198 use `"lungfish"`; 311 uses `"lungfish-cli"`; 382 `["lungfish"]` — normalize all to `lungfish-cli`).
- Modify: `Sources/LungfishApp/Views/Results/Genotype/GenotypeAnnotationStore.swift` (452 `"lungfish-gui"`), `Sources/LungfishApp/Views/Results/Genotype/GenotypeResultViewController.swift` (2059 `"lungfish-gui"`) — normalize to `lungfish-cli` (these are replay-argv strings recorded in provenance, not actual GUI launches).
- Decision (S-P1-8): two MHC bundle-create commands exist — `fastq mhc-reference-bundle` (`FastqMHCReferenceBundleSubcommand`) and `haplotypes bundle-create` (`HaplotypeDefinitionsCommand` 160). Pick `haplotypes bundle-create` as canonical (it lives with the rest of the haplotype CRUD the manager calls) and route the GUI there consistently. **Do NOT delete `FastqMHCReferenceBundleSubcommand` in this task** — it is a CLI-surface change with potential external callers (recipe engine, docs, tests). Make it DELEGATE to the canonical path (or leave it in place). Removal, if warranted, is a separate follow-up gated on a full caller audit (`grep -rn "mhc-reference-bundle" Sources docs Tests` and the recipe definitions). This keeps the risky surface change out of the low-risk argv normalization.
- Test: `Tests/LungfishAppTests/` argv assertions (extend `GenotypeViewportExcelExportTests`/manager tests) + grep-guard.

- [ ] Step 1: Write the failing test. Add `testAllRecordedReplayArgvUseLungfishCli` that asserts each argv-producing site emits `"lungfish-cli"` as argv[0]. Where a manager action records argv, assert via the recording runner. Also add a lightweight source guard test:
  ```swift
  func testNoLungfishGuiArgvRemainsInGenotypeSources() throws {
      // Read the two genotype source files and assert they contain no "lungfish-gui" argv literal.
      for file in ["GenotypeAnnotationStore.swift", "GenotypeResultViewController.swift"] {
          let text = try String(contentsOf: genotypeSourceURL(file), encoding: .utf8)
          XCTAssertFalse(text.contains("\"lungfish-gui\""), "\(file) still records a lungfish-gui argv")
      }
  }
  ```
- [ ] Step 2: Run, expect FAIL.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter testNoLungfishGuiArgvRemainsInGenotypeSources`
  Expected: both files still contain `"lungfish-gui"`.
- [ ] Step 3: Implement — replace every replay-argv `"lungfish"` / `"lungfish-gui"` literal at the listed sites with `"lungfish-cli"`. Point `HaplotypeDefinitionManagerWindowController.createMHCReferenceBundle`'s argv (311) and the actual service invocation at the canonical `haplotypes bundle-create`. Leave `FastqMHCReferenceBundleSubcommand` in place (or make it delegate to the canonical path) — do not remove it here (see Decision above; removal is a separate audited follow-up). Keep `mhcReferenceBundleURL(from:)` etc. unchanged.
- [ ] Step 4: Run, expect PASS.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter WorkflowLibraryTests` is unrelated; run the new guard + `swift build`:
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter GenotypeViewportExcelExportTests` and `swift build --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update`
- [ ] Step 5: Commit.
  `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/LungfishApp/Views/ Sources/LungfishCLI/ Tests/ && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "$(cat <<'MSG'
Normalize replay argv to lungfish-cli; pick canonical MHC bundle-create (S-P1-8)

All recorded replay argv now use lungfish-cli (was lungfish / lungfish-gui).
Standardize MHC bundle creation on `haplotypes bundle-create`.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
)"`

---

### Task 11: Converge 12S free-text search on the in-viewport NSSearchField idiom  (addresses S-P1-9)
**Files:**
- Modify: `Sources/LungfishApp/Views/Results/TwelveS/TwelveSAmpliconResultViewController.swift` (add a header `NSSearchField` like `TaxTriageResultViewController`/genotype; bind to `displayState.filterText`).
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/TwelveSResultDisplaySection.swift` (257-264: remove the Inspector-only "Filter species or matches" `TextField`, or leave it mirrored read-only; the canonical control moves to the viewport header).
- Test: `Tests/LungfishAppTests/TwelveSResultDisplaySectionTests.swift` (assert `setFilterText` still drives `displayState.filterText` and the filtered-row count) — the binding contract is unchanged; only the control's host moves.

**Divergence (I4/D2):** 12S exposes free-text search only as an Inspector `TextField`; the classifier idiom (TaxTriage) and genotype use an in-viewport debounced `NSSearchField`. Converge 12S onto the in-viewport header `NSSearchField` so search lives where the other result viewports put it.

- [ ] Step 1: Write the failing test. The filter-text contract is already covered; add `testFilterTextFromViewportSearchFieldFiltersRows` at the view-controller test layer (if `TwelveSAmpliconResultViewControllerTests` exists; else assert at the display-state layer that `setFilterText("homo")` yields the expected `visibleRowCount`). Concretely, assert: given rows `["Homo sapiens","Gadus morhua"]`, setting `filterText = "homo"` makes the filtered set `["Homo sapiens"]`. Pull the row-filtering into a pure helper if not already (see Task 12 for the shared filter) so the test is deterministic.
- [ ] Step 2: Run, expect FAIL (helper/assert not yet wired to a viewport search field).
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter TwelveSResultDisplaySectionTests`
- [ ] Step 3: Implement. Add an `NSSearchField` to the 12S viewport header (mirror `TaxTriageResultViewController`'s setup: `searchField.sendsSearchStringImmediately`, target/action debounced via the existing pattern), wire its `stringValue` to `viewModel.setFilterText(_:)`/`displayState.filterText`. Remove the Inspector `TextField` (257-264) or convert it to a non-editable echo; keep `accessibilityIdentifier("twelve-s-filter-field")` on the new field so any UI tests still resolve it.
- [ ] Step 4: Run, expect PASS, plus build.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter TwelveSResultDisplaySectionTests` and `swift build --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update`
- [ ] Step 5: Commit.
  `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/LungfishApp/Views/Results/TwelveS/TwelveSAmpliconResultViewController.swift Sources/LungfishApp/Views/Inspector/Sections/TwelveSResultDisplaySection.swift Tests/LungfishAppTests/TwelveSResultDisplaySectionTests.swift && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "$(cat <<'MSG'
Move 12S free-text search to in-viewport NSSearchField (S-P1-9)

Adopt the classifier/genotype in-viewport search idiom for 12S instead of the
Inspector-only text field; filter-text binding contract unchanged.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
)"`

---

### Task 12: Converge include/exclude + boolean filters on the pill-row idiom  (addresses S-P1-10)
**Files:**
- Modify: `Sources/LungfishApp/Views/Inspector/Sections/TwelveSResultDisplaySection.swift` (`taxonomyControls` 267-307: replace the dual `Menu`-of-`Toggle`s + standalone `Toggle`s with a pill row matching the genotype `GenotypeQuickFilterBarView` pill idiom — `pushOnPushOff` buttons for taxon groups, boolean pills for Exclude Human / Only With Alternates).
- Modify (reference): `Sources/LungfishApp/Views/Results/Genotype/GenotypeQuickFilterBarView.swift` (the pill idiom to converge on — extract a reusable pill-row view if cheap).
- Test: `Tests/LungfishAppTests/TwelveSResultDisplaySectionTests.swift` — the `setIncludedTaxonGroup` / `setExcludedTaxonGroup` / `setExcludeHuman` / `setRequireAlternateMatches` view-model contracts are unchanged; assert they still produce the right `displayState` (include clears exclude and vice versa, per 96-127).

**Divergence (I8/I9/D6):** 12S uses two `Menu`s of `Toggle`s for taxon groups plus SwiftUI `Toggle`s for booleans; genotype uses `pushOnPushOff` pill `NSButton`s. Converge on one pill-row idiom for both categories and boolean attributes.

- [ ] Step 1: Write the failing test (contract-preserving). Assert: `setIncludedTaxonGroup("Mammal", isIncluded: true)` then `setExcludedTaxonGroup("Mammal", isExcluded: true)` leaves `includedTaxonGroups` empty and `excludedTaxonGroups == ["Mammal"]` (mutual exclusivity, per existing 96-127). Add a new assertion that a `pillState(for:)` helper on the view-model returns `.included`/`.excluded`/`.neutral` so the pill view can render tri-state from one source of truth.
  ```swift
  func testTaxonPillTriStateReflectsDisplayState() {
      let vm = TwelveSResultDisplaySectionViewModel()
      vm.setIncludedTaxonGroup("Mammal", isIncluded: true)
      XCTAssertEqual(vm.pillState(for: "Mammal"), .included)
      vm.setExcludedTaxonGroup("Mammal", isExcluded: true)
      XCTAssertEqual(vm.pillState(for: "Mammal"), .excluded)
      XCTAssertTrue(vm.displayState.includedTaxonGroups.isEmpty)
  }
  ```
- [ ] Step 2: Run, expect FAIL.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter TwelveSResultDisplaySectionTests/testTaxonPillTriStateReflectsDisplayState`
  Expected: no `pillState(for:)` → compile error.
- [ ] Step 3: Implement. Add `enum TaxonPillState { case neutral, included, excluded }` + `func pillState(for group: String) -> TaxonPillState` to the 12S view-model. Replace `taxonomyControls` with a pill row: one tri-state pill per taxon group (tap cycles neutral→include→exclude, or an include/exclude segmented affordance matching genotype), plus boolean pills for Exclude Human / Only With Alternates bound to the existing setters. Reuse the genotype pill styling (Lungfish Orange selected state `#D47B3A`); if extracting a shared `FilterPillRow` view is more than ~30 lines of churn, defer the extraction to P2 and just match the visual+interaction idiom now.
- [ ] Step 4: Run, expect PASS + build.
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter TwelveSResultDisplaySectionTests` and `swift build --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update`
- [ ] Step 5: Commit.
  `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/LungfishApp/Views/Inspector/Sections/TwelveSResultDisplaySection.swift Sources/LungfishApp/Views/Results/Genotype/GenotypeQuickFilterBarView.swift Tests/LungfishAppTests/TwelveSResultDisplaySectionTests.swift && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "$(cat <<'MSG'
Converge 12S include/exclude + boolean filters on the pill-row idiom (S-P1-10)

Replace dual Menu-of-Toggles + standalone Toggles with the genotype pill-row
idiom (tri-state taxon pills + boolean pills); setter contracts unchanged.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
)"`

---
## Phase 2 — P2 reuse refactors and polish (opted in)

> These build on the shared types from Phase 1a. Each is independently revertible. Where a refactor is "extract + redirect callers with no behavior change," the test is a characterization test asserting identical output before and after.

### Task 13: Extract shared BundleBuilderSupport + ProvenanceDirectoryDescriptor + a single TSVTable reader  (addresses S-P2-2)
**Prerequisite:** Task 8 (the `DelimitedLineParser` this task's `TSVTable` reader builds on). Do not start until Task 8 has landed.
**Files:**
- Create: `Sources/LungfishIO/Bundles/BundleBuilderSupport.swift` (shared dir-checksum / provenance-directory descriptor) and `Sources/LungfishIO/Formats/TSVTable.swift` (one quote-aware delimited-table reader — reuse `DelimitedLineParser` from Task 8).
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/MHCAmpliconReferenceBundleBuilder.swift`, `Sources/LungfishWorkflow/TwelveS/TwelveSReferenceBundleBuilder.swift`, `Sources/LungfishWorkflow/TwelveS/TwelveSResultExportWorkflow.swift`, `Sources/LungfishWorkflow/ONTGenotyping/HaplotypeDefinitionCommandService.swift` — replace the triplicated copies.
- Test: `Tests/LungfishIOTests/TSVTableTests.swift` (new) + existing builder suites as regression.

- [ ] Step 1: Write `TSVTableTests` asserting quote-aware parse, header access, and round-trip equal to the prior ad-hoc parse on a known fixture (characterization). Add a `BundleBuilderSupportTests.testDirectoryChecksumIsStableAndOrderIndependent`.
- [ ] Step 2: `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter TSVTableTests` → FAIL (symbol missing).
- [ ] Step 3: Implement the shared types; redirect each duplicated site. No behavior change; keep outputs byte-identical (verify against builder suites).
- [ ] Step 4: `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter TSVTable` then `--filter MHCAmpliconReferenceBundleBuilder` then `--filter TwelveSReferenceBundleBuilder` → PASS.
- [ ] Step 5: `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/LungfishIO/ Sources/LungfishWorkflow/ Tests/LungfishIOTests/TSVTableTests.swift && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "$(cat <<'MSG'
Extract shared BundleBuilderSupport + TSVTable reader (S-P2-2)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
)"`

### Task 14: Decompose the 846-line TwelveSAmpliconResultViewController  (addresses S-P2-1)
**Files:**
- Create: `Sources/LungfishWorkflow/TwelveS/TwelveSResultRowFilter.swift` (move display-state→row filtering into a shared model-layer filter; also the single source for `TwelveSResultExportWorkflow.filteredRows`).
- Create: `Sources/LungfishApp/Views/Results/Shared/BlastDrawerHosting.swift` (extract the BLAST-drawer hosting mixin shared with classifiers) and a shared detail-rows builder.
- Modify: `Sources/LungfishApp/Views/Results/TwelveS/TwelveSAmpliconResultViewController.swift`.
- Test: `Tests/LungfishWorkflowTests/TwelveSResultRowFilterTests.swift` (new) — drive the extracted filter directly with `TwelveSResultDisplayState` permutations (min reads, filterText, include/exclude, excludeHuman, requireAlternates) and assert visible rows; this is the deterministic home for Task 11/Task 12's row-count assertions.

- [ ] Step 1: Write `TwelveSResultRowFilterTests` capturing current behavior for ~6 display-state permutations (exact expected row sets). This DOUBLES as the regression net proving the extraction preserves behavior.
- [ ] Step 2: `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter TwelveSResultRowFilterTests` → FAIL (symbol missing).
- [ ] Step 3: Extract `TwelveSResultRowFilter.filter(rows:state:)`; point both the view controller and `TwelveSResultExportWorkflow.filteredRows` at it (kills the two-sources-of-truth). Extract `BlastDrawerHosting` + the detail-rows builder.
- [ ] Step 4: `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter TwelveS` (whole 12S suite) → PASS; `swift build --skip-update`.
- [ ] Step 5: `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/ Tests/LungfishWorkflowTests/TwelveSResultRowFilterTests.swift && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "$(cat <<'MSG'
Decompose TwelveSAmpliconResultViewController into shared filter + mixins (S-P2-1)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
MSG
)"`

### Task 15: Split HaplotypeDefinitionCommandService; unify its provenance writers  (addresses S-P2-3)
**Files:** Modify `Sources/LungfishWorkflow/ONTGenotyping/HaplotypeDefinitionCommandService.swift` → split into library-CRUD vs MHC-bundle services; unify the two provenance writers; move manifest mutation onto `MHCAmpliconReferenceBundle`. Test: existing `MHCAmpliconReferenceBundleBuilderTests` + a new `HaplotypeDefinitionCommandServiceTests` characterization.
- [ ] Step 1: Characterization test: create+save+replace-reference a bundle via the service and snapshot the resulting manifest + provenance shape.
- [ ] Step 2: `swift test ... --skip-update --filter HaplotypeDefinitionCommandServiceTests` → FAIL.
- [ ] Step 3: Split services; keep the public CLI-facing methods stable (the CLI in `HaplotypeDefinitionsCommand` and the manager call them).
- [ ] Step 4: `swift test ... --skip-update --filter Haplotype` + `--filter MHCAmpliconReferenceBundle` → PASS; `swift build --skip-update`.
- [ ] Step 5: `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/ Tests/ && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "Split HaplotypeDefinitionCommandService; unify provenance writers (S-P2-3)$(printf '\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"`

### Task 16: Extract ResultBundle protocol + shared sample-metadata snapshot + one target-name resolver  (addresses S-P2-4)
**Files:** Create `Sources/LungfishIO/Bundles/ResultBundle.swift` (protocol + shared sample-metadata snapshot); move 12S target-name interpretation into one resolver shared with `TwelveSTaxonGroupResolver`. Modify `TwelveSAmpliconResultBundle.swift`, `ONTGenotypeResultBundle`, `TwelveSTaxonGroupResolver.swift`. Test: new `ResultBundleTests` + existing `TwelveSReferenceBundleTests`/`ONTGenotypeResultBundleTests`.

**Follow-up from Task 2 code review (reference-bundle envelope symmetry):** while here, also close the dead-code gap the Task 2 reviewer noted — (a) `MHCAmpliconReferenceBundle.validate(at:)` does not check `schemaVersion`, so `ReferenceBundleValidationError.Kind.schemaMismatch` is currently dead; add a `manifest.schemaVersion == supportedSchema` guard. (b) `TwelveSReferenceBundle` has NO `validate(at:)` at all — add a parallel one so both adopters of the shared envelope validate symmetrically. (c) Align existence-checking between MHC and 12S `referenceFASTAURL` (12S nil-checks, MHC doesn't). Add a focused test that `validate(at:)` rejects a manifest with a mismatched `schemaVersion`.
- [ ] Step 1: Characterization test for target-name→taxon-group resolution across both call sites (assert identical results from the unified resolver).
- [ ] Step 2: `swift test ... --skip-update --filter ResultBundleTests` → FAIL.
- [ ] Step 3: Implement; redirect callers.
- [ ] Step 4: `swift test ... --skip-update --filter TwelveS` + `--filter Genotyp` → PASS.
- [ ] Step 5: `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/ Tests/ && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "Extract ResultBundle protocol + shared target-name resolver (S-P2-4)$(printf '\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"`

### Task 17: Make 12S result columns sortable  (addresses S-P2-5)
**Files:** Modify `Sources/LungfishApp/Views/Results/TwelveS/TwelveSAmpliconResultViewController.swift` (add `sortDescriptorPrototype` to columns + `tableView(_:sortDescriptorsDidChange:)`). Test: `TwelveSResultRowFilterTests` (extend) — assert a sort comparator over rows yields the expected order for reads asc/desc and species A→Z.
- [ ] Step 1: Failing test: `TwelveSResultRowFilter.sorted(rows:by:)` for `(.reads, .descending)` and `(.species, .ascending)`.
- [ ] Step 2: `swift test ... --skip-update --filter TwelveSResultRowFilterTests` → FAIL.
- [ ] Step 3: Implement the comparator + wire `sortDescriptorPrototype`/`sortDescriptorsDidChange` to it (NSTableView header-sort, app-wide idiom).
- [ ] Step 4: `swift test ... --skip-update --filter TwelveS` → PASS; build.
- [ ] Step 5: `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/ Tests/ && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "Add column sorting to 12S result table (S-P2-5)$(printf '\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"`

### Task 18: Add a saved-filter-set service to 12S  (addresses S-P2-6)
**Files:** Create `Sources/LungfishApp/Views/Results/Shared/SavedFilterSetService.swift` (generic, parity with genotype Smart Cohorts); wire into 12S view-model. Test: new `SavedFilterSetServiceTests` (save/recall round-trips a `TwelveSResultDisplayState`).
- [ ] Step 1: Failing test: save a named `TwelveSResultDisplayState`, recall by name → equal state; list returns the saved name.
- [ ] Step 2: `swift test ... --skip-update --filter SavedFilterSetServiceTests` → FAIL.
- [ ] Step 3: Implement (persist to UserDefaults keyed per-result like Smart Cohorts; `Codable` state).
- [ ] Step 4: → PASS; build.
- [ ] Step 5: `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/ Tests/ && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "Add saved-filter-set service to 12S (S-P2-6)$(printf '\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"`

### Task 19: Surface both reference-bundle builders from the run-dialog reference picker  (addresses S-P2-7)
**Files:** Modify `Sources/LungfishApp/Views/WorkflowOperations/WorkflowOperationsDialog.swift` / `WorkflowOperationDialogState.swift` so both "Create 12S Reference…" and "Create Project (MHC) Bundle…" are reachable from one place (the run-dialog reference picker). Test: dialog-state test asserting both builder entry points are exposed when the relevant workflow is selected.
- [ ] Step 1: Failing test: `WorkflowOperationDialogState.referenceBuilderEntries(for: .twelveS)` and `(.ontGenotyping)` each include the expected builder action id.
- [ ] Step 2: → FAIL. Step 3: implement. Step 4: → PASS; build.
- [ ] Step 5: `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/ Tests/ && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "Surface both reference-bundle builders from the run-dialog picker (S-P2-7)$(printf '\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"`

### Task 20: Pick one canonical provenance-surface location  (addresses S-P2-8)
**Files:** Modify genotype + 12S viewports so the run-summary/provenance affordance lives in the same place. Recommended: a `ClassifierActionBar.onProvenance` popover for both (genotype gains a `ClassifierActionBar` with the BLAST button hidden, per the matrix root-cause note); this also nets genotype the action-bar export from Task 5. Test: assert both view controllers construct an action bar exposing an `onProvenance` handler.
- [ ] Step 1: Failing test: genotype VC exposes a provenance affordance handler (nil today).
- [ ] Step 2: → FAIL. Step 3: add `ClassifierActionBar` to genotype with BLAST hidden (`extractButton.isHidden = true`, precedented in 12S) and route provenance through its popover; align 12S to the same. Step 4: → PASS; build.
- [ ] Step 5: `git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add Sources/ Tests/ && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "Unify provenance-surface location across result viewports (S-P2-8)$(printf '\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"`

### Task 21: Swift/UI polish batch  (addresses S-P2-9, S-P2-10, S-P2-11, S-P2-12)
**Files & fixes (each its own commit; small, well-scoped):**
- **S-P2-9** `Sources/LungfishApp/Views/Inspector/Sections/GenotypeDropoutThresholdSection.swift:129` — replace `Color.accentColor` (system blue) with Lungfish Orange (`Color(nsColor: .lungfishAccent)` / `#D47B3A`). Test: assert the section's accent resolves to the Lungfish accent constant, not `.accentColor`.
- **S-P2-10** `Sources/LungfishWorkflow/TwelveS/*` — rename the `Swift.zip`-shadowing free function to `zipOptionals` (grep for the local `func zip(`). Test: build + a unit test calling `zipOptionals`.
- **S-P2-11** `Sources/LungfishWorkflow/TwelveS/TwelveSChimeraReview.swift` (UCHIME parse) — parse the designated column index instead of scanning all fields. Test: `TwelveSChimeraReviewTests` asserting a row whose non-designated field coincidentally matches no longer misparses.
- **S-P2-12** is NOT one fix — it is seven independent sub-fixes. Do each as its own failing-test→implement→commit cycle, tracked with its own checkbox. Grouped by risk tier (do the low-risk ones first; the last two are real refactors, not cosmetics):
  - [ ] **(a, logic)** `MHCAmpliconReferenceBundle.swift:121` — remove the dead `?? ""` guard (bind the optional once). Test: a unit assertion that species matching still works with/without a species code.
  - [ ] **(b, logic)** `HaplotypeDefinitionCommandService.swift:485` — replace the fragile `targetID!` with `targetID.flatMap { $0.isEmpty ? nil : $0 } ?? source.definitionSet.id`. Test: feed an empty/`nil` `targetID`, assert it falls back to the definition-set id without trapping.
  - [ ] **(c, refactor)** `MHCAmpliconReferenceBundleBuilder.swift:199-204` — delete the duplicate private `ResolvedDefinitionInput`; thread the public `MHCAmpliconReferenceBundleDefinitionInput` through `validate`/`build`. Test: existing builder suite stays green (characterization).
  - [ ] **(d, cosmetic)** 12S detail-pane bespoke `NSButton(.disclosure)` buttons — drop them for plain sections (or a shared helper). Build-only.
  - [ ] **(e, cosmetic)** `HaplotypeDefinitionManagerWindowController.swift:604-605` — delete-button color doubling: use a single danger channel (`role: .destructive` or `.tint` alone). Build-only.
  - [ ] **(f, cosmetic)** 12S Inspector metadata-source/warnings asymmetry — drop to a footnote or promote to a shared component. Build-only.
  - [ ] **(g, refactor — highest risk, may defer)** dialog reference picker → `ReferenceSequencePickerView` (matrix I13, affects BOTH workflows since the dialog is shared). This is a real shared-control swap that needs `ReferenceSequencePickerView` extended for FASTA-or-bundle + the "Create reference" entry. If it balloons, split it into its own task rather than forcing it into the polish batch. Test: dialog-state test that reference selection still resolves for both 12S and genotype.

For each fix above: Step 1 failing test (or `swift build` red where purely cosmetic), Step 2 run → FAIL, Step 3 implement, Step 4 `swift test ... --skip-update --filter <Suite>` → PASS, Step 5 commit (one commit per sub-fix):
`git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" add <files> && git -C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" commit -m "<polish fix> (S-P2-12<letter>)$(printf '\n\nCo-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>')"`

---
## Phase 5 — End-to-end verification (these are the gates; nothing is "done" until all pass)

> Run every command below from inside the worktree (or with `-C "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching"`). Build both products first:
> `swift build --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --product Lungfish` and
> `swift build --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --product lungfish-cli`.
> The built CLI is `.build/debug/lungfish-cli`; below, `CLI` = `/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching/.build/debug/lungfish-cli`.

### Task 22: Phase 5 verification gates

- [ ] **12S synthetic / deterministic.**
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter TwelveS`
  Gate: all `TwelveS*` suites green (matching, reference bundle, row filter, display section, sort, export).

- [ ] **12S real run.** Build `.lungfish12sref` from the real reference, produce the merged FASTQ via the amplicon import recipe path, then match:
  ```
  $CLI fastq 12s-reference-bundle \
    --fasta /Users/dho/Downloads/32308/ref/amplicons_deduplicated.fa \
    --target-metadata /Users/dho/Downloads/32308/intermediate/12s_reference.tsv \
    --output /tmp/12s-ref.lungfish12sref --force
  # Merge the paired Hilo reads through the same amplicon-merge recipe the GUI import uses
  # (R1/R2 -> clumpified, merged single FASTQ). For a pure-CLI run, invoke that recipe first:
  #   inputs: /Users/dho/Downloads/HI_Hilo_WWTP_20260511__12S_F09_S69_L001_R{1,2}_001.fastq.gz
  #   output: /tmp/hilo-merged.fastq(.gz)
  $CLI fastq 12s-match \
    --reference-bundle /tmp/12s-ref.lungfish12sref \
    --input /tmp/hilo-merged.fastq.gz \
    --output /tmp/hilo-12s.lungfish12s --force
  ```
  Gate: `/tmp/hilo-12s.lungfish12s/targets.tsv` has populated `taxid` / `taxon_group` / `taxonomy` for known rows (e.g. `Homo sapiens` → `9606`), and `/tmp/hilo-12s.lungfish12s/.lungfish-provenance.json` is canonical (`toolName == "lungfish-cli"`, non-empty `argv`, output path recorded). (Confirm exact flag names against `FastqTwelveSReferenceBundleSubcommand` / `FastqTwelveSMatchSubcommand` — adjust `--fasta`/`--input` to the real option names.)

- [ ] **MHC genotyping — base + multi-bundle + bundle-format gates** (uses `/Users/dho/Desktop/sandbox/32271.lungfish`):
  - Base ONT run against barcode05-08 `.lungfishfastq`, the MHC/KIR `.lungfishref`, and the Mauritian-cynomolgus haplotype defs (materialize virtual FASTQ as needed):
    ```
    $CLI fastq genotype --mode ont-barcode-demux \
      --reference "/Users/dho/Desktop/sandbox/32271.lungfish/Reference Sequences/<MHC>.lungfishref" \
      --barcodes <fluidigm-barcodes.csv> \
      --haplotype-definition <mcm-def-id> --haplotype-assay <assay> --haplotype-species MCM \
      "/Users/dho/Desktop/sandbox/32271.lungfish/Imports/barcode05.lungfishfastq" ... \
      --output-dir /tmp/mhc-base --output-name mhc-base
    ```
  - **Multi-bundle gate** (S-P0-1): run the genotyping CLI over MULTIPLE prepared sample bundles in ONE invocation (Illumina sample-bundle batch path). Gate: per-sample results present, the comparison/report label correct, batch provenance correct, and (regression check for S-P0-1) **two same-named-sanitizing inputs do not overwrite/merge** — verify distinct per-sample outputs.
  - **Bundle-format gate** (S-P1-1): build a `.lungfishmhcref` (FASTA + paired defs) via `$CLI haplotypes bundle-create ...`, then run `$CLI fastq genotype --reference /tmp/mhc.lungfishmhcref <inputs> --output-dir /tmp/mhc-bundle ...` with NO separate `--haplotype-definition`. Gate: the CLI resolves both the reference FASTA and the paired haplotype definition from the single `.lungfishmhcref`, and produces the **same** genotype/haplotype result as the separate-inputs base run. Also verify an explicit `--haplotype-definition` absent from the bundle is rejected (Task 6).
  - Compare against the project's existing `Analyses/Amplicon genotyping results` to confirm no regression.
  Also run the suite: `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter ONTBarcodeDemuxGenotypingPipelineTests` and `--filter Genotyp` and `--filter Haplotype`.

- [ ] **Sample metadata + provenance.**
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter SampleMetadata`
  `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter Provenance`
  Plus a CLI smoke run with a small metadata CSV (assert the quote-aware parse from Task 8 handles a quoted-comma field correctly end to end).

- [ ] **Cross-workflow filter equivalence.** Confirm the converged minimum-reads filter behaves equivalently in both workflows:
  - 12S (threshold is a CLI parameter): re-run `fastq 12s-export --min-exact-reads N` and verify the row count changes with N.
  - Genotype (display-state filter): `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update --filter GenotypeResultDisplaySectionTests` and `--filter MinimumReadsThreshold` — same control idiom, same semantics, two data bindings.

- [ ] **Full regression sweep.** `swift test --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update` (whole suite) green, and `swift build --package-path "/Users/dho/Documents/lungfish-genome-explorer/.worktrees/12s-amplicon-matching" --skip-update` clean for both products. GUI testing is the user's manual follow-up (out of scope here).

---

## Phase 6 — Release: notarized DMG + GitHub + Sparkle (autonomous, runs after Phase 5 is fully green)

> User directive: after all code work + Phase 5 verification pass, ship a release unattended — notarized/signed build with the next alpha bump, DMG uploaded to GitHub with detailed change notes, and a Sparkle appcast update so existing users auto-update. Authoritative process: `docs/release/sparkle-updates.md`. Current version is `0.5.0-alpha8`; next is **`0.5.0-alpha9`** (tag `v0.5.0-alpha9`).
>
> **HARD PRECONDITION GATE:** Do NOT start Phase 6 unless Phase 5 is entirely green (full suite + both products build + the multi-bundle and `.lungfishmhcref` gates pass on real data). A release of unverified code is worse than no release.

### Task 23: Version bump 0.5.0-alpha8 -> 0.5.0-alpha9

**Files (every hardcoded occurrence — verified by grep; update ALL or tests fail):**
- `Sources/LungfishCLI/LungfishCLI.swift:31` (`version: "0.5.0-alpha8"`)
- `Sources/LungfishCLI/Commands/SequenceCommand.swift:258` (`cliVersion`)
- `Sources/LungfishCLI/Commands/PrimerCommand.swift:64` (`toolVersion: "lungfish-cli 0.5.0-alpha8"`)
- `Sources/LungfishApp/App/AboutWindowController.swift:89` and `Sources/LungfishApp/Views/Welcome/WelcomeWindowController.swift:898` (fallback strings)
- `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json:4` (`"version"`)
- `Sources/LungfishApp/Resources/HelpBook/Lungfish.help/Contents/Info.plist:16` (`CFBundleShortVersionString`)
- Tests that assert the version (MUST update in the same commit or they go red): `Tests/LungfishCLITests/CLIRegressionTests.swift:30` (`== "0.5.0-alpha8"`) and `Tests/LungfishWorkflowTests/CondaManagerTests.swift:202` (`lock.version == "0.5.0-alpha8"`).
- Also grep for any I missed: `grep -rn "0.5.0-alpha8\|alpha8" --include=*.swift --include=*.json --include=*.plist --include=*.xcconfig . | grep -v .build`
- Confirm the app target's marketing version source (xcconfig/project) is bumped so `CFBundleShortVersionString` of the BUILT app is `0.5.0-alpha9` — the release script reads it; if the app version is set in an Xcode project/xcconfig not yet found, locate and update it.

- [ ] Step 1: grep for every `alpha8` occurrence; update each to `alpha9` (source + the 2 test expectations). 
- [ ] Step 2: `swift build --package-path "..." --skip-update` clean; `swift test --package-path "..." --skip-update --filter CLIRegression` and `--filter CondaManager` green (version assertions now match).
- [ ] Step 3: Commit `Bump version to 0.5.0-alpha9`.

### Task 24: Write release notes

- [ ] Create `docs/release-notes/v0.5.0-alpha9.md` (the release script copies notes from this exact path). Follow the style of `docs/release-notes/v0.5.0-alpha8.md`. Detailed change notes covering this effort: the P0 multi-bundle genotyping data-loss fix; `.lungfishmhcref` consume path for MHC genotyping; reference-bundle unification; the cross-workflow consistency convergences (shared minimum-reads threshold, search placement, pill filters, CLI-backed genotype export, etc.); and the pre-existing fixes folded in (subcommand count, hello-world templates, runModal). Honor docs prose rules (no em dashes, bullet caps). Commit.

### Task 25: Preflight the release credentials (gate)

- [ ] Verify ALL of the following are present; if ANY is missing, STOP and leave a clear written report for the user instead of a half-run release:
  - `LUNGFISH_SPARKLE_PUBLIC_ED_KEY` available (env or known location), and the Sparkle EdDSA private key reachable (Keychain, or exported to a temp mode-0600 file for `--sparkle-ed-key-file`).
  - A `Developer ID Application` signing identity in the keychain (`security find-identity -v -p codesigning`).
  - The notary profile (`xcrun notarytool history --keychain-profile <PROFILE>` succeeds) — profile name per memory is `LungfishNotary`, team-id `29G3WN2GSA`.
  - `gh auth status` authenticated with release permissions.
  - `generate_appcast` tool path (Sparkle bin).
- [ ] Record which are present/absent (the preflight probe results are captured during planning — see the session).

**Preflight results (probed 2026-05-30, during planning):**
- Signing identity: ✅ `Developer ID Application: Pathogenuity LLC (29G3WN2GSA)` in login keychain.
- Notary profile `LungfishNotary`: ✅ valid (`xcrun notarytool history --keychain-profile LungfishNotary` succeeded).
- `gh` auth: ✅ logged in as `dhoconno` (keyring), release perms.
- `generate_appcast`: ✅ vendored at `.build/sparkle-tools/bin/generate_appcast`.
- Sparkle EdDSA PRIVATE key: ✅ present in login keychain (genp item) — `generate_appcast` reads it directly, so `--sparkle-ed-key-file` is NOT needed.
- Sparkle PUBLIC key (`LUNGFISH_SPARKLE_PUBLIC_ED_KEY`): ✅ RECOVERED. Not in env/source/shell profile, but the authoritative value is embedded in the previously-shipped Release app and DMG. Verified identical across `build/Release/Lungfish.app/Contents/Info.plist`, the alpha8 xcarchive, and the shipped `Lungfish-0.5.0-alpha8-arm64.dmg`:
  **`LUNGFISH_SPARKLE_PUBLIC_ED_KEY="FtnZIDTqGTwkglQR0z8iSgVvxvT26a05QB3cI4xQw/c="`**
  This matches the private EdDSA key in the login keychain and the `SUFeedURL` (`.../sparkle-alpha/appcast-alpha.xml`) the shipped app already trusts. Export this at release time (Task 26). All release preconditions are therefore satisfied — the full Sparkle auto-update wiring can complete unattended.

### Task 26: Build, notarize, upload DMG, publish Sparkle appcast

- [ ] Run the documented release command (fill the signing identity from the keychain, the appcast tool path, and the private-key file from preflight):
  ```bash
  export LUNGFISH_SPARKLE_PUBLIC_ED_KEY="<base64 public key>"
  bash scripts/release/build-notarized-dmg.sh \
    --signing-identity "Developer ID Application: <name> (29G3WN2GSA)" \
    --team-id 29G3WN2GSA \
    --notary-profile LungfishNotary \
    --github-release-tag "v0.5.0-alpha9" \
    --sparkle-generate-appcast "<path>/generate_appcast" \
    --sparkle-ed-key-file "<temp private-key.txt>" \
    --sparkle-publish-release "sparkle-alpha"
  ```
  The script: sets `CFBundleVersion` from `git rev-list --count HEAD` (must exceed the prior shipped build), builds + signs + notarizes the DMG, uploads it to the `v0.5.0-alpha9` GitHub prerelease, regenerates `appcast-alpha.xml`, and publishes that feed to the fixed `sparkle-alpha` release (so existing users get the Sparkle update). Release notes are copied from `docs/release-notes/v0.5.0-alpha9.md`.
- [ ] Delete any temporary exported private-key file afterward (mode-0600 cleanup).
- [ ] Verify: the `v0.5.0-alpha9` GitHub release exists with the notarized DMG asset; `appcast-alpha.xml` on the `sparkle-alpha` release references the new DMG with a `sparkle:version` (CFBundleVersion) greater than the previous; `gh release view v0.5.0-alpha9` shows the change notes.
- [ ] Run `scripts/tests/test_sparkle_release_packaging.py` if it validates the produced appcast/DMG.

> If notarization or upload fails, STOP and leave a detailed report (do NOT retry-loop on credential or network failures). A failed notarization is not something to brute-force overnight.

---

## Self-review

### Spec coverage — every synthesis finding maps to a task

| Finding | Task(s) |
|---|---|
| S-P0-1 multi-bundle sample-ID collision | Task 1 (+ Phase 5 multi-bundle gate) |
| S-P1-1 `.lungfishmhcref` consume completion | Task 6 (+ Phase 5 bundle-format gate) |
| S-P1-2 12S opt-in default | Task 7 |
| S-P1-3 low-abundance filter convergence (+ shared threshold model A8) | Task 3 (model) + Task 9 (UI control) |
| S-P1-4 genotype export CLI-backed | Task 5 |
| S-P1-5 unified reference-bundle design | Task 2 |
| S-P1-6 quote-aware parser unification | Task 8 |
| S-P1-7 haplotype-manager `Task.detached` fix | Task 9 |
| S-P1-8 argv normalization + canonical bundle-create | Task 10 |
| S-P1-9 free-text search placement | Task 11 |
| S-P1-10 include/exclude + boolean pill idiom | Task 12 |
| S-P1-11 unified genotype export CLI shape | Task 4 |
| S-P2-1 decompose 846-line viewport | Task 14 |
| S-P2-2 shared BundleBuilderSupport + TSVTable | Task 13 |
| S-P2-3 split HaplotypeDefinitionCommandService | Task 15 |
| S-P2-4 ResultBundle protocol + target-name resolver | Task 16 |
| S-P2-5 sortable 12S columns | Task 17 |
| S-P2-6 saved-filter-set service | Task 18 |
| S-P2-7 both bundle builders from run dialog | Task 19 |
| S-P2-8 canonical provenance-surface location | Task 20 |
| S-P2-9 accent color (system blue → Lungfish Orange) | Task 21 |
| S-P2-10 `Swift.zip` shadow → `zipOptionals` | Task 21 |
| S-P2-11 UCHIME designated-column parse | Task 21 |
| S-P2-12 Swift/UI polish bundle | Task 21 |

Domain-justified divergences (I2, I3, I7, I10, I20, I25, I28, I29, I30) are explicitly accepted per the matrix and are NOT work items. Recorded here so their status is unambiguous.

### Ordering check
P0 (Task 1) → prerequisites S-P1-5 (Task 2) → S-P1-3 model (Task 3) → S-P1-11 CLI (Task 4) → dependents S-P1-4 (Task 5, needs Task 4), S-P1-1 (Task 6, needs Task 2), S-P1-2 (Task 7) → independent P1 (Tasks 8-12) → P2 (Tasks 13-21) → Phase 5 (Task 22). Each dependent task names its prerequisite. The two Phase-5 gates are pinned to Task 1 and Task 6, both early.

### Placeholder scan
No "TODO", no "add error handling" hand-waving: every code step shows the actual change or a precise sketch with real symbol names and line ranges; every test step shows the assertions and the exact `swift test --skip-update --filter` command; every commit step gives the literal `git -C "<WT>"` command. One deliberate flexibility note remains where the real CLI flag names must be confirmed against source (Phase 5 12S flags; Task 4 projection flags) — these are marked "confirm against <file>" rather than guessed, because inventing a flag name would be worse than instructing the implementer to read the one authority.

### Type / name consistency
Shared types introduced once and reused: `ReferenceBundleEnvelope` / `ReferenceBundleSourceFile` / `ReferenceBundleManifesting` (Task 2); `MinimumReadsThreshold` (Task 3, referenced by Tasks 9, 22); `DelimitedLineParser` (Task 8, reused by Task 13's `TSVTable`); `GenotypeXlsxWorkbookWriter` (Task 4, reused by Task 5); `TwelveSResultRowFilter` (Task 14, reused by Tasks 11, 12, 17). `GenotypeResultDisplayState.minimumReads`/`activeMinimumReads`, `GenotypeResultDisplaySectionViewModel.setMinimumReads`, and `TwelveSResultDisplaySectionViewModel.pillState(for:)` are named identically wherever referenced. Provenance assertions consistently require `toolName == "lungfish-cli"` (Tasks 4, 5, 22), matching the existing 12S verifier.

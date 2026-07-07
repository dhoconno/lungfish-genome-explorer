# Issue #27 — Add Trim Galore --clumpify Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.
> **Read `docs/superpowers/specs/2026-07-06-weekly-issues-master-spec.md` first.** Do the shared **VSP2 Recipe Reconciliation** (Task 0 of the #24 plan) before Task 5 here — you must know where clumpify runs in the VSP2 path.

**Goal:** Let users choose their read-compression ("clumping") tool at FASTQ import: BBTools clumpify (default, unchanged) OR Trim Galore `--clumpify` OR skip. Register Trim Galore as a core tool. Make the VSP2 import path use Trim Galore `--clumpify`; other recipes keep BBTools clumpify.

**Architecture:** Clumpify runs in `FASTQIngestionPipeline.clumpify(...)`, gated by a `skipClumpify` boolean on `FASTQIngestionConfig`. We (1) register Trim Galore as a managed conda tool (tool lock + `NativeTool` enum + `PluginPack` requirement), (2) replace the boolean `skipClumpify` with a three-way `ClumpingTool` choice threaded from the import UI (`FASTQImportConfiguration`) through `FASTQBatchImporter` into `FASTQIngestionConfig`, (3) add a Trim-Galore branch in the ingestion pipeline that runs `trim_galore --clumpify` (without adapter removal where undesirable), and (4) default the VSP2 import path to Trim Galore while all other paths default to BBTools.

**Tech Stack:** Swift 6.2, conda/micromamba (`CondaManager`), Trim Galore (bioconda), AppKit (import sheet), XCTest.

## Global Constraints

- Build/test/serialization/green-bar per master spec §1.3–§1.4.
- Existing behavior (BBTools clumpify) MUST remain the default for all non-VSP2 imports.
- Tool version strings appear in ~8 hardcoded sites — see master spec release notes; adding a NEW tool does not require bumping those, but if you touch `third-party-tools-lock.json` version expectations there may be a test in `CondaManagerTests` / `CLIRegressionTests` that enumerates tools — run them.
- OperationCenter `update` + `log` during the clumping step.
- Commit trailer: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## Acceptance criteria

1. Trim Galore is registered as a managed tool and can be installed via the existing conda plugin flow.
2. The FASTQ import sheet offers three clumping choices: "BBTools clumpify (recommended)" [default], "Trim Galore --clumpify", "Skip (compress only)".
3. Choosing BBTools reproduces today's exact behavior; choosing Skip reproduces today's skip behavior.
4. Choosing Trim Galore runs `trim_galore --clumpify` producing a clumped FASTQ, recorded in provenance.
5. A VSP2 import uses Trim Galore `--clumpify` by default; a non-VSP2 import defaults to BBTools clumpify.
6. CLI import exposes the choice via a flag (e.g. `--clumping-tool bbtools|trim-galore|none`).
7. Suite is GREEN.

## Key files

- `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json` (tool registry)
- `Sources/LungfishWorkflow/Native/NativeToolRunner.swift` (`NativeTool` enum ~325–357; `executableName` ~359–391; `location` ~417–475)
- `Sources/LungfishWorkflow/Conda/PluginPack.swift` (`PackToolRequirement` statics ~96–177)
- `Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift` (`skipClumpify` field ~57–59; clumpify gate ~230–258; `clumpify(...)` ~330–457)
- `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift` (import orchestration; ingestion-config build ~819–877)
- `Sources/LungfishApp/Views/FASTQ/FASTQImportConfiguration.swift` (`skipClumpify` ~22–23; `recipeName`)
- `Sources/LungfishApp/Views/FASTQ/FASTQImportConfigSheet.swift` (clumpify checkbox ~120, ~257–262)

---

### Task 1: Define the `ClumpingTool` enum (single source of truth)

**Files:**
- Create: `Sources/LungfishWorkflow/Ingestion/ClumpingTool.swift`
- Test: `Tests/LungfishWorkflowTests/ClumpingToolTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum ClumpingTool: String, Codable, Sendable, CaseIterable {
      case bbtools        // BBTools clumpify.sh (default)
      case trimGalore     // trim_galore --clumpify
      case none           // skip clumping; compress only
      public var displayName: String
      public static var `default`: ClumpingTool { .bbtools }
  }
  ```

- [ ] **Step 1: Write the failing test.**

```swift
import XCTest
@testable import LungfishWorkflow

final class ClumpingToolTests: XCTestCase {
    func testDefaultIsBBTools() { XCTAssertEqual(ClumpingTool.default, .bbtools) }
    func testRawValuesStableForCLI() {
        XCTAssertEqual(ClumpingTool.bbtools.rawValue, "bbtools")
        XCTAssertEqual(ClumpingTool.trimGalore.rawValue, "trimGalore")
        XCTAssertEqual(ClumpingTool.none.rawValue, "none")
    }
    func testAllCasesCovered() { XCTAssertEqual(ClumpingTool.allCases.count, 3) }
    func testDisplayNames() {
        XCTAssertEqual(ClumpingTool.bbtools.displayName, "BBTools clumpify (recommended)")
        XCTAssertEqual(ClumpingTool.trimGalore.displayName, "Trim Galore --clumpify")
        XCTAssertEqual(ClumpingTool.none.displayName, "Skip (compress only)")
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (type missing).

- [ ] **Step 3: Implement `ClumpingTool.swift`.**

```swift
import Foundation

public enum ClumpingTool: String, Codable, Sendable, CaseIterable {
    case bbtools
    case trimGalore
    case none

    public static var `default`: ClumpingTool { .bbtools }

    public var displayName: String {
        switch self {
        case .bbtools:    return "BBTools clumpify (recommended)"
        case .trimGalore: return "Trim Galore --clumpify"
        case .none:       return "Skip (compress only)"
        }
    }
}
```

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Commit** `feat(import): add ClumpingTool enum`.

---

### Task 2: Register Trim Galore as a managed tool

**Files:**
- Modify: `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`
- Modify: `Sources/LungfishWorkflow/Native/NativeToolRunner.swift`
- Modify: `Sources/LungfishWorkflow/Conda/PluginPack.swift`
- Test: `Tests/LungfishWorkflowTests/NativeToolRegistrationTests.swift` (create/extend)

**Interfaces:**
- Produces: `NativeTool.trimGalore` with `executableName == "trim_galore"` and `location == .managed(environment: "trim_galore", executableName: "trim_galore")`; a `PackToolRequirement.trimGalore`.

- [ ] **Step 1: Write the failing test.**

```swift
import XCTest
@testable import LungfishWorkflow

final class NativeToolRegistrationTests: XCTestCase {
    func testTrimGaloreExecutableName() {
        XCTAssertEqual(NativeTool.trimGalore.executableName, "trim_galore")
    }
    func testTrimGaloreIsManagedInOwnEnvironment() {
        if case .managed(let env, let exe) = NativeTool.trimGalore.location {
            XCTAssertEqual(env, "trim_galore")
            XCTAssertEqual(exe, "trim_galore")
        } else {
            XCTFail("trimGalore must be a managed tool")
        }
    }
}
```
(Match the real `NativeTool.location` associated-value labels; read them first.)

- [ ] **Step 2: Run — expect FAIL** (`NativeTool.trimGalore` missing).

- [ ] **Step 3: Register the tool.**
  - In `third-party-tools-lock.json`, add an entry (pin a real bioconda build — verify the exact `packageSpec`/build string against bioconda before committing; the version below is a placeholder to confirm):
    ```json
    { "id": "trim_galore", "environment": "trim_galore", "packageSpec": "bioconda::trim-galore=0.6.10", "executables": ["trim_galore"], "version": "0.6.10", "license": "GPL-3.0", "sourceUrl": "https://github.com/FelixKrueger/TrimGalore" }
    ```
    Note: Trim Galore depends on Cutadapt and pigz; bioconda pulls those transitively, but confirm the env resolves (Task 3 Step 5 installs it). If a smoke test needs a companion binary, add it to `executables`.
  - In `NativeToolRunner.swift`: add `case trimGalore` to the `NativeTool` enum; add `case .trimGalore: return "trim_galore"` to `executableName`; add `case .trimGalore: return .managed(environment: "trim_galore", executableName: "trim_galore")` to `location`.
  - In `PluginPack.swift`: add
    ```swift
    public static let trimGalore = PackToolRequirement(
        id: "trim_galore",
        displayName: "Trim Galore",
        environment: "trim_galore",
        installPackages: ["trim-galore"],
        executables: ["trim_galore"],
        smokeTest: .usage(executable: "trim_galore")   // or the nearest existing smokeTest case
    )
    ```
    (Use whatever `smokeTest` cases exist; if `.usage` is not a case, mirror an existing simple tool's smoke test.)
  - Add `.trimGalore` to whichever pack lists the core/import tools (find where `.bbtools` is referenced in pack membership and add `.trimGalore` to the core tools so it is installable via the existing flow).

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Run tool-registry tests.** `swift test --package-path <worktree> --skip-update --filter CondaManagerTests` and `--filter CLIRegressionTests`. If either enumerates tools and now fails because Trim Galore is new, update the expected list. Confirm no version-string test regressed.

- [ ] **Step 6: Commit** `feat(tools): register Trim Galore as a managed core tool`.

---

### Task 3: Thread `ClumpingTool` through ingestion and add the Trim Galore branch

**Files:**
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQIngestionPipeline.swift` (replace `skipClumpify: Bool` with `clumpingTool: ClumpingTool`; branch in the clumpify gate; add `trimGaloreClumpify(...)`)
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift` (pass `clumpingTool` into `FASTQIngestionConfig`)
- Test: `Tests/LungfishWorkflowTests/FASTQIngestionClumpingTests.swift` (create)

**Interfaces:**
- Consumes: `ClumpingTool` (Task 1); `NativeTool.trimGalore` (Task 2).
- Produces: `FASTQIngestionConfig.clumpingTool: ClumpingTool` (replacing `skipClumpify`); `FASTQIngestionPipeline` dispatches to bbtools / trim_galore / skip.

**Before you start:** Read `FASTQIngestionConfig` init and every caller of `skipClumpify` (grep repo-wide: `grep -rn "skipClumpify" Sources Tests`). You will replace the boolean everywhere. Keep a computed bridge `var skipClumpify: Bool { clumpingTool == .none }` ONLY if some read-only caller is awkward to migrate; prefer migrating all callers.

- [ ] **Step 1: Write the failing test** for argument construction (pure, no tool execution):

```swift
import XCTest
@testable import LungfishWorkflow

final class FASTQIngestionClumpingTests: XCTestCase {
    func testTrimGaloreClumpifyArgumentsNoAdapterRemoval() {
        // The Trim Galore clumpify invocation should enable --clumpify and
        // avoid unwanted adapter trimming (issue #27: adapter removal "not
        // always desirable"). Assert the built argument vector.
        let args = FASTQIngestionPipeline.trimGaloreClumpifyArguments(
            input: URL(fileURLWithPath: "/in/reads.fastq.gz"),
            outputDir: URL(fileURLWithPath: "/out"),
            paired: false,
            threads: 4
        )
        XCTAssertTrue(args.contains("--clumpify"))
        XCTAssertTrue(args.contains("/in/reads.fastq.gz"))
        // Adapter trimming suppressed:
        XCTAssertTrue(args.contains("--no_adapter") || args.contains("--length") == false)
    }

    func testBBToolsRemainsDefaultBranch() {
        XCTAssertEqual(ClumpingTool.default, .bbtools)
    }
}
```
> Note: verify the exact Trim Galore flag to suppress adapter removal by running `trim_galore --help` in the installed env (Task 2). Trim Galore does not have a literal `--no_adapter`; the correct approach may be `-a ""`/`--adapter ''` or running with `--dont_gzip`/`--clumpify` only. Adjust the assertion to the real flag you settle on, and document the chosen flag in the report. The test's INTENT is: clumpify on, adapter trimming not applied.

- [ ] **Step 2: Run — expect FAIL** (`trimGaloreClumpifyArguments` missing).

- [ ] **Step 3: Implement.**
  - Add `public static func trimGaloreClumpifyArguments(input:outputDir:paired:threads:) -> [String]` building the `trim_galore` invocation: enable `--clumpify`, set `--cores/--threads`, target output dir, and suppress adapter trimming per the flag confirmed above. For paired input, pass `--paired r1 r2`.
  - Replace `FASTQIngestionConfig.skipClumpify: Bool` with `clumpingTool: ClumpingTool` (update the init + all callers found by grep).
  - In the clumpify gate (~230–258), branch:
    ```swift
    switch config.clumpingTool {
    case .none:
        clumpifiedFile = config.inputFiles[0]; wasClumpified = false
        progress(0.5, "Clumping disabled, compressing only...")
    case .bbtools:
        // existing clumpify(...) call, unchanged
    case .trimGalore:
        let record = try await trimGaloreClumpify(config: config, outputFile: outputFile, progress: { ... })
        clumpifiedFile = record.url; processingRecord = record; wasClumpified = true
        provenanceSteps.append(record.step)
    }
    ```
  - Implement `trimGaloreClumpify(...)` mirroring the structure of the existing `clumpify(...)` (resolve tool path via `runner.toolPath(for: .trimGalore)`, build args via `trimGaloreClumpifyArguments`, run with `NativeToolRunner`, produce a `FASTQProcessingRecord` with provenance step + OperationCenter `update`/`log`). Handle Trim Galore's output filename convention (it appends suffixes like `_val_1`/`_trimmed`); locate the produced file and set `record.url` to it.
  - In `FASTQBatchImporter.swift` (~819–877), replace `skipClumpify: !config.optimizeStorage` with `clumpingTool: <resolved choice>` (resolution comes from Task 5 for VSP2; for now pass a `clumpingTool` value plumbed from the config).

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Install + smoke the real tool.** Trigger installation of the `trim_galore` env via the app's plugin flow (or `CondaManager`), then run an actual Trim Galore clumpify on a small FASTQ fixture and confirm it produces a clumped output. Record the exact working command in `docs/reports/2026-07-06-trim-galore-clumpify.md`.

- [ ] **Step 6: Commit** `feat(import): run trim_galore --clumpify as a clumping option`.

---

### Task 4: Import sheet UI — three-way clumping choice

**Files:**
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQImportConfiguration.swift` (replace `skipClumpify: Bool` with `clumpingTool: ClumpingTool`)
- Modify: `Sources/LungfishApp/Views/FASTQ/FASTQImportConfigSheet.swift` (replace the checkbox ~120/257–262 with an `NSPopUpButton`)

**Interfaces:**
- Consumes: `ClumpingTool` (Task 1).
- Produces: `FASTQImportConfiguration.clumpingTool` chosen by the user; default `.bbtools`.

**Before you start:** `FASTQImportConfiguration` currently carries `skipClumpify`. Migrate it to `clumpingTool`, updating the config's init and every reader (grep `skipClumpify` under `Sources/LungfishApp`). The sheet's completion currently maps the checkbox to `skipClumpify`; map the popup selection to `clumpingTool` instead.

- [ ] **Step 1: Replace the field.** In `FASTQImportConfiguration`, remove `skipClumpify` and add `public let clumpingTool: ClumpingTool`. Update init + all call sites. Keep `optimizeStorage`-style bridging only if a non-UI caller demands a boolean.

- [ ] **Step 2: Replace the checkbox with a popup.** In `FASTQImportConfigSheet.swift`, replace `clumpifyCheckbox` with:
  ```swift
  private let clumpingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
  ```
  Populate it in setup:
  ```swift
  clumpingPopup.removeAllItems()
  for tool in ClumpingTool.allCases { clumpingPopup.addItem(withTitle: tool.displayName) }
  clumpingPopup.selectItem(withTitle: ClumpingTool.default.displayName)  // BBTools default
  ```
  Keep the existing help affordance (`applyLungfishHelp(...)`). On confirm, map the selected title/index back to a `ClumpingTool` case and put it in the produced `FASTQImportConfiguration`.

- [ ] **Step 3: Build.** `swift build --package-path <worktree> --skip-update` → succeeds.

- [ ] **Step 4: GUI verification (required).** Launch `.build/debug/Lungfish` via computer-use, open the FASTQ import sheet, confirm the popup shows the three options with BBTools selected by default. Import once with each option against a small fixture and confirm: BBTools → same as today; Trim Galore → clumped via trim_galore (check provenance); Skip → no clumping. Screenshot the popup and one provenance panel.

- [ ] **Step 5: Commit** `feat(import): choose clumping tool in the FASTQ import sheet`.

---

### Task 5: VSP2 uses Trim Galore; other recipes keep BBTools

**Files:**
- Modify: `Sources/LungfishWorkflow/Ingestion/FASTQBatchImporter.swift` (resolve `clumpingTool` per recipe)
- Possibly modify: `Sources/LungfishWorkflow/Resources/Recipes/vsp2.recipe.json` (add a `preferredClumpingTool` field) OR resolve by recipe id.

**Prerequisite:** The #24 plan's Task 0 reconciliation finding — you must know where clumpify runs for VSP2 (it is the separate post-recipe compression step per research). This task sets which tool that step uses when the recipe is VSP2.

**Interfaces:**
- Consumes: `ClumpingTool`; the recipe identity (from `FASTQImportConfiguration.recipeName` / the resolved recipe).
- Produces: VSP2 import → `clumpingTool = .trimGalore` by default (user can still override in the sheet); all other imports → `.bbtools` default.

- [ ] **Step 1: Write the failing test.**

```swift
    func testVSP2DefaultsToTrimGaloreClumping() {
        let tool = FASTQBatchImporter.defaultClumpingTool(forRecipeID: "vsp2-target-enrichment", userChoice: nil)
        XCTAssertEqual(tool, .trimGalore)
    }
    func testNonVSP2DefaultsToBBTools() {
        let tool = FASTQBatchImporter.defaultClumpingTool(forRecipeID: "some-other-recipe", userChoice: nil)
        XCTAssertEqual(tool, .bbtools)
    }
    func testUserChoiceOverridesRecipeDefault() {
        let tool = FASTQBatchImporter.defaultClumpingTool(forRecipeID: "vsp2-target-enrichment", userChoice: .bbtools)
        XCTAssertEqual(tool, .bbtools)
    }
```

- [ ] **Step 2: Run — expect FAIL** (`defaultClumpingTool` missing).

- [ ] **Step 3: Implement resolution.**
  ```swift
  static func defaultClumpingTool(forRecipeID recipeID: String?, userChoice: ClumpingTool?) -> ClumpingTool {
      if let userChoice { return userChoice }              // explicit UI/CLI choice wins
      if let recipeID, recipeID.lowercased().contains("vsp2") { return .trimGalore }
      return .bbtools
  }
  ```
  Use its result when building `FASTQIngestionConfig` in `FASTQBatchImporter`. If the import sheet already forced a choice, that becomes `userChoice`; if the user left the default, a VSP2 import silently uses Trim Galore. (Confirm the desired precedence with the reconciliation report; the code above makes explicit choice win, VSP2 default trim_galore, else bbtools.)

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: GUI verification.** VSP2-import a fixture leaving the clumping choice at its default; confirm provenance shows trim_galore clumping. Import the same fixture with a non-VSP2 flow; confirm bbtools clumpify. Screenshot both provenance panels.

- [ ] **Step 6: Commit** `feat(vsp2): default VSP2 import to trim_galore --clumpify`.

---

### Task 6: CLI parity — `--clumping-tool` flag

**Files:** the CLI import command (`grep -rn "skipClumpify\|clumpify\|import" Sources/LungfishCLI/Commands`).

- [ ] **Step 1: Write a failing test** asserting the import command parses `--clumping-tool trim-galore` into `ClumpingTool.trimGalore` (map dashed CLI value → enum). Include `bbtools`, `trim-galore`, `none`.
- [ ] **Step 2: Run — expect FAIL.**
- [ ] **Step 3: Add** an `@Option var clumpingTool: String` (or a custom `ExpressibleByArgument` enum) to the import command; map to `ClumpingTool`; thread into the import config. Default `bbtools`. If `--recipe vsp2` is given and no `--clumping-tool`, resolve via `defaultClumpingTool` (Task 5).
- [ ] **Step 4: Run — expect PASS.** Manual: `.build/debug/lungfish-cli import <fastq> --clumping-tool trim-galore ...`.
- [ ] **Step 5: Commit** `feat(cli): add --clumping-tool to FASTQ import`.

---

### Final verification

- [ ] `swift build/test --package-path <worktree> --skip-update` → clean + GREEN.
- [ ] Trim Galore installs via the plugin flow; real clumpify command recorded in the report.
- [ ] Screenshots: import popup, VSP2 provenance (trim_galore), non-VSP2 provenance (bbtools).
- [ ] `CondaManagerTests` / `CLIRegressionTests` pass with the new tool.
- [ ] Issue #27 updated.

## Self-review checklist

- Spec coverage: enum (T1), tool registration (T2), pipeline branch (T3), UI (T4), VSP2 default (T5), CLI (T6) → all criteria mapped.
- No placeholders: enum, registration entries, argument builder, popup, resolver all concrete; the one genuine unknown (exact Trim Galore adapter-suppression flag) is flagged with a verification step, not left vague.
- Type consistency: `ClumpingTool` (rawValues `bbtools`/`trimGalore`/`none`), `defaultClumpingTool(forRecipeID:userChoice:)`, `trimGaloreClumpifyArguments(...)` named identically across tasks.
- Default preserved: BBTools is the default everywhere except VSP2 (acceptance #3, #5).

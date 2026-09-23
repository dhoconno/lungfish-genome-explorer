# Simplification audit: overengineering, dead code, duplication, repo hygiene

Prefix: SIMP. Reviewer role: staff engineer, simplification of LLM-generated code. HEAD a1f439076, 2026-09-23.

## Scope, method, limits

**Scope.** All of `Sources/` (about 700K Swift lines), with extra depth in `LungfishWorkflow` (193K), `LungfishGenotypeUI` (50K), primer design and genotyping code changed since 2026-09-01. Repo hygiene covered `docs/`, `scripts/`, fixtures, binaries, `.gitignore`, agent definitions and commit patterns.

**Method.** I wrote throwaway Python scripts (session scratchpad, not the repo) and then checked their output by hand:

1. **Unreferenced declarations.** Every `func` whose identifier occurs exactly once across `Sources/` (the declaration), split by whether `Tests/` mention it. `override`, `@objc`, `@IBAction` and common delegate names were excluded.
2. **Unreferenced private symbols.** Every `private`/`fileprivate` symbol whose identifier occurs once in its own file. File scope makes this check decisive.
3. **Dead files.** Files whose top-level declarations are never named in any other `Sources/` file and that contain no `extension`.
4. **Duplication.** 8-line shingles over normalized lines (whitespace collapsed; comments, braces-only lines and imports dropped), with cross-file pair counts and per-pair line ranges.
5. **Single-conformer protocols.** Conformance counts split between production and test code.
6. **Test hooks.** `testing*`/`test*` members in `Sources/`, and whether each sits inside `#if DEBUG`.
7. **Size and churn.** `git ls-tree -l` byte sizes, blob sizes across all history, `git log --numstat` since 2026-09-01, and commit-subject prefixes.

For every item in the deletion list below I opened the code and grepped the name across `Sources/`, `Tests/`, `Package.swift`, and where relevant `docs/`. I spot-checked 30 of the name-unique functions. None had a hidden caller, apart from delegate or protocol names, which the scripts already exclude.

**Limits.**
- I did not build or run anything (brief rule 3). Every finding is **Traced** or **Suspected**. None is **Confirmed**.
- Name-based scans cannot see calls made through protocol existentials with a generic name, Objective-C runtime lookup by string, or SwiftUI `PreviewProvider` discovery. See "Looks dead but is used".
- I did not judge scientific correctness. Two items in that area (SIMP-01, SIMP-03) are handed to the relevant reviewers as Suspected.
- I did not read the excluded 2026-09-05 audit folders.

## Executive summary

For an LLM-written codebase of this size, this one is less duplicated than I expected. Only 6.8% of normalized source lines sit inside an 8-line window that appears somewhere else. The FASTQ reader, the provenance file hasher and the CLI launcher already have one canonical implementation each. The kernel/leaf module split is holding up. The problems are concentrated, not spread everywhere, and they come in four shapes.

1. **Retirements that stop halfway.** Features get replaced, but the machinery around the old version stays behind and keeps growing:
   - About 5.9K lines of workbook-transaction recovery remain after their only writer was deleted on 2026-09-13.
   - A CLI subcommand for a replaced tool (RiboDetector) is still in the tree.
   - A dead Orient wizard is still named in the manual's feature inventory.
   - 636 lines of dead SwiftUI copies sit inside `InspectorView.swift`.
   - Several dead files were edited as recently as 2026-09-09. Agents are maintaining code that nothing calls.
2. **Parallel encodings of one fact that already disagree.** The clearest case is FASTQ operations. The same request is turned into a CLI command three separate ways. Provenance records a display string (for example `seqkit grep ...`) instead of the command that actually ran (`lungfish fastq search-text ...`).
3. **Speculative generality in fast-moving areas.** The primer-design adapter accepts four versions of a fork the app pins itself, plus about 2.3K lines of hand-written `[String: Any]` contract checks. Those checks only apply when the user supplies an older external binary, and the GUI never offers that path. The project-storage cleanup and workbook-transaction subsystems have the same flavour: journals, receipts and attestations around a move-to-Trash.
4. **Process output outgrowing product output.** Since 2026-09-01, `docs/` gained 171K lines against 57K in `Sources/`. `docs/user-manual/reviews` alone gained 91K lines. `docs/user-manual` is 312 MB of the 512 MB checkout, including three stored copies of each generated illustration.

A realistic cleanup:
- removes about 5K production lines of verified dead code plus about 2.5K dedicated test lines;
- consolidates about 3–4K lines of copy-pasted runners and helpers;
- moves more than 100 MB of review scratch and redundant images out of the working tree.

The riskiest items are deletions that touch persisted formats (Codable raw values, on-disk markers). Those need a sunset decision, not just a cleanup.

## Preserve (do not "fix" these away)

- **Deny-by-default `.gitignore`** ([.gitignore:3](.gitignore:3)): `*` followed by explicit allow-lists. It stops stray outputs from being committed. Only the contradictions listed in SIMP-14 need tidying.
- **The 2026-09-13 retirement commit** `7f74c0055` deleted about 20K lines (the Excel workbook lifecycle, `GenotypeWorkbookRevisionService` and others) in one reviewable change. That is the pattern to repeat. SIMP-02 finishes it.
- **Canonical helpers that already exist.** Extend these instead of adding new ones:
  - [LungfishCLIRunner.swift:18](Sources/LungfishKit/LungfishCLIRunner.swift:18) (kernel CLI subprocess runner)
  - [FASTQReader.swift:161](Sources/LungfishIO/Formats/FASTQ/FASTQReader.swift:161) (the only general FASTQ reader; the 68-line 12S reader is the only duplicate)
  - [ProvenanceFileHasher.swift:25](Sources/LungfishWorkflow/Provenance/ProvenanceFileHasher.swift:25) (streaming SHA-256 with a cancellation hook)
- **Single-conformer protocols that have test mocks.** 62 of the 79 single-production-conformer protocols have test conformers, for example `FASTQOperationCommandRunning` and `PluginPackStatusProviding` (28 test conformers). These are real test seams, not over-abstraction. Keep them.
- **Test hooks are mostly compiled out.** 1,010 of 1,285 `testing*` members sit inside `#if DEBUG`.
- **Feature-flag rot is essentially absent.** I found no always-true or always-false feature switches beyond two harmless defaults, for example [SequenceViewerView+Rendering.swift:112](Sources/LungfishApp/Views/Viewer/SequenceViewerView+Rendering.swift:112) `let needsAnnotations = true`.
- **Large bundled binaries are loaded at runtime.** `init.rootfs.tar.gz` (85 MB) and `vmlinux` (15 MB) are used by [AppleContainerRuntime.swift](Sources/LungfishWorkflow/Engines/AppleContainerRuntime.swift). Each has exactly one version in history, so history is not bloated by churn.

## Findings table

| ID | Priority | Title | Confidence | Effort |
|---|---|---|---|---|
| SIMP-01 | P2 | FASTQ operations have three independent CLI encodings; provenance records a command that did not run | Traced | M |
| SIMP-02 | P2 | About 5.9K lines of workbook-transaction recovery outlive their only writer | Traced | M |
| SIMP-03 | P2 | PrimalScheme3 adapter supports 4 fork versions and 2 external-binary-only selectors (about 3.3K lines) | Traced (reachability), Suspected (lge.5 break) | M |
| SIMP-04 | P2 | Nine copy-pasted CLI subprocess runners (about 3.4K lines) next to an unused kernel runner | Traced | M |
| SIMP-05 | P2 | Verified dead code: about 5.0K production lines plus about 2.5K test lines (ranked list) | Traced | M |
| SIMP-06 | P2 | Same-named public types in two modules (`SequencingPlatform`, `AlignmentFilter*`) | Traced | M |
| SIMP-07 | P2 | Chromosome aliasing implemented at least 5 times; the dedicated resolver is unused | Traced (duplication), Suspected (inconsistency) | M |
| SIMP-08 | P2 | Docs and review artifacts dominate the checkout and the churn | Traced | M |
| SIMP-09 | P3 | Process-doc sprawl and stale process pointers to dead code | Traced | S |
| SIMP-10 | P3 | 49 SHA-256 helpers and 15 CSV/TSV escapers with inconsistent rules | Traced | S |
| SIMP-11 | P3 | About 5.4K lines of test hooks in production types, and 109 source-text test files | Traced | M |
| SIMP-12 | P3 | Two container-runtime factories plus a Docker fallback | Traced (duplication), Suspected (Docker unused) | S |
| SIMP-13 | P3 | Copy-paste pairs: classifier VCs, genotype replay commands and payloads, tree runners | Traced | M |
| SIMP-14 | P3 | Small hygiene items: drifted agent copies, diverged prompt copy, unused fixture, `.gitignore` contradictions | Traced | S |
| SIMP-15 | P3 | `scripts/`: 45K Python lines, including one-off research labs and 23.5K lines of script tests | Traced | S |
| SIMP-16 | P3 | About 1.4K lines of Python embedded in Swift string literals | Traced | S |
| SIMP-17 | P3 | Project-storage cleanup is 9.3K source lines plus 15.7K test lines for a move-to-Trash | Suspected | L |

---

## SIMP-01 (P2) FASTQ operations have three independent CLI encodings, and provenance records a command that did not run

**Evidence (Traced).** `FASTQDerivativeRequest` (about 30 cases) is switched over exhaustively in 10 files. Three of those switches each produce a command line:

1. **Display string.** `cliCommand(inputPath:outputPath:)` at [FASTQDerivativeServiceModels.swift:394](Sources/LungfishApp/Services/FASTQDerivativeServiceModels.swift:394).
   - For `searchText`, its comment says "No direct lungfish CLI subcommand — show the seqkit grep invocation" and it emits `seqkit grep ...` ([FASTQDerivativeServiceModels.swift:413](Sources/LungfishApp/Services/FASTQDerivativeServiceModels.swift:413)).
2. **Actual invocation.** `fastqArguments(for:)` at [FASTQOperationCLIInvocationBuilder.swift:232](Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift:232).
   - It runs `lungfish fastq search-text --query ...` ([FASTQOperationCLIInvocationBuilder.swift:252](Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift:252)).
   - It silently drops the deduplicate `preset` (`_ = preset`, [FASTQOperationCLIInvocationBuilder.swift:262](Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift:262)).
   - The public `buildInvocation` is a pass-through to a function still named `legacyBuildInvocation` ([FASTQOperationCLIInvocationBuilder.swift:10](Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift:10)).
3. **Provenance argv.** `provenanceCLIArguments` at [FASTQDerivativeServiceModels.swift:605](Sources/LungfishApp/Services/FASTQDerivativeServiceModels.swift:605).
   - It spells length filtering `--min-length/--max-length`. The real CLI uses `--min/--max` ([FastqCommand.swift:435](Sources/LungfishCLI/Commands/FastqCommand.swift:435)).
   - It spells dedupe as `--substitutions N --optical true`, which is not valid CLI syntax.
   - It is appended to the pseudo-command `lungfish-app-workflow:fastq-derivative` ([FASTQDerivativeService+MixedOutput.swift:855](Sources/LungfishApp/Services/FASTQDerivativeService+MixedOutput.swift:855)).

**How the disagreement reaches provenance.** The output importer stores the display string, not the executed argv, as the derived bundle's `toolCommand` ([FASTQOperationOutputImporter.swift:341](Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift:341), [:348](Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift:348)). The ribosomal RNA filter also records `riboDetectorEnsure: ensure` ([FASTQOperationOutputImporter.swift:334](Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift:334)), but the executed Deacon invocation ignores `ensure` ([FASTQOperationCLIInvocationBuilder.swift:512](Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift:512)).

**Impact.** For search-text and search-motif, a user who copies the recorded command from the Inspector reproduces a different program (seqkit instead of `lungfish fastq search-text`). Each new operation needs about 12 parallel switch edits. The three encodings have already drifted, so the next change will drift them further.

**Recommendation.**
- Make `FASTQOperationCLIInvocationBuilder` the single source of argv.
- Derive the display string by quoting that argv, and have the importer record that string.
- Delete `cliCommand` and `legacyBuildInvocation`.
- Replace `provenanceCLIArguments` with the real argv. Or keep only `provenanceExplicitOptions`, which is a key-value map and cannot mis-spell flags.
- Either pass `ensure` through to the CLI or stop recording it.
- Hand the provenance-accuracy aspect to the provenance/correctness reviewer.

**Acceptance test.** A table-driven test over every `FASTQDerivativeRequest` case asserts that the recorded `toolCommand` equals the quoted `buildInvocation` argv. A second test parses every generated argv with `LungfishCLI`'s `FastqCommand.parseAsRoot` so that invalid flags fail to parse.

**Effort.** M. Net about -350 lines.

## SIMP-02 (P2) About 5.9K lines of workbook-transaction recovery outlive their only writer

**Evidence (Traced).**
- Commit `7f74c0055` (2026-09-13, "Retire active genotype Excel lifecycle") deleted the code that wrote workbook update transactions: `GenotypeWorkbookRevisionService` (about 8K lines), `FastqUpdateCurrentWorkbookSubcommand` and others.
- The transaction library it wrote through is still present, and its forward-path functions now have no callers anywhere in `Sources/`:
  - `createAttestation` [ONTGenotypeWorkbookUpdateTransaction.swift:526](Sources/LungfishIO/Bundles/ONTGenotypeWorkbookUpdateTransaction.swift:526)
  - `write` [:614](Sources/LungfishIO/Bundles/ONTGenotypeWorkbookUpdateTransaction.swift:614)
  - `removeUnpublishedAttestation` [:649](Sources/LungfishIO/Bundles/ONTGenotypeWorkbookUpdateTransaction.swift:649)
  - `finalizeCommittedTransactionAssumingLock` [:687](Sources/LungfishIO/Bundles/ONTGenotypeWorkbookUpdateTransaction.swift:687)
  - `discardPreparedTransactionAssumingLock` [:736](Sources/LungfishIO/Bundles/ONTGenotypeWorkbookUpdateTransaction.swift:736)
  - `moveDirectoryNoReplaceAssumingLock` [:1797](Sources/LungfishIO/Bundles/ONTGenotypeWorkbookUpdateTransaction.swift:1797)
  - `swapDirectoriesAssumingLock` [:1820](Sources/LungfishIO/Bundles/ONTGenotypeWorkbookUpdateTransaction.swift:1820)
- `git log -S "ONTGenotypeWorkbookUpdateRecovery.write("` shows the last caller removed in `7f74c0055`.
- What remains in use is read-side recovery. When a bundle loads, [ONTGenotypeResultBundle.swift:2247-2276](Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift:2247) looks for a marker left by a pre-September transaction and calls `recoverIfNeededAssumingLock`. Storage cleanup classifies legacy workbooks through [ProjectStorageLegacyWorkbookClassifier.swift](Sources/LungfishWorkflow/Storage/ProjectStorageLegacyWorkbookClassifier.swift).
- Size:
  - `ONTGenotypeWorkbookUpdateTransaction.swift`: 3,532 lines, 85 functions
  - `ONTGenotypeWorkbookCleanupState.swift`: 1,848 lines
  - the two `ProjectStorageLegacy*` files: 561 lines
  - `GenotypeHistoricalWorkbookRecoveryTests.swift`: 456 lines

**Impact.** About 5.9K lines of the most intricate code in the repo (Darwin `lstat`/inode identity checks, attestation publication, rollback phases) now exist only to recover interrupted transactions from the July–September builds. They have no forward path to test them against. The shingle scan ranks the file fifth in the repo for duplicated lines (411), which signals internal copy-paste.

**Recommendation.**
- Product decision first: how long must interrupted pre-2026.9.13 workbook transactions stay recoverable in place?
- Suggested sunset: one or two Preview releases. After that, replace recovery with a small detector of about 150 lines. It finds the marker and the transaction root, moves both to the project's quarantine or Trash with a provenance note, and shows the user one message.
- Delete the unreferenced forward-path functions now. That is zero risk and about 350 lines.
- Leave `ONTGenotypeBundlePublicationLock` ([:194](Sources/LungfishIO/Bundles/ONTGenotypeWorkbookUpdateTransaction.swift:194)) where it is. It is still used by five live writers, for example [GenotypeApplyAnnotationsSubcommand.swift:74](Sources/LungfishCLI/Commands/GenotypeApplyAnnotationsSubcommand.swift:74). Move it into its own file before any deletion.

**Acceptance test.**
- A fixture bundle with a leftover marker loads. The marker is quarantined and the user sees one alert.
- `grep -r ONTGenotypeWorkbookUpdateRecovery Sources` returns only the detector.
- The five publication-lock callers still compile and their tests pass.

**Effort.** M. Removes about 5.5K lines. Risk: medium (on-disk state).

## SIMP-03 (P2) PrimalScheme3 adapter supports four fork versions and two selectors that only an external binary can run

**Evidence (Traced for reachability).**
- The adapter carries four pinned versions of a fork the project controls: `toolVersion = "3.3.0+lge.2"`, `coverageToolVersion = "…lge.3"`, `alleleToolVersion = "…lge.4"` and `managedToolVersion = "…lge.5"` ([PrimalScheme3DesignPipeline.swift:282-285](Sources/LungfishWorkflow/PrimerDesign/PrimalScheme3DesignPipeline.swift:282)).
- The version probe accepts any of the four ([PrimalScheme3DesignPipeline.swift:1080-1084](Sources/LungfishWorkflow/PrimerDesign/PrimalScheme3DesignPipeline.swift:1080)).
- The managed install is lge.5 only ([third-party-tools-lock.json:37](Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json:37)).
- The two non-default selectors require an exact older version in the capabilities JSON:
  - coverage requires `toolVersion == coverageToolVersion` (lge.3), [PrimalScheme3CoverageContract.swift:24](Sources/LungfishWorkflow/PrimerDesign/PrimalScheme3CoverageContract.swift:24)
  - allele-coverage requires `toolVersion == alleleToolVersion` (lge.4), [PrimalScheme3AlleleContract.swift:33](Sources/LungfishWorkflow/PrimerDesign/PrimalScheme3AlleleContract.swift:33)
- The project's own feature doc agrees: coverage "currently requires an explicit local executable through `--primalscheme3-path`" and "the managed installation is lge.5" (`docs/features/primalscheme3-lge-fork.md`, line 19).
- The GUI never selects either mode. `PrimerDesignDialogState` builds `PrimalScheme3DesignOptions` without `selectionAlgorithm` ([PrimerDesignDialogState.swift:261-274](Sources/LungfishApp/Views/PrimerDesign/PrimerDesignDialogState.swift:261)), so it gets the default `.legacy` ([PrimalScheme3DesignPipeline.swift:79](Sources/LungfishWorkflow/PrimerDesign/PrimalScheme3DesignPipeline.swift:79)).
- The modes are reachable only through the CLI `--selection-algorithm` option ([PrimerDesignCommand.swift:117](Sources/LungfishCLI/Commands/PrimerDesignCommand.swift:117)).
- Code serving those paths: `PrimalScheme3AlleleContract` 1,231 lines, `PrimalScheme3CoverageContract` 930, `PrimalScheme3AlleleLabelMap` 475, `PrimalScheme3AlleleOptions` 282, and `PrimerAnalysisNativeInspectionService` 340 (it only accepts lge.4, [:116](Sources/LungfishWorkflow/PrimerDesign/PrimerAnalysisNativeInspectionService.swift:116)). About 3.3K lines in total.
- The two contract files each re-implement the same untyped JSON accessors (`object`, `string`, `strings`, `bool`, `integer`, `number`, around [AlleleContract:670-724](Sources/LungfishWorkflow/PrimerDesign/PrimalScheme3AlleleContract.swift:670) and [CoverageContract:253-303](Sources/LungfishWorkflow/PrimerDesign/PrimalScheme3CoverageContract.swift:253)). They validate the tool's output field by field instead of decoding `Codable` structs.
- The `PrimerDesign/` directory grew by 6.4K lines since 2026-09-01.

**Suspected defect (for the primer or correctness reviewer).** The managed lge.5 runtime appears to report `toolVersion "3.3.0+lge.5"`: the recovery probe accepts `capabilityVersion ∈ {lge.4, lge.5}` and requires it to equal the `--version` output ([:1104-1106](Sources/LungfishWorkflow/PrimerDesign/PrimalScheme3DesignPipeline.swift:1104)). If so, `--selection-algorithm coverage` or `allele-coverage` against the managed runtime always fails the capabilities check. I did not run it.

**Impact.** The primer adapter is multi-version infrastructure for a fork the project pins itself. The allele and coverage paths cannot be exercised with the shipped runtime. Every change to the default path must also keep these paths compiling and tested.

**Recommendation.**
- Product decision first: are coverage and allele-coverage shipped features or research?
- **If research:** move them behind a clearly experimental CLI group or into a separate target. Delete lge.2, lge.3 and lge.4 acceptance from the probe. Keep a single `managedToolVersion`.
- **If shipped:** rebuild lge.5 to advertise both selectors, pin one version, and replace the `[String: Any]` validators with `Codable` decoding plus schema-version checks. That typically needs about 30% of the code.
- Note that "legacy" here is the live default selector, not dead code (see "Looks dead but is used").

**Acceptance test.** With only the managed runtime installed, every `--selection-algorithm` value the CLI advertises either runs end to end on a tiny MSA fixture or is absent from `--help`.

**Effort.** M. Could remove about 2–3K lines.

## SIMP-04 (P2) Nine copy-pasted CLI subprocess runners next to an unused kernel runner

**Evidence (Traced).**
- `Sources/LungfishApp/Services/` contains nine `CLI*Runner.swift` files, 3,377 lines together.
- Each spawns its own `Process()`, wires its own pipes, stream state and `DispatchGroup`s, and defines its own `parseEvent(from:)`. Examples: [CLITreeInferenceRunner.swift:98](Sources/LungfishApp/Services/CLITreeInferenceRunner.swift:98), [CLIMSAAlignmentRunner.swift:157](Sources/LungfishApp/Services/CLIMSAAlignmentRunner.swift:157), [CLIVariantCallingRunner.swift:336](Sources/LungfishApp/Services/CLIVariantCallingRunner.swift:336).
- `CLITreeInferenceRunner.swift` and `CLITreeTransformRunner.swift` are both 297 lines. After renaming the type, they differ in six string literals (36 diff lines).
- The shingle scan finds 56–133 shared 8-line windows between each pair in the family.
- A kernel `LungfishCLIRunner` already exists ([LungfishCLIRunner.swift:18](Sources/LungfishKit/LungfishCLIRunner.swift:18)) and is used by 10 other call sites, but none of the nine runners use it.
- Binary lookup is split too: 14 files call `CLIImportRunner.cliBinaryPath()` directly.

**Impact.** Changes to cancellation, environment (`ManagedStorageConfigStore().subprocessEnvironment()`), stderr capture or OperationCenter logging must be made nine times. Memory notes record past bugs in exactly this area (bare PATH, missing `.log()` calls).

**Recommendation.** Extend `LungfishCLIRunner` with one generic `runStreaming(arguments:operationID:eventDecoder:onEvent:)` built on `NativeProcessCancellationHandle`. Reduce each runner to an event enum plus about 40 lines of argument building. Merge the two tree runners into one parameterized by a label.

**Acceptance test.**
- Existing runner tests pass unchanged.
- `grep -l "Process()" Sources/LungfishApp/Services/CLI*Runner.swift` returns nothing.
- A single cancellation test on the shared runner covers all nine.

**Effort.** M. About -2.3K lines. Risk: medium (long-running operations). Do it one runner per commit.

## SIMP-05 (P2) Verified dead code: ranked deletion list

**Evidence (Traced).** Scan totals:
- 197 functions (3,456 lines) referenced nowhere.
- 655 functions (6,351 lines) referenced only from `Tests/`.
- 71 private symbols (1,674 lines) never used in their own file.
- 16 whole files with no inbound production reference (3,742 lines).

The table lists the items I verified by hand, ordered by lines removed and then by risk. "Tests" means dedicated tests that would go too.

| # | Item | Lines | Evidence | Tests | Risk |
|---|---|---|---|---|---|
| 1 | Six dead private SwiftUI sections in `InspectorView.swift` (`InspectorAlignmentVisibilitySection` … `InspectorExportWorkflowSection`). They are near-copies of `ReadStyleSection` (204 shared normalized lines). | 636 | [InspectorView.swift:394-1029](Sources/LungfishApp/Views/Inspector/InspectorView.swift:394). Each name occurs once and the structs are `private`. | none (but see SIMP-11 source-text tests) | Low |
| 2 | `DemultiplexingPipeline+MultiStep.swift`: `runMultiStep` (321 lines) and its private helpers | ~520 | [DemultiplexingPipeline+MultiStep.swift:33](Sources/LungfishWorkflow/Demultiplex/DemultiplexingPipeline+MultiStep.swift:33). No callers; untouched since 2026-03-21. | `DemultiplexPlanTests` partially (591) | Low |
| 3 | `NextflowWorkflowSchema` family | 504 | [WorkflowSchema.swift](Sources/LungfishWorkflow/Nextflow/WorkflowSchema.swift). No reference anywhere, not even in tests. | none | Low |
| 4 | `SnakemakeConfigParser` / `YAMLValue` | 454 | [SnakemakeConfigParser.swift](Sources/LungfishWorkflow/Schema/SnakemakeConfigParser.swift). Test-only. | `SchemaParserTests` (3 uses) | Low |
| 5 | `UnifiedMetagenomicsWizard` | 330 | [UnifiedMetagenomicsWizard.swift](Sources/LungfishApp/Views/Metagenomics/UnifiedMetagenomicsWizard.swift). Test-only. | 3 test files | Low |
| 6 | `FastqRiboDetectorSubcommand` and `RiboDetectorOutputPlan`. Not registered in the `fastq` subcommand list ([FastqCommand.swift:34-78](Sources/LungfishCLI/Commands/FastqCommand.swift:34)); the GUI uses `deacon-ribo`. Also the `.ribodetector` cases in `NativeTool` ([NativeToolRunner.swift:329](Sources/LungfishWorkflow/Native/NativeToolRunner.swift:329)) and the `ribodetector` plugin-pack entry ([PluginPack.swift:861](Sources/LungfishWorkflow/Conda/PluginPack.swift:861)). | ~319 + ~40 | [FastqRiboDetectorSubcommand.swift:13](Sources/LungfishCLI/Commands/FastqRiboDetectorSubcommand.swift:13) | none | Low for the command. Plugin-pack removal needs a check of installed-env migration. Keep the `FASTQRiboDetector*` enums (Codable). |
| 7 | Orient legacy path: `OrientWizardSheet` plus private `runOrientReads` | 256 + 56 | [OrientWizardSheet.swift:49](Sources/LungfishApp/Views/Metagenomics/OrientWizardSheet.swift:49), [AppDelegate+ToolsMenu.swift:1605](Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:1605). Orient now runs through the FASTQ operations dialog. | none | Low. Also fix `features.yaml:437` (SIMP-09). |
| 8 | Genotype UI and IO files that are dead but still being edited: `GenotypeStatusFlagSection` (201), `GenotypeDropoutThresholdSection` (159), `GenotypeResultTableView` (139), `GenotypeReviewableRowResolver` (125). The first two were last modified 2026-09-09. | 624 | e.g. [GenotypeResultTableView.swift:4](Sources/LungfishGenotypeUI/GenotypeResultTableView.swift:4). Test-only references. | 5 test files | Low |
| 9 | FASTQ import leftovers: `runVSP2RecipeWithDelayedInterleave` (180), `shouldDelayInterleaveForVSP2` (19), `importViaSubprocess` (34), `writeImportManifest` (26) | 259 | [FASTQIngestionService.swift:1167](Sources/LungfishApp/Services/FASTQIngestionService.swift:1167), [:1354](Sources/LungfishApp/Services/FASTQIngestionService.swift:1354) | none | Low |
| 10 | `ConsensusCoordinateMap`, built speculatively ("Correct three coordinate-map errors before anything wires it", 2026-09-02) | 180 | [ConsensusCoordinateMap.swift:16](Sources/LungfishWorkflow/ViralRecon/ConsensusCoordinateMap.swift:16) | 18 test refs | Low, unless Viral Recon plans to wire it soon (ask). |
| 11 | `materializeVirtualFASTQSubset` / `materializeVirtualFASTASubset` | 162 | [FASTQDerivativeService+Materialization.swift:62](Sources/LungfishApp/Services/FASTQDerivativeService+Materialization.swift:62), [:138](Sources/LungfishApp/Services/FASTQDerivativeService+Materialization.swift:138) | none | Low |
| 12 | App-local `AlignmentFilterCommandBuilder` and `AlignmentFilterModels`, which shadow the `LungfishWorkflow` types (SIMP-06) | 143 | [AlignmentFilterCommandBuilder.swift:3](Sources/LungfishApp/Services/AlignmentFilterCommandBuilder.swift:3). Production uses the Workflow builder ([BundleAlignmentFilterService.swift:125](Sources/LungfishWorkflow/Alignment/BundleAlignmentFilterService.swift:125)). | `AlignmentFilterCommandBuilderTests` (64) | Low |
| 13 | TaxTriage: `enableMultiSampleFlatTableMode` (85), `discoverRelatedAnalyses` (60) | 145 | [TaxTriageResultViewController.swift:2959](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:2959), [:3440](Sources/LungfishTaxTriageUI/TaxTriageResultViewController.swift:3440) | none | Low |
| 14 | `BatchProcessingEngine.processBarcode` (private) | 130 | [BatchProcessingEngine.swift:293](Sources/LungfishApp/Services/BatchProcessingEngine.swift:293) | none | Low |
| 15 | `PrimerSchemeInspectorView` (100), `ProjectLockWarningBannerView` (92) | 192 | [PrimerSchemeInspectorView.swift:12](Sources/LungfishApp/Views/Sidebar/PrimerSchemeInspectorView.swift:12), [ProjectLockWarningBannerView.swift](Sources/LungfishApp/Views/MainWindow/ProjectLockWarningBannerView.swift) | none | Low |
| 16 | `FullLengthONTPBAAArtifactPlanner` | 96 | [FullLengthONTPBAAArtifactPlanner.swift:9](Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTPBAAArtifactPlanner.swift:9) | 1 test file | Low |
| 17 | Remaining smaller unreferenced functions I checked, e.g. `prepareONTGenotypingViewerBundlesIfPossible` (68), `multiSequenceContextMenu` (62), `createRuntimeWithError` (56), `buildAccessionSummaries` (53), `renderAnnotationTile` (47), `deriveTaxonNames` (46), `selectMiniBAMAccessions` (39), `materializeBatch` (38) | ~600 | see the per-function lines in the scan output | none | Low |

**Totals.** About 5.0K production lines plus about 2.5K dedicated test lines. `ChromosomeAliasResolver` (545) is excluded here: see SIMP-07, which recommends adopting it rather than deleting it.

**Impact.** Dead code gets maintained. Items 8 and 10 were edited or "corrected" after they became dead, so agent effort is going into code nothing runs. Dead code also misleads readers and the manual pipeline (SIMP-09).

**Recommendation.**
- Delete in the order of the table, one module per commit.
- Before each deletion, grep `Tests/` for source-text assertions on the file (SIMP-11) and remove those assertions in the same commit.
- Add a CI lint (Periphery, or the scan script checked in under `scripts/`) to report new unreferenced declarations. Report only, not a gate, at first.

**Acceptance test.**
- `swift build` and the unit tier stay green.
- Re-running the name-unique scan shows the listed identifiers gone.
- Periphery (or the script) reports a lower count, recorded in the PR.

**Effort.** M overall. Each row is S.

## SIMP-06 (P2) Same-named public types in two modules

**Evidence (Traced).**
- **`SequencingPlatform`** is declared twice:
  - [LungfishIO/Formats/FASTQ/SequencingPlatform.swift:12](Sources/LungfishIO/Formats/FASTQ/SequencingPlatform.swift:12): cases `illumina, oxfordNanopore, pacbio, element, ultima, mgi, unknown`
  - [LungfishWorkflow/Recipes/SequencingPlatform.swift:42](Sources/LungfishWorkflow/Recipes/SequencingPlatform.swift:42): cases `illumina, ont, pacbio, ultima`
  - Both are `String`-backed `Codable`, so they persist different raw values for the same platform (`"oxfordNanopore"` vs `"ont"`).
  - `LungfishWorkflow` imports `LungfishIO`, so callers must disambiguate. `Sources/` contains 43 fully qualified `LungfishIO.SequencingPlatform` / `LungfishWorkflow.SequencingPlatform` references, e.g. [MainSplitViewController+FASTQImport.swift:376](Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift:376).
- **`AlignmentFilterRequest`, `AlignmentFilterDuplicateMode` and related types** are public in both `LungfishApp` ([AlignmentFilterModels.swift](Sources/LungfishApp/Services/AlignmentFilterModels.swift)) and `LungfishWorkflow`. Live App code has to write `LungfishWorkflow.AlignmentFilterRequest` ([ReadStyleSection.swift:660](Sources/LungfishApp/Views/Inspector/Sections/ReadStyleSection.swift:660)).
- **Typealias shims keep old names alive:** [LungfishApp/Services/MetagenomicsBatchResultStore.swift](Sources/LungfishApp/Services/MetagenomicsBatchResultStore.swift) (5 typealiases) and [LungfishCLI/Commands/WorkflowEngineLaunch.swift](Sources/LungfishCLI/Commands/WorkflowEngineLaunch.swift).

**Impact.**
- New code picks whichever name resolves first.
- A future "unify" refactor can silently change persisted raw values: recipe JSON with `"ont"` versus FASTQ metadata with `"oxfordNanopore"`.
- Qualified names spread through call sites.

**Recommendation.**
- Delete the App `AlignmentFilter*` copies (SIMP-05 #12).
- Rename the Workflow enum to `RecipeSequencingPlatform`, or merge it into the IO enum with a custom `init(from:)` that accepts `"ont"`.
- Inline the typealias shims at their call sites.

**Acceptance test.**
- `grep -c "LungfishIO.SequencingPlatform\|LungfishWorkflow.SequencingPlatform" Sources` returns 0.
- Decoding fixtures containing both `"ont"` and `"oxfordNanopore"` round-trips.

**Effort.** M. Risk: medium (Codable).

## SIMP-07 (P2) Chromosome aliasing implemented at least five times while the dedicated resolver is unused

**Evidence.**
- *Traced:* [ChromosomeAliasResolver.swift](Sources/LungfishCore/Models/ChromosomeAliasResolver.swift) (545 lines, 873 lines of tests in `ChromosomeAliasResolverTests.swift`) has no production reference.
- *Traced:* separate alias logic lives in:
  - [SequenceViewerView+Rendering.swift:965](Sources/LungfishApp/Views/Viewer/SequenceViewerView+Rendering.swift:965) (`buildVariantChromosomeAliasMap`)
  - [SequenceViewerView+Alignment.swift:153](Sources/LungfishApp/Views/Viewer/SequenceViewerView+Alignment.swift:153) (`buildAlignmentChromosomeAliasMap`)
  - [SequenceExtractionPipeline.swift:725](Sources/LungfishApp/ViewModels/SequenceExtractionPipeline.swift:725)
  - [AIToolRegistry.swift:485](Sources/LungfishApp/Services/AI/AIToolRegistry.swift:485)
  - [VariantChromosomeHelpers.swift](Sources/LungfishApp/Views/Viewer/VariantChromosomeHelpers.swift) (233)
  - [ChromosomeNameMapping.swift](Sources/LungfishCore/Bundles/ChromosomeNameMapping.swift) (117)
- *Suspected:* these implementations match names differently, so the same VCF can map to a chromosome in the viewer but not in extraction or AI tools. I did not construct a failing case.

**Impact.** Different parts of the app may disagree about which contig a variant or read is on. Users would see it as "variants show in the viewer but extraction finds nothing".

**Recommendation.** Before deleting anything, have the variant/alignment reviewer compare the behaviours. Then either adopt `ChromosomeAliasResolver` in `LungfishCore` as the single matcher with strategy options (exact, chr-prefix, version-strip, length fallback), or delete it and promote the viewer's matcher. Do not keep both.

**Acceptance test.** One table-driven test, run through every call site, shows identical mappings for the VCF/BAM naming fixtures (`chr1`/`1`/`NC_…`/`MN908947.3` vs `MN908947`).

**Effort.** M.

## SIMP-08 (P2) Docs and review artifacts dominate the checkout and the churn

**Evidence (Traced).**
- **Size:** the checkout is 512 MB of tracked bytes. `docs/user-manual` is 312 MB of that.
- **Churn:** since 2026-09-01, `git log --numstat` shows `docs/` +171,219 lines against `Sources/` +57,032 and `Tests/` +54,864. `docs/user-manual/reviews` alone gained 91,271 lines, and 123 new files landed in `docs/superpowers|reports|reviews`.
- **Illustrations are stored three times each.** 26 illustrations × {`.png`, `.source.png`, `.svg`}:
  - The `.svg` files (73.7 MB) are base64-wrapped PNGs (`data:image/png;base64`, e.g. `coverage-histogram.svg` line 1). They are referenced only by `docs/user-manual/illustrations.yaml`.
  - Chapters reference the `.png` (25.5 MB).
  - `.source.png` (55.3 MB) is referenced nowhere.
- **Stale screenshots:** `docs/user-manual/shots/captured/2026-05-09/` (39 files, 35.8 MB) is referenced only by review documents and issues, never by a chapter.
- **Review scratch:** `docs/user-manual/reviews/` holds 723 files (15.4 MB), and 667 of them are in `fidelity-2026-09/`.
- **History:** docs assets are about 221 MB of on-disk blobs. The whole pack is 1.15 GB.

**Impact.**
- Clones and worktrees are slow. Every agent worktree copies 312 MB of manual assets.
- Searches return review scratch alongside real docs.
- The stored bytes suggest the user manual is the product.

**Recommendation.** Do not rewrite history. Stop the growth instead:
1. Keep one illustration format. Delete `.source.png`, and either the base64 `.svg` wrappers or the `.png`, pointing `illustrations.yaml` at the survivor. About -80 MB.
2. Move `shots/captured/2026-05-09`, `reviews/fidelity-2026-09` and similar capture sets to a release asset or a separate `lge-manual-captures` repo, leaving a pointer README.
3. Route new binary docs assets through Git LFS, or a size check in the push gate that rejects files over 1 MB under `docs/` without an allow-list entry.

**Acceptance test.** Tracked bytes under `docs/user-manual` fall below 150 MB. The manual build (`docs/user-manual/build`) still renders every chapter with no missing image.

**Effort.** M. Risk: low. No code depends on these paths (0 references from `Sources/`, `Tests/`, `scripts/` or `.github`).

## SIMP-09 (P3) Process-doc sprawl and stale process pointers to dead code

**Evidence (Traced).**
- `docs/superpowers`: 315 files, 95K lines (167 plans, 134 specs).
- `docs/archive`: 248 files, 129K lines. `docs/reports`: 101 files. `docs/reviews`: 39 files. Two overnight-session summaries sit at the top of `docs/superpowers`.
- Since 2026-09-01, 112 commit subjects start with `Record`, `Document` or `docs:`. Many record experiment runs, e.g. `6104b389e Record bounded shared two-pool A1 A2 evaluation` and `cebc55109 Record stronger cached two-pool evaluation budget`.
- Code refers to `docs/reports` only in test comments (12 files, all pointing to `2026-08-21-test-suite-review.md`), and to `docs/superpowers` only in 4 comments.
- **Stale pointers:**
  - [features.yaml:437](docs/user-manual/features.yaml:437), the manual's feature inventory, lists the dead `OrientWizardSheet.swift` (SIMP-05 #7).
  - `docs/issues/2026-05-09-docs-039-gatk-first-class-integration.md` calls `OrientWizardSheet` "the existing … dialog pattern".
  - Project memory names `OrientWizardSheet` and `MapReadsWizardSheet` as the dialog templates to copy. `MapReadsWizardSheet` no longer exists, and a test asserts its absence ([WindowAppearanceTests.swift:751](Tests/LungfishAppTests/WindowAppearanceTests.swift:751)).

**Impact.** Agents are told to copy dead templates. Plans and specs for merged work compete with living docs in search results. The commit log reads as a lab notebook rather than a product history.

**Recommendation.**
- Adopt a lifecycle rule. Plans and specs are deleted, or moved into a single `docs/archive/<year>.tar.zst` or an `archive/docs` branch, when their work merges. Experiment results go in PR descriptions or an external notebook.
- Keep `docs/` for living material: user manual chapters, formats, release process, design.
- Fix `features.yaml` and the template pointers to name `ClassificationWizardSheet` / `AssemblyWizardSheet`.

**Acceptance test.** `docs/superpowers` contains only plans for unmerged branches. `features.yaml` paths all exist (a small CI check: every `Sources/…` path in `features.yaml` resolves).

**Effort.** S.

## SIMP-10 (P3) 49 SHA-256 helpers and 15 CSV/TSV escapers with inconsistent rules

**Evidence (Traced).**
- **SHA-256:** `grep` finds 49 separate `sha256*` / `computeSHA256` helpers across 5 modules. Behaviour varies:
  - Some read the whole file into memory: [ManagedToolSourceInstaller.swift:299](Sources/LungfishWorkflow/Conda/ManagedToolSourceInstaller.swift:299) (which also returns `nil` on error) and [TreeCommand.swift:1356](Sources/LungfishCLI/Commands/TreeCommand.swift:1356).
  - Others stream with differing chunk sizes: [KrakenIndexDatabase.swift:786](Sources/LungfishIO/Formats/Kraken/KrakenIndexDatabase.swift:786), [FASTQDerivedBundleManifest.swift:86](Sources/LungfishIO/Formats/FASTQ/FASTQDerivedBundleManifest.swift:86).
- **Delimited text:** 15 escapers with different rules.
  - TSV "escaping" replaces tab/LF/CR with a space in [SampleMetadataResolver.swift:440](Sources/LungfishCore/Models/SampleMetadataResolver.swift:440), [TwelveSAmpliconMatchingWorkflow.swift:1164](Sources/LungfishWorkflow/TwelveS/TwelveSAmpliconMatchingWorkflow.swift:1164) and [NaoMgsResultViewController.swift:2808](Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:2808). [UniversalSearchCommand.swift:213](Sources/LungfishCLI/Commands/UniversalSearchCommand.swift:213) forgets CR.
  - CSV quoting in [TaxTriageBatchExporter.swift:215](Sources/LungfishTaxTriageUI/TaxTriageBatchExporter.swift:215) ignores CR.

**Impact.** Large-file hashing can use unbounded memory in a few paths. Exports disagree on edge cases. Each new feature adds another private helper.

**Recommendation.**
- Move `ProvenanceFileHasher` (streaming, cancellable) down to `LungfishCore` as `FileDigest.sha256(of:)` and `Data.sha256Hex`. Replace the private copies.
- Add `DelimitedText.tsvField` / `csvField` in `LungfishCore` with one documented rule set.

**Acceptance test.** `grep -rn "func sha256\|func computeSHA256" Sources` returns only the Core helper. Escaper tests cover CR, LF, tab, quote and comma.

**Effort.** S. About -400 lines.

## SIMP-11 (P3) About 5.4K lines of test hooks in production types, and 109 source-text test files

**Evidence (Traced).**
- `Sources/` declares 1,285 `testing*`/`test*` members covering about 5.4K lines:
  - `LungfishGenotypeUI`: 2,905 lines ([GenotypeResultViewController.swift](Sources/LungfishGenotypeUI/GenotypeResultViewController.swift) has 287, [GenotypeComparisonMatrixView.swift](Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift) has 237)
  - `LungfishApp`: 1,069 lines
- 275 of these members are outside `#if DEBUG` and ship in release builds.
- Production paths increment counters that exist only for tests, e.g. `testingLayoutApplicationCount += 1` ([GenotypeResultViewController.swift:4034](Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:4034), declared at [:333](Sources/LungfishGenotypeUI/GenotypeResultViewController.swift:333)).
- Separately, 109 test files read Swift source as text (418 `Sources/Lungfish…` path literals), for example [InspectorViewControllerSourceTestSupport.swift:42](Tests/LungfishAppTests/InspectorViewControllerSourceTestSupport.swift:42), which lists `InspectorView.swift`.

**Impact.**
- The two largest UI files are about 2–3% test scaffolding.
- Source-text tests pin implementation text. Deleting dead code such as SIMP-05 #1 can fail tests that assert on strings rather than behaviour. That discourages exactly the simplification this report recommends.

**Recommendation.**
- Move `testing*` accessors into `#if DEBUG` extensions in sibling `+Testing.swift` files, as `MainSplitViewController+Testing.swift` already does.
- Treat source-text tests as a known cost. When a simplification PR breaks one, replace it with a behavioural test or delete it, not re-add the text.
- The test-suite reviewer owns the broader policy.

**Acceptance test.** No `testing*` member in `Sources/` is outside `#if DEBUG`. Counted by the scan script.

**Effort.** M (mechanical).

## SIMP-12 (P3) Two container-runtime factories plus a Docker fallback

**Evidence.**
- *Traced:* `public enum ContainerRuntimeFactory` in [NextflowRunner.swift:502](Sources/LungfishWorkflow/Engines/NextflowRunner.swift:502) is a logging wrapper around `public enum NewContainerRuntimeFactory` ([ContainerRuntimeFactory.swift:73](Sources/LungfishWorkflow/Engines/ContainerRuntimeFactory.swift:73)). The file named `ContainerRuntimeFactory.swift` defines the `New…` type.
- *Traced:* `NewContainerRuntimeFactory.createRuntimeWithError` ([:174](Sources/LungfishWorkflow/Engines/ContainerRuntimeFactory.swift:174)) and `environmentDescription` ([:450](Sources/LungfishWorkflow/Engines/ContainerRuntimeFactory.swift:450)) are unreferenced.
- *Suspected:* project policy says Apple Containers is the only runtime on arm64, yet `DockerRuntime` (709 lines) remains as the automatic fallback ([ContainerRuntimeFactory.swift:157](Sources/LungfishWorkflow/Engines/ContainerRuntimeFactory.swift:157)).

**Recommendation.**
- Merge into one `ContainerRuntimeFactory` in its own file and delete the unreferenced members.
- Decide the Docker question explicitly. If Docker is unsupported, delete `DockerRuntime` and the `.docker` preference.

**Acceptance test.** One factory type. The Nextflow profile selection test still passes.

**Effort.** S (about -150 lines; about -850 if Docker goes).

## SIMP-13 (P3) Copy-paste pairs worth consolidating

**Evidence (Traced, shingle scan plus manual range check).**
- **NaoMgs and NVD result VCs:**
  - `NaoMgsResultViewController` shares 322 normalized lines with `NvdResultViewController`: loading overlay, BLAST drawer install, split layout and callback wiring (e.g. [NaoMgsResultViewController.swift:1228-1271](Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:1228), [:2008-2058](Sources/LungfishNaoMgsUI/NaoMgsResultViewController.swift:2008)).
  - `BlastResultsDrawerContainerView()` installation is repeated in 6 result VCs.
  - Multi-selection placeholder logic is repeated in 5.
- **Genotype replay commands and payloads:**
  - `GenotypeReplayCallOverridesSubcommand` / `GenotypeReplayManualHaplotypeAssignmentsSubcommand` share 230 normalized lines (495 and 479 lines).
  - Their IO payloads share 98 lines.
  - Each re-declares a private `sha256Hex` ([GenotypeReplayCallOverridesSubcommand.swift:490](Sources/LungfishCLI/Commands/GenotypeReplayCallOverridesSubcommand.swift:490)).
- **Tree runners:** see SIMP-04.
- **Fluidigm materializers:** `ONTFluidigmAmpliconMaterializer` / `ONTFluidigmSampleMaterializer` share 90 windows.

**Recommendation.**
- Extract a kernel `ClassifierResultScaffold`. Use composition, not a base class, to fit the leaf-module pattern. It installs summary bar, split, action bar, BLAST drawer and loading overlay.
- Extract a generic `GenotypeReplayCommand<Payload>` for the two replay commands.
- Do these after SIMP-04 and SIMP-05 so the diffs stay small.

**Acceptance test.** The per-pair shingle count falls below 30. Leaf UI test targets stay green.

**Effort.** M. Risk: medium (GUI). Needs a Computer Use walkthrough per project rules.

## SIMP-14 (P3) Small hygiene items

**Evidence (Traced).**
- **Drifted agent copies.** Claude agent personas exist in both `.claude/agents/*.md` and `agents/definitions/claude/*.md`. All five shared personas differ, by 32–53 lines each. The Codex copies are identical.
- **Diverged prompt copy.** `docs/mcm-mhc-haplotyping-specialist-prompt.md` differs from the shipped resource `Sources/LungfishWorkflow/Resources/MCMHaplotyping/mcm-mhc-haplotyping-specialist-prompt.md` (first difference at line 48).
- **Unused fixture.** `TestData/HepatitisB.lungfishref` is referenced by no code or test.
- **Three fixture roots:** `TestData/`, `test-data/` (2 files, one test depends on a file not in git) and `Tests/Fixtures/`.
- **`.gitignore` contradictions:** `.claude/` ignored then re-included, `*.xcodeproj/` ignored then re-included, `/test-data/*` rules repeated.
- **Duplicate fixture copy.** One ONT FASTQ appears twice in the manual fixtures (same blob `52e210a6…`). Git dedupes the blob, so this only costs checkout space.

**Recommendation.**
- Make `agents/definitions` the single source and generate or symlink `.claude/agents`.
- Delete the docs copy of the prompt, or link to the resource.
- Delete `HepatitisB.lungfishref`.
- Fold `TestData/TestGenome.lungfishref` into `Tests/Fixtures/`, updating `LungfishProjectFixtureBuilder`.
- Collapse the `.gitignore` duplicate rules.

**Effort.** S.

## SIMP-15 (P3) `scripts/`: research labs and heavy script-testing

**Evidence (Traced).**
- `scripts/` has 152 files and 45,213 Python lines. 23,573 of those lines are in `scripts/tests`, and release tooling is 12,287.
- Not referenced by any code, CI or other script (checked with a scan over all tracked text files):
  - `analysis/macaque_mhc_prompt_lab.py` (1,504 lines, OpenAI runner, plus a 1,770-line test)
  - `analysis/12s_primer_hamming_sweep.py` (715)
  - `analysis/normalize_full_length_ont_mhc_unmatched.py` (1,023)
  - `analysis/reorder_color_intact_mhc_workbook.py` (435)
  - `create-azure-openai-deployment.sh` (216)
  - `deps/check-upstream.py`
  - `examples/notebook_to_lungfish_haplotypes.py`
- For example, the prompt lab defaults to an `inputs/30783_SNPRC22_…xlsx` workbook that is not in the repo ([macaque_mhc_prompt_lab.py:31-36](scripts/analysis/macaque_mhc_prompt_lab.py:31)).

**Recommendation.** Move `scripts/analysis/*`, the prompt lab and the Azure script to a research repo. The release scripts are the release reviewer's call. I only note their weight: about 12K lines of release scripts plus about 15K lines of tests for them.

**Effort.** S. About -6K lines including tests.

## SIMP-16 (P3) Python embedded in Swift string literals

**Evidence (Traced).** About 1.4K lines of Python live inside Swift string literals:
- `GenotypeWorkbookPresentation.snapshotPythonScript` ([GenotypeWorkbookSnapshot+Script.swift:4](Sources/LungfishIO/Bundles/GenotypeWorkbookSnapshot+Script.swift:4), 550 lines). Used by [GenotypeExcelExportService.swift:375](Sources/LungfishWorkflow/ONTGenotyping/GenotypeExcelExportService.swift:375) and by tests that concatenate further Python onto it.
- The filter script written by `writeFilterScript` ([ONTBarcodeDemuxGenotypingPipeline+Scripts.swift:8](Sources/LungfishWorkflow/ONTGenotyping/ONTBarcodeDemuxGenotypingPipeline+Scripts.swift:8), 617 lines).
- [ONTGenotypingPysamFilterRunner.swift](Sources/LungfishWorkflow/ONTGenotyping/ONTGenotypingPysamFilterRunner.swift) (279).

**Impact.** No linting, no syntax highlighting, no `python -m py_compile` in CI, and the Swift diffs are noisy.

**Recommendation.** Move each script to `Resources/…/*.py`, load it with `Bundle.module`, and add a `py_compile` step to the fast push gate.

**Effort.** S.

## SIMP-17 (P3) Project-storage cleanup: heavy machinery for move-to-Trash

**Evidence.**
- *Traced (numbers):* `Sources/LungfishWorkflow/Storage/` is 9,253 lines: executor 2,663, receipt writer 1,680, scanner 1,256, journal 358, inventory verifier 483, published-outcome reader 517. It has 15,728 lines of `ProjectStorage*` tests.
- *Traced:* the final action is `FileManager.default.trashItem` ([ProjectStorageCleanupExecutor.swift:405](Sources/LungfishWorkflow/Storage/ProjectStorageCleanupExecutor.swift:405)), which the user can undo.
- *Suspected:* the journal, receipts, inventory re-verification and published-outcome reader are sized for irreversible deletion, not for a recoverable Trash move.

**Recommendation.** Not a deletion item. Run a design review with the storage owner: which guarantees does move-to-Trash actually need? A likely outcome is dropping the receipt and published-outcome layers and keeping the scanner and a simple journal. Do this after SIMP-02, which removes the legacy workbook classifier this code depends on.

**Effort.** L. Risk: medium-high. Do not start without an owner decision.

---

## Looks dead but is used (do not delete)

- **`CodingKeys` private enums** show up in the private-unused scan, e.g. [FullLengthONTMHCUnmatchedClosestMatchWorkbookRow.swift:21](Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCUnmatchedClosestMatchWorkbookRow.swift:21) and [PBAANextflowWorkflowWriter.swift:46](Sources/LungfishWorkflow/PBAA/PBAANextflowWorkflowWriter.swift:46). `Codable` synthesis uses them.
- **AppKit delegate methods with no call site**, e.g. `applicationShouldHandleReopen` ([AppDelegate.swift:1117](Sources/LungfishApp/App/AppDelegate.swift:1117)) and `applicationWillTerminate`. The runtime calls them.
- **`@objc` menu actions** reached through `#selector`, e.g. `showWorkflowBuilder` ([MainMenu.swift:744](Sources/LungfishApp/App/MainMenu.swift:744), [AppDelegate+ToolsMenu.swift:1676](Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift:1676)). The Workflow Builder UI (4.8K lines) is reachable.
- **`FASTQRiboDetectorRetention` / `FASTQRiboDetectorEnsure`.** The names are legacy, but they are persisted in derived-bundle manifests ([FASTQDerivativeOperation.swift:127-129](Sources/LungfishIO/Formats/FASTQ/FASTQDerivativeOperation.swift:127)). Keep the types and raw values when deleting the RiboDetector subcommand.
- **Both `SequencingPlatform` enums** are `Codable` with different raw values (SIMP-06). Consolidate with a decoding shim, never by rename alone.
- **PrimalScheme3 "legacy" selection algorithm, `legacySalvage*` and `terminalGapPolicy .legacy`.** "Legacy" here names the live default algorithm used by the GUI ([PrimalScheme3DesignPipeline.swift:79](Sources/LungfishWorkflow/PrimerDesign/PrimalScheme3DesignPipeline.swift:79)), not a retired path.
- **`sources/IPD-MHC_NHKIR_Mafa_genomic.fasta`** (7.3 MB) inside the bundled `.lungfishmhcref` is recorded by path in its `mhc-reference.json` manifest and provenance. Keep it with the reference.
- **Other resources and fixtures loaded by name:**
  - `init.rootfs.tar.gz` and `vmlinux` (AppleContainerRuntime)
  - `Examples/WorkflowPackages` (loaded by `WorkflowLibraryViewModel`)
  - `TestData/TestGenome.lungfishref` (XCUI fixture builder)
- **`ONTGenotypeBundlePublicationLock`** lives in the otherwise-retirable transaction file and has five live callers (SIMP-02). Move it before deleting.
- **Single-conformer protocols with test conformers** (62 of them) are test seams, not over-abstraction.
- **`VSP2WorkflowTemplate`** has no `Sources/` reference but 6 Workflow-Builder test files. Check whether the Builder loads templates by name before deleting it. I did not include it in SIMP-05.
- **`*_Previews` structs** in Inspector sections are discovered by Xcode previews. They are not dead, though they are candidates for `#if DEBUG`.

## Proposed work packages

Order matters. Each package is independently reviewable and leaves the build green.

1. **WP-A: Zero-risk dead code** (SIMP-05 rows 1–5, 7, 9, 11–17; SIMP-12 unreferenced members).
   - Files: those listed. Also fix the source-text tests they break.
   - Removes about 4.3K production and about 1.5K test lines.
   - Risk: low. Depends on nothing.
   - Rows 6, 8 and 10 go separately, because they need a one-line owner confirmation (RiboDetector plugin pack; genotype review sections; Viral Recon coordinate map).
2. **WP-B: Single CLI encoding for FASTQ operations** (SIMP-01).
   - Files: `FASTQDerivativeServiceModels.swift`, `FASTQOperationCLIInvocationBuilder.swift`, `FASTQOperationOutputImporter.swift`, `FASTQDerivativeService+MixedOutput.swift`.
   - Risk: medium (provenance format). Coordinate with the provenance reviewer.
3. **WP-C: CLI runner consolidation** (SIMP-04, then SIMP-13 tree runners).
   - Files: `LungfishKit/LungfishCLIRunner.swift` plus the nine `CLI*Runner.swift` files.
   - Risk: medium. One runner per commit, each with a GUI smoke test.
4. **WP-D: Name collisions** (SIMP-06).
   - Files: the two `SequencingPlatform.swift`, the App `AlignmentFilter*` files, the typealias shims.
   - Depends on WP-A #12.
5. **WP-E: Core helpers** (SIMP-10, SIMP-16).
   - Files: new `LungfishCore/FileDigest.swift` and `DelimitedText.swift`, plus about 60 call sites. Python scripts move to resources.
   - Risk: low.
6. **WP-F: Workbook-transaction sunset** (SIMP-02).
   - Needs the product decision on the recovery window.
   - Files: `ONTGenotypeWorkbookUpdateTransaction.swift`, `ONTGenotypeWorkbookCleanupState.swift`, `ProjectStorageLegacy*.swift`, `ONTGenotypeResultBundle.swift:2240-2290`.
   - Risk: medium.
7. **WP-G: Primer adapter decision** (SIMP-03).
   - Needs the product decision (research vs shipped). First verify the lge.5 capability behaviour (Suspected).
   - Risk: medium.
8. **WP-H: Repo hygiene** (SIMP-08, SIMP-09, SIMP-14, SIMP-15).
   - Docs moves, illustration dedupe, `features.yaml` path check, agent-definition source of truth, research scripts out.
   - Risk: low. Independent of the code packages and can run in parallel.
9. **WP-I: Later, with owners** (SIMP-07 alias unification, SIMP-11 test-hook relocation, SIMP-13 classifier scaffold, SIMP-17 storage design review).

**Accept, do not fix:**
- The single-conformer protocols that have test mocks.
- The large runtime binaries in `Resources/`: rewriting history to remove them or the docs assets would cost more than it saves.
- The overall 6.8% exact-duplication level outside the listed clusters.
- The release-script weight, which belongs to the release reviewer and needs no action from this report.

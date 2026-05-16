# Wave 3 Next Phase Design

Date: 2026-05-16
Base: `codex/wave2-integrated-fixes` at `7d0ced6f`
Source review: `.claude/worktrees/fervent-boyd-45e388/review/2026-05-15` plus Wave 2 residual-risk notes

## Goal

Wave 3 should close the remaining high-value review findings that still matter
after Wave 2: scientific provenance for GUI ONT import, decomposition of the
large FASTQ execution service, streaming IO fixes for GenBank and Kraken2, and
the next batch of AppKit/test polish. Missing provenance remains a blocking
defect for any workflow that creates, imports, transforms, exports, or wraps
scientific data.

## Current State

Wave 2 closed the highest-risk module and runtime gaps:

- `LungfishCore` no longer exposes AppKit color types.
- `LungfishCLI` no longer depends on `LungfishApp`.
- CLI/application-export/reference import provenance is rehydrated into final
  bundle payloads.
- Desktop-only IO test fixtures were replaced with package fixtures.
- Kraken2 database recommendations are RAM-aware.
- Plugin pack status freshness and orphan `env-<32 hex>` classification are
  fixed.

Remaining findings now cluster into four themes:

1. Provenance: GUI ONT import still calls `ONTDirectoryImporter` directly, while
   the CLI writes canonical provenance for `lungfish fastq import-ont`.
2. Architecture: `FASTQOperationExecutionService.swift` is 2,414 lines and mixes
   planning, CLI argument construction, staging cleanup, output import, bundle
   writing, and provenance rehydration.
3. IO correctness and scale: `GenBankReader` still reads whole files via
   `readToEnd()`, nested `complement(...)` inside `join/order` loses
   per-segment strand information, and `Kraken2OutputParser.parse(url:)` loads
   the whole per-read output into memory.
4. AppKit/test polish: source-level AppKit/modal guards remain broader than the
   real semantic coverage, many source-string assertions remain in dialog/routing
   tests, and several import/wizard sheets have not moved onto shared dialog
   shells.

## Approaches Considered

### Approach 1: Provenance And Architecture First

Fix GUI ONT provenance and split FASTQ operation execution before touching IO or
UI polish. This addresses the blocking scientific requirement and makes later
FASTQ/import work easier. The downside is that IO streaming fixes remain open
for another wave.

### Approach 2: IO Correctness First

Prioritize GenBank and Kraken2 streaming work. This reduces memory risk for
large real-world files, but leaves a known GUI provenance gap and the large
FASTQ service in place.

### Approach 3: Balanced Parallel Wave

Run independent lanes for ONT provenance, FASTQ service decomposition, GenBank
streaming/strand correctness, Kraken2 streaming, and AppKit/test polish. This
keeps the provenance blocker first while letting low-conflict IO and UI workers
make progress in parallel.

Recommendation: use Approach 3, with a strict integration order. The first two
lanes are P1 because they affect provenance and architecture boundaries. The IO
lanes are scoped to additive APIs and compatibility-preserving parser changes.
The AppKit/test lane is deliberately constrained to semantic tests and the next
small set of dialog migrations, not a broad UI rewrite.

## Wave 3 Worktree Slices

### Slice A: GUI ONT Import Provenance

Priority: P1 scientific provenance

Branch: `codex/wave3-ont-provenance`

Expected ownership:

- Create `Sources/LungfishWorkflow/Ingestion/ONTImportWorkflow.swift`.
- Create `Sources/LungfishApp/Services/ONTImportOperationCoordinator.swift`.
- Modify `Sources/LungfishCLI/Commands/FastqCommand.swift`.
- Modify `Sources/LungfishApp/Views/MainWindow/MainSplitViewController.swift`.
- Add tests in `Tests/LungfishWorkflowTests/ONTImportWorkflowTests.swift`.
- Add `Tests/LungfishCLITests/FastqImportONTProvenanceTests.swift`.
- Add `Tests/LungfishAppTests/ONTImportOperationCoordinatorTests.swift`.

Design:

- Keep `ONTDirectoryImporter` in `LungfishIO` as the low-level layout and bundle
  creator.
- Add a workflow-layer wrapper that calls the importer and writes canonical
  provenance for the final output directory and every created `.lungfishfastq`
  bundle.
- The workflow API should accept an explicit command context:
  tool/workflow name, version, argv, reproducible command, resolved options plus
  defaults, and whether the caller is CLI or GUI.
- The CLI subcommand should delegate to this workflow instead of writing its own
  provenance inline.
- The GUI should call the same workflow through an app coordinator, not shell
  out to the CLI. The coordinator should own Operation Center progress/completion
  updates and should still surface the copy-pasteable
  `lungfish fastq import-ont ...` command.
- Provenance files must point to final project/bundle payload paths, not
  temporary staging files. Chunk FASTQs are inputs; manifest and bundle payloads
  are outputs.
- On a provenance write failure, created ONT bundles and the demultiplex
  manifest should be rolled back unless the failure occurs after a documented
  final commit point. Prefer all-or-nothing behavior because this is an import.

Red tests:

- Workflow test: importing a fixture ONT directory writes `.lungfish-provenance.json`
  at the output root and focused provenance for each created `.lungfishfastq`.
- Workflow test: output descriptors point at final bundle payloads and manifest,
  and input descriptors include the original chunk files with checksums/sizes.
- App test: `ONTImportOperationCoordinator` uses the shared workflow, passes GUI
  command context, and records completed bundle URLs in Operation Center.
- CLI test: `lungfish fastq import-ont` still records argv/defaults/runtime and
  produces the same bundle output as before.
- Failure test: if provenance writing throws, partially created bundles are
  removed and no orphan manifest remains.

Verification:

- `swift test --filter 'ONTImportWorkflowTests|ONTDirectoryImporterTests'`
- `swift test --filter 'FASTQIngestionProvenanceTests|CLICommandTests/testFastqSubcommandsRegistered'`
- `swift build --product lungfish-cli`
- `swift build --product Lungfish`

### Slice B: FASTQ Operation Execution Decomposition

Priority: P1 architecture and maintainability

Branch: `codex/wave3-fastq-execution-split`

Expected ownership:

- Modify `Sources/LungfishApp/Services/FASTQOperationExecutionService.swift`.
- Create `Sources/LungfishApp/Services/FASTQOperationPlanner.swift`.
- Create `Sources/LungfishApp/Services/FASTQOperationCLIInvocationBuilder.swift`.
- Create `Sources/LungfishApp/Services/FASTQOperationOutputImporter.swift`.
- Create `Sources/LungfishApp/Services/FASTQOperationProvenanceRehydrator.swift`.
- Create `Sources/LungfishApp/Services/FASTQOperationStagingCleanup.swift` if
  cleanup logic remains nontrivial.
- Update `Tests/LungfishAppTests/FASTQOperationExecutionServiceTests.swift`.
- Add focused tests for each extracted unit where the behavior is currently only
  covered through the large service.

Design:

- This slice is a behavior-preserving extraction. Do not change CLI commands,
  output naming, manifest semantics, or provenance semantics except where tests
  expose an existing bug.
- Keep the public entry point `FASTQOperationExecutionService.execute(...)`.
  It should become an orchestrator that composes smaller units.
- Planning should own split execution requests, execution directories, and output
  target kind decisions.
- Invocation building should own mapping from `FASTQOperationLaunchRequest` and
  `FASTQDerivativeRequest` to `CLIInvocation`.
- Output importing should own reference wrapping, FASTQ bundle import, QC report
  application, and grouped result handling.
- Provenance rehydration should own source-to-final path maps, materialized input
  replacement, and reference-bundle provenance merging.
- Staging cleanup should be explicit and tested; no cleanup method should delete
  a final bundle or caller-provided directory.

Red tests:

- Planner tests for grouped result, per-input, fixed batch, assembly, mapping,
  classification, and demultiplex execution plans.
- Invocation-builder tests for at least one operation per operation family:
  trim, contaminant filter, primer removal, demultiplex, orient, classify, map,
  assemble, and QC summary.
- Output-importer tests for FASTA-to-reference wrapping, FASTQ output bundle
  writing, QC report application, and demultiplex grouped result preservation.
- Provenance-rehydrator tests for materialized input path replacement and
  reference-bundle provenance merging.
- Cleanup tests proving transient staging directories are removed while final
  bundles are preserved.

Verification:

- `swift test --filter FASTQOperationExecutionServiceTests`
- `swift test --filter FASTQOperationDialogRoutingTests`
- `swift test --filter ScientificFASTQProvenancePolicyTests`
- `swift build --product Lungfish`
- `git diff --check`

### Slice C: GenBank Streaming And Feature Location Fidelity

Priority: P2 IO correctness and scale

Branch: `codex/wave3-genbank-streaming`

Expected ownership:

- Modify `Sources/LungfishIO/Formats/GenBank/GenBankReader.swift`.
- Modify `Sources/LungfishCore/Models/SequenceAnnotation.swift` only if the
  selected location model requires an interval-level strand field.
- Update `Tests/LungfishIOTests/GenBankReaderTests.swift`.
- Update `Tests/LungfishIOTests/GenBankReaderComprehensiveTests.swift`.
- Add a focused large-file regression fixture generator inside tests rather than
  committing a large GenBank file.

Design:

- Replace `parseFileSync` whole-file reads with a record-streaming parser that
  accumulates one GenBank record at a time and emits it when `//` is reached.
- Keep `readAllSync()` and `readAll()` API-compatible by collecting streamed
  records internally.
- Preserve `records()` as the memory-efficient public API. It should no longer
  require a full-file string in memory.
- Parse GenBank locations into a small internal location tree before converting
  to `SequenceAnnotation`.
- Add optional per-interval strand storage if needed:
  `AnnotationInterval(start:end:phase:strand:)` with default `nil` so existing
  serialized annotations remain decodable. A feature-level `strand` remains for
  current display and query behavior.
- For `complement(join(...))`, preserve current feature-level reverse behavior.
- For `join(complement(...),...)` or `order(complement(...),...)`, preserve the
  nested segment strand in interval metadata and set feature-level strand to
  `.unknown` when intervals mix forward and reverse.
- Preserve raw GenBank location text in a reserved qualifier so export and
  diagnostics can round-trip the exact expression even when the display model
  simplifies it.

Red tests:

- Source-level guard: `GenBankReader.parseFileSync` no longer contains
  `readToEnd()` or `components(separatedBy: .newlines)` over a full file.
- Streaming test: a generated multi-record file can be read through `records()`
  with bounded record accumulation.
- Location test: `complement(join(10..20,30..40))` yields reverse feature strand.
- Location test: `join(complement(10..20),30..40)` preserves a reverse interval
  and a forward interval without pretending the whole feature is forward.
- Export test: raw location qualifier is preserved for mixed-strand locations.

Verification:

- `swift test --filter 'GenBankReaderTests|GenBankReaderComprehensiveTests'`
- `swift test --filter LungfishIOTests`
- `swift build --product lungfish-cli`

### Slice D: Kraken2 Per-Read Streaming Parser

Priority: P2 IO scale

Branch: `codex/wave3-kraken2-streaming`

Expected ownership:

- Modify `Sources/LungfishIO/Formats/Kraken/Kraken2OutputParser.swift`.
- Update `Tests/LungfishIOTests/Kraken2OutputParserTests.swift`.
- Search downstream callers and update them to use the streaming API where they
  only need read IDs or filtered records.

Design:

- Keep `parse(url:)`, `parse(data:)`, and `parse(text:)` as compatibility APIs.
- Add a streaming API such as:
  `parseRecords(url:onRecord:) throws -> Int` and
  `readIds(url:classifiedTo:) throws -> [String]`.
- The streaming implementation should read the file incrementally with
  `FileHandle.read(upToCount:)` or another bounded line reader. It must not
  create a full `Data` or full `String` for URL parsing.
- Reuse the existing `parseLine` behavior so malformed-line tolerance remains
  unchanged.
- Return `.emptyFile` when no parseable records are seen, matching existing
  behavior.
- Prefer streaming APIs in extraction/filtering code that only needs read IDs.

Red tests:

- Source-level guard: `parse(url:)` delegates to streaming and does not call
  `Data(contentsOf:)`.
- Streaming test: callback receives records in order and returns the parse count.
- Error test: empty or fully malformed files still throw `.emptyFile`.
- Filter test: `readIds(url:classifiedTo:)` returns the same IDs as in-memory
  parsing without materializing all records.

Verification:

- `swift test --filter Kraken2OutputParserTests`
- `swift test --filter ClassifierReadResolverTests`
- `swift test --filter LungfishIOTests`

### Slice E: AppKit Modal And Main-Actor Semantic Cleanup

Priority: P2 polish and AppKit best practice

Branch: `codex/wave3-appkit-modal-actors`

Expected ownership:

- Modify a small, enumerated set of AppKit files after inventory:
  `ReferenceBundleAnnotationImportConfigurationPresenter.swift`,
  `InspectorViewController.swift`,
  `WorkflowBuilderViewController.swift`,
  `AssemblyRuntimePreflight.swift`,
  `ViralReconWorkflowExecutionService.swift`, and settings tabs if feasible.
- Update `Tests/LungfishAppTests/AppKitConcurrencyModalSafetyTests.swift`.
- Add semantic tests where a coordinator can be extracted without launching the
  full UI.

Design:

- Start with an inventory of remaining `.runModal(`, `Task { @MainActor`, and
  `await MainActor.run` occurrences.
- Keep justified synchronous fallbacks only where the caller has no presenting
  window and the method is already a synchronous gate. The justification must
  state the user-visible failure mode.
- Convert alert/panel flows with a window presenter to completion-handler sheets
  or async wrappers.
- Replace broad source-string checks with semantic tests for extracted
  presenters/coordinators where the code can be tested without UI automation.
- Avoid XCUITest unless a behavior cannot be verified below the app shell.

Red tests:

- Inventory test lists only allowed legacy modal call sites and requires a
  reason string.
- Presenter/coordinator tests for at least two converted modal paths.
- Main-actor source guard remains, but gets narrower as semantic tests replace
  broad file scans.

Verification:

- `swift test --filter AppKitConcurrencyModalSafetyTests`
- Focused tests for converted presenters/coordinators.
- `swift build --product Lungfish`

### Slice F: Dialog Shell Migration And Source-String Test Replacement

Priority: P2/P3 polish and test quality

Branch: `codex/wave3-dialog-test-hygiene`

Expected ownership:

- Modify `Sources/LungfishApp/Views/Metagenomics/CzIdImportSheet.swift`.
- Modify `Sources/LungfishApp/Views/Metagenomics/TaxTriageWizardSheet.swift`.
- Modify `Tests/LungfishAppTests/FASTQOperationDialogRoutingTests.swift`.
- Modify `Tests/LungfishAppTests/DatabaseSearchDialogSourceTests.swift`.
- Modify `Tests/LungfishAppTests/AssemblyWizardSheetTests.swift`.
- Add behavior-level state/presentation tests near existing dialog state tests.

Design:

- Continue using `WizardSheet` and `ImportSheet` from
  `Sources/LungfishApp/Views/Shared/DialogSheets.swift`.
- Migrate CZ-ID import first because it was explicitly deferred in Wave 2.
- Migrate TaxTriage second because it shares metagenomics wizard conventions but
  does not need the mapping/assembly routing surface.
- Replace source-string assertions with behavior-level tests in small batches:
  state objects, presentation structs, command builders, and public test hooks.
- Keep genuine policy source tests only for anti-pattern prevention where runtime
  behavior is not practical to assert.
- Do not change visual design beyond the shared shell migration.

Red tests:

- `DialogShellTests` gains coverage for the shared shell features CZ-ID needs.
- CZ-ID import state/presenter test verifies primary action enablement, browsing
  path capture, cancellation, and progress text without reading Swift source.
- Routing tests verify operation-to-sheet selection through a presentation model
  rather than `source.contains(...)`.
- Source-string test count for the touched files decreases, with no loss of
  behavior coverage.

Verification:

- `swift test --filter DialogShellTests`
- `swift test --filter 'CzIdImportWorkflowTests|CzIdDataConverterTests'`
- `swift test --filter FASTQOperationDialogRoutingTests`
- `swift test --filter DatabaseSearchDialogSourceTests`
- `swift build --product Lungfish`

## Integration Order

1. Slice A first. It closes the remaining provenance blocker and may affect
   FASTQ import tests.
2. Slice B second or in parallel with A, but integrate after A so the FASTQ
   service split can keep the new ONT workflow boundary.
3. Slices C and D can run in parallel; both are in `LungfishIO` but touch
   different parsers.
4. Slices E and F can run in parallel after a shared AppKit/dialog inventory.
   If both touch the same dialog, F owns the SwiftUI sheet and E owns the
   AppKit presentation/callback surface.
5. Final integration should run the full test suite and rebuild debug products.

## Review Gates

Each slice needs two independent reviews before integration:

1. Requirements review against this design and the original Claude finding.
2. Code-quality review for Swift/AppKit best practices, composability, and
   scientific provenance.

Provenance-affecting slices must include an explicit reviewer checklist:

- output bundle/directory has a canonical `.lungfish-provenance.json`;
- tool/workflow name and version are present;
- exact argv or reproducible command is present;
- user-visible options and resolved defaults are present;
- runtime identity is present when applicable;
- input/output paths point to durable final locations;
- checksums and file sizes are present for concrete files;
- exit status, wall time, and useful stderr are present;
- GUI-imported outputs preserve or rehydrate CLI-equivalent provenance.

If a reviewer finds a gap, the worker iterates in the same worktree and the
reviewer re-checks the updated patch before integration.

## Final Verification Target

- `swift build --product lungfish-cli`
- `swift build --product Lungfish`
- Focused test filters from each integrated slice
- `swift test`
- `rg -n '^import LungfishApp' Sources/LungfishCLI Tests/LungfishCLITests` returns nothing
- `rg -n '^import (AppKit|SwiftUI)' Sources/LungfishCore Tests/LungfishCoreTests` returns nothing
- `rg -n '/Users/dho/Desktop|Desktop/test|testProjectPath|skipIfTestDirectoryMissing' Tests` returns nothing except archived docs if intentionally searched
- `otool -L .build/arm64-apple-macosx/debug/lungfish-cli` contains no AppKit or SwiftUI linkage
- `git diff --check`
- Record debug artifact paths for `Lungfish` and `lungfish-cli`

## Deferred Beyond Wave 3

- Full XCUITest provenance coverage for every GUI workflow remains valuable but
  should follow the workflow-level provenance fixes rather than lead them.
- Live database tests remain opt-in through `LUNGFISH_RUN_LIVE_DATABASE_TESTS=1`.
- Full end-to-end native/conda tool execution remains environment-gated.
- Large historical doc/comment cleanup for removed `LungfishPlugin` or
  `LungfishUI` names should be a separate repo-hygiene pass unless it blocks a
  touched file.

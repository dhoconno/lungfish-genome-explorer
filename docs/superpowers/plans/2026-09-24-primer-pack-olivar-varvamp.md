# Olivar and varVAMP Primer Pack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native, portable Olivar and varVAMP to the existing optional primer pack and expose their designs through the shared primer-analysis interface, with all varVAMP modes, meaningful size controls, complete provenance and real MHC validation.

**Architecture:** Keep four independently pinned environments in the existing pack. Versioned app-owned Python adapters translate typed requests to the pinned engines, preserve coordinate transforms and enforce output contracts; Swift workflows publish existing `.lungfishprimeranalysis` bundles containing an engine-neutral normalized payload. GUI and CLI share request validation and workflows; presentation components remain shared with PrimalScheme.

**Tech Stack:** Swift 6, SwiftUI/AppKit, existing SwiftPM/SwiftBuild tests, Python 3.12/3.13, micromamba, Bioconda, Olivar 1.3.3, varVAMP 1.3.2.

**Spec:** `docs/superpowers/specs/2026-09-24-primer-pack-olivar-varvamp-design.md` — approved by the user on 2026-09-24. The user selected Astra oversight with smaller focused implementation/testing agents.

## Global Constraints

- Work only in `.worktrees/primer-pack-olivar-varvamp`, branch `codex/primer-pack-olivar-varvamp`; do not merge, publish, or remove other worktrees.
- Retain optional pack ID `pcr-primer-design`; include `primer3`, `primalscheme3`, `olivar`, `varvamp` with one environment per tool.
- Pin Olivar `bioconda::olivar=1.3.3=pyhdfd78af_3` and varVAMP `bioconda::varvamp=1.3.2=pyhdfd78af_0`; retain the captured resolved locks/ABIs unless a new native smoke verifies a deliberate change.
- Preserve current Primer3 and PrimalScheme identities and saved documents. New engines must not impersonate PrimalScheme or its fork capability contract.
- All scheme controls validate `minimum <= target <= maximum`; target remains nominal where the engine does not optimize proximity. Olivar minimum is at least 120 bp; no silent clamps.
- varVAMP modes are `single`, `tiled`, `qpcr`; qPCR/dPCR UI wording must not claim a separate dPCR optimizer.
- Do not translate varVAMP consensus threshold to `1 - minimumBaseFrequency`.
- Never load user-supplied Olivar pickles. Keep original native files and use safe normalized payloads for reopening.
- Every scientific workflow/transform/export retains exact executed argv or replay command, tool and adapter version/hash, explicit and resolved settings, runtime identity, inputs/outputs with checksums/sizes, exit status, wall time and useful stderr. Final descriptors point to durable stored payloads.
- The source MHC project is read-only; create validation copies under this worktree. No pathogen fixtures or public sequence downloads are needed.
- No success claim until the actual pack install/export/import paths, focused tests, native MHC workflows and GUI behavior have been verified.

## Review Focus

1. A moved pack under a path with spaces must work with old prefixes absent, including Python launchers and MAFFT children (Task 1).
2. A primer crossing collapsed alignment columns must not receive fabricated row-level mismatch counts or a continuous original coordinate span (Tasks 2–4).
3. Unpooled qPCR alternatives must retain their probes and assay membership through selection and ordering export (Tasks 3–4).
4. Olivar no-feasible-pair and varVAMP dimer-repair size changes must fail publication rather than silently dropping tiles (Tasks 2–3).
5. Switching engines/modes or toggling Advanced Options must preserve applicable settings, reject incompatible settings, and save the actual resolved defaults (Tasks 3–4).

## Execution and shared boundaries

Task 1 and Task 2 can run independently with Sol implementers. Task 3 consumes their final runtime/adapter interfaces; Task 4 consumes Task 3's public models; Task 5 validates the integrated result. Astra controls model/schema decisions and reviews cross-task contracts. Use fresh focused task reviewers; serialize Swift builds to avoid duplicate full compilations and generated-artifact contention. The separate GenBank task owns another worktree and is not part of this plan.

Keep progress and review evidence in ignored `.superpowers/sdd/2026-09-24-primer-pack-olivar-varvamp/`. Preserve any local native smoke/MHC artifacts when finishing. Every task records its exact tests and commits; do not re-run unchanged tests solely for a reviewer.

## Task 1: Four-tool optional pack and portable managed launchers

**Files:**
- Modify `Sources/LungfishWorkflow/Conda/{PluginPack,ManagedToolLock,PluginPackStatusService,ManagedPythonRuntimeInstaller,CondaOfflinePackService}.swift` only where needed for typed lock/launcher and import readiness contracts.
- Create `Sources/LungfishWorkflow/Conda/PrimerToolPortableLauncher.swift`.
- Modify `Sources/LungfishWorkflow/Resources/ManagedTools/{third-party-tools-lock.json,bundled-payloads.json}`.
- Create `Sources/LungfishWorkflow/Resources/ManagedTools/{olivar,varvamp}-osx-arm64-explicit.txt` from verified smoke inventories and a checksum-bound typed lock reference in the tool manifest.
- Test `Tests/LungfishWorkflowTests/{PrimerToolPortableLauncherTests,PluginPackRegistryTests,CondaOfflinePackServiceTests,PrimerDesignRuntimePreparationTests}.swift`; CLI pack tests in `Tests/LungfishCLITests/CondaPacksCommandTests.swift` if affected.

**Interfaces:** `PrimerToolPortableLauncher.prepare(toolID: String, environmentURL: URL) throws` installs only recognized primer-tool launchers before runtime receipts are hashed. `PrimerToolPortableLauncher.validate(toolID: String, environmentURL: URL) throws` checks versioned launcher/entrypoint bytes, relative paths and helper locations. Preserve `PrimerDesignManagedRuntime.prepareAndAcquire(toolID:progress:)` and its lease semantics. Expose ordinary `olivar`/`varvamp` executables to existing pack consumers.

- [ ] Add a registry test that expects exactly four named primer requirements and checks distinct environments and pinned versions.

```swift
let pack = try XCTUnwrap(PluginPack.builtInPack(id: "pcr-primer-design"))
XCTAssertEqual(Set(pack.toolRequirements.map(\.id)),
               Set(["primer3", "primalscheme3", "olivar", "varvamp"]))
XCTAssertEqual(Set(pack.toolRequirements.map(\.environment)).count, 4)
```

- [ ] Add launcher tests using a temporary `source root/envs/<tool>` and a mock Python executable that records argv and `MAFFT_BINARIES`. Generate the launcher, move to `moved root`, remove the original prefix, execute, and assert both interpreter and preserved-script paths resolve inside the new environment. Corrupt the launcher and assert readiness rejects it. Test paths with spaces and repeated prepare calls.
- [ ] Run `swift test --build-system swiftbuild -j 4 --filter 'PrimerToolPortableLauncherTests|PluginPackRegistryTests'` and capture the expected failures before implementation.
- [ ] Add typed optional explicit-lock metadata and install from checksum-verified captured package URLs instead of a drifting solver result. Keep existing manifest decoding backward compatible. Ensure transactional install and receipts inventory new files; reject unsafe lock paths/URLs and mismatched checksums before mutation. Reuse the existing lockfile installer instead of introducing a second package manager.
- [ ] Implement relative launchers with same-environment Python and preserved upstream console scripts. Limit mutations to named primer tools, preserve permissions and record source/generated hashes. Olivar's run-local environment includes its relative `libexec/mafft`; no global shell/environment edits. Ensure PrimalScheme repair updates its managed receipt consistently and old valid tools remain usable while additions install.
- [ ] Register all four tools, native probes, sufficient cold-start timeout, license/source metadata and measured disk estimate. Verify status checks use the same launch path as workflows. Verify offline imports validate launcher/runtime readiness inside the existing rollback transaction.
- [ ] Re-run the above tests plus `CondaOfflinePackServiceTests|PrimerDesignRuntimePreparationTests|CondaPacksCommandTests`. Then opt into native installation under a fresh root, export the actual pack, import at a new path, remove source prefixes and run every tool plus MAFFT/BLAST probes. Record exit status, duration, runtime identity and final package hashes.
- [ ] Commit this tested pack/runtime change and produce a focused review package. Resolve material findings before marking Task 1 complete.

## Task 2: Versioned native adapters and scientific contracts

**Files:**
- Create `Sources/LungfishWorkflow/Resources/PrimerDesignAdapters/v1/{run.py,common.py,olivar_adapter.py,varvamp_adapter.py,contract.json,NOTICE,LICENSES/}`; add `.copy("Resources/PrimerDesignAdapters")` to the workflow resources in `Package.swift` and ensure native Xcode resources use the existing generated project/resource mechanism.
- Create `scripts/tests/test_primer_design_adapters.py` with synthetic in-memory fixtures; no external sequences.
- Keep source-inspection evidence in `.build/primer-engine-research`; do not ship entire development repositories.

**Interfaces:** Execute `<managed-env>/bin/python <run-owned>/adapter/run.py --request <request.json>`. `run.py` reads schema version 1, engine/mode, analysis/run/input/result UUIDs, input FASTA paths, output directory and typed options. Successful execution writes `adapter-result-v1.json` plus native outputs and mapping artifacts. `contract.json` declares adapter version, supported upstream distribution versions, verified source-file hashes, supported modes and coordinate conventions. The full adapter bytes are copied to each run for replay.

`adapter-result-v1.json` contains `schemaVersion`, `engine`, `engineVersion`, `adapterVersion`, `mode`, `resolvedOptions`, `results`. Each result contains `id`, `inputIDs`, and `targets`. Each target contains `id`, `label`, `referencePath`, `referenceID`, `referenceLength`, `sourceInputID`, `bindingProjectionPath`, `assays`, and `oligos`. Artifact paths are run-relative and cannot escape the output. Task 3 defines their Swift Codable equivalents.

Assays contain `id`, `start`, `end`, `memberIDs`, nullable `pool`, `status` (`selected` or `alternative`), optional `rank`, and native metadata. Oligos contain `id`, `name`, `role` (`forward`, `reverse`, `probe`), `sequence`, `start`, `end`, `strand`, `assayIDs`, nullable `pool`, and native metadata. Coordinates are zero-based half-open on the saved generated reference; pool is a nullable string. Binding maps contain exact source-column blocks or explicitly collapsed/synthetic blocks, never invented bijections.

- [ ] Add failing contract tests for unsupported versions, unsafe output paths, non-finite options, invalid mode/grouping, CSV/BED coordinate agreement, role/membership, reverse probes, and mapped versus collapsed gap intervals. Include this size guard behavior:

```python
self.assertTrue(accept_pair_length(200, minimum=180, maximum=220))
self.assertFalse(accept_pair_length(179, minimum=180, maximum=220))
self.assertFalse(accept_pair_length(221, minimum=180, maximum=220))
```

Define `accept_pair_length(length: int, *, minimum: int, maximum: int) -> bool` in `common.py`; reject invalid range before evaluating pairs. The Olivar integration test must prove this guard executes before a pair reaches SADDLE, not merely test the helper in isolation.

- [ ] Run `python3 -m unittest discover -s scripts/tests -p test_primer_design_adapters.py -v` and retain failures.
- [ ] Implement strict request validation, safe private output ownership, runtime/source verification, machine-readable errors, and deterministic resolved-settings capture. No evaluation of user Python or shell snippets.
- [ ] Implement Olivar build/tiling using the verified pinned API. Capture normal/degenerated MSA-to-consensus mapping, native min-var semantics and all output files. Adapt only the verified pair-list construction inside the native optimizer so final full-span lengths outside the inclusive request are excluded before SADDLE. Preserve upstream attribution, seed behavior and the rest of optimization. If a tile has no feasible pair, fail with a specific structured reason; do not delete completed tiles or silently widen bounds. Initially make one attempt per explicitly recorded seed; retries require a recorded bounded policy rather than hidden repeated searches.
- [ ] Implement varVAMP invocation with a generated supported `VARVAMP_CONFIG`, inherited by worker processes. Map minimum to native opt-length and maximum to max-length for single/tiled; set qPCR `QAMPLICON_LENGTH=(min,max)`. Retain nominal target as a distinct resolved UI field. Capture the native `process_alignment` mapping without altering its algorithm; verify cleaned output and source intervals. Expose native cumulative threshold separately. Use independent invocations for multiple input alignments.
- [ ] Normalize native results including full-span assays, explicit LEFT/RIGHT/PROBE membership, alternative qPCR assays, unpooled single/qPCR results, all IUPAC sequences, reference/mapping artifacts, and original native metadata. Independently recheck final span bounds after native dimer-repair routines. A contract mismatch fails before publication.
- [ ] Re-run adapter tests in both the installed native environments and the portable copied environments; include spawned-worker configuration propagation tests. Cold imports use writable run-owned cache paths and bounded timeouts.
- [ ] Commit resources/tests and produce a focused review package, particularly for changed Olivar pair semantics and varVAMP coordinate mapping.

## Task 3: Shared normalized model, workflows, CLI and durable provenance

**Files:**
- Create `Sources/LungfishWorkflow/PrimerDesign/{PrimerSchemeDesignOptions,PrimerSchemeNormalizedResults,PrimerSchemeInputPreparation,PrimerSchemeAdapterRunner,PrimerSchemeDesignPipeline}.swift`.
- Extend `Sources/LungfishCLI/Commands/PrimerDesignCommand.swift` with separate subcommand files `OlivarDesignCommand.swift` and `VarVAMPDesignCommand.swift` if needed to keep ownership focused.
- Reuse `PrimerAnalysisBundleWriter.swift` without relaxing its validation.
- Create `Tests/LungfishWorkflowTests/{PrimerSchemeOptionsTests,PrimerSchemeNormalizationTests,PrimerSchemePipelineTests}.swift` and `Tests/LungfishCLITests/PrimerSchemeCommandsTests.swift`.

**Interfaces:**

```swift
public enum PrimerSchemeEngine: String, Codable, Sendable { case olivar, varvamp }
public enum PrimerSchemeMode: String, Codable, Sendable { case single, tiled, qpcr }
public enum PrimerOligoRole: String, Codable, Sendable { case forward, reverse, probe }
public enum PrimerAssayStatus: String, Codable, Sendable { case selected, alternative }
```

`PrimerSchemeDesignOptions` contains engine/mode, grouping, nominal target/min/max, workers and typed `OlivarDesignOptions` or `VarVAMPDesignOptions`, with `validate() throws` and `provenanceOptions: [String: ParameterValue]`. Engine-specific options are exclusive; passing settings for the wrong engine is an error.

`PrimerSchemeResultsDocument` contains schemaVersion=1, analysisID, runID, engine, engineVersion, adapterVersion, mode and results. Its result/target/assay/oligo models exactly match Task 2's field names and zero-based half-open convention. `PrimerBindingProjection` retains the source input ID and verified mapping blocks. Stored path: `results/primer-schemes-v1.json`.

`PrimerSchemeDesignRequest` contains inputURLs, destinationURL, options, invocation (`PrimerAnalysisWrapperInvocation`) and expectedInputChecksums. `PrimerSchemeDesignPipeline.run(request:progress:) async throws -> URL` prepares the selected managed runtime, snapshots input, executes the copied adapter, validates and publishes. Inject runner/runtime-preparer closures for tests; explicit executable overrides must verify the same source/version contract and be recorded as overrides.

- [ ] Add failing options/CLI tests: target=min=max boundary, Olivar min119 rejection, varVAMP single/tiled/qpcr acceptance, unsupported combined varVAMP rejection, qPCR missing threshold rejection, NaN/infinity, reversed ranges, and bad CPU counts. Confirm PrimalScheme's existing default behavior is unchanged.
- [ ] Add fake-runner pipeline tests for a valid tiled result and a probe-bearing alternative qPCR result, plus invalid span, malformed map, missing probe, mismatched input/result UUIDs, duplicate names, corrupted artifact hash, nonzero child, cancellation and destination collision. Test unrecognized native files are preserved byte-for-byte.
- [ ] Run `swift test --build-system swiftbuild -j 4 --filter 'PrimerSchemeOptionsTests|PrimerSchemeNormalizationTests|PrimerSchemePipelineTests|PrimerSchemeCommandsTests'` to establish failures.
- [ ] Implement input snapshotting for native MSA/reference and aligned FASTA consistent with existing PrimalScheme input policy. Require actual equal-length alignments where needed; never silently use only the first record of multi-record input. Preserve row order/identities, source bytes and checksum checks. Use unique run-owned directories because varVAMP deletes its requested output path.
- [ ] Implement Codable models and strict validation: contained paths; finite properties; intervals within reference; legal IUPAC sequences; role/strand; referenced input identities; assay/oligo membership; qPCR LEFT+PROBE+RIGHT; optional native pool; generated reference and mapping coherence. Verify a normalized target cannot borrow another target's input or probe.
- [ ] Add `lungfish primer design olivar` and `lungfish primer design varvamp` with `--msa`, `--output`, target/min/max, grouping where supported, mode and typed advanced flags. Resolve every visible option through the same options model; preserve supplied versus default values. CLI help explains native semantics and identifies the LGE adapter.
- [ ] Execute `NativeToolRunner` with process cancellation and managed runtime lease, controlled PATH/MAFFT helper path/cache dirs, copied adapter/config and exact argv. Capture tool, preprocessing/normalization, wrapper and export provenance. Retain failures with useful diagnostics while never publishing a partial analysis as successful.
- [ ] Publish only through `PrimerAnalysisBundleWriter`, inventory all native/normalized/map/config/adapter/log/runtime files, and verify final-path provenance after staging deletion and after bundle relocation. Reading a bundle must not invoke Python or unpickle files.
- [ ] Re-run Task 3 tests plus `PrimerAnalysisBundleWriterTests|PrimerAnalysisBundleTests|PrimalScheme3PublicationTests`. Commit and review before the GUI depends on these contracts.

## Task 4: Shared dialog, viewport, Inspector, binding and ordering

**Files:**
- Modify `Sources/LungfishApp/Views/PrimerDesign/{PrimerDesignDialogState,PrimerDesignDialog,PrimerDesignDialogPresenter}.swift`, `App/AppDelegate+PrimerDesign.swift`, and `App/MainMenu.swift` only as required for engine availability/routing.
- Add focused `PrimerSchemeAdvancedOptionsView.swift` and `PrimerSchemeViewerAdapter.swift` under the existing primer UI directories.
- Modify `Views/PrimerAnalysis/{PrimerAnalysisViewerModel,PrimerAnalysisDisplayModels,PrimerDesignReview,PrimerBindingInspectionModels,PrimalSchemeResultsView,PrimerOrderExportView}.swift` through a small shared presentation extraction. Preserve old bundle-loading paths.
- Add `Sources/LungfishWorkflow/PrimerDesign/PrimerSchemeOrderSheet.swift` for generic order rows/provenance integration.
- Extend the existing Inspector sections and export services only where optional pools/probe roles/new metadata require it.
- Tests: `PrimerDesignDialogStateTests`, `PrimerDesignDialogVisualTests`, `PrimerDesignReviewTests`, `PrimerAnalysisRoutingTests`, `PrimerBindingInspectionTests`, new `PrimerSchemeViewerTests`, `PrimerSchemeOrderSheetTests`.

**Interfaces:** Extend `PrimerDesignEngine` with `olivar` and `varVAMP`; dialog state produces the Task 3 `PrimerSchemeDesignOptions`. `PrimerSchemeViewerAdapter` converts validated normalized targets into existing shared review/binding/display presentation, preserving IDs and optional scientific fields. Generic order rows carry stable oligo ID, role, sequence, assay IDs, candidate status and nullable native pool; explicit selection is an input, not inferred from what happens to be visible.

- [ ] Add failing tests that open the same selected inputs with each engine, switch varVAMP modes, edit min/target/max, toggle advanced settings twice, and assert the submitted request still contains the exact settings. Invalid configuration must disable Run with an actionable message.
- [ ] Add representative synthetic normalized documents: degenerate tiled primers, unpooled single assays, two alternative qPCR assays with reverse-oriented probes, and a collapsed mapping block. Assert selected assay export includes its probe, all-assay export keeps alternatives labeled, and a collapsed primer produces no invented mismatch count.
- [ ] Run the focused app and ordering tests to establish failures.
- [ ] Add tool/mode selectors and consistent basic sizing controls. Preserve existing PrimalScheme defaults; expose its already-supported minimum-base-frequency option rather than hardcoding zero. Olivar min-var retains native wording; varVAMP gets native threshold/auto controls, with a required visible threshold for qPCR. Do not silently supply an undocumented threshold when changing modes. Fixed two-pool engines show their actual pool behavior without an ineffective editable field.
- [ ] Implement the collapsed Advanced Options sections with validated typed bindings. Olivar: native risk weights, degeneracy, variant avoidance, GC bounds, primer maximum length/complexity, temperature/salinity, dimer bound, seed, effort, CPU, optional local BLAST database. varVAMP: threshold/ambiguity, tiled overlap, result/test limits, primer length/Tm/GC, dimer/hairpin/3-prime constraints, optional compatible-primer input and BLAST database, plus probe length/Tm/GC/ambiguity, probe-primer temperature difference/distance and secondary-structure controls in qPCR. Record native defaults for every exposed setting and reject settings unsupported in the selected mode.
- [ ] Reuse the same PrimalScheme viewport components for all scheme engines, including shared selection/zoom/filter state and Inspector. Distinguish scientific pool IDs from display groups. Show unpooled results as unpooled, probes as probes, and alternative assays separately. Present engine-specific native files and resolved options without displaying fictitious metrics.
- [ ] Extend binding inspection with the explicit Task 3 map: exact blocks support original-row comparison; collapsed/synthetic/discontinuous projections show their unavailable reason. Preserve generated-reference display and never fall back to first-row matching for new engines. Existing PrimalScheme first-row maps remain backward compatible.
- [ ] Implement probe-aware selected/all ordering export using generic rows and canonical provenance. Preserve untouched native ordering files. Reopening/exporting results works without installed engines.
- [ ] Re-run app/ordering tests and render representative dialog/viewport/Inspector screenshots. Inspect light/dark, long names, narrow window, advanced expanded and probe selection; test actual mouse selection/pan/zoom and shared Inspector updates. Commit and review.

## Task 5: Actual portable pack, MHC comparisons, integrated regression and delivery

**Files:**
- Create `scripts/analysis/validate-primer-pack-mhc.py` as an opt-in validation driver (not part of routine unit tests).
- Extend `Tests/LungfishAppTests/PrimerAnalysisNativeMHCViewerTests.swift` for explicit engine/mode expectations rather than inferring engine solely from Primer3-versus-other.
- Update `docs/features/pcr-primer-design.md`; add `docs/reports/2026-09-24-primer-pack-mhc-validation.md` with actual evidence and limitations.
- Store large fixtures/logs/screenshots outside SwiftPM build storage at `/Users/dho/Documents/lungfish-validation/primer-pack-2026-09-24/`. This execution correction prevents `swift package clean` from removing scientific validation evidence.

**Interfaces:** Driver takes explicit `--cli`, `--project`, `--output`, `--conda-root`, and `--workers`; never defaults output to the source project. It records an input checksum manifest, exact argv/config/runtime identities, result summaries and pass/fail for each case. It invokes public Lungfish CLI workflows; it does not directly synthesize production bundles.

- [ ] Add driver tests verifying output cannot alias the source project, a failed command cannot be reported passed, and result bounds/counts are read from validated saved output rather than guessed from exit 0. Run `python3 -m unittest discover -s scripts/tests -p test_primer_pack_mhc_validation.py -v`.
- [ ] Verify Task 1's four-tool install/upgrade and offline export/import against the actual changed registry. Relocate to a path with spaces with old prefixes absent; run through the same launcher/adapter paths as GUI/CLI. Inspect receipts and provenance after repair and import. Do not use the original disposable smoke launchers as evidence of product correctness.
- [ ] Copy the user's project `/Users/dho/Desktop/sandbox/mhc-primal-scheme/mhc-primal-scheme.lungfish` into worktree validation storage and checksum all source alignment payloads before/after testing. Preserve originals and existing analyses.
- [ ] Run baseline independent tiled comparisons on all 11 saved inputs using PrimalScheme, Olivar and varVAMP with the same 400-bp nominal target and 360–440 bounds. Record native no-feasible outcomes honestly; do not tune one engine silently until it looks successful. If input length or biology prevents a design, use additional declared compatible bounds as a separate case and retain the original outcome.
- [ ] Exercise varVAMP single and qPCR/probe modes on the same input set. qPCR uses native 70–200 bounds and a recorded nominal midpoint; require an explicitly supplied consensus threshold in the test case. Include a representative non-default advanced run per engine/mode, narrower and wider bounds, worker changes, degeneracy/frequency/consensus changes and ordering/export of probes. Every exposed option additionally has Task 3/4 forwarding/validation coverage; do not claim all numerical combinations were tested natively.
- [ ] Independently validate every published full-span size, coordinate/reference/map relation, primer/probe membership and provenance checksum/final path. Reopen copied bundles after deleting staging. Keep native logs for no-feasible designs and contract failures; never change their classification to make a test table green.
- [ ] Build the Debug app through the supported front door `python3 scripts/release/release.py debug --portable --jobs 4`. Launch only the validation project copy. Open actual outputs from all three scheme engines and every varVAMP mode, inspect advanced settings, shared viewport/Inspector, mouse interactions, probe selection, native file inspection and derived order export. Save screenshots and explicit pass/fail notes.
- [ ] Run the combined relevant Swift suites and Python adapter/driver suites once after integration; broaden only for changed code or unresolved risks. Run `git diff --check` and inspect the final diff for scientific provenance, resources and legacy compatibility.
- [ ] Commit validation/docs, then obtain an Astra whole-branch review with the complete branch diff, test/native/UI evidence and deferred findings. Fix material issues with a focused smaller agent, re-run covering checks, and re-review the fix. Report implemented behavior, exact verification and limitations. Leave the feature worktree available; do not merge/release/delete it without the user's request.

## Plan self-review

Every approved spec section has an owner: installation/portability → Task 1; sizing, frequency, upstream versions and maps → Task 2; generic storage/provenance and CLI → Task 3; consistent GUI/Inspector/probes/export → Task 4; copied MHC project and actual install/GUI verification → Task 5. The five Review Focus cases have explicit tests in their owning tasks. New source fields and cross-task signatures are defined above; existing public storage/runtime interfaces are reused. Unmet biological design constraints are reportable scientific outcomes, not permission to loosen UI promises or fabricate results.

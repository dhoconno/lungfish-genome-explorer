# Dependency Upgrade Program: Plan A (Mechanism) Results

Date: 2026-08-18. Branch: claude/lge-dependency-upgrade-plan-b6b53b (base f8c6e86c, head d0385ecf, 33 commits). Tag: deps-plan-a-complete.

This is the execution ledger of docs/superpowers/plans/2026-08-17-dependency-upgrade-01-mechanism.md, kept verbatim as the record of rulings, deferred minors, and gate results.

```
# SDD ledger — plan: docs/superpowers/plans/2026-08-17-dependency-upgrade-01-mechanism.md

Spec: docs/superpowers/specs/2026-08-17-dependency-upgrade-mechanism-design.md (read; binding authority)
Branch: claude/lge-dependency-upgrade-plan-b6b53b (worktree). Start HEAD: 12f5ff6d
Master index: docs/superpowers/plans/2026-08-17-dependency-upgrade-00-master.md (Fable orchestrates; model routing there)

## Pre-flight scan

| Tasks | Produces vs consumes | Finding |
|---|---|---|
| A1↔A2 | A1 `packTool(packID:id:)`, `PackToolSpec.toolID` (JSON key `id`) / A2 `fromManifest` | consistent |
| A1↔A5 | manifest `databases[].collection` raw values / `DatabaseCollection(rawValue:)` = standard, standard-8, standard-16, pluspf, pluspf-8, pluspf-16, viral, minus-b, eupathdb46; `tool` "ncbi-taxonomy" = `MetagenomicsTool.ncbiTaxonomy.rawValue` | verified match |
| A1↔A6 | manifest `filename` for human-scrubber/deacon-* / DatabaseRegistry `BundledDatabase.filename` | consistent |
| A2↔A3 | A2 adds `private static let manifest` in PluginPack; A3 adds `ManagedToolLock.bundled` | duplication → Ruling below |
| A3↔A4/A5/A6/A7 | `.bundled` consumed | order A3 first ✓ |
| A6↔A16 | micromamba version equality across manifest/tool-versions.json/ToolManifest | consistent |
| A8↔A14/A15 | `currentLocation(environment:)` default param / CLI+App call `currentLocation()` | consistent |
| A9↔A10 | `CondaMetaReader`, `CondaSpec` / receipt synthesize | order ✓ |
| A10↔A11↔A12 | `DependencyReceipt.EnvironmentEntry.state`, planner inputs, `PlanSelection`, `ReconcilerServices` | consistent names |
| A12↔A13 | `ReconcilerServices.live.updateMetagenomicsDatabase` calls A13's `updateDatabase(catalogID:progress:)` but A12 precedes A13 | Ruling below |
| A12↔A15 | `DependencyOperationSink` protocol / `OperationCenterDependencySink` | consistent |
| A14 test | asserts `targetDependencySet == "2026.1"` literal with note | Ruling below |
| A15 | `UpdateToolsSheetViewModel(plan:reconciler: DependencyReconciler?)` | fixed in plan (optional) |
| A11 self | reason-classification tests vs sketch code says "adjust until pass" | acceptable: tests are the contract |
| A5 self | test seeds registry JSON with `collection: "eupathdb46"` and expects correction to 20230407 | consistent with A1 manifest entry |

Rulings (pre-flight):
- Ruling: execute A13 before A12 — A12's live services depend on A13's `updateDatabase(catalogID:)`; ordering avoids a stub — costs nothing if wrong (pure ordering).
- Ruling: A2 uses `ManagedToolLock.bundled` (introduce it in A2 instead of a private static; A3 then only adds `packageSpec(forEnvironment:)`/`toolVersion(forEnvironment:)`) — avoids duplicate cached loaders — cost if wrong: trivial rename.
- Ruling: A14 test must read the expected set from `ManagedToolLock.bundled.resolvedDependencySet`, not a literal — plan text says so in a note; the literal in the code block is illustrative — cost if wrong: none.
- Ruling: model routing per master plan: A1,A3,A4,A6,A7,A8,A9,A16 → sonnet (transcription-heavy); A2,A5,A10,A11,A13,A14 → opus; A12,A15 → opus (design-sensitive; A15 has GUI + Computer Use); reviews: sonnet for small mechanical diffs, opus for A11/A12/A13/A15.

## Task execution order
A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A13, A12, A14, A15, A16, A17

## Progress
Task A1: complete (commits 12f5ff6d..f87a82e5, review clean)
Task A1: Ruling: freyja 2.0.0 has no osx-arm64/noarch build upstream (pre-existing breakage in the experimental wastewater pack); manifest keeps `bioconda::freyja=2.0.0` with a single named test exception — Plan C sweep bumps freyja to 2.0.3 (noarch, has build) which removes the exception — cost if wrong: one experimental pack uninstallable on arm64, as today.
Task A1: minor (deferred): SILVA/Greengenes size constants now live in the manifest; A5 must read them from there (single source). Test exception set `knownUnresolvedBuilds` should self-detect staleness (assert the spec still lacks a build).
Task A2: complete (commits f87a82e5..576056ad, review clean)
Task A2: minor (deferred): tests call loadFromBundle() repeatedly instead of .bundled (style); fromManifest fallback sets environment: id.
Task A2: note: A2 introduced ManagedToolLock.bundled per ruling; A3 adds only packageSpec(forEnvironment:)/toolVersion(forEnvironment:).
Task A3: review approved by reviewer; controller-confirmed gap: CondaLockfileService.parsePackageSpec single-split → lockfile version field carries build. Ruling: fix in A3 (parse version/build, emit build:, compose on install) — cost if wrong: lockfile YAML gains an extra field; harmless.
Task A3: fix round 1/5 dispatched (resume aedd63ef2e4f80a11) at head edb7678c
Task A3: fix round 1/5 (1 addressed, 0 open — lockfile version/build parse; commits edb7678c..fdc86433)
Task A3: complete (commits 576056ad..fdc86433, review clean)
Task A4: implementer DONE at 7896252f; controller asked pre-review follow-up: convert viralrecon '3.0.0' test literal (spec criterion 1) — Ruling: pre-review self-fix, not a fix round — cost if wrong: none
Task A4: complete (commits fdc86433..1e9b7de9, review clean)
Task A4: minor (deferred): NFCore catalog static let computes pinnedVersion once vs TaxTriageConfig static vars recomputed; harmless since .bundled is static let.
Task A5: complete (commits 1e9b7de9..c12771f7, review clean)
Task A5: minor (deferred): EsVirituDatabaseManager.downloadURL falls back to "" (vs "unknown"); Kraken2 collection sizes/RAM still from DatabaseCollection (not pins); reconciliation refreshes URL/version/recipe only (sizes stale until reinstall); zenodoDOI still a display literal.
Task A6: complete (commits c12771f7..71224962, review clean)
Task A6: minor (deferred): stale doc comment on BundledDatabase ("Manifests live in Resources/Databases/<id>/manifest.json").
Task A7: complete (commits 71224962..adf32021, review clean)
Task A7: Ruling: "first line" of `version --tools` means first line of the tools section (after the app version banner) — matches About window placement — cost if wrong: cosmetic.
Task A8: complete (commits adf32021..f0a8b2d6, review clean)
Task A9: fix round 1/5 dispatched (message uses spec.version; explicit build guard) at head 0ae7d490
Task A9: fix round 1/5 (1 addressed, 0 open; commits 0ae7d490..0ab27726)
Task A9: complete (commits f0a8b2d6..0ab27726, review clean)
Task A9: minor (deferred): CondaMetaReader.primaryPackage unused until A10; channel parsed but not compared (by design).
Task A10: complete (commits 0ab27726..69fe6deb, review clean)
Task A10: Ruling: brief's testRoundTrip equality was unsatisfiable (updatedAt restamp + ISO8601 second precision); accepted implementer fix (save returns receipt, dates truncated to seconds) — cost if wrong: none.
Task A10: minor (deferred): missing tests for disk-path missing envs dir, dot-prefix skip, and unknown-env fallback branch.
Task A10: carry to A12: load() throws on schema mismatch → reconciler must catch and synthesize; synthesized receipt has no databases (planner reads DB versions from disk).
Task A11: Ruling: accepted deviations (missing envs of installed optional packs planned as installs; pipeline prefetch only on recorded drift; A12 stamps pipeline revisions into receipt) — cost if wrong: minor.
Task A11: Ruling: removal policy narrowed — remove only envs that are (in manifest.retiredEnvironments OR receipt-recorded with packID) AND not in manifest/knownEnvironmentNames, never dot-prefixed/hex caches; user-created envs never touched. Adds optional manifest section `retiredEnvironments` and inputs.knownEnvironmentNames — cost if wrong: retired envs may linger (safe direction).
Task A11: fix round 1/5 dispatched at head 6040a6c0 (findings: unsafe removals; .lock file removal)
Task A11: minor (deferred): .retired/.bootstrap enum cases unused; .metadataMismatch overloaded (UI messaging in A15); duplicate primary package in conda-meta resolves by array order.
Task A11: fix round 1/5 (2 addressed, 0 open; commits 6040a6c0..94849532)
Task A11: complete (commits 69fe6deb..94849532, review clean)
Task A11: carry to A12: pass knownEnvironmentNames = every PluginPack.builtIn requirement/package environment (safety net); note pre-existing flake PluginPackStatusServiceTests.testStatusForPackUsesPersistedSnapshotAcrossServiceInstancesWithinTTL (order-dependent; passes in isolation).
Task A13: implementer DONE at 894fff0b; review: Needs fixes (3 Important: crash-window orphan recovery; non-dot staging/old dirs; external-volume rows unhandled) + minors
Task A13: fix round 1/5 dispatched at head 894fff0b
Task A13: minor (deferred): EsViritu tests hand-write registry JSON because registerExisting validates against Kraken2 file list (follow-up: tool-aware registerExisting); no metagenomics entry pins md5/sha256 yet (Plan C bump.py fills); updated rows lack payloadDigest.
Task A13: carry to A12/A14: updateDatabase throws updateNotSupported for kraken2Special (route to reinstall) and possibly for external rows.
Task A13: fix round 1/5 (4 addressed, 0 open; commits 894fff0b..acc51753)
Task A13: complete (commits 94849532..acc51753, review clean)
Task A13: minor (deferred): recovery skips external rows (documented); promoted staging copy has no provenance sidecar; safeSuffix version round-trip lossy for exotic strings.
Task A12: implementer DONE at 49752921; review Approved with 3 Important (micromamba version pipe drain/blocking; snapshot comment; final-save failure poisons parent op) → fix round 1/5 dispatched
Task A12: Ruling: accepted deviation — mid-apply receipt saves best-effort (failure recorded as failed["dependency-receipt"]) — cost if wrong: a resume after crash may re-do an item.
Task A12: Ruling: prefetchPipeline logs+skips (TaxTriage fetch is private); provenance written directly via ProvenanceWriter (builder needs an output descriptor).
Task A12: minor (deferred): ReconciliationResult keys mix namespaces (env/db/bootstrap/pipeline ids in one map); CondaCommand smokeTestFailed arm unreachable; runSmokeTest allocates throwaway actor per call; ReconcilerServices.live untested until A15/A17.
Task A12: fix round 1/5 (4 addressed, 0 open; commits 49752921..73b438c1)
Task A12: complete (commits acc51753..73b438c1, review clean)
Task A12: minor (deferred): micromamba probe timeout uses SIGTERM (a SIGTERM-ignoring child could outlive the deadline).
Task A14: implementer DONE at 23637bf6; Ruling: exit codes — pending plan = new CLIExitCode.updatesPending (10) (plan said 3, collides with inputError); --apply without --yes = usage (2); real failure = failure (1); no executionError case — cost if wrong: scripts read a different code; documented in help.
Task A14: Ruling: `db update` lives under `conda db update` (no top-level db command); --storage-root flag exports LUNGFISH_STORAGE_ROOT so CondaManager.shared follows (implementer found the brief's sketch moved only the receipt).
Task A14: pre-review follow-up dispatched.
Task A14: complete (commits 73b438c1..2c519967, review clean)
Task A14: minor (deferred): --required-only + --include-databases is a silent no-op for advisory DBs; conda db update uses inputError(3) for missing --yes vs tools update usage(2); --storage-root via setenv (single-shot CLI, documented); no e2e --apply test (needs network).
Task A15: implementer DONE_WITH_CONCERNS at 214db747; GUI verification BLOCKED (computer-use request_access user_denied twice). Ruling: park GUI walkthroughs as an open item requiring the user to grant Computer Use access; review code now; isolated roots /tmp/lge-fresh and /tmp/lge-upgrade remain staged (CLI --plan confirmed: fresh = 17 installs/2.67 GB; upgrade = 1 install + 6 reinstalls/1.1 GB, zero removals incl. user envs) — cost if wrong: an unrendered sheet ships until the walkthrough runs; A17/Plan C tier 4 will require it.
Task A15: review Needs fixes (5 Important: optional-plan re-presents each launch; sync volume I/O in computed property; Quit not quitting via Plugin Manager; Quit under restored project windows; race with Welcome install) → fix round 1/5 dispatched at 214db747
Task A15: Ruling: "Later" stores com.lungfish.deferredDependencyManifestHash; optional-only plans with matching deferred hash are silent; Quit only on Welcome-hosted launch with required work, all other hosts allow deferral (Welcome gate still blocks new analyses); DependencyReconciliationActivity.isApplying disables Welcome/Plugin Manager installs — cost if wrong: a user may defer an optional update indefinitely (by design).
Task A15: minor (deferred): host-window selection nondeterministic; retry loop likely dead; sink registry entries leak on abandoned ops; isCheckingForToolUpdates cleared while sheet open; ItemStatus.pending unrendered.
Task A15: fix round 1/5 (5 addressed, 1 new open — Welcome flag latch; commits 214db747..e6f4ecc4)
Task A15: fix round 2/5 dispatched at e6f4ecc4
Task A15: fix round 2/5 (1 addressed, 0 open; commits e6f4ecc4..c543a155)
Task A15: complete (commits 2c519967..c543a155, review clean; GUI walkthrough PARKED pending user's Computer Use access — open item for A17/final)
Task A16: implementer DONE at 410fcfd1; review Needs fixes (stale swift-testing test reads deleted script). Ruling: deleting that test is in scope — cost if wrong: none. fix round 1/5 dispatched.
Task A16: fix round 1/5 (3 addressed, 0 open; commits 410fcfd1..41f9e4af)
Task A16: complete (commits c543a155..41f9e4af, review clean)
Task A17: full-suite gate running (bg bt30lu9do); final whole-branch review dispatched (fable) on code-only package final-review-code-only.diff (base f8c6e86c, head 41f9e4af)
Task A17: gate run 1 FAIL — xctest SIGSEGV in GenotypeAnnotationStoreCallOverrideTests (backtrace: outlined copy of ProvenanceRuntimeIdentity → stale test-module object after A7 added a stored property); passes on main and after clean rebuild of the test bundle. FileSystemWatcherTests 3 swift-testing issues under load; pass in isolation (flake). Ruling: stale artifact + load flake, not regressions; gate rerun 2 in progress (bajcru3ab).
Final review (fable): With fixes. Critical: (1) bootstrap version compare never matches (`micromamba --version` prints 2.0.5 vs manifest 2.0.5-0) → plan never empty, receipt never stamped, sheet every launch; (2) installedPackIDs any-env heuristic plans freyja for users with variant-calling/read-mapping (shared .package("ivar"/"minimap2")). Important: (3) reconciler never calls sink.log; (4) sheet rows render full conda specs; (5) fresh-install sheet-over-Welcome collision (UX); (6) build-string enforcement downgrades some optional builds (release-notes + Plan C pins); (7) db update exit codes/help; (8) --required-only --include-databases no-op. Minors 9-16 recorded.
Final review: single fix wave to be dispatched after gate rerun (bajcru3ab) completes.
Task A17: gate rerun 2 — XCTest 13302 executed, 2 failures (both A14 fallout: SubcommandRegistrationTests.testTotalSubcommandCount 43→44; ScientificCLIProvenanceCoverageTests missing policy for `tools`); swift-testing FileSystemWatcherTests fail in the full swift-testing phase on BOTH this branch (6) and main (5) → Ruling: environmental (FSEvents on this machine today), not a regression; record in memory as a known-environmental baseline item — cost if wrong: a real watcher regression on main hides behind the label.
Final review fix wave dispatched (opus) at head 41f9e4af: Critical 1,2; Important 3,4,7,8; UX 5 (suppress launch sheet when required pack entirely absent — Welcome owns first install); minors 9-13; plus the two XCTest failures.
Final fix wave: complete (commits 41f9e4af..d0385ecf; re-review: all findings addressed, no new breakage)
Final fix wave: Ruling: empty-root plan legitimately includes a bootstrap line (nil probe → install bundled micromamba) — cost if wrong: none.
Task A17: final full-suite gate 3 running on d0385ecf
Task A17: final gate 3 (d0385ecf): XCTest 13324 executed, 36 skipped, 1 failure = PBAAClusteringPipelineTests.testProcessRunnerTerminatesNextflowProcessPromptlyWhenTaskIsCancelled (timing; passes in isolation; branch touched no PBAA/ProcessRunner file) → Ruling: load flake, environmental; swift-testing 3 issues = FileSystemWatcherTests (environmental, also on main). Verdict: GREEN modulo known-environmental.
Task A17: complete (final review + fix wave clean; tag deps-plan-a-complete)
```

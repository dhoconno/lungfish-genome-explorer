# Validation, inventory, and assessment limits

## Baseline and working-tree policy

- Source commit: `13e114087b1c0a994ad1d957ce7d71b963e5575d`.
- Date: 2026-09-05, America/Chicago.
- Machine observed: Apple Silicon, macOS 26.6.2 (25G83), Apple Swift 6.3.3 / swift-driver 1.148.6.
- Initial `git status --porcelain` was empty. The audit added only this report directory and the linked implementation-plan Markdown file. No production Swift, tests, project configuration, release configuration, lockfiles or existing documentation were edited.
- Builds/tests used existing local dependencies and disposable fixtures. Build caches and temporary files changed as a consequence; “code untouched” does not mean the filesystem was bit-identical after validation.
- No commits, branches, PRs, releases, publication, credential changes, tool provisioning, or real-data workflow runs were performed.

## Executed validation

| Check | Actual result | Evidence / interpretation |
|---|---|---|
| `swift build --product lungfish-cli` | Exit 0; incremental build 5.54 s | [cli-build.log](evidence/cli-build.log); verifies current source through SwiftPM's build graph, not a clean-room or packaged-app build |
| Provenance selection below | Exit 0; build 7.97 s; 32 XCTest + 41 Swift Testing cases passed | [provenance-tests.log](evidence/provenance-tests.log) |
| Lifecycle/storage selection below | Exit 0; build 6.29 s; 29 XCTest cases passed | [lifecycle-tests.log](evidence/lifecycle-tests.log); separate Swift Testing harness had zero selected tests, which is expected here |
| Current CLI synthetic numerical probes | Exit 0 with incorrect expected values | [cli-probes.json](evidence/cli-probes.json); N50 3 versus expected 2; invented cross-record adjacency |
| Current CLI failed forced conversion | Exit 1; original destination already replaced | Same evidence; confirms failure changes data without completed provenance |
| Current CLI same-path conversion | Exit 0; consumed-input digest equals new output digest instead of old input | Same evidence; old/new digests retained |
| Canonical provenance replay fixture | Exit 0; emitted historical argv rather than durable argv | Same evidence; fixture isolated from real source-chain lookup |
| Extracted actual gate functions + fake runner | Both zero-test and crash-then-retry scenarios exit 0 / GATE PASS | [gate-probes.log](evidence/gate-probes.log); independently repeated by root reviewer |
| Focused release Python selection | Exit 1; 118 reported, 117 passed, 1 module import error; 124.343 s | Reviewer execution recorded in [quality-release.md](quality-release.md); missing `yaml`, not an assertion failure |
| Release skill validator | Passed | Exact command recorded in quality report; no actual package/publish |
| Release CLI help commands | All exited 0 | Help only for top-level/doctor/package/publish/debug |
| Independent skeptical source review | Highest-risk chains upheld, wording tightened | Reviewer cross-checks summarized below; no runtime claims added |

The two fresh Swift selections passed **102 cases total**. This is deliberately not called a whole-suite pass. The repeated earlier skip-build orientation run is excluded from this count. The Python selection is not described as green: both ambient Homebrew Python and the existing parity verification Python lacked PyYAML; no dependency installation was performed to conceal that environment mismatch.

Commands for the fresh Swift selections:

```sh
swift test --filter 'ProvenanceFileHasherTests|ProvenanceBuilderTests|ScientificFileExportProvenanceTests|ScientificCLIProvenanceCoverageTests'
swift test --filter 'OperationCenterLockingTests|SidebarImportPlannerTests|VariantDeletionMutationServiceTests|ProjectFileTests|ProjectSessionRegistryTests'
```

The recorded Python selection:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest scripts.tests.test_release_contract scripts.tests.test_release_frontdoor scripts.tests.test_release_cache_fingerprint scripts.tests.test_release_artifact_receipt scripts.tests.test_full_suite_gate_tiers scripts.tests.test_ci_workflow scripts.tests.test_releasing_lungfish_skill
```

Exact gate reproduction code is embedded in the quality report. The current-CLI evidence records command arguments, stdout/stderr, exit values and expected-versus-observed data. Temporary paths are not permanent deliverables. The report preserves enough input text and schema fixture data to rebuild probes without those directories.

## Codebase inventory

Counts include blank lines/comments and embedded scripts in `.swift` files; they are size indicators, not executable LOC or quality scores. Generated dependencies under `.build`, resource files and non-Swift scripts are excluded.

| Top-level source module | Swift files | Physical lines |
|---|---:|---:|
| Lungfish | 1 | 77 |
| LungfishApp | 465 | 222,662 |
| LungfishCore | 90 | 30,490 |
| LungfishIO | 202 | 91,107 |
| LungfishWorkflow | 376 | 194,459 |
| LungfishCLI | 102 | 56,372 |
| LungfishKit | 63 | 14,714 |
| LungfishAlignmentUI | 1 | 321 |
| LungfishAssemblyUI | 7 | 1,960 |
| LungfishEsVirituUI | 6 | 5,553 |
| LungfishGenotypeUI | 56 | 50,176 |
| LungfishNaoMgsUI | 5 | 4,073 |
| LungfishNvdUI | 3 | 3,116 |
| LungfishPhylogeneticsUI | 2 | 1,912 |
| LungfishTaxTriageUI | 7 | 7,308 |
| LungfishTwelveSUI | 11 | 3,101 |
| **Sources total** | **1,397** | **687,401** |
| **Tests total** | **1,054** | **462,862** |

Largest examples: `GenotypeResultViewController.swift` 12,168 lines, `GenotypeComparisonMatrixView.swift` 8,603, `ONTBarcodeDemuxGenotypingPipeline.swift` 5,815, `AnnotationTableDrawerView.swift` 5,344. `GenotypeWorkbookRevisionServiceTests.swift` is 12,665 lines. These sizes make focused ownership boundaries worth reviewing; they do not establish a safe deletion percentage. Test lines are about two-thirds of production Swift lines, but that ratio says nothing about the value or coverage of individual tests.

## Independent review and rejected overclaims

Three focused reviewers assessed architecture; user journeys; and testing/releases. The coordinating reviewer assessed provenance, generic numerical correctness, evidence and the implementation plan. Each then skeptically checked another report's highest-risk claims against source.

Corrections and qualifications retained in the packet:

- Normal `.lungfishfastq` ZIP import does not take the suspected early-cleanup sheet path. The remaining embedded-payload scenario is conditional and subordinate to native-bundle dispatch; it is not an independently reproduced ordinary ZIP failure.
- The project Save/Save As gap does not mean no `save(_:)` exists anywhere. A folder metadata sheet has its own save action. Autosaved project data loss is not inferred from inert project menu actions.
- Fast settings tab departure demonstrably cancels delayed credential persistence. Closing a retained settings window needs actual AppKit lifecycle validation. Explicit Clear All has an immediate path and is not the same defect.
- Native bundle flattening is established for ordinary MSA/tree bundles. Earlier ONT-content detection can route some other packages differently; the report does not claim identical flattening for every possible bundle layout.
- A passing isolated test retry is not evidence that the original full process completed. The fake runner proves a gate property, not an observed real Swift process crash.
- Missing expected database digests are different from missing received-payload provenance. The installer does record what it downloaded; the gap is reproducibility/enforcement of the approved catalog identity.
- MainActor I/O paths were confirmed; stall duration and memory figures were not measured. No invented benchmark appears in the report.
- No claim is made that current release signing, receipt verification or update signatures are bypassed. The principal release issue is the evidence being authorized, not the cryptography.

## Feature validation matrix for the implementation stage

The workflow report inventories 16 families. The following is the smallest useful *runtime completion* matrix, not a claim it ran during this source audit. Each row needs an owning maintainer, result artifact and any intentionally unsupported combinations. Use existing fixtures where their licensing and semantics are understood; prefer small invented records for lifecycle behavior.

| Family group | Success path | Failure/recovery path | Persistence/export check |
|---|---|---|---|
| Project/window | Open/create, two windows, independent selection | Locked/future/malformed project, late load, close during work | Read-only unchanged; reopen/copy scope; no wrong-window document |
| Native objects | Finder, panel, drop and ZIP each preserve object identity | Malformed manifest, nested package, unavailable volume | One object, complete bundle, final provenance after relocation |
| Reference/annotation | Import and inspect records/annotations | Invalid input, helper startup failure, sidecar obstruction | Export/reimport annotations; selection and edited snapshot preserved |
| Raw read import | Single, paired, run folder and sample sheet | Bad pair/cardinality, missing member, cancel | Bundle counts/source identities and final stored paths |
| Read operation families | Representative shared runner success and result navigation | Missing tool, nonzero exit, cancellation at startup/work/publication | No partial complete bundle; inspect options and re-run safely |
| Alignment/variant | Open with required reference/index and inspect coordinate | Missing reference/index, malformed file, interrupted mutation | Boundary coordinates and sample identifiers round-trip; retained recovery |
| MSA/tree | Native open/import, select, export | Unsupported input, missing dependency, multi-file drop | Topology/alignment object identity and annotation/source linkage |
| Classification/result tables | Import existing harmless fixture; table/search/result navigation | Missing analysis database, rebuild failure and retry | Relocate/reopen with cross-links; no unvalidated interpretation claims |
| Assembly results | Existing fixture table/plot/contig navigation | Empty/malformed summary, missing payload | Nx consistency and selected-record export scope |
| Genotype/12S | Existing fixture viewers and revision inspection | Missing workbook/artifact and invalid revision | Existing manual edits/revisions remain independent and traceable |
| External app migrations | One documented supported fixture per adapter | Unsupported records and mixed-validity archive | Per-item conversion report; preserve raw source if configured |
| Workflow registrations | Add/reload/enable/locate | Missing/invalid source, duplicate ID, unavailable runtime | Stable registration identity and declared linked/copy semantics |
| AI/settings | Fake provider/context and fast field commit | Missing key, provider error, storage failure | Saved values, disclosed recipient/context; no real secrets in logs |
| First-run/offline | Viewer-only entry and on-demand dependency state | Offline/missing runtime, interrupted install | Retry/repair action and truthful readiness |
| Exports | Correct source/count/destination across formats | Existing destination, failed sidecar, moved source | Final hashes, complete provenance, executable retained replay |
| Installed app/update | Signed channel identity, open/reopen and updater route | Interrupted feed publication, higher-build correction | Candidate evidence, data/schema compatibility and client recovery |

Cross-cut each relevant row with single/multiple input, malformed/missing input, read-only destination, changed frontmost window, cancellation/retry, and close/reopen. Do not multiply every axis into an enormous redundant Cartesian suite: select cases that exercise distinct contracts and use one representative per shared mechanism, with extra tests only for adapters with different behavior.

## Unverified areas and limits

This was a broad, traced engineering assessment of a large repository, not line-by-line verification of over a million Swift/test lines. It did not execute all analytical tools, install all dependency packs, launch/render every AppKit/SwiftUI view, inspect user credentials, or run a notarized release/update cycle. It did not measure line/branch coverage, semantic test redundancy, accessibility, localization, frame rates, peak memory, clean-machine installation, or current remote release/feed state.

No complete security threat-model review of archives, downloads, web rendering, AI providers, SQLite extension behavior or all process runners was performed. Source-level AI boundaries and release supply-chain controls were sampled. There is no assertion that all parsers handle every malformed input, that all format conversions are lossless, or that outputs are biologically appropriate. These boundaries are why the plan contains explicit runtime/fault/replay acceptance gates rather than a blanket “all features work” conclusion.

The requested audit/report/implementation plan is complete as a review packet. Implementation, full runtime qualification and release signoff are separate future work.

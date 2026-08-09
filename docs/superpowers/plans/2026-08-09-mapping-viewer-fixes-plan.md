# Mapping Viewer Fixes — Phased Implementation Plan (2026-08-09)

Spec: `docs/superpowers/specs/2026-08-09-mapping-viewer-fixes-spec.md`. Branch `worktree-mapping-viewer-fixes` off main b6ad0dd9. TDD throughout (tests first, red, then green). **Per-phase review gate**: an independent reviewer subagent reviews the phase diff before the next phase starts; orchestrator adjudicates and loops until clean.

## Binding execution rules
- **Serialize ALL swift invocations** — single `.build` lock. One implementer subagent at a time; the orchestrator runs no `swift` while any implementer may be building. `swift build/test --package-path <worktree> --skip-update`.
- Green-bar = XCTest failures ⊆ 9 known-environmental (+`testSRASearch` NCBI flake) AND swift-testing 0.
- OperationCenter ops: BOTH `update()` and `log()`. UI-from-background: `DispatchQueue.main.async { MainActor.assumeIsolated { … } }`. No `runModal`, no `Task{@MainActor in}` from GCD, no `%s` in `String(format:)`.
- Each phase: write failing tests → confirm red → implement → green → self-verify (run the phase's tests + a build) → hand diff to review gate.

## Phase 0 — Shared test scaffold (prereq for Item 1 + Item 2 real-path tests)
Resolves QA BLOCKERs 1 & 2.
1. Add `Tests/Support/LungfishTestSupport/` helper (or extend existing support target) that builds a synthetic `.lungfish` project on disk in a temp dir: `Test.lungfish/Reference Sequences/src.lungfishref` (real manifest + genome payload) and `Test.lungfish/Analyses/run/viewer.lungfishref`, with a helper to run the real `MappingViewerBundlePreparer` symlink step and to set matching/mismatching `identifier`s.
2. Commit a bgzip+GZI sarscov2 genome fixture (`genome.fasta.gz`+`.fai`+`.gzi`) under `Tests/Fixtures/sarscov2/`, OR provide an in-test synthesizer (BgzipReaderRegressionTests pattern) exposed from the support target. At least the helper that yields a bgzip-backed source bundle.
3. Verify the scaffold compiles and a smoke test (build both bundles, assert the genome symlink exists) passes — this is pure fixture infra, no product change yet.
Review gate 0: fixture realism (matches production layout), no external-path reads, both plain + bgzip payloads available.

## Phase 1 — Item 1: validator symlink fix (SECURITY-CRITICAL, lands first; Item 4 depends on it)
1. **Tests first** (red), per the QA test list:
   - LungfishCoreTests: default-strict-behavior; owned-top-level-symlink-into-origin accepted; leaf-file symlink rejected even with origin; target-outside-origin rejected; all security negatives (absolute origin, `..` origin, non-`.lungfishref` origin, mismatched identifier, chained-origins-no-recursion, origin=ancestor-of-viewer, origin-outside-project-root, nested-symlink-escape-past-origin); file-identity checks (private/tmp alias, NFC/NFD, case-variant).
   - LungfishAppTests (real path via Phase 0 scaffold): prepared viewer bundle opens + `fetchSequenceSync` byte-for-byte equals source (bgzip branch); second contig at non-zero offset; `@/` project-relative origin opens; viewer-bundle-outside-project stays strict (pin behavior); record-store/annotation-index resolves through symlinked `metadata/`/`annotations/` dir; no-originBundlePath rejects top-level symlink.
2. **Implement** (spec Item 1 hardened rule):
   - `BundleManifest.validatedBundleMemberURL` gains `allowedEscapeRoots: [URL] = []`. Keep lexical `isSafeBundleMemberPath` + unresolved-candidate `isDescendant`. When the post-resolution re-check fails, permit ONLY IF (a) first path component is a bundle-owned top-level symlink AND (b) resolved candidate is contained in an allowed root — containment by **file identity** `(st_dev, st_ino)` walking the parent chain (resolve symlinks both sides), NOT string prefix.
   - New LungfishIO helper on `ReferenceBundle`: derive `allowedEscapeRoots` from `manifest.originBundlePath` using `FASTQBundle.resolveBundle` + `findProjectRoot`, enforcing ALL origin constraints (validate the origin string; inside same project root; `.lungfishref`; origin `manifest.validate()` passes; identifier == viewer identifier; not ancestor/HOME/`/`/volume-root; depth=1 no transitive). Store `private let allowedEscapeRoots: [URL]` in all three inits before member checks.
   - Expose public `ReferenceBundle.memberURL(for:field:)` (wrap :760 helper). Migrate viewer-bundle display call sites (Finding 3 list) + direct pipeline callers to it / to the escape-root-aware path.
   - Preparer Finding 2 guard: only emit `@/` origin when the viewer bundle has a project root.
   - Refactor `ReferenceBundleSourceResolver.manifestOriginBundleURL` onto the shared IO helper.
3. Green; self-verify; **Security re-review gate**: the security auditor subagent re-pentests the IMPLEMENTED code (not the spec) against its own attack list — must return APPROVE. Plus a general Swift review gate.

## Phase 2 — Item 2: bundle display name (independent of 1; serialized for build lock)
1. Tests first (red): additive kernel seam present; mapping contig cell shows bundle-name primary + contig secondary (omit when equal); `columnValue`/copy/sort/reselection keep contig id; filter matches display label (and the intentional all-rows-match test); reference record cell; track header single vs multi-contig (parenthetical, no em dash) + nil-cache fallback + navigate-hot-path; `documentTitle` unchanged when manifest supplied.
2. Implement: additive `secondaryCellText(for:row:)` on `BatchTableView` (default nil); decouple `cellContent` from `columnValue` for sequence/contig columns; new `viewerBundleManifest`/`displayName` field on `ReferenceBundleViewportInput.mappingResult` (NOT `manifest`); cache bundle display name on `ViewerViewController` at context activation; shared display-label helper for track header + tables; `#if DEBUG testTrackNames`.
3. Green; self-verify; review gate (watch the at-risk exact-string/model tests updated in lockstep, not broken silently).

## Phase 3 — Item 3: read selection → copy/extract FASTA (independent; serialized)
1. Tests first (red): formatter (headers with region/strand/cigar/mapq; reverse-strand; `10S80M10S` length 100; `*`/empty skipped w/ count; hardclip annotation); menu branch (read menu before annotation menu, disabled at zero selection, right-click-replaces-selection); UUID→QNAME mapping incl. mate pair; extraction config persists ID file + CLI replay + provenance + OperationCenter; CLI parse (`--no-keep-read-pairs` rejected in BAM mode, `-F 0x900` default, dedup off); CLI/service integration on a crafted SAM→BAM (secondary/supplementary/dup/mate/singleton).
2. Implement: extract testable menu-build + formatter seams; read branch in `rightMouseDown` via `FASTASequenceActionMenuBuilder`; multi-read FASTA formatter (aligned-orientation, annotated headers, skip `*`); `extractSelectedReads` cloned from `extractOverlappingReads` template w/ full OperationCenter; NEW `ReadExtractionService.extractByReadIDsFromBAM` (samtools `-N`, `-F 0x900` default, singleton routing); CLI `--by-id --bam` (validation source-XOR-bam, `--read-format` on by-id path, `--include-secondary`/`--exclude-duplicates` flags, materialized+persisted ID file).
3. Green; self-verify; review gate.

## Phase 4 — Item 4: dots for reference match (depends on Phase 1 landed)
1. Tests first (red): three-valued classifier (`=` in SEQ → match; explicit CIGAR `=`/`X`; read N never a dot; ref N/non-ACGTU no-call neutral; IUPAC documented-limitation; refBytes-window-miss → MD fallback; no-ref-no-MD all-mismatch; MD deletion runs). Badge seam (message shown when no-ref-no-MD; absent when ref loaded or MD present). Toggle hint label.
2. Implement: extract three-valued render classification from `ReadTrackRenderer.drawReadBases` (mismatch-letter / match-dot / neutral-N); fix `=`/N/ref-N rules; badge via `drawTrackLoadingBadge` seam + condition property "No reference: all bases shown as mismatches"; inspector toggle label hint. KEEP 4.0 px/base threshold.
3. Verify end-to-end that with Phase 1 landed, a real minimap2-style bundle now renders dots (Computer Use GUI smoke per project rule: launch `.build/debug/Lungfish`, open a mapping bundle, confirm reference loads + dots appear). Review gate.

## Phase 5 — Whole-branch verification, final review, merge
1. Full suite `swift test --skip-update`; confirm green-bar definition. Investigate any XCTest failure not in the known-9; 0 swift-testing failures required.
2. Whole-branch review (requesting-code-review skill) across all four items; security auditor final sign-off on the merged Item 1 code.
3. Results report to `docs/reports/2026-08-09-mapping-viewer-fixes-results.md`.
4. **Merge to main** (user-confirmed 2026-08-09): fast-forward/merge branch → main, then ExitWorktree remove. Push only if user's workflow expects it (main memory: release flow pushes; here just merge locally unless asked).

## Sequencing & parallelism
Phases run sequentially (build-lock serialization). Within a phase, one implementer subagent. Phase 0 → 1 → 2 → 3 → 4 → 5. Items 2 and 3 are logically independent of 1, but serialized for the lock; 4 must follow 1. Model choice: implementers = swift-expert or general-purpose (Sonnet-class) per Fable's discretion; review gates = swift-expert + security-auditor (Item 1) / qa-expert (test-heavy phases). Orchestrator (Fable) adjudicates every gate.

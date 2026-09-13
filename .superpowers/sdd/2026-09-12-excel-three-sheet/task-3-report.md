# Task 3 production integration report

## Result and scope

Production current and filtered exports now use the shared schema-2 three-sheet renderer. New focused adapters replace the production use of legacy worksheet mutation; the old script remains intact for legacy test/history context. No scientific calling rule, inference threshold, private project, or unrelated worktree was changed.

Full current exports use catalog/validated CSV evidence and the exact call roster. Samples are the authoritative roster followed by deterministic exact call-only IDs. Call-only evidence is null and review-ineligible, never synthetic zero. Annotation-only refresh retains full semantic calls using the captured snapshot, baseline-attested retained presentation, trusted legacy baseline, or recorded initial scientific/manual authority. Empty pipeline strings remain available baselines; nil remains unavailable.

Filtered exports preserve captured cells independently of row membership (including `[null,5]` beside a retained same-row value). No-projection/headless exports retain minimum-read threshold semantics but now produce exactly three sheets. Headless manual assignments and active-definition palette are resolved using existing authorities.

Active palette and exact per-slot source/status/baseline availability pass through UI snapshot, CLI, canonical fingerprint schema 4, retained presentation input and renderer. Equivalent palette ordering has an identical fingerprint; color/presentation-schema changes invalidate it. Sidecar review enum values map to the importer’s dashed tokens without changing biological meaning.

The renderer is the final XLSX writer and its trusted manifest is passed directly into schema-2 attestation. Semantic no-ops byte-copy the existing cached package instead of re-saving it. Existing admission, pending-v1-edit, no-clobber, atomic publication, rollback and retained-source mechanisms remain in use.

Scientific provenance retains script, payload, layout and presentation inputs in final bundle/output locations; exact executed argv and durable replay argv remain distinct. Runtime, versions, resolved defaults, input/output hashes/sizes, status/timing and stderr remain recorded. Filtered tests delete staging before verifying retained renderer/payload descriptors still resolve.

## Verification

TDD observations included: legacy 14-sheet current output; legacy filtered shape; omitted-null summary failure; annotation refresh dropping the call band; palette API/fingerprint omissions; non-idempotent ZIP timestamps; sidecar metadata-only revision failing admission; missing candidate tints; absent headless manual calls; missing initial manual annotation-refresh calls. Each received a focused regression and implementation change. Existing initial MiSeq provenance compatibility was identified by the affected run and fixed without weakening its test.

Final focused command: `swift test --jobs 6 --filter 'GenotypeWorkbookRevisionServiceTests.testThreeSheet|GenotypeWorkbookRevisionServiceTests.testAnnotationUpdateAcceptsInitialMiSeq|GenotypePivotFilteredCopyTests.testThreeSheet|GenotypeCurrentWorkbookInputFingerprintTests|GenotypeEffectiveHaplotypeProjectionTests|GenotypeResultViewportCandidateDetailTests.testCandidateRowsRemainExcluded|Genotype(ThreeSheet)?EditableWorkbookTests'`.

`/tmp/lungfish-task3-final-verification.log`: **66 tests, zero failures**, including first manual annotation refresh. Earlier `/tmp/lungfish-task3-final-green.log` passed 43 tests with zero failures, including current/filtered regressions, schema/color fingerprints, effective projection and manual UI sources. `git diff --check` passed.

After making candidate ARGB alpha retention explicit, `/tmp/lungfish-task3-tint-final.log` passed the dedicated candidate-evidence/tint test (1 test, zero failures).

The broad affected run `/tmp/lungfish-task3-affected.log` executed 228 tests with 84 failure assertions (50 unexpected), spanning 56 failed methods. This is not a green integrated suite. One genuine initial MiSeq defect is fixed; 55 obsolete-layout/initial-authority/counter cases are explicitly assigned to Task 4. Exact names and rulings are in `task-4-migration-handoff.md`; no failing test was skipped or removed. The original importer (10), schema-2 importer (12), effective projection (11), and fingerprint (24) suites passed in that run.

## Self-review / bounded follow-up

Task 4 owns the bounded old-layout test migration; Task 5 owns final visual/interactivity acceptance. Their failures are not silently classified as successful guards: removed-sheet mutation helpers must be migrated so the original post-attestation/no-clobber protections are actually exercised again.

Existing analyst style transport still needs Task 5’s explicit scope: `MatrixStyle` has optional string fill/text/border colors, legacy bold/italic flags and optional boolean overrides. This adapter currently carries fill only (row/cell, not column-style inheritance). The captured viewport row/cell style model contains fill and border, but the serializer previously carried only fill; the richer rendered font/style state is not yet captured. Comments/raw evidence/Notes semantic authority are retained. Candidate category fallback retains configured RGBA tint in ARGB form. Task 5 also owns FP/FN visible formatting, worksheet protection flags, adjacent H1/H2 layout, widths, audit toggle and native/cohort QA.

No native Excel acceptance is claimed here. No original private project was used or modified. No additional agents were spawned by this implementer.

## Formal review fix round 1 (base `72b2b8cbd`)

Addressed the four Important review findings with bounded adapter/provenance changes:

- Current review projection no longer uses comment/style latest-wins resolution. Every repeated exact review target is withheld, including repeated identical dispositions; all source records remain retained.
- Filtered projection uses the same fail-closed duplicate rule and validates dispositions against independent raw evidence: FP requires positive support; FN requires explicit zero; unknown is ineligible. Captured display values remain untouched. Both roles have tests for valid/invalid/unknown evidence and both conflict orders, with identical duplicates covered too.
- Headless manual eligibility and active scientific analysis are mutually exclusive branches. The regression now installs a resolvable definition snapshot and proves manual exact labels, per-slot source and unavailable/nil pipeline baselines survive.
- Producing-step provenance receives explicit newly generated payload/layout output URLs. Prior retained payloads remain inputs, never newly produced outputs. The current refresh test verifies exact output filenames, producing-generation directory, input/output disjointness, final bundle paths, output roles, SHA-256 and sizes for all producing-step outputs after publication.

RED: `/tmp/lungfish-task3-review-red.log`, 4 tests, 26 expected assertion failures, no unexpected errors. GREEN: `/tmp/lungfish-task3-review-green.log`, the same 4 tests passed. Covering verification used the final focused command above: `/tmp/lungfish-task3-review-covering.log`, **68 tests, zero failures**, including both importer schemas, all three-sheet production regressions, fingerprint/effective-call suites and the manual UI regression. `git diff --check` passed.

The existing UI still resolves duplicate reviews latest-wins in `GenotypeResultViewController.swift:1728` and `GenotypeComparisonMatrixView.swift:797`. This concrete display mismatch was reported to the parent for Task 5; this fix round does not change UI/inference review authority or captured display masks.

Build output is **not pristine**. Pre-existing warning identities observed in this round (unmodified files): `Sources/LungfishWorkflow/Provenance/ProvenanceRecorder.swift:738:5`, redundant `public` in a public extension; and `Tests/LungfishWorkflowTests/ProjectStorageCleanupExecutorTests.swift`, unused `execute` results at lines 846, 918, 1087, 2025, 2145, 2229, 2292, 2359, 2426, 2489, 2610, 2743, 2836, 2930, 2989, 3044, 3092 and 3319. These were not suppressed or cleaned up as part of this scope.

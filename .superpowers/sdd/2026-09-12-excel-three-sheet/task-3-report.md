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

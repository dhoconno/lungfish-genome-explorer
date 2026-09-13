# Unified one-way Excel export QA

Status: implementation verification passes. Independent Task 6 and whole-branch reviews remain pending, followed by the separately owned release workflow.

## Acceptance outcome

The unified one-way exporter was exercised through production capture, snapshot validation, rendering, publication, provenance, and replay paths for haplotyped miSeq, genotype-only, and legacy/manual call workflows. The final covering selection executed 102 tests with zero failures and zero skips. A subsequent focused private-cohort run, after adding explicit annotation assertions, executed one test with zero failures and zero skips. Both the app and CLI products build successfully.

The independent raw-evidence oracle verifies exact row and sample identities, integer support, unknown-versus-zero semantics, filtered masks, stable identities, effective H1/H2 calls, and palette transport. It accepts the literal baseline and rejects ten deliberate corruptions: dropped row, dropped sample, coherent support change, unknown changed to zero, stable-ID retargeting, H2 divergence, palette divergence, and post-render Filtered value, row-order, and annotation corruption.

## Workflow coverage

- Haplotyped miSeq produces Calls, All, Filtered, and Metadata sheets. Synthetic evidence covers exact zero, unknown, positive and low-support rows, visible and hidden samples, combined filtering, homozygous display, unresolved calls, FP/FN annotations, comments, and multiple colors.
- Genotype-only export produces exactly All, Filtered, and Metadata sheets, retains eligible positive evidence in both matrices, has no artificial call bands, and semantically replays after its source directory is removed.
- Legacy analyzed/manual export retains effective call, status, source, and explicit absence behavior.
- The configured disposable cohort was read from a fresh working copy. A raw CSV/JSON oracle was captured before the application loader and verified 26 samples, 169 rows, 4,394 evidence cells, 1,909 known values, 2,485 unknown values, and 160 floor-filtered rows. Before each export, the ordered native Filtered viewport was captured independently of the snapshot. The actual worksheet then matched its dimensions, sample/row order, stable IDs, displayed allele values, 4,160 literal/masked cells, raw support, annotations, and relevant styles; reopen parity was exact. Native detail, outline semantics, matrix-band values, and the cached active definition's semantic palette witness were also compared against 130 exported calls in initial, annotation-set, and annotation-clear phases. The chosen cell's FP/comment addition and removal were asserted in the persisted sidecar, snapshot, and actual workbook. Source-independent semantic replay passed.
- Nine CSV/TSV transaction guards cover rollback and race behavior for prior output/root/sidecar restoration, concurrent writers, snapshot and force-claim races, provenance boundaries, stale signatures, late writers, no-force publication, and shared-root concurrency.
- Shared exporter, native authority, exact-zero, and historical recovery suites passed in the consolidated gate.

## Defect found and corrected

Actual cohort rendering exposed empty haplotype-band placeholders: raw genotype-evidence loci were combined with the native call axis. A focused regression first failed on both All and Filtered. The builder now derives default band loci only from frozen actual calls, preserving their native order. Explicit Filtered scope remains authoritative, including the distinction between nil fallback and an intentionally empty scope. Raw genotype evidence and its ordering are unchanged.

Post-fix cohort workbooks contain exactly the five native call loci in A/B/DR/DQ/DP order in both bands, with no blank raw-evidence placeholders.

## Review correction: Filtered worksheet acceptance

The implementation QA now captures an ordered witness from the held native viewport before snapshot/export and keeps raw eligibility expectations independent. A synthetic controller test combines sample search, manual sample hiding, and the read floor, then checks exact Filtered worksheet order, identities, literal values/types, masks, FP/FN comments, and review styling. The four-sheet miSeq fixture also checks its rendered Filtered dimensions, stable IDs, numeric FP/zero-FN values, complete comments, and formats. A DEBUG-only testing accessor was corrected to read the mounted generic allele column or the mounted miSeq reference-allele column; production export behavior is unchanged.

The bounded post-review gate executed seven tests with zero failures and zero skips, including all six unified workflow tests, the configured cohort, and the ten-corruption oracle. The earlier 102-test gate remains the broader Task 6 evidence; the post-review gate verifies only this amended acceptance scope.

## Visual inspection

Twenty read-only PNG inspections covered every sheet in representative four-sheet and three-sheet workbooks, edge fixtures, the pre-fix cohort defect, and corrected cohort All/Filtered views. The workbooks were not recalculated or rewritten, and before/after hashes were unchanged. Calls, homozygotes, palette colors, positive and zero annotations, filtered omission, metadata disclosures, and genotype-only layout were readable. One concurrent rendering attempt produced an incomplete PNG; an isolated repeat from the unchanged workbook rendered correctly, so this was classified as a renderer diagnostic rather than workbook data loss.

## Limits

The raw matrix oracle is independent of application parsers and export adapters. Cohort call/status/source acceptance deliberately compares export transport with pre-export native viewer authority; it does not independently reimplement or scientifically validate the inference engine. Exact pipeline-baseline expectations and nonstandard missing/error/custom palette cases are pinned by literal synthetic fixtures. The cached definition witness checks the active semantic palette, not appearance-dependent screen pixels. The retained historical H2/palette RED log contains only a bare generated-script assertion, so it does not by itself prove which intended mutation caused that earlier failure; the final GREEN explicitly lists all ten rejections, and the new Filtered RED explicitly lists the three previously accepted corruptions. XLSX ZIP bytes are not expected to be deterministic; replay equality is semantic across sheet order, values and types, axes, stable identities, calls, masks, annotations, colors, metadata, and receipts.

## Reproduce

Use the managed openpyxl Python path for the runtime variables and a disposable private project copy for the optional cohort variables. The private test skips only when both cohort variables are absent; an incomplete or invalid configuration fails.

```sh
LUNGFISH_EXCEL_QA_PROJECT="$DISPOSABLE_PROJECT" \
LUNGFISH_EXCEL_QA_BUNDLE="$DISPOSABLE_BUNDLE" \
LUNGFISH_TEST_PYTHON="$MANAGED_OPENPYXL_PYTHON" \
LUNGFISH_TEST_OPENPYXL_PYTHON="$MANAGED_OPENPYXL_PYTHON" \
swift test --jobs 6 --filter 'GenotypeUnifiedExcelAcceptanceTests|GenotypeFullCurrentEvidenceOracleTests|GenotypeExactZeroWorkbookAcceptanceTests|GenotypeExcelExportServiceTests|GenotypeExportSubcommandTests|GenotypeResultViewportSelectionAndComparisonTests.testNonMiSeqEffectiveCallsKeepHomozygotesAndExplicitAbsenceAcrossViews|GenotypeResultViewportSelectionAndComparisonTests.testApplicableHaplotypedMiSeqWorkbookIgnoresManualAssignments|GenotypeResultViewportSelectionAndComparisonTests.testFrozenSnapshotKeepsRealManualAssignmentsAndFullNativeEditorScopeForONTAndMiSeq|GenotypeResultViewportStylingAndMiSeqE2ETests.testNativeIncludedLociStayScopedWhileFrozenCallsRetainFullAuthority|GenotypeSampleComparisonModelTests|GenotypeHistoricalWorkbookRecoveryTests'
```

After any cohort-annotation assertion change, rerun its focused case:

```sh
LUNGFISH_EXCEL_QA_PROJECT="$DISPOSABLE_PROJECT" \
LUNGFISH_EXCEL_QA_BUNDLE="$DISPOSABLE_BUNDLE" \
LUNGFISH_TEST_PYTHON="$MANAGED_OPENPYXL_PYTHON" \
swift test --jobs 6 --filter 'GenotypeUnifiedExcelAcceptanceTests/testConfiguredDisposableCohortRunsAgainstRawEvidence'
```

Run the bounded post-review Filtered acceptance gate with the private cohort configured:

```sh
LUNGFISH_EXCEL_QA_PROJECT="$DISPOSABLE_PROJECT" \
LUNGFISH_EXCEL_QA_BUNDLE="$DISPOSABLE_BUNDLE" \
LUNGFISH_TEST_PYTHON="$MANAGED_OPENPYXL_PYTHON" \
swift test --jobs 6 --filter 'GenotypeUnifiedExcelAcceptanceTests|GenotypeFullCurrentEvidenceOracleTests'
```

Build both delivered products:

```sh
swift build --jobs 6 --product Lungfish
swift build --jobs 6 --product lungfish-cli
```

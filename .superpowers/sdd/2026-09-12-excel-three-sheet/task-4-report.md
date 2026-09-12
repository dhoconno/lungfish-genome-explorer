# Task 4 legacy writer-test migration report

## Outcome

Migrated the bounded legacy writer expectations in `GenotypeWorkbookRevisionServiceTests` and `GenotypePivotFilteredCopyTests` to the three-sheet contract (`Genotype Matrix`, `Haplotype Calls`, `Export Metadata`) and trusted manifest addresses. No production source was changed.

The affected runner executed 177 tests: 174 passed and exactly three retained assertions failed. Those failures are concrete Task 6 presentation gaps, not migration errors:

1. `testAbsentAnnotationOnlyRowsUseCanonicalCatalogSortOrder`: actual `Mamu-B*010:01|Mamu-A1*002:01`; required `Mamu-A1*002:01|Mamu-B*010:01`.
2. `testFullLengthMHCUpdateUsesSpeciesAgnosticBiologicalAlleleOrder`: the writer emits catalog input order instead of `MHCAlleleDisplayOrder.lessThan` order. The actual payload also retains the separate unnameable row `cluster-u`; Task 6 must sort the named biological rows without deleting or folding that evidence row.
3. `testManagedFalseNegativeStateDigestBindsExpectedBold`: the exact manifest-selected `cluster-a` / `Sample-Zero` FN target has `font.bold == false`; the established required value is `true`.

## Migration decisions

- Initial un-attested legacy geometry is treated as presentation only. All five authority migrations now assert literal validated catalog/artifact identities, exact sample rosters, raw supports, eligibility and review dispositions in both the final retained payload and the generated workbook cells selected through `trustedManifest.noteTargets`, while preserving input checksums.
- Post-attestation edits still fail closed. Mutation setup selects real schema-2 cells through `trustedManifest.noteTargets`, `callTargets`, or `immutableCells`; no removed worksheet is reconstructed.
- Genuine v1 coverage remains in `testThreeSheetMigrationRejectsUnreviewedV1EditsWithoutMutation`. The exact admitted legacy managed-state fixture now proves safe migration to schema 2 and CSV-derived evidence. A missing editable-baseline version and an externally changed workbook presentation-schema value each fail closed without mutation.
- The old scan-count assertion became repeated-refresh correctness plus byte/revision no-op coverage; no replacement counter was invented.
- Scientific assertions read actual retained payload fields, manifest fields and workbook cells. Helpers now read actual `data_type`, reviews, retained calls, comments and manifest loci. Obsolete fabricated invalid-review rows, conflict counts, sheet flags, missing-target types and display-as-closest-reference aliases were removed.
- A focused failure was initially misdiagnosed as call fan-out. Inspection proved both retained semantic payload and trusted manifest contained all seven supplied loci (`MHC-A`, `MHC-B`, `MHC-DRB`, `MHC-DQA`, `MHC-DQB`, `MHC-DPA`, `MHC-DPB`). The defect was test-helper aggregation of DQA/DQB and DPA/DPB. The helper was corrected, and all fourteen literal call assertions pass.
- Candidate review targets use the exact scientific genotype (`Mafa-A1*018:01:01:01_5nt_nov`) plus stable ID `cluster-1`; stable ID alone is not substituted for genotype identity.
- Candidate raw-support expectations come from the fixture observations: shared `cluster-1` and `cluster-3` have `sample-a/sample-b` values `7/3` and `4/2`; singleton `cluster-2`, singleton `cluster-4`, and unnameable `cluster-u` have `sample-a` value `4` and no `sample-b` observation, so their final `sample-b` cells are `nil` and ineligible, not fabricated zeroes. The four reviewable-catalog authority cases separately assert their explicit roster-attested zeroes.
- Retention checks reload the final stored unnameable JSON and annotation sidecars after publication, compare their bytes/checksums, and then assert exact retained records. They no longer inspect only a pre-update decode or the submitted in-memory object.
- The version guard changes the actual manifest-bound `Export Metadata` `Presentation schema` cell from `2` to `3`; regeneration rejects it without mutation.
- The biological-order test now has three independent checks: a literal expected named-allele sequence, agreement with `MHCAlleleDisplayOrder.lessThan`, and separately retained unnameable `cluster-u` evidence.
- Both eligible zero-support FN targets (`Sample-Zero`, `Sample-Absent`) are asserted as `false-negative` in the actual payload and trusted manifest. The positive-support `cluster-c` FN is asserted `nil` in both.

## Task 6 presentation handoff

The following original visual assertions were intentionally kept out of semantic Task 4 bodies or retained as an exact pending failure. Task 6 must reinstate equivalent assertions against manifest-selected three-sheet cells:

| Source test | Target | Required presentation |
|---|---|---|
| `testViewportProjectionControlsVisibleRowsColumnsValuesAndAnnotations` | projected matrix sample/row columns and candidate row | sample column width at least 18 with wrapped header; candidate row height at most 30; label column width at least 60 with wrapped label |
| same | `01_Middle` / `Animal2` false positive | display `[8]`; italic; font `767676`; retain native fill `654321`; retain visible cell Note |
| same | `01_Background` / `Animal2` false negative | display `FN`; four `mediumDashed` borders; fill `FFF2CC` |
| `testViewportProjectionFindsPublishedCurrentWorkbookMatrixAndMatchesDisplayAliases` | published-current M3 and overridden M6 calls | M3 font `0432FF`; M6 font `595959`; stale source fills cleared |
| same | exact reviewed matrix targets | FP display `[9]` and italic; FN display `FN`; retain native and projected Notes |
| `testAbsentZeroSupportFalseNegativeUsesExactPortablePresentation` | both exact zero-support reference cells (`Sample-A`, `Sample-B`) | preserve numeric raw value `0`/cell type `n` and visibly display `FN`; four `mediumDashed` borders color `C65911`; solid fill `FFF2CC`; bold font color `7F6000` |
| same | portable OOXML | the legacy assertion required literal `FN` plus dashed-border, border-color, fill-color and font-color records. Under the approved numeric-backed contract, Task 6 must replace only the literal-string check with an exact numeric-cell plus visible-number-format/display check; the four style/color checks remain exact |
| `testApplyHaplotypeOverridesWritesMatrixAnnotationsToCurrentWorkbook` | exact `MHC-B` / `Mamu-I*expected` / `AR3628` target | fill `FFF2CC`; text `C00000`; border `666666`; bold `true`; italic `true`; Note contains `Expected genotype missing from reads.` |
| `testApplyHaplotypeOverridesFormatsReviewsUsingExactSemanticIdentity` | `cluster-a` / `Sample-FP`, raw support 42 | display `[42]`; italic; font `767676` |
| same | `cluster-a` / `Sample-Zero` and `Sample-Absent`, raw support 0 | preserve numeric raw support (or null where scientifically absent) and visibly format as `FN`; four `mediumDashed` borders color `C65911`; solid fill `FFF2CC`; bold; font `7F6000` |
| same | incompatible positive-support FN | remain raw `42`, no managed FN border/presentation |
| `testReviewBecomingInvalidRestoresPriorManagedPresentation` | `cluster-a` / `Sample-FP` after FP becomes invalid FN | restore raw `42`, non-italic native font/color and original borders/fill; sidecar record remains retained but is not promoted |
| `testManagedFalseNegativeStateDigestBindsExpectedBold` | `cluster-a` / `Sample-Zero` | generated FN is bold; post-attestation removal of bold is rejected without bundle mutation |
| `testExplicitUpdateRetainsAllCandidateCategoriesAndUnnameableEvidenceWithNameOnlyTints` | candidate row labels `cluster-1...cluster-4` | fills `FFFF0000|8000FF00|FF0000FF|40FFFF00` respectively; do not tint the unnameable row by candidate-name rules |

## Pre/post coverage map

Every method from the Task 3 failure ledger is mapped below. “Same name” means only its assertions/setup moved to payload/manifest-backed evidence.

| Pre-migration method | Post-migration method | Scientific/behavioral coverage retained |
|---|---|---|
| `testFilteredCopyKeepsEverySheetAndFormattingAndFiltersOnlyThePivot` | `testFilteredCopyWritesThreeSheetSnapshotAndFiltersOnlyTheEvidenceMatrix` | exact three-sheet output, evidence-only filtering, masks, sample values, metadata/provenance and source no-clobber |
| `testViewportProjectionControlsVisibleRowsColumnsValuesAndAnnotations` | same name | projected row/sample ordering, threshold boundary, raw/display separation, Notes, exact call/comment and provenance |
| `testViewportProjectionFindsPublishedCurrentWorkbookMatrixAndMatchesDisplayAliases` | same name | published-current discovery, raw identity/display aliases, calls, reviews, Notes and exact samples |
| `testAbsentAnnotationOnlyRowsUseCanonicalCatalogSortOrder` | same name | exact absent-zero catalog rows and required biological order; retained pending Task 6 |
| `testAbsentZeroSupportFalseNegativeUsesExactPortablePresentation` | same name | exact catalog identity, numeric raw zero, both FN reviews and provenance; exact visible/OOXML expectations are handed to Task 6 above, not claimed as passing here |
| `testAmbiguousExistingRowsFailClosedBeforeAnnotationOnlySynthesis` | `testAmbiguousExistingRowsAreRebuiltFromExactCatalogIdentity` | one exact catalog row/review; ambiguous initial geometry has no identity authority |
| `testAmbiguousManagedCandidateMarkersFailClosedWithoutBundleMutation` | same name | malformed initial managed-marker collision remains fail-closed/no-clobber |
| `testAnnotationOnlyCachingScalesWithUniqueSheetsAndRows` | `testRepeatedAnnotationRefreshRetainsAllCatalogReviewsAndIsANoOp` | all exact reviews retained; repeated refresh is byte- and revision-no-op |
| `testAnnotationOnlyUpdateAttestsFullSemanticCallsAndRetainsTheirProvenance` | same name | complete semantic calls, attestation and reproducible provenance inputs |
| `testAnnotationUpdateAcceptsInitialMiSeqReportProvenanceAndPreservesIt` | same name | Task 3 fix retained; MiSeq provenance accepted and preserved |
| `testApplyHaplotypeOverridesComposesResolvedNativeNotesByScope` | `testApplyHaplotypeOverridesWritesResolvedSidecarNotesByExactScope` | latest exact row/sample/cell sidecar comments appear in payload/manifest targets |
| `testApplyHaplotypeOverridesFormatsReviewsUsingExactSemanticIdentity` | same name | exact raw support, valid FP/FN disposition and incompatible-review withholding; styling handed to Task 6 |
| `testApplyHaplotypeOverridesPatchesCurrentWorkbookAndRecordsSidecarProvenance` | same name | supplied calls, exact DP/DRB comments, revision/provenance and sidecar descriptors |
| `testApplyHaplotypeOverridesWritesMatrixAnnotationsToCurrentWorkbook` | same name | exact reference catalog row, raw zero, fill/comment Notes, three-sheet output |
| `testApplyManualHaplotypeSnapshotWritesFourteenLiteralValuesAndSidecarRevisionProvenance` | same name | all fourteen values at seven exact loci plus sidecar revision provenance |
| `testCandidateUpdateRejectsMissingUnifiedPivotWithoutBundleMutation` | `testCandidateUpdateRebuildsMissingUnifiedPivotFromValidatedArtifacts` | validated artifact rebuild with literal five-row identity, exact `sample-a/sample-b` raw matrix (`7/3`, `4/nil`, `4/2`, `4/nil`, `4/nil`), manifest-cell agreement, eligibility/reviews and original source checksum |
| `testCommittedCleanupFailureReturnsSuccessWarningWithoutSecondRetiredGeneration` | same name | cleanup warning/recovery semantics and single retired generation |
| `testCompleteSevenLocusHaplotypedSnapshotIsNeverInferredAsManual` | same name | seven-locus haplotyped authority classification, exact calls |
| `testCurrentWorkbookScientificAndEditingTablesRetainEveryExactLocus` | same name | payload and manifest each retain every supplied exact locus; no DQ/DP helper aggregation |
| `testDuplicateExactReviewTargetsFailClosedInEitherOrder` | same name | duplicate exact reviews withheld regardless of order; final stored sidecar bytes and exact source-order records reloaded and retained |
| `testDuplicateStableWorkbookIdentityFailsClosedBeforeFormatting` | `testDuplicateStableWorkbookIdentityRebuildsOneExactCatalogRow` | one catalog-authoritative stable identity/value and original source preservation |
| `testDuplicateUnifiedSampleIntroducedAfterManagedApplyMakesClearFailClosed` | same name | manifest-addressed post-attestation identity collision rejects clear/no-clobber |
| `testExactLegacyManagedStateSchemaRestoresAndMigratesSafely` | `testExactLegacyManagedStateSchemaMigratesToValidatedThreeSheetEvidence` | admitted legacy state migrates to schema 2; exact CSV row/sample/support and empty review |
| `testExcelEditAfterStageCreationCannotBecomeAdmittedSourceInAnyUpdateMode` | same name | manifest-selected post-stage edit is rejected in full and annotation-only modes |
| `testExplicitUpdateNormalizesCandidateOnlyArtifactTriplet` | same name | candidate-only artifacts normalize to exact evidence/presentation/provenance |
| `testExplicitUpdateNormalizesUnnameableOnlyArtifactTriplet` | same name | unnameable-only artifact identity and GenBank provenance remain retained |
| `testExplicitUpdateRetainsAllCandidateCategoriesAndUnnameableEvidenceWithNameOnlyTints` | same name | all four candidate categories plus unnameable evidence and exact tint mapping |
| `testExplicitUpdateWritesTwoSheetContractFromEmbeddedUnifiedHeaderAndNormalizedUnmatchedRows` | `testExplicitUpdateWritesThreeSheetContractFromValidatedScientificInputs` | exact sheet order, candidate/reference identities/support, group calls and artifact provenance |
| `testExplicitWorkbookUpdateAcceptsWriterShapedSchemaV5CandidateDocument` | same name | schema-5 candidate input acceptance and source artifact identity/provenance |
| `testExternalCandidateTintEditRequiresReviewAndPreservesNativeStyle` | same name | manifest-selected candidate row post-attestation edit rejects/no-clobber |
| `testExternalLegacyCandidateLabelEditRequiresReviewBeforeAnnotationOnlyUpdate` | same name | exact candidate target edit blocks a legitimate exact sidecar review update |
| `testExternallyAddedRealWorkbookRowRequiresReviewBeforeManagedUpdate` | same name | externally appended matrix evidence row rejects/no-clobber |
| `testExternalManagedReviewStyleEditRequiresReviewBeforeClear` | same name | post-attestation managed review style changes reject clear/no-clobber |
| `testExternalManagedStateVersionChangeRequiresReviewBeforeMigration` | `testExternalEditableBaselineVersionChangeFailsClosedWithoutMutation` | actual manifest-bound `Presentation schema` workbook value changes `2` to `3` and rejects/no-clobber |
| `testExternalMarkerOnlyEditRequiresReviewAndPreservesEntireSyntheticBlock` | same name | manifest row Note mutation rejects/no-clobber; no fake marker row |
| `testExternalNativeCommentAndFormattingRequireReviewBeforeRebuild` | same name | actual candidate target native Note/style mutation rejects a valid review update |
| `testExternalRetainedSyntheticBlockRequiresReviewBeforeClearing` | same name | manifest row mutation rejects clearing/no-clobber |
| `testExternalTablelessRealRowRequiresReviewBeforeCompacting` | same name | actual matrix row append rejects compacting/no-clobber |
| `testFullLengthMHCUpdateUsesSpeciesAgnosticBiologicalAlleleOrder` | same name | literal original named-allele order plus comparator agreement retained; unnameable `cluster-u` asserted separately; named ordering pending Task 6 |
| `testGenericAnnotationOnlyRowIsIdempotentAndClearsSafely` | same name | exact reference row/review lifecycle, repeated no-op and safe clear while evidence remains |
| `testGenericClearIgnoresUnrelatedTableSpanningManagedRows` | same name | clear changes semantic review only and preserves exact row/sheet contract |
| `testGenericDuplicateAliasesAndUnsupportedLayoutsFailClosed` | `testGenericDuplicateAliasesAndUnsupportedLayoutsRebuildFromCatalog` | exact catalog row/value rebuilt independently of unsupported initial aliases/layout |
| `testHaplotypedDuplicateExactLocusPreservesEstablishedLastWinsBehavior` | same name | duplicate exact sample/locus retains established last-wins calls |
| `testLegacyCombinedManualRowsComposeEmptySingleSameAndDistinctValues` | same name | empty/single/same/distinct manual calls compose at exact loci without fan-out |
| `testLegacyCSVIdentitiesSeedEditableMatrixAndMapCompactReportLabels` | same name | raw CSV call identity, compact display, exact AnimalA/AnimalB support and valid FP review |
| `testManagedFalseNegativeStateDigestBindsExpectedBold` | same name | exact FN target must be bold and bold removal must be attestation-bound; pending Task 6 |
| `testRecognizedLegacyGenotypeOnlyKindsUseSharedManualAuthority` | same name | recognized legacy kinds retain shared manual-authority classification |
| `testReferenceTargetFailsClosedWhenWorkbookRequiresStableIdentity` | `testReferenceTargetRebuildIgnoresLegacyStableIdentityCollision` | exact reference catalog identity/value rebuilt despite legacy stable-ID collision |
| `testReviewBecomingInvalidRestoresPriorManagedPresentation` | same name | actual payload/manifest withhold positive-support FN; final stored invalid sidecar bytes/record reloaded; native-style restoration handed to Task 6 |
| `testSchemaThreeCleanupPendingRecoveryFinishesThenPublishesLatestAssignments` | same name | cleanup recovery publishes latest exact assignments and provenance |
| `testSchemaVersionTwoCandidateUpdateUsesCompactRowsAndHeaderNamedPivotColumns` | same name | schema-2 candidate rows/headers map to exact compact three-sheet evidence |
| `testTablelessClearFailsClosedForDuplicateUnannotatedCatalogSample` | same name | manifest-addressed duplicate exact sample identity rejects clear/no-clobber |
| `testTwoSheetCurrentWorkbookRetainsAndAppliesSemanticReviews` | `testThreeSheetCurrentWorkbookRetainsAndAppliesSemanticReviews` | exact candidate genotype/stable ID, raw support and FP review in three-sheet payload |
| `testTypedONTAndMiSeqGenotypeOnlyBundlesMaterializeManualSnapshots` | same name | typed ONT/MiSeq bundles retain exact manual snapshot behavior |
| `testUnreleasedUnversionedTask4ManagedStateFailsClosed` | `testUnversionedEditableBaselineFailsClosedWithoutMutation` | missing schema version in the real editable baseline rejects/no-clobber |
| `testUserEditedSyntheticRowRequiresReviewAndPreservesExactInput` | same name | manifest row edit rejects/no-clobber; exact input remains unchanged |

## Verification

- Focused initial-authority/exact-locus/no-op set: 7 tests, 7 passed.
- Focused recently migrated semantic set: 16 tests; after correcting the exact candidate genotype lookup, all 16 passed.
- Focused legacy-state set: three schema/security tests passed; the retained exact bold requirement failed as documented above.
- Required affected runner: `swift test --jobs 6 --filter 'GenotypeWorkbookRevisionServiceTests|GenotypePivotFilteredCopyTests'` — 177 tests, 3 failures, 0 unexpected, 321.975 seconds. Full log: `/tmp/lungfish-task4-affected.log`.

## Review-fix verification

After the Astra review, the changed 13-method focused runner was:

`swift test --jobs 6 --filter 'GenotypeWorkbookRevisionServiceTests/(testAnnotationOnlyUpdateAttestsFullSemanticCallsAndRetainsTheirProvenance|testCandidateUpdateRebuildsMissingUnifiedPivotFromValidatedArtifacts|testAmbiguousExistingRowsAreRebuiltFromExactCatalogIdentity|testReferenceTargetRebuildIgnoresLegacyStableIdentityCollision|testDuplicateStableWorkbookIdentityRebuildsOneExactCatalogRow|testGenericDuplicateAliasesAndUnsupportedLayoutsRebuildFromCatalog|testApplyHaplotypeOverridesFormatsReviewsUsingExactSemanticIdentity|testDuplicateExactReviewTargetsFailClosedInEitherOrder|testReviewBecomingInvalidRestoresPriorManagedPresentation|testExplicitWorkbookUpdateAcceptsWriterShapedSchemaV5CandidateDocument|testExternalEditableBaselineVersionChangeFailsClosedWithoutMutation|testFullLengthMHCUpdateUsesSpeciesAgnosticBiologicalAlleleOrder|testManagedFalseNegativeStateDigestBindsExpectedBold)'`

Result: 13 executed, 11 passed, 2 failed, 0 unexpected, 34.196 seconds. The failures are the expected Task 6 named biological-order and FN-bold assertions. The canonical two-row ordering gap remains the third known Task 6 failure from the required 177-test runner; that unchanged method was not rerun in this scoped fix wave. Full focused log: `/tmp/task4-fix1-focused-final2.log`.

Self-review confirmed:

- no asserted helper value is a fabricated constant or display-label substitute;
- all five initial-authority tests compare payload science and manifest-addressed workbook cells;
- final stored artifact/sidecar data is reloaded for retention claims;
- named biological ordering and unnameable retention are separate domains with a literal oracle;
- the version guard mutates the actual workbook schema value;
- deferred visual/OOXML expectations above distinguish numeric raw science from visible presentation;
- the review-fix diff remains limited to `GenotypeWorkbookRevisionServiceTests.swift` and this report; the other owned filtered-copy test file needed no review-fix change, and there are no production changes.

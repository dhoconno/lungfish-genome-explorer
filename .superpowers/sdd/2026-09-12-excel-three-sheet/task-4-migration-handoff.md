# Task 4 legacy-test migration handoff

Task 3 affected run: `swift test --jobs 6 --filter 'GenotypeWorkbookRevisionServiceTests|GenotypePivotFilteredCopyTests|GenotypeCurrentWorkbookInputFingerprintTests|GenotypeEffectiveHaplotypeProjectionTests|Genotype(ThreeSheet)?EditableWorkbookTests'`.

Log: `/tmp/lungfish-task3-affected.log`. 228 tests, 84 failure assertions (50 unexpected), 56 failed methods. This is an explicit incomplete integration result, not a passing suite. Of those, the initial MiSeq compatibility defect is fixed and subsequently passed; 55 methods require migration below.

Fingerprint 24/24, original importer 10/10, effective-call projection 11/11 and schema-2 importer 12/12 passed. Revision suite ran 165 tests and filtered suite ran 6.

Parent ruling: initial admitted legacy worksheet geometry is not scientific authority when validated catalog/CSV establishes exact IDs. Rebuild independently, retain original bytes, assert original source checksum unchanged. This does NOT relax attested v1 pending-edit or post-attestation mutation/layout guards.

Removed-sheet failures include both output-inspection expectations and guard setup that mutates a removed worksheet. Preserve their behavioral assertions by targeting attested schema-2 addresses (trusted manifest), or explicitly seed/attest a real v1 fixture where the subject is v1 migration. Do not delete/skip tests or turn security guards into success expectations. Styling parity/FP/FN presentation assertions need coordination with Task 5, which owns rendering/style completion.

## old-shape

- `testFilteredCopyKeepsEverySheetAndFormattingAndFiltersOnlyThePivot`
- `testViewportProjectionControlsVisibleRowsColumnsValuesAndAnnotations`

## removed-sheet

- `testViewportProjectionFindsPublishedCurrentWorkbookMatrixAndMatchesDisplayAliases`
- `testAbsentAnnotationOnlyRowsUseCanonicalCatalogSortOrder`
- `testAbsentZeroSupportFalseNegativeUsesExactPortablePresentation`
- `testAmbiguousManagedCandidateMarkersFailClosedWithoutBundleMutation`
- `testAnnotationOnlyUpdateAttestsFullSemanticCallsAndRetainsTheirProvenance`
- `testApplyHaplotypeOverridesComposesResolvedNativeNotesByScope`
- `testApplyHaplotypeOverridesFormatsReviewsUsingExactSemanticIdentity`
- `testApplyHaplotypeOverridesPatchesCurrentWorkbookAndRecordsSidecarProvenance`
- `testApplyHaplotypeOverridesWritesMatrixAnnotationsToCurrentWorkbook`
- `testApplyManualHaplotypeSnapshotWritesFourteenLiteralValuesAndSidecarRevisionProvenance`
- `testCommittedCleanupFailureReturnsSuccessWarningWithoutSecondRetiredGeneration`
- `testCompleteSevenLocusHaplotypedSnapshotIsNeverInferredAsManual`
- `testCurrentWorkbookScientificAndEditingTablesRetainEveryExactLocus`
- `testDuplicateExactReviewTargetsFailClosedInEitherOrder`
- `testDuplicateUnifiedSampleIntroducedAfterManagedApplyMakesClearFailClosed`
- `testExactLegacyManagedStateSchemaRestoresAndMigratesSafely`
- `testExcelEditAfterStageCreationCannotBecomeAdmittedSourceInAnyUpdateMode`
- `testExplicitUpdateNormalizesCandidateOnlyArtifactTriplet`
- `testExplicitUpdateNormalizesUnnameableOnlyArtifactTriplet`
- `testExplicitUpdateRetainsAllCandidateCategoriesAndUnnameableEvidenceWithNameOnlyTints`
- `testExplicitUpdateWritesTwoSheetContractFromEmbeddedUnifiedHeaderAndNormalizedUnmatchedRows`
- `testExplicitWorkbookUpdateAcceptsWriterShapedSchemaV5CandidateDocument`
- `testExternalCandidateTintEditRequiresReviewAndPreservesNativeStyle`
- `testExternalLegacyCandidateLabelEditRequiresReviewBeforeAnnotationOnlyUpdate`
- `testExternallyAddedRealWorkbookRowRequiresReviewBeforeManagedUpdate`
- `testExternalManagedReviewStyleEditRequiresReviewBeforeClear`
- `testExternalManagedStateVersionChangeRequiresReviewBeforeMigration`
- `testExternalMarkerOnlyEditRequiresReviewAndPreservesEntireSyntheticBlock`
- `testExternalNativeCommentAndFormattingRequireReviewBeforeRebuild`
- `testExternalRetainedSyntheticBlockRequiresReviewBeforeClearing`
- `testExternalTablelessRealRowRequiresReviewBeforeCompacting`
- `testFullLengthMHCUpdateUsesSpeciesAgnosticBiologicalAlleleOrder`
- `testGenericAnnotationOnlyRowIsIdempotentAndClearsSafely`
- `testGenericClearIgnoresUnrelatedTableSpanningManagedRows`
- `testHaplotypedDuplicateExactLocusPreservesEstablishedLastWinsBehavior`
- `testLegacyCombinedManualRowsComposeEmptySingleSameAndDistinctValues`
- `testLegacyCSVIdentitiesSeedEditableMatrixAndMapCompactReportLabels`
- `testManagedFalseNegativeStateDigestBindsExpectedBold`
- `testRecognizedLegacyGenotypeOnlyKindsUseSharedManualAuthority`
- `testReviewBecomingInvalidRestoresPriorManagedPresentation`
- `testSchemaThreeCleanupPendingRecoveryFinishesThenPublishesLatestAssignments`
- `testSchemaVersionTwoCandidateUpdateUsesCompactRowsAndHeaderNamedPivotColumns`
- `testTablelessClearFailsClosedForDuplicateUnannotatedCatalogSample`
- `testTwoSheetCurrentWorkbookRetainsAndAppliesSemanticReviews`
- `testTypedONTAndMiSeqGenotypeOnlyBundlesMaterializeManualSnapshots`
- `testUnreleasedUnversionedTask4ManagedStateFailsClosed`
- `testUserEditedSyntheticRowRequiresReviewAndPreservesExactInput`

## initial-authority

- `testAmbiguousExistingRowsFailClosedBeforeAnnotationOnlySynthesis`
- `testCandidateUpdateRejectsMissingUnifiedPivotWithoutBundleMutation`
- `testDuplicateStableWorkbookIdentityFailsClosedBeforeFormatting`
- `testGenericDuplicateAliasesAndUnsupportedLayoutsFailClosed`
- `testReferenceTargetFailsClosedWhenWorkbookRequiresStableIdentity`

## legacy-counters

- `testAnnotationOnlyCachingScalesWithUniqueSheetsAndRows`

## fixed-behavior

- `testAnnotationUpdateAcceptsInitialMiSeqReportProvenanceAndPreservesIt`

## Additional notes

The five initial-authority tests need catalog-exact output and original-source preservation assertions. The old scan-counter test should become repeated-refresh correctness/no-op coverage, not compare new synthetic counters to old scan totals. The two old-shape filtered tests must retain exact row/sample/mask/Notes checks while updating sheet and coordinate assumptions. `testAnnotationUpdateAcceptsInitialMiSeqReportProvenanceAndPreservesIt` must remain in the affected suite; it now passes without test weakening.

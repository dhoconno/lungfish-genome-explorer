# MHC Candidate GenBank Consequence Comments Implementation Plan

## Goal

Add deterministic, feature-aware nucleotide and protein consequence comments to the forward full-length ONT MHC `candidate_alleles.gb` artifact, using only data already available to the renderer.

## Task 1: Define aligned change events in the existing projection

Files:

- Modify `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateGenBankArtifactBuilder.swift`
- Modify `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateGenBankArtifactBuilderTests.swift`

Steps:

1. Add failing tests for substitutions, insertions, deletions, skipped regions, reverse orientation, and deterministic coordinates.
2. Extend the builder's single CIGAR pass to retain change events while preserving existing liftover behavior.
3. Compare bases for both `M` and explicit `X`, in reference orientation.
4. Keep reference-to-query and stored-candidate coordinate conversion in one projection implementation.
5. Run the focused builder tests.

## Task 2: Add a pure feature-aware consequence summarizer

Files:

- Create `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateConsequenceAnnotator.swift`
- Modify `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateGenBankArtifactBuilder.swift`
- Modify `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateGenBankArtifactBuilderTests.swift`

Steps:

1. Add failing genomic tests containing an exon-2 missense, exon-3 synonymous change, another CDS missense, and an intron change.
2. Add failing tests for two substitutions in one codon, reverse-strand CDS, frame-preserving/frame-disrupting indels, ambiguous/partial CDS, and missing annotations.
3. Select and validate the primary CDS; order intervals by transcript strand and honor `codon_start` and `transl_table`.
4. Group substitutions per codon and produce deterministic `CDS-NS`, `CDS-SYN`, or `CDS-UNRESOLVED` details.
5. Annotate coding indels conservatively using frame delta and whole-product translation status.
6. Use explicit exon/intron numbers when present and deterministic transcript-order inference otherwise.
7. Emit the four required stable summaries and ordered detail comments.
8. Run the focused builder tests.

## Task 3: Separate cDNA intron fills from coding indels

Files:

- Modify `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateConsequenceAnnotator.swift`
- Modify `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateGenBankArtifactBuilderTests.swift`

Steps:

1. Add a failing cDNA extension test with an internal long insertion and no coding changes.
2. Add a failing regression with an ordinary deletion adjacent to the long insertion.
3. Emit `INTRON-FILL` details for eligible long cDNA insertions and exclude those bases from coding-indel consequences.
4. Preserve independent reporting of adjacent ordinary indels.
5. Verify terminal insertions and partial alignments are not overinterpreted.

## Task 4: Publish comments and provenance

Files:

- Modify `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateArtifactWriter.swift`
- Modify `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateArtifactWriterTests.swift`
- Modify `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`

Steps:

1. Add failing assertions for exact provenance rule values.
2. Add a pipeline fixture assertion that the published `candidate_alleles.gb` contains all four summaries and representative detail comments.
3. Record the change source, coordinate convention, coding consequence, cDNA intron-fill, and ambiguity rules in both GenBank render transformations.
4. Confirm existing provenance inputs/outputs, checksums, sizes, argv, runtime, status, and timing remain complete.
5. Run builder, artifact-writer, and pipeline tests.

## Task 5: Crop candidate GenBank records to the lifted CDS span

Files:

- Modify `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateGenBankArtifactBuilder.swift`
- Modify `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateConsequenceAnnotator.swift`
- Modify `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCWorkbookProjection.swift`
- Modify `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateArtifactWriter.swift`
- Modify focused builder, projection, writer, revision, and pipeline tests

Steps:

1. Add failing tests showing terminal UTR/flanking bases are removed at the outer lifted-CDS boundaries while intervening introns remain.
2. Add failing reverse-orientation, partial-CDS, and no-CDS tests.
3. Crop only candidate GenBank `ORIGIN`; preserve the full candidate FASTA/cluster identity.
4. Rebase/clamp annotations and consequence candidate coordinates to the cropped `ORIGIN`.
5. Add source qualifiers and comments for original length, 1-based trim start/end, full-cluster SHA-256, cropped GenBank SHA-256, trim status, and reference-readiness status.
6. Update the current workbook validator to verify the cropped record is the declared exact substring of the full candidate FASTA, while retaining compatibility with existing exact-match candidate records and exact equality for un-nameable records.
7. Add `Full-Length FASTA Sequence` and `UTR-Trimmed FASTA Sequence` to the current `Unmatched Alleles` sheet; populate candidate trimmed values from the verified GenBank `ORIGIN`, preserve old exact candidate compatibility, and leave un-nameable trimmed values blank in both initial and explicit-update paths.
8. Record the UTR-trim derivation rule in GenBank-render provenance.
9. Run builder, artifact-writer, pipeline, workbook projection, and explicit-update tests.

## Task 6: Review and integrated verification

1. Add RED regressions for complete CDS assessment/readiness, unchanged ambiguous codons, candidate-only lifted introns, and touching versus non-touching replacement indels; apply minimal fixes and update exact provenance rules.
2. Add RED regressions preserving un-nameable boundary-coverage status, scoping unresolved evidence to intersecting exon summaries, and retaining candidate/exon coordinates for partial-CDS substitutions; apply minimal fixes and update exact provenance rules.
3. Add RED regressions for reference-class-aware long-insertion lifting, deletion-aware cDNA feature inference, unsupported translation tables, and reference-only outside-crop intronic coordinates; apply minimal fixes and update exact provenance rules.
4. Run specification review, then code-quality review; fix and rereview any findings.
5. Run the combined focused MHC classifier, GenBank builder/writer, pipeline, workbook projection/revision, viewport, and debug-launch tests.
6. Build a fresh signed `Lungfish Debug` app.
7. Run the established four-sample CLI analysis with the newly bundled CLI.
8. Verify sorted/indexed BAMs, candidate/un-nameable FASTA/JSON/GenBank artifacts, manifest entries, and complete provenance.
9. Inspect representative GenBank comments for genomic novel alleles and cDNA extensions; verify terminal UTR removal, feature rebasing, intron retention, and both sequence checksums.
10. Verify the two-sheet workbook cell types and render both sheets.
11. Quit other Lungfish processes and launch only the exact fresh debug bundle for testing.

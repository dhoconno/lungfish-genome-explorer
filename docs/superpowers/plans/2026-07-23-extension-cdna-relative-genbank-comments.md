# cDNA-relative extension GenBank comments implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `_ext` GenBank records report cDNA-relative evidence while identifying the genomic allele only as a feature scaffold.

**Architecture:** The existing GenBank builder already receives cDNA extension interpretations and the selected genomic visualization record. Branch comment generation on extension classification: emit cDNA comparison summaries from the extension interpretations, retain the genomic record only for feature liftover, and skip genomic sequence-consequence reporting. Non-extension candidates continue through the existing consequence annotator unchanged.

**Tech Stack:** Swift, XCTest, LungfishWorkflow GenBank builder and consequence annotator.

---

### Task 1: Separate extension cDNA evidence from genomic feature scaffolding

**Files:**
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateGenBankArtifactBuilderTests.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateGenBankArtifactBuilder.swift`

- [ ] **Step 1: Write the failing extension-comment test**

Extend `testExtensionRecordCommentsPersistCDNAAndSelectedGenomicInterpretations` so its candidate differs from an annotated genomic scaffold while its cDNA interpretation remains exact. Assert that the generated comments contain:

```swift
XCTAssertTrue(comments.contains {
    $0.contains("Lungfish cDNA sequence comparison:")
        && $0.contains("allele=Mafa-A1*001")
        && $0.contains("raw_id=ref-cdna")
        && $0.contains("SNP substitutions=0")
        && $0.contains("ordinary indel bases=0")
        && $0.contains("SNP-defined amino-acid differences=none")
})
XCTAssertTrue(comments.contains {
    $0 == "Lungfish genomic feature scaffold: ref-genomic (Mafa-A1*001); used only to lift exon, intron, and CDS coordinates; sequence differences relative to this scaffold are intentionally not reported"
})
XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish reciprocal alignment:") })
XCTAssertFalse(comments.contains { $0.hasPrefix("Lungfish translation comparison:") })
for prefix in consequenceSummaryPrefixes {
    XCTAssertFalse(comments.contains { $0.hasPrefix(prefix) })
}
XCTAssertFalse(comments.contains { $0.hasPrefix("CDS-NS-") })
XCTAssertFalse(comments.contains { $0.hasPrefix("CDS-SYN-") })
XCTAssertFalse(comments.contains { $0.hasPrefix("INTRON-") })
```

Retain the existing novel-candidate consequence assertions elsewhere in the test file as the regression control.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
swift test --filter FullLengthONTMHCCandidateGenBankArtifactBuilderTests.testExtensionRecordCommentsPersistCDNAAndSelectedGenomicInterpretations
```

Expected: FAIL because the current record reports the genomic scaffold as the selected closest reference and emits scaffold-relative alignment/consequence comments.

- [ ] **Step 3: Implement the extension-specific comment branch**

In `baseComments(_:)`, replace the current extension interpretation text with an explicit cDNA comparison line:

```swift
let aminoAcidSummary = interpretation.snpSubstitutions == 0
    ? "none"
    : "not resolved from aggregate cDNA alignment metrics"
values.append(
    "Lungfish cDNA sequence comparison: allele=\(interpretation.alleleName); "
        + "raw_id=\(interpretation.rawReferenceID); locus=\(interpretation.locus); "
        + "cDNA coverage=\(interpretation.cDNAReferenceCoverage); "
        + "cluster coverage=\(interpretation.clusterCoverage); identity=\(interpretation.identity); "
        + "SNP substitutions=\(interpretation.snpSubstitutions); "
        + "ordinary indel bases=\(interpretation.ordinaryIndelBases); "
        + "SNP-defined amino-acid differences=\(aminoAcidSummary); "
        + "leading flank=\(interpretation.leadingClusterFlankBases); "
        + "trailing flank=\(interpretation.trailingClusterFlankBases); "
        + "largest structural segment=\(interpretation.largestClusterStructuralSegmentBases); "
        + "largest cDNA deficit=\(interpretation.largestCDNADeficitSegmentBases); "
        + "strand=\(interpretation.isReverse ? "reverse" : "forward")"
)
```

In `makeCanonicalization(_:)`, derive:

```swift
let isExtension = input.subject.candidateRecord?.classification == .extension
```

For extensions:

- emit candidate amino-acid count and internal-stop count without comparing it to the genomic scaffold;
- emit the genomic feature-scaffold comment with the selected raw ID and allele name;
- retain scaffold orientation without its CIGAR;
- do not invoke `FullLengthONTMHCCandidateConsequenceAnnotator`.

For non-extensions, preserve the existing translation comparison, selected-reference, reciprocal-alignment, and consequence-annotation paths.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run:

```bash
swift test --filter FullLengthONTMHCCandidateGenBankArtifactBuilderTests.testExtensionRecordCommentsPersistCDNAAndSelectedGenomicInterpretations
```

Expected: PASS.

- [ ] **Step 5: Run the complete builder and affected MHC test suites**

Run:

```bash
swift test --filter 'FullLengthONTMHCCandidateGenBankArtifactBuilderTests|FullLengthONTMHCCandidateArtifactWriterTests|FullLengthONTMHCGenotypingPipelineTests|ONTGenotypeResultBundleTests'
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 6: Build and verify Lungfish Debug**

Run:

```bash
./scripts/build-app.sh --configuration debug --log-dir .superpowers/build-logs
codesign --verify --deep --strict build/Debug/Lungfish.app
```

Expected: successful Debug build named `Lungfish Debug`, with valid code signature.

- [ ] **Step 7: Commit**

```bash
git add \
  Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateGenBankArtifactBuilder.swift \
  Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateGenBankArtifactBuilderTests.swift \
  docs/superpowers/plans/2026-07-23-extension-cdna-relative-genbank-comments.md
git commit -m "fix: clarify cDNA-relative extension comments"
```


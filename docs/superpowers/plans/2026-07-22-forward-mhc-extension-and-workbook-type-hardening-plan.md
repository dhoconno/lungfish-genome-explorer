# Forward MHC Extension and Workbook Numeric-Type Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent current full-length MHC analyses from misclassifying zero-SNP genomic indels or truncated cDNA relationships as extensions, while allowing indels in true cDNA extensions and exporting current workbook statistics as native Excel numbers.

**Architecture:** Keep the reciprocal `FullLengthONTMHCCandidateClassifier` as the sole current classification authority. Broaden only its structurally complete cDNA-extension predicate to permit ordinary indels while retaining the zero-SNP and complete-coverage requirements. Add a typed analyst-header projection for the current two-sheet workbook; preserve legacy string projections and identifiers without modifying vestigial workflows.

**Tech Stack:** Swift, XCTest, SwiftPM, OOXML `.xlsx`, embedded Python/OpenPyXL workbook updater, existing Lungfish provenance and debug-build scripts.

---

### Task 1: Harden the authoritative cDNA-extension predicate

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateClassifier.swift:229-263,515-532`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift:4050-4090`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateClassifierTests.swift:24-105`

- [ ] **Step 1: Write failing classifier regressions**

Add separate tests that express the four forward rules:

```swift
func testCompleteCDNAExtensionAllowsOrdinaryIndelsWhenThereAreNoSNPs() throws {
    for (cigar, sequenceLength) in [
        ("499=1D50I500=", 1_049),
        ("499=1I1=50I500=", 1_051),
    ] {
        let cluster = makeCluster(
            sequenceLength: sequenceLength,
            alignments: [alignment(reference: cdnaReference, cigar: cigar)]
        )
        guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
            return XCTFail("Expected structural cDNA extension for \(cigar)")
        }
        XCTAssertEqual(candidate.classification, .extension)
        XCTAssertEqual(candidate.snpCount, 0)
        XCTAssertEqual(candidate.provisionalName, "Mafa-A1*018:01:01:01_ext")
    }
}

func testTerminallyTruncatedCDNAWithIntronInsertionIsKnownNotExtension() throws {
    let longCDNA = MHCReferenceRecord(
        sequenceID: "ref-long-cdna",
        alleleName: "Mafa-A2*024:01:01:01",
        locus: "Mafa-A2",
        moleculeClass: .cDNA,
        classEvidence: .annotatedMetadata,
        sequenceLength: 1_200
    )
    let cluster = makeCluster(
        sequenceLength: 1_150,
        alignments: [alignment(
            reference: longCDNA,
            cigar: "500=50I600=",
            referenceStart: 101
        )]
    )
    guard case .known(let calls) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
        return XCTFail("Expected existing cDNA genotype")
    }
    XCTAssertEqual(calls.map(\.reference.sequenceID), ["ref-long-cdna"])
}

func testCDNAIntronFillWithSNPIsNovelNotExtension() throws {
    let cluster = makeCluster(
        sequenceLength: 1_050,
        alignments: [alignment(reference: cdnaReference, cigar: "499=1X50I500=")]
    )
    guard case .candidate(let candidate) = try FullLengthONTMHCCandidateClassifier().classify(cluster) else {
        return XCTFail("Expected novel candidate")
    }
    XCTAssertEqual(candidate.classification, .novel)
    XCTAssertEqual(candidate.provisionalName, "Mafa-A1*018:01:01:01_1nt_nov")
}
```

Retain the existing genomic-indel-known test as the regression for the reported A1 shape.

- [ ] **Step 2: Run the new tests and verify RED**

Run:

```bash
swift test --filter 'FullLengthONTMHCCandidateClassifierTests/testCompleteCDNAExtensionAllowsOrdinaryIndelsWhenThereAreNoSNPs|FullLengthONTMHCCandidateClassifierTests/testTerminallyTruncatedCDNAWithIntronInsertionIsKnownNotExtension|FullLengthONTMHCCandidateClassifierTests/testCDNAIntronFillWithSNPIsNovelNotExtension'
```

Expected: the ordinary-indel extension test fails because `isExactCDNAExtension` currently requires identity 1, zero non-intron indels, and zero deletions. The truncation and SNP tests may already pass; record those results rather than weakening them.

- [ ] **Step 3: Implement the minimal authoritative predicate change**

Rename the predicate to reflect structural rather than exact identity and remove only the guards that prohibit ordinary indels:

```swift
private func isCDNAExtension(
    _ hit: AnalyzedAlignment,
    cluster: FullLengthONTMHCCandidateCluster
) -> Bool {
    guard let reference = hit.resolvedReference,
          reference.moleculeClass == .cDNA,
          hit.metrics.snps == 0,
          hit.metrics.comparableBases == reference.sequenceLength,
          hit.longGapBases > 0,
          hit.metrics.skippedReferenceBases == 0,
          hit.metrics.softClippedBases == 0,
          hit.metrics.querySpan == cluster.sequenceLength else {
        return false
    }
    return true
}
```

Update both call sites from `isExactCDNAExtension` to `isCDNAExtension`. Do not change genomic-known ordering, eligibility thresholds, SNP counting, support policy, preliminary closest-hit logic, or legacy worksheets.

- [ ] **Step 4: Update current-workflow interpretation text**

Revise the current interpretation row to say that genomic zero-SNP indels remain known, whereas a complete zero-SNP cDNA relationship with internal intron filling is `_ext` and may also contain ordinary recorded indels. State explicitly that any SNP prevents extension classification.

- [ ] **Step 5: Run classifier and pipeline tests and verify GREEN**

Run:

```bash
swift test --filter 'FullLengthONTMHCCandidateClassifierTests|FullLengthONTMHCGenotypingPipelineTests'
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 6: Build and launch the first debug change set**

Run:

```bash
./scripts/build-app.sh --configuration debug --log-dir .superpowers/build-logs
```

Verify `CFBundleDisplayName` is `Lungfish Debug`, the bundle identifier is `com.lungfish.browser.debug`, and the app passes `codesign --verify --deep --strict`. Quit existing Lungfish processes and launch only this app bundle.

- [ ] **Step 7: Commit the classifier change set**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateClassifier.swift \
  Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift \
  Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateClassifierTests.swift
git commit -m "fix: harden forward MHC extension classification"
```

### Task 2: Emit native numbers in the current Unified workbook header

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift:5815-5885,6740-6770`
- Test: `Tests/LungfishWorkflowTests/FullLengthONTMHCWorkbookProjectionTests.swift:255-315,492-560`
- Test: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift:200-350,3550-3620`

- [ ] **Step 1: Write failing in-memory cell-type assertions**

In `testUnifiedWorkbookCellsPrependAnalystHeaderAndMapKnownDisplayNamesWithoutConflation`, find rows by their first text cell and assert exact cell variants:

```swift
let mappedRow = try XCTUnwrap(cells.first { $0.first?.value == .text("Mapped Read Count") })
XCTAssertEqual(mappedRow[1].value, .integer(17))
XCTAssertEqual(mappedRow[2].value, .decimal(17))
XCTAssertEqual(mappedRow[12].value, .integer(17))

let totalRow = try XCTUnwrap(cells.first { $0.first?.value == .text("total_read_count") })
XCTAssertEqual(totalRow[12].value, .integer(20))

let unmappedRow = try XCTUnwrap(cells.first { $0.first?.value == .text("percent_reads_unmapped") })
XCTAssertEqual(unmappedRow[12].value, .decimal(15))
```

Also assert that a numeric-looking sample identifier remains `.text`.

- [ ] **Step 2: Write failing OOXML assertions**

Export `buildWorkbookCells` and assert representative summary cells use numeric `<v>` elements and do not use `t="inlineStr"`. Cover mapped total, mapped average, per-sample mapped reads, total reads, and percent unmapped.

- [ ] **Step 3: Run workbook projection tests and verify RED**

Run:

```bash
swift test --filter 'FullLengthONTMHCWorkbookProjectionTests/testUnifiedWorkbookCellsPrependAnalystHeaderAndMapKnownDisplayNamesWithoutConflation|FullLengthONTMHCWorkbookProjectionTests/testWorkbookWritesFourTintStylesOnlyOnCandidateNameCellsAndUsesTypedNumbers'
```

Expected: the new summary assertions fail because the current bridge wraps all analyst-header values as `.text`.

- [ ] **Step 4: Add a typed header-cell projection**

Add `FullLengthONTMHCPivotWorkbookBuilder.buildHeaderCells(...)` that uses `.integer` for counts, `.decimal` for averages and percentages, `.text` for labels/identifiers/haplotypes/comments, and `.blank` for empty cells. Keep `buildHeaderRows(...)` available for existing consumers by rendering typed cells back to their prior strings.

Update `FullLengthONTMHCUnifiedPivotWorkbookBuilder.buildWorkbookCells(...)` to use the typed header cells directly before inserting the nine blank Unified metadata columns. Do not generically parse numeric-looking text.

- [ ] **Step 5: Add explicit-update numeric type verification**

Extend the existing OpenPyXL inspection helper in `GenotypeWorkbookRevisionServiceTests` to report `cell.data_type` for representative cells. Assert `n` for summary statistics, Unified counts/sample reads, and Unmatched numeric/sample-read fields, while numeric-looking IDs remain `s`.

- [ ] **Step 6: Run workbook tests and verify GREEN**

Run:

```bash
swift test --filter 'FullLengthONTMHCWorkbookProjectionTests|GenotypeWorkbookRevisionServiceTests'
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 7: Build and launch the second debug change set**

Run the debug build, plist identity, signature, single-process relaunch, and bounded-memory launch checks from Task 1 again.

- [ ] **Step 8: Commit the workbook change set**

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift \
  Tests/LungfishWorkflowTests/FullLengthONTMHCWorkbookProjectionTests.swift \
  Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift
git commit -m "fix: write MHC workbook summaries as numbers"
```

### Task 3: Verify the complete forward workflow

**Files:**
- Verify: `docs/superpowers/specs/2026-07-22-mhc-extension-and-workbook-type-hardening-design.md`
- Verify: `docs/superpowers/plans/2026-07-22-forward-mhc-extension-and-workbook-type-hardening-plan.md`

- [ ] **Step 1: Run the complete focused suite**

```bash
swift test --filter 'FullLengthONTMHCCandidateClassifierTests|FullLengthONTMHCWorkbookProjectionTests|FullLengthONTMHCGenotypingPipelineTests|GenotypeWorkbookRevisionServiceTests|GenotypeResultViewportTests|AppDebugLaunchConfigurationTests'
```

Expected: all selected tests pass with zero failures.

- [ ] **Step 2: Run a fresh four-sample current workflow**

Use the bundled debug CLI with CR1178, CR1178b, CR1182, and CR1182b, the approved Mafa reference bundle, a new output bundle name, and the established current CLI options. Require exit status zero and final successful provenance.

- [ ] **Step 3: Verify scientific artifacts and provenance**

Confirm:

- both BAMs pass `samtools quickcheck`, are coordinate sorted, and have working indexes;
- final candidate, un-nameable, FASTA, GenBank, JSON, workbook, and manifest paths exist;
- final provenance records the exact argv/resolved defaults, runtime identity, input/output paths, checksums, sizes, zero exit status, and wall time; and
- provenance workbook checksum/size match the final stored workbook.

- [ ] **Step 4: Inspect the final workbook with the spreadsheet runtime**

Using `@oai/artifact-tool`, verify the workbook contains exactly `Unified Genotype Pivot` and `Unmatched Alleles`, scan for formula errors, confirm representative semantic numerics have JavaScript `number` values, confirm identifier cells remain strings, and render both sheets for visual inspection.

- [ ] **Step 5: Request final code review**

Provide the reviewer the approved spec, base SHA, head SHA, focused test output, four-sample verification evidence, and explicit confirmation that vestigial workflows were not changed. Resolve all Critical and Important findings.

- [ ] **Step 6: Build and relaunch the final debug app**

Create a fresh signed debug build, quit every Lungfish process, and open only the exact `Lungfish Debug` bundle with the new verification result. Confirm a single process remains running and memory stays bounded during initial load and row selection.

- [ ] **Step 7: Final repository checks**

```bash
git diff --check
git status --short --branch
```

Expected: no whitespace errors and a clean feature branch.

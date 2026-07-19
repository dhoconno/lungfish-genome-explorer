# Full-Length MHC Candidate Genotyping Viewport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce reproducible candidate-allele and alignment artifacts from fresh full-length ONT MHC analyses, then show known, singleton novel/extension, and shared novel/extension rows in only the full-length genotyping viewport and both Excel workbook views.

**Architecture:** The CLI workflow remains the only scientific producer: it creates two cohort BAM/BAI pairs, classifies stable unmatched clusters, publishes versioned JSON/FASTA artifacts, and records complete provenance. LungfishIO validates and loads the optional artifacts, while LungfishGenotypeUI projects them into stable-ID matrix rows with per-bundle visibility and four tint settings; the GUI never remaps or reclassifies sequences. Work is split into three releasable changesets, each ending in focused tests and a newly built and launched `Lungfish Debug` app.

**Tech Stack:** Swift 6, Swift Package Manager/XCTest, AppKit, SQLite3, minimap2, samtools, Codable JSON, FASTA/SAM/BAM, Python openpyxl workbook updater, macOS app bundle scripts.

---

## Scope guardrails

- Change only the full-length ONT MHC analysis, its `.lungfishgenotype` bundle contract, its workbook projections, and its viewport.
- Preserve legacy bundles and every other genotype surface.
- Require a fresh analysis for candidate artifacts; do not migrate or rewrite an existing result.
- Treat the stable cluster ID as row identity. Equal provisional labels never merge distinct sequences.
- Treat a zero-SNP genomic match as the existing allele even if it has insertion/deletion differences. Never emit `_0nt_nov`.
- Count only substitutions in `<N>nt_nov`.
- Keep all candidate and un-nameable records in Excel regardless of viewport filters.
- Make tint synchronization to `current.xlsx` an explicit Update Current Workbook action.
- Satisfy `AGENTS.md`: every scientific command and transformation records complete provenance, including exact argv, resolved defaults, runtime/tool versions, paths, checksums, sizes, status, duration, and useful stderr.

## File map

### New source files

- `Sources/LungfishIO/Bundles/ONTMHCCandidateAlleles.swift` — versioned candidate/un-nameable JSON models and typed artifact references.
- `Sources/LungfishIO/Bundles/MHCReferenceRecordCatalog.swift` — annotated `.lungfishref` SQLite metadata reader with FASTA fallback.
- `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCSAMMetrics.swift` — one `=/X/I/D/N/S` metric parser shared by known-call and candidate classification.
- `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCohortAlignmentBuilder.swift` — temporary sample BAMs, read groups, merge/sort/index/quickcheck, and atomic publication.
- `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateClassifier.swift` — deterministic closest-reference ranking and known/novel/extension/un-nameable classification.
- `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateArtifactWriter.swift` — stable JSON/FASTA publication with checksums.
- `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCWorkbookProjection.swift` — shared workbook row projection for initial and current workbooks.
- `Sources/LungfishGenotypeUI/GenotypeCandidateMatrixRow.swift` — stable candidate matrix identity and category/tint metadata.
- `Sources/LungfishGenotypeUI/GenotypeCandidateEvidenceSection.swift` — full-length-only candidate filters, tint controls, and evidence detail.

### Existing source files

- `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCClusterGenotyper.swift` — consume shared SAM metrics and apply zero-SNP genotype semantics.
- `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift` — orchestrate the two BAMs, classifier, artifact writers, workbook projection, and provenance.
- `Sources/LungfishCLI/Commands/FastqFullLengthONTMHCGenotypingSubcommand.swift` — expose resulting artifact paths and preserve exact CLI provenance.
- `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift` — optional candidate manifest loading and integrity warnings.
- `Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift` — per-bundle filter/tint settings.
- `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift` and `GenotypeWorkbookRevisionService+OverrideScript.swift` — explicit `current.xlsx` candidate sheets and tint refresh.
- `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`, `GenotypeComparisonMatrixView.swift`, `GenotypeResultDisplayState.swift`, and `GenotypeResultDisplaySection.swift` — full-length-only combined rows and controls.
- `scripts/build-app.sh` and app Info.plist generation sources — ensure the debug menu/build identity is `Lungfish Debug`.

### Tests

- `Tests/LungfishWorkflowTests/FullLengthONTMHCSAMMetricsTests.swift`
- `Tests/LungfishWorkflowTests/FullLengthONTMHCCohortAlignmentBuilderTests.swift`
- `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateClassifierTests.swift`
- `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateArtifactWriterTests.swift`
- `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`
- `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`
- `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`
- `Tests/LungfishIOTests/MHCReferenceRecordCatalogTests.swift`
- `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`
- `Tests/LungfishAppTests/AppDebugLaunchConfigurationTests.swift`
- `Tests/LungfishCLITests/FastqFullLengthONTMHCGenotypingCommandTests.swift`

## Changeset 1 — Durable cohort genotyping evidence

### Task 1: Add typed optional artifact contracts

**Files:**
- Create: `Sources/LungfishIO/Bundles/ONTMHCCandidateAlleles.swift`
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`
- Test: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`

- [ ] **Step 1: Write failing bundle-contract tests**

Add tests that decode an old manifest with no candidate field, round-trip a new typed pair, and reject a declared pair missing its index:

```swift
func testLegacyManifestDecodesWithoutCandidateArtifacts() throws {
    let legacy = ONTGenotypeResultBundleManifest(
        kind: "full-length-ont-mhc-genotype",
        outputName: "legacy",
        analysisName: "Legacy",
        primaryWorkbookPath: "legacy.xlsx",
        longSummaryCSVPath: "calls.csv",
        sampleSummaryCSVPath: "samples.csv",
        statsJSONPath: "stats.json",
        provenancePath: "provenance.json"
    )
    let manifest = try JSONDecoder().decode(
        ONTGenotypeResultBundleManifest.self,
        from: JSONEncoder().encode(legacy)
    )
    XCTAssertNil(manifest.mhcCandidateArtifacts)
}

func testCandidateArtifactManifestRoundTripsChecksummedBAMPairs() throws {
    let bam = ONTMHCBAMArtifactPair(
        bam: .init(path: "artifacts/alignments/genotyping-evidence.bam", sha256: "aa", sizeBytes: 12),
        bai: .init(path: "artifacts/alignments/genotyping-evidence.bam.bai", sha256: "bb", sizeBytes: 4)
    )
    let value = ONTMHCCandidateArtifactManifest(
        schemaVersion: 1,
        genotypingEvidence: bam,
        reciprocalEvidence: nil,
        candidateJSON: nil,
        candidateFASTA: nil,
        unnameableJSON: nil,
        unnameableFASTA: nil
    )
    XCTAssertEqual(
        try JSONDecoder().decode(ONTMHCCandidateArtifactManifest.self, from: JSONEncoder().encode(value)),
        value
    )
}
```

- [ ] **Step 2: Run the focused test and confirm it fails**

Run: `swift test --filter ONTGenotypeResultBundleTests`

Expected: FAIL because `ONTMHCArtifactReference`, `ONTMHCBAMArtifactPair`, and `mhcCandidateArtifacts` do not exist.

- [ ] **Step 3: Add the versioned types and optional manifest field**

Implement the complete public value types with explicit snake-case coding keys:

```swift
public struct ONTMHCArtifactReference: Codable, Equatable, Sendable {
    public let path: String
    public let sha256: String
    public let sizeBytes: Int64
    public init(path: String, sha256: String, sizeBytes: Int64) {
        self.path = path; self.sha256 = sha256; self.sizeBytes = sizeBytes
    }
}

public struct ONTMHCBAMArtifactPair: Codable, Equatable, Sendable {
    public let bam: ONTMHCArtifactReference
    public let bai: ONTMHCArtifactReference
    public init(bam: ONTMHCArtifactReference, bai: ONTMHCArtifactReference) {
        self.bam = bam; self.bai = bai
    }
}

public struct ONTMHCCandidateArtifactManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let genotypingEvidence: ONTMHCBAMArtifactPair?
    public let reciprocalEvidence: ONTMHCBAMArtifactPair?
    public let candidateJSON: ONTMHCArtifactReference?
    public let candidateFASTA: ONTMHCArtifactReference?
    public let unnameableJSON: ONTMHCArtifactReference?
    public let unnameableFASTA: ONTMHCArtifactReference?
    public init(
        schemaVersion: Int,
        genotypingEvidence: ONTMHCBAMArtifactPair?,
        reciprocalEvidence: ONTMHCBAMArtifactPair?,
        candidateJSON: ONTMHCArtifactReference?,
        candidateFASTA: ONTMHCArtifactReference?,
        unnameableJSON: ONTMHCArtifactReference?,
        unnameableFASTA: ONTMHCArtifactReference?
    ) {
        self.schemaVersion = schemaVersion
        self.genotypingEvidence = genotypingEvidence
        self.reciprocalEvidence = reciprocalEvidence
        self.candidateJSON = candidateJSON
        self.candidateFASTA = candidateFASTA
        self.unnameableJSON = unnameableJSON
        self.unnameableFASTA = unnameableFASTA
    }
}
```

Add `mhcCandidateArtifacts: ONTMHCCandidateArtifactManifest?` to only the full-length result manifest, leaving absence legal.

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter ONTGenotypeResultBundleTests`

Expected: PASS.

```bash
git add Sources/LungfishIO/Bundles/ONTMHCCandidateAlleles.swift Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift
git commit -m "feat: add MHC candidate artifact contracts"
```

### Task 2: Centralize alignment metrics and correct zero-SNP semantics

**Files:**
- Create: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCSAMMetrics.swift`
- Create: `Tests/LungfishWorkflowTests/FullLengthONTMHCSAMMetricsTests.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCClusterGenotyper.swift`
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`

- [ ] **Step 1: Replace the obsolete extension expectation with failing biological rules**

Add exact CIGAR cases:

```swift
func testMetricsCountOnlyXAsSNPs() throws {
    let metrics = try FullLengthONTMHCSAMMetrics(cigar: "100=2X30I40D900=", nm: 72)
    XCTAssertEqual(metrics.snps, 2)
    XCTAssertEqual(metrics.nonIntronIndelBases, 70)
    XCTAssertEqual(metrics.comparableBases, 1_002)
}

func testClusterGenotyperTreatsZeroSNPIndelOnlyHitAsKnownGenotype() throws {
    let call = try genotype(cigar: "1000=30I900=", reference: "Mafa-A1*018:01:01:01")
    XCTAssertEqual(call.genotype, "Mafa-A1*018:01:01:01")
    XCTAssertEqual(call.snpCount, 0)
}
```

Delete or rewrite `testClusterGenotyperTreatsZeroSNPIndelOnlyHitAsExtension`; `_extension` is no longer a valid classification.

- [ ] **Step 2: Run the tests and confirm the semantic test fails**

Run: `swift test --filter FullLengthONTMHCSAMMetricsTests && swift test --filter FullLengthONTMHCGenotypingPipelineTests.testClusterGenotyperTreatsZeroSNPIndelOnlyHitAsKnownGenotype`

Expected: first command fails to compile; second fails under the current `_extension` behavior.

- [ ] **Step 3: Implement the single CIGAR metric parser**

```swift
struct FullLengthONTMHCSAMMetrics: Equatable, Sendable {
    let matches: Int
    let snps: Int
    let insertedBases: Int
    let deletedBases: Int
    let skippedReferenceBases: Int
    let softClippedBases: Int
    var comparableBases: Int { matches + snps }
    var nonIntronIndelBases: Int { insertedBases + deletedBases }
    var referenceSpan: Int { matches + snps + deletedBases + skippedReferenceBases }
    var querySpan: Int { matches + snps + insertedBases + softClippedBases }
}
```

Parse numeric/operator runs, reject malformed/unsupported operators with a typed error, count `=` as matches and `X` as substitutions, and use `M` only with `NM` reconciliation. Make `FullLengthONTMHCClusterGenotyper` call this parser and accept every eligible genomic hit with `snps == 0` as known, irrespective of `I`/`D`.

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter FullLengthONTMHCSAMMetricsTests && swift test --filter FullLengthONTMHCGenotypingPipelineTests`

Expected: PASS (31 baseline pipeline tests plus new tests).

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCSAMMetrics.swift Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCClusterGenotyper.swift Tests/LungfishWorkflowTests/FullLengthONTMHCSAMMetricsTests.swift Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift
git commit -m "fix: treat zero SNP MHC alignments as known genotypes"
```

### Task 3: Build the cohort BAM atomically

**Files:**
- Create: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCohortAlignmentBuilder.swift`
- Create: `Tests/LungfishWorkflowTests/FullLengthONTMHCCohortAlignmentBuilderTests.swift`
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`

- [ ] **Step 1: Write failing command-plan and cleanup tests**

Test that two samples produce namespaced target IDs and unique RG records, and that publication executes this order:

```swift
XCTAssertEqual(plan.sampleMappings[0].readGroup, "@RG\\tID:CR1178\\tSM:CR1178")
XCTAssertTrue(plan.sampleMappings[0].targetPrefix.hasPrefix("CR1178|"))
XCTAssertEqual(plan.finalBAM.lastPathComponent, "genotyping-evidence.bam")
XCTAssertEqual(plan.finalBAI.lastPathComponent, "genotyping-evidence.bam.bai")
XCTAssertEqual(plan.validationCommands.map(\.executableName), ["samtools", "samtools"])
```

Use a fake tool directory whose scripts append argv to a log and create only requested output files. Assert temporary BAMs remain after failure and are removed after full success unless `keepIntermediates` is true.

- [ ] **Step 2: Run the focused tests and confirm failure**

Run: `swift test --filter FullLengthONTMHCCohortAlignmentBuilderTests`

Expected: FAIL because the builder is absent.

- [ ] **Step 3: Implement the builder and exact command sequence**

Model each invocation as an argv array (never a shell string) and record it in provenance. Use:

```text
minimap2 -a -x splice --eqx -t <threads> -N 100 --secondary=yes <namespaced-clusters.fa> <reference.fa>
samtools view -b -o <sample.unsorted.bam> <sample.sam>
samtools addreplacerg -r ID:<sample> -r SM:<sample> -o <sample.rg.bam> <sample.unsorted.bam>
samtools sort -o <sample.sorted.bam> <sample.rg.bam>
samtools merge -f -o <cohort.merged.bam> <all sample.sorted.bam paths>
samtools sort -o <staged genotyping-evidence.bam> <cohort.merged.bam>
samtools index <staged genotyping-evidence.bam> <staged genotyping-evidence.bam.bai>
samtools quickcheck <staged genotyping-evidence.bam>
samtools idxstats <staged genotyping-evidence.bam>
```

Write namespaced FASTA headers as `<sampleID>|<originalClusterID>`, preserve the original in metadata, move the validated pair into `artifacts/alignments` only after both exist, and return paths plus per-command provenance results.

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter FullLengthONTMHCCohortAlignmentBuilderTests`

Expected: PASS.

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCohortAlignmentBuilder.swift Tests/LungfishWorkflowTests/FullLengthONTMHCCohortAlignmentBuilderTests.swift Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift
git commit -m "feat: retain merged MHC genotyping evidence BAM"
```

### Task 4: Make the final BAM authoritative in the CLI pipeline

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqFullLengthONTMHCGenotypingSubcommand.swift`
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`
- Modify: `Tests/LungfishCLITests/FastqFullLengthONTMHCGenotypingCommandTests.swift`

- [ ] **Step 1: Write failing end-to-end fake-tool tests**

Extend the fake conda root with a `samtools` program and assert:

```swift
XCTAssertTrue(fileExists("artifacts/alignments/genotyping-evidence.bam"))
XCTAssertTrue(fileExists("artifacts/alignments/genotyping-evidence.bam.bai"))
XCTAssertEqual(result.manifest.mhcCandidateArtifacts?.genotypingEvidence?.bam.path,
               "artifacts/alignments/genotyping-evidence.bam")
XCTAssertTrue(result.provenance.commands.contains { $0.argv.starts(with: ["samtools", "merge"]) })
```

Assert known calls are parsed from the merged evidence path, not the deleted per-sample SAM path, and checkpoint reuse remaps retained clusters rather than reusing stale genotype summaries.

- [ ] **Step 2: Run tests and confirm failure**

Run: `swift test --filter FullLengthONTMHCGenotypingPipelineTests && swift test --filter FastqFullLengthONTMHCGenotypingCommandTests`

Expected: FAIL because the pipeline does not publish or return a BAM pair.

- [ ] **Step 3: Wire the builder, final-BAM parser, manifest, and provenance**

Add the builder after sample cluster generation; parse the final BAM through `samtools view -h` using read group and namespaced reference identity; checksum/size both files before writing `genotype-result.json`; include the pair in the CLI JSON/text result. Do not declare candidate JSON fields yet.

Extend the existing `FullLengthONTMHCProvenanceStep` path and record each command with this complete shape; resolved user options/defaults and runtime identity stay in the enclosing `ProvenanceRunBuilder` envelope:

```swift
FullLengthONTMHCProvenanceStep(
    toolName: executableName,
    toolVersion: toolVersion,
    argv: argv,
    inputs: finalInputURLs,
    outputs: finalOutputURLs,
    exitStatus: status,
    stderr: stderr.isEmpty ? nil : stderr,
    startedAt: startedAt,
    completedAt: completedAt
)
```

The final bundle must point to the final stored BAM paths, never staging paths.

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter FullLengthONTMHCGenotypingPipelineTests && swift test --filter FastqFullLengthONTMHCGenotypingCommandTests && swift test --filter ONTGenotypeResultBundleTests`

Expected: PASS.

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift Sources/LungfishCLI/Commands/FastqFullLengthONTMHCGenotypingSubcommand.swift Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift Tests/LungfishCLITests/FastqFullLengthONTMHCGenotypingCommandTests.swift
git commit -m "feat: make cohort BAM the MHC genotype evidence source"
```

### Task 5: Verify and launch changeset 1

**Files:**
- Modify if needed: `scripts/build-app.sh`
- Modify if needed: `Tests/LungfishAppTests/AppDebugLaunchConfigurationTests.swift`

- [ ] **Step 1: Lock debug identity with a failing test if CFBundleName is wrong**

```swift
XCTAssertEqual(try plistString("CFBundleName"), "Lungfish Debug")
XCTAssertEqual(try plistString("CFBundleIdentifier"), "com.lungfish.browser.debug")
XCTAssertTrue(FileManager.default.isExecutableFile(atPath: bundledCLIPath))
```

- [ ] **Step 2: Run focused tests and build**

```bash
swift test --filter FullLengthONTMHCCohortAlignmentBuilderTests
swift test --filter FullLengthONTMHCGenotypingPipelineTests
swift test --filter ONTGenotypeResultBundleTests
swift test --filter AppDebugLaunchConfigurationTests
scripts/build-app.sh --configuration debug
```

Expected: all tests PASS and build exits 0.

- [ ] **Step 3: Verify bundle identity and launch a fresh instance**

```bash
test "$(/usr/bin/plutil -extract CFBundleName raw -o - build/Debug/Lungfish.app/Contents/Info.plist)" = "Lungfish Debug"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - build/Debug/Lungfish.app/Contents/Info.plist)" = "com.lungfish.browser.debug"
test -x build/Debug/Lungfish.app/Contents/MacOS/lungfish-cli
open -n build/Debug/Lungfish.app
```

Expected: all checks exit 0 and the menu/app identity is Lungfish Debug.

- [ ] **Step 4: Commit any debug identity correction**

```bash
git add scripts/build-app.sh Tests/LungfishAppTests/AppDebugLaunchConfigurationTests.swift
git diff --cached --quiet || git commit -m "fix: identify debug app as Lungfish Debug"
```

## Changeset 2 — Candidate classification and scientific exports

### Task 6: Resolve annotated reference names, loci, and molecule class

**Files:**
- Create: `Sources/LungfishIO/Bundles/MHCReferenceRecordCatalog.swift`
- Create: `Tests/LungfishIOTests/MHCReferenceRecordCatalogTests.swift`

- [ ] **Step 1: Write failing SQLite and FASTA fallback tests**

Create a temporary SQLite fixture with `records` and `field_values` matching `.lungfishref` and verify:

```swift
XCTAssertEqual(record.sequenceID, "NHP01222")
XCTAssertEqual(record.alleleName, "Mafa-A1*006:01:01:01")
XCTAssertEqual(record.locus, "Mafa-A1")
XCTAssertEqual(record.moleculeClass, .genomicDNA)
XCTAssertEqual(cDNARecord.moleculeClass, .cDNA)
```

Also create a FASTA-only fixture and assert the header description supplies the allele and `sequenceLength < cdnaThreshold` supplies `.cDNA` with `.lengthThresholdFallback` evidence.

- [ ] **Step 2: Run tests and confirm failure**

Run: `swift test --filter MHCReferenceRecordCatalogTests`

Expected: FAIL because the catalog does not exist.

- [ ] **Step 3: Implement deterministic catalog loading**

```swift
public enum MHCReferenceMoleculeClass: String, Codable, Sendable { case genomicDNA, cDNA }
public enum MHCReferenceClassEvidence: String, Codable, Sendable { case annotatedMetadata, lengthThresholdFallback }
public struct MHCReferenceRecord: Codable, Equatable, Sendable {
    public let sequenceID: String
    public let alleleName: String
    public let locus: String
    public let moleculeClass: MHCReferenceMoleculeClass
    public let classEvidence: MHCReferenceClassEvidence
    public let sequenceLength: Int
}
```

Decode `record_store.database_path` from the reference manifest; query `feature.allele`, `feature.gene`, and `feature.mol_type` read-only; parse FASTA headers as fallback; fail with a typed ambiguity error when an ID has conflicting classes or no resolvable allele/locus.

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter MHCReferenceRecordCatalogTests`

Expected: PASS.

```bash
git add Sources/LungfishIO/Bundles/MHCReferenceRecordCatalog.swift Tests/LungfishIOTests/MHCReferenceRecordCatalogTests.swift
git commit -m "feat: resolve MHC reference allele metadata"
```

### Task 7: Implement the pure candidate classifier

**Files:**
- Expand: `Sources/LungfishIO/Bundles/ONTMHCCandidateAlleles.swift`
- Create: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateClassifier.swift`
- Create: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateClassifierTests.swift`

- [ ] **Step 1: Write the complete failing rule matrix**

Use table-driven tests covering: zero-SNP genomic plus indel => known; complete zero-SNP cDNA plus intron-sized query insertion => extension; 1/5 SNP => `_1nt_nov`/`_5nt_nov`; two samples => shared; one sample => singleton; label collision => two records; and every un-nameable reason.

```swift
XCTAssertEqual(classify(genomicZeroSNPIndel).kind, .known(referenceAllele: "Mafa-A1*018:01:01:01"))
XCTAssertEqual(classify(cDNAWithIntron).candidate?.provisionalName, "Mafa-A1*018:01:01:01_ext")
XCTAssertEqual(classify(fiveSNPs).candidate?.provisionalName, "Mafa-A1*018:01:01:01_5nt_nov")
XCTAssertFalse(classify(fiveSNPs).candidate!.provisionalName.contains("_0nt_nov"))
XCTAssertEqual(shared.supportClass, .shared)
XCTAssertEqual(singleton.supportClass, .singleton)
```

- [ ] **Step 2: Run tests and confirm failure**

Run: `swift test --filter FullLengthONTMHCCandidateClassifierTests`

Expected: FAIL because candidate models/classifier are absent.

- [ ] **Step 3: Implement models, thresholds, ranking, and classification order**

```swift
public enum ONTMHCCandidateClassification: String, Codable, Sendable { case novel, extension }
public enum ONTMHCCandidateSupportClass: String, Codable, Sendable { case singleton, shared }
public enum ONTMHCUnnameableReason: String, Codable, Sendable {
    case noAlignment = "no-alignment"
    case insufficientAlignedBases = "insufficient-aligned-bases"
    case insufficientCoverage = "insufficient-coverage"
    case insufficientIdentity = "insufficient-identity"
    case unresolvedLocus = "unresolved-locus"
    case ambiguousReferenceClass = "ambiguous-reference-class"
}
public struct ONTMHCCandidateThresholds: Codable, Equatable, Sendable {
    public let minimumAlignedBases: Int       // 1000
    public let minimumIdentity: Double       // 0.75
    public let minimumShorterCoverage: Double // 0.70
    public let minimumIntronGapBases: Int    // 20
}

public struct ONTMHCEvidenceLocator: Codable, Equatable, Sendable {
    public let bamPath: String
    public let queryName: String
    public let referenceName: String
    public let readGroupID: String?
    public let referenceStart: Int
    public let cigar: String
}
public struct ONTMHCCandidateObservation: Codable, Equatable, Sendable {
    public let stableClusterID: String
    public let sampleID: String
    public let readGroupID: String
    public let sourceClusterIDs: [String]
    public let sourceClusterReadCounts: [String: Int]
    public let aggregatedSampleReadCount: Int
    public let evidence: [ONTMHCEvidenceLocator]
}
public struct ONTMHCCandidateRecord: Codable, Equatable, Sendable {
    public let stableClusterID: String
    public let provisionalName: String
    public let locus: String
    public let classification: ONTMHCCandidateClassification
    public let supportClass: ONTMHCCandidateSupportClass
    public let closestReferenceName: String
    public let closestReferenceClass: MHCReferenceMoleculeClass
    public let snpCount: Int
    public let insertedBases: Int
    public let deletedBases: Int
    public let longGapBases: Int
    public let comparableBases: Int
    public let shorterCoverage: Double
    public let identity: Double
    public let mappingQuality: Int
    public let alignmentScore: Int
    public let independentSampleCount: Int
    public let occurrenceCount: Int
    public let totalClusterReads: Int
    public let supportingSampleIDs: [String]
    public let fastaRecordID: String
    public let sequenceSHA256: String
    public let selectedEvidence: ONTMHCEvidenceLocator
}
public struct ONTMHCUnnameableRecord: Codable, Equatable, Sendable {
    public let stableClusterID: String
    public let reason: ONTMHCUnnameableReason
    public let failedMetrics: [String: Double]
    public let supportClass: ONTMHCCandidateSupportClass
    public let independentSampleCount: Int
    public let occurrenceCount: Int
    public let totalClusterReads: Int
    public let supportingSampleIDs: [String]
    public let fastaRecordID: String
    public let sequenceSHA256: String
    public let evidence: [ONTMHCEvidenceLocator]
}
public struct ONTMHCCandidateAllelesDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let createdAt: String
    public let thresholds: ONTMHCCandidateThresholds
    public let inputs: [ONTMHCArtifactReference]
    public let evidence: [ONTMHCArtifactReference]
    public let sequenceFASTA: ONTMHCArtifactReference
    public let candidates: [ONTMHCCandidateRecord]
    public let observations: [ONTMHCCandidateObservation]
}
public struct ONTMHCUnnameableClustersDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let createdAt: String
    public let thresholds: ONTMHCCandidateThresholds
    public let sequenceFASTA: ONTMHCArtifactReference
    public let clusters: [ONTMHCUnnameableRecord]
    public let observations: [ONTMHCCandidateObservation]
}
```

Apply binding order: eligible zero-SNP genomic known; exact complete cDNA extension; SNP-positive novel; explicit un-nameable. Rank defensible hits by SNPs ascending, comparable bases descending, non-intron indel bases ascending, AS descending, MAPQ descending, localized allele name ascending. Deduplicate support by distinct sample ID, never by observation count.

The JSON record models must carry the complete approved projection rather than recomputing it in the app: stable ID, provisional name/locus/classification/support class, closest reference name/class, SNP/insertion/deletion/long-gap/comparable-base/coverage/identity/MAPQ/score metrics, independent sample count, occurrence count, total cluster reads, ordered sample IDs, FASTA record/checksum, BAM/BAI path and alignment locators. Observation records carry stable ID, sample ID/read-group, source cluster IDs and read counts, aggregated sample reads, and alignment locators. Un-nameable records use the same identity/support/evidence fields plus reason and failed-threshold metrics. Sequence bases live only in FASTA.

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter FullLengthONTMHCCandidateClassifierTests && swift test --filter FullLengthONTMHCSAMMetricsTests`

Expected: PASS.

```bash
git add Sources/LungfishIO/Bundles/ONTMHCCandidateAlleles.swift Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateClassifier.swift Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateClassifierTests.swift
git commit -m "feat: classify MHC novel and extension candidates"
```

### Task 8: Publish reciprocal BAM and deterministic candidate artifacts

**Files:**
- Create: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateArtifactWriter.swift`
- Create: `Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateArtifactWriterTests.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`

- [ ] **Step 1: Write failing reciprocal-command and artifact tests**

Assert the exact target/query order and outputs:

```swift
XCTAssertEqual(minimapArgv.prefix(8), ["minimap2", "-a", "--eqx", "--cs=long", "-x", "asm20", "-t", "14"])
XCTAssertEqual(minimapArgv.suffix(2), [referenceFASTA.path, stableUnmatchedFASTA.path])
XCTAssertEqual(candidateFASTA.headers, ["cluster-shared", "cluster-singleton"])
XCTAssertEqual(unnameableFASTA.headers, ["cluster-unresolved"])
XCTAssertEqual(candidateJSON.schemaVersion, 1)
```

Assert records are sorted by stable cluster ID, JSON uses sorted keys, and stable IDs are sequence-derived and unchanged by sample input order.

- [ ] **Step 2: Run focused tests and confirm failure**

Run: `swift test --filter FullLengthONTMHCCandidateArtifactWriterTests && swift test --filter FullLengthONTMHCGenotypingPipelineTests`

Expected: FAIL because reciprocal evidence and classified artifacts are absent.

- [ ] **Step 3: Implement one cohort reciprocal alignment and atomic writers**

Execute:

```text
minimap2 -a --eqx --cs=long -x asm20 -t <threads> -N 100 --secondary=yes <reference.fa> <stable-unmatched.fa>
samtools view -b -o <reciprocal.unsorted.bam> <reciprocal.sam>
samtools sort -o <staged unmatched-to-reference.bam> <reciprocal.unsorted.bam>
samtools index <staged unmatched-to-reference.bam> <staged unmatched-to-reference.bam.bai>
samtools quickcheck <staged unmatched-to-reference.bam>
samtools idxstats <staged unmatched-to-reference.bam>
```

Parse the sorted BAM via `samtools view -h`, classify every deduplicated cluster, write `candidate_alleles.fasta`, `candidate-alleles.json`, `unnameable_unmatched_clusters.fasta`, and `unnameable-unmatched-clusters.json` to staging, checksum all six outputs, then atomically publish and update the manifest.

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter FullLengthONTMHCCandidateArtifactWriterTests && swift test --filter FullLengthONTMHCGenotypingPipelineTests`

Expected: PASS.

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCCandidateArtifactWriter.swift Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift Tests/LungfishWorkflowTests/FullLengthONTMHCCandidateArtifactWriterTests.swift Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift
git commit -m "feat: publish MHC candidate and unnameable artifacts"
```

### Task 9: Validate optional artifacts when loading a bundle

**Files:**
- Modify: `Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift`
- Modify: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`

- [ ] **Step 1: Write failing loader tests**

Cover valid loading, missing JSON, escaping relative path, checksum mismatch, malformed schema, missing FASTA stable ID, and legacy absence. Assert all integrity failures preserve known calls:

```swift
XCTAssertEqual(bundle.calls, knownCalls)
XCTAssertNil(bundle.mhcCandidates)
XCTAssertEqual(bundle.integrityWarnings.first?.code, .candidateArtifactChecksumMismatch)
```

- [ ] **Step 2: Run tests and confirm failure**

Run: `swift test --filter ONTGenotypeResultBundleTests`

Expected: FAIL because candidate validation/loading is absent.

- [ ] **Step 3: Implement fail-soft candidate loading**

Resolve every declared path under the bundle root, compare size and SHA-256, decode schema version 1, confirm candidate/un-nameable stable IDs exist in their declared FASTA, and return typed warnings. Never suppress known-call CSV data because an optional candidate artifact is invalid.

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter ONTGenotypeResultBundleTests`

Expected: PASS (legacy 15 tests plus the new cases).

```bash
git add Sources/LungfishIO/Bundles/ONTGenotypeResultBundle.swift Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift
git commit -m "feat: validate MHC candidate bundle artifacts"
```

### Task 10: Put all candidates and un-nameable clusters in the initial workbook

**Files:**
- Create: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCWorkbookProjection.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`

- [ ] **Step 1: Write failing workbook-content tests**

Open generated OOXML and assert the existing sheets are retained and candidate projections are added:

```swift
XCTAssertTrue(sheetNames.contains("Unified Genotype Pivot"))
XCTAssertTrue(sheetNames.contains("Unmatched Clusters"))
XCTAssertTrue(sheetNames.contains("Unmatched Shared Pivot"))
XCTAssertTrue(sheetNames.contains("MHC-like Unmatched Clusters"))
XCTAssertTrue(sheetNames.contains("MHC-like Unmatched Pivot"))
XCTAssertTrue(sheetNames.contains("Candidate Alleles"))
XCTAssertTrue(sheetNames.contains("Un-nameable Clusters"))
XCTAssertTrue(unifiedRows.contains { $0["Cluster ID"] == "cluster-singleton" })
XCTAssertTrue(candidateRows.contains { $0["Provisional Name"] == "Mafa-A1*018:01:01:01_5nt_nov" })
XCTAssertTrue(unnameableRows.contains { $0["Reason"] == "unresolved-locus" })
XCTAssertEqual(candidateRows.count, allCandidates.count)
```

Assert four distinct fill IDs appear only on candidate allele-name cells: shared novel, singleton novel, shared extension, singleton extension.

- [ ] **Step 2: Run test and confirm failure**

Run: `swift test --filter FullLengthONTMHCGenotypingPipelineTests`

Expected: FAIL because the workbook lacks the three unified projections/styles.

- [ ] **Step 3: Add the shared projection and styled OOXML**

Define a workbook row model carrying `stableClusterID`, `provisionalName`, `locus`, `classification`, `supportClass`, per-sample/total reads, sample/occurrence counts, FASTA identity/checksum, BAM locator, closest-reference metrics, and tint category. Generate all candidate rows without applying app visibility. Extend the existing `Unified Genotype Pivot` rather than replacing its known rows. Retain the four unmatched detail/pivot sheets, but source their stable IDs and classification/metric columns from the candidate model so they emit `_nov`/`_ext`, never `_extension`/`_<N>SNP`. Add `xl/styles.xml` with four default fills and reference them only for the provisional allele-name cell.

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter FullLengthONTMHCGenotypingPipelineTests`

Expected: PASS.

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCWorkbookProjection.swift Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift
git commit -m "feat: export MHC candidates to initial workbook"
```

### Task 11: Complete candidate provenance and CLI reporting

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift`
- Modify: `Sources/LungfishCLI/Commands/FastqFullLengthONTMHCGenotypingSubcommand.swift`
- Modify: `Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift`
- Modify: `Tests/LungfishCLITests/FastqFullLengthONTMHCGenotypingCommandTests.swift`

- [ ] **Step 1: Write failing provenance audit tests**

For minimap2, every samtools step, reference metadata import, classification, JSON/FASTA export, and workbook projection assert nonempty workflow/version/argv/options/runtime/inputs/outputs, status, wall time, and checksummed final paths. Assert defaults include `minimumIntronGapBases=20` and the 1000/0.75/0.70 thresholds.

- [ ] **Step 2: Run tests and confirm failure**

Run: `swift test --filter FullLengthONTMHCGenotypingPipelineTests && swift test --filter FastqFullLengthONTMHCGenotypingCommandTests`

Expected: FAIL with missing scientific-step provenance fields.

- [ ] **Step 3: Record every transformation and CLI payload path**

Represent in-process transformations with reproducible pseudo-argv such as:

```text
lungfish-internal mhc-candidate-classify --schema-version 1 --min-aligned-bases 1000 --min-identity 0.75 --min-shorter-coverage 0.70 --min-intron-gap-bases 20 ...
lungfish-internal mhc-candidate-workbook-project --candidate-json <final path> --workbook <final path>
```

Capture tool versions using `minimap2 --version`, `samtools --version`, Lungfish build version, and conda/runtime identity. Return all published paths from CLI JSON and text output.

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter FullLengthONTMHCGenotypingPipelineTests && swift test --filter FastqFullLengthONTMHCGenotypingCommandTests`

Expected: PASS.

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/FullLengthONTMHCGenotypingPipeline.swift Sources/LungfishCLI/Commands/FastqFullLengthONTMHCGenotypingSubcommand.swift Tests/LungfishWorkflowTests/FullLengthONTMHCGenotypingPipelineTests.swift Tests/LungfishCLITests/FastqFullLengthONTMHCGenotypingCommandTests.swift
git commit -m "feat: record MHC candidate workflow provenance"
```

### Task 12: Verify and launch changeset 2

**Files:** none unless a verification failure identifies an in-scope correction.

- [ ] **Step 1: Run the changeset suites**

```bash
swift test --filter MHCReferenceRecordCatalogTests
swift test --filter FullLengthONTMHCCandidateClassifierTests
swift test --filter FullLengthONTMHCCandidateArtifactWriterTests
swift test --filter FullLengthONTMHCGenotypingPipelineTests
swift test --filter FastqFullLengthONTMHCGenotypingCommandTests
swift test --filter ONTGenotypeResultBundleTests
```

Expected: all PASS.

- [ ] **Step 2: Build, verify identity, and launch**

```bash
scripts/build-app.sh --configuration debug
test "$(/usr/bin/plutil -extract CFBundleName raw -o - build/Debug/Lungfish.app/Contents/Info.plist)" = "Lungfish Debug"
test -x build/Debug/Lungfish.app/Contents/MacOS/lungfish-cli
open -n build/Debug/Lungfish.app
```

Expected: build/checks exit 0 and a fresh Lungfish Debug launches.

## Changeset 3 — Full-length viewport and explicit workbook synchronization

### Task 13: Persist per-bundle candidate visibility and four tints

**Files:**
- Modify: `Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift`
- Modify: `Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift`

- [ ] **Step 1: Write failing defaults and round-trip tests**

```swift
XCTAssertTrue(settings.showKnown)
XCTAssertTrue(settings.showSharedCandidates)
XCTAssertTrue(settings.showSingletonCandidates)
XCTAssertEqual(Set(settings.tints.keys), Set(ONTMHCCandidateTintCategory.allCases))
XCTAssertEqual(try roundTrip(settings), settings)
```

Also decode an old sidecar and assert the defaults are synthesized.

- [ ] **Step 2: Run tests and confirm failure**

Run: `swift test --filter ONTGenotypeResultBundleTests`

Expected: FAIL because candidate display settings are absent.

- [ ] **Step 3: Add candidate-only display settings**

```swift
public enum ONTMHCCandidateTintCategory: String, Codable, CaseIterable, Sendable {
    case sharedNovel, singletonNovel, sharedExtension, singletonExtension
}
public struct ONTMHCCandidateDisplaySettings: Codable, Equatable, Sendable {
    public var showKnown: Bool
    public var showSharedCandidates: Bool
    public var showSingletonCandidates: Bool
    public var tints: [ONTMHCCandidateTintCategory: AnnotationColor]
    public static let defaultTints: [ONTMHCCandidateTintCategory: AnnotationColor] = [
        .sharedNovel: AnnotationColor(hex: "#F5D78E")!,
        .singletonNovel: AnnotationColor(hex: "#F5B97A")!,
        .sharedExtension: AnnotationColor(hex: "#A8D8D0")!,
        .singletonExtension: AnnotationColor(hex: "#AFCBF2")!,
    ]
}
```

Store the settings inside the existing bundle sidecar using its atomic save and provenance-update path. Do not add global user defaults. Add a test that a visibility/tint edit publishes a new sidecar checksum and provenance entry scoped to that bundle, while candidate JSON and both workbooks retain their prior checksums.

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter ONTGenotypeResultBundleTests`

Expected: PASS.

```bash
git add Sources/LungfishIO/Bundles/GenotypeAnnotationSidecar.swift Tests/LungfishIOTests/ONTGenotypeResultBundleTests.swift
git commit -m "feat: persist MHC candidate viewport settings"
```

### Task 14: Project stable known and candidate rows without conflation

**Files:**
- Create: `Sources/LungfishGenotypeUI/GenotypeCandidateMatrixRow.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing row identity/filter/tint tests**

```swift
XCTAssertEqual(rows.filter { $0.alleleName == collisionLabel }.count, 2)
XCTAssertNotEqual(rows[0].id, rows[1].id)
XCTAssertTrue(defaultRows.contains { $0.population == .known })
XCTAssertTrue(defaultRows.contains { $0.population == .sharedCandidate })
XCTAssertTrue(defaultRows.contains { $0.population == .singletonCandidate })
XCTAssertEqual(candidateCell.backgroundColor, settings.tints[.sharedNovel]?.nsColor)
XCTAssertNil(sampleSupportCell.candidateTint)
```

- [ ] **Step 2: Run viewport tests and confirm failure**

Run: `swift test --filter GenotypeResultViewportTests`

Expected: FAIL because rows are keyed only by locus/genotype and candidates are absent.

- [ ] **Step 3: Implement stable row adapters and full-length-only projection**

```swift
enum GenotypeCandidateMatrixRowID: Hashable {
    case known(locus: String, genotype: String)
    case candidate(stableClusterID: String)
}
struct GenotypeCandidateMatrixRow: Equatable {
    let id: GenotypeCandidateMatrixRowID
    let alleleName: String
    let locus: String
    let stableClusterID: String?
    let population: Population
    let tintCategory: ONTMHCCandidateTintCategory?
    let sampleSupport: Set<String>
}
```

Build known rows from existing calls and candidate rows from candidate JSON, sort deterministically by locus/name/stable ID, filter by the three visibility booleans, and color only the allele-name cell. Keep existing annotation and selection precedence explicit; candidate tint is the base background, selection remains the active overlay.

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter GenotypeResultViewportTests`

Expected: PASS (baseline 130 plus new cases).

```bash
git add Sources/LungfishGenotypeUI/GenotypeCandidateMatrixRow.swift Sources/LungfishGenotypeUI/GenotypeComparisonMatrixView.swift Sources/LungfishGenotypeUI/GenotypeResultDisplayState.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: show stable MHC candidate matrix rows"
```

### Task 15: Add full-length candidate controls, cluster details, and warnings

**Files:**
- Create: `Sources/LungfishGenotypeUI/GenotypeCandidateEvidenceSection.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultViewController.swift`
- Modify: `Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift`
- Modify: `Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift`

- [ ] **Step 1: Write failing controller tests**

Assert the candidate section is present only for full-length bundles with candidate data, all three visibility controls start on, four color controls map to four sidecar keys, selecting either colliding candidate shows the correct stable cluster ID, and invalid candidate artifacts show a nonfatal integrity warning while known rows remain.

- [ ] **Step 2: Run tests and confirm failure**

Run: `swift test --filter GenotypeResultViewportTests`

Expected: FAIL because the controls/detail/warning do not exist.

- [ ] **Step 3: Implement the controls and evidence section**

Create checkboxes labeled `Known`, `Shared candidates (2+ samples)`, and `Singleton candidates (1 sample)`. Create four color wells labeled `Shared novel`, `Singleton novel`, `Shared extension`, and `Singleton extension`, each with a reset-to-default action. Persist changes to the open bundle sidecar and immediately redraw the matrix, but do not touch `current.xlsx`. Candidate sample cells use aggregated cluster-read counts and participate in existing search, locus filtering, sorting, selection, and matrix display-support thresholds; they remain excluded from haplotype inference and QC calculations. Show stable cluster ID, classification, support sample IDs/read counts, closest reference, SNP/gap metrics, FASTA record/checksum, and BAM/BAI artifact locations and alignment locators in candidate evidence detail.

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter GenotypeResultViewportTests`

Expected: PASS.

```bash
git add Sources/LungfishGenotypeUI/GenotypeCandidateEvidenceSection.swift Sources/LungfishGenotypeUI/GenotypeResultViewController.swift Sources/LungfishGenotypeUI/GenotypeResultDisplaySection.swift Tests/LungfishGenotypeUITests/GenotypeResultViewportTests.swift
git commit -m "feat: add MHC candidate viewport controls"
```

### Task 16: Synchronize all candidates and four tints through explicit workbook update

**Files:**
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift`
- Modify: `Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift`
- Modify: `Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift`

- [ ] **Step 1: Write failing explicit-update tests**

Start from a workbook with known rows, mutate sidecar filters/tints, and assert before Update Current Workbook the file checksum is unchanged. After update assert all candidates remain even when hidden in the viewport, un-nameable rows remain, and only candidate allele-name cells receive the current four fills.

```swift
XCTAssertEqual(beforeExplicitUpdateSHA, afterSidecarOnlySHA)
XCTAssertEqual(updatedCandidateRows.count, allCandidates.count)
XCTAssertEqual(updatedUnnameableRows.count, allUnnameable.count)
XCTAssertEqual(updatedFill(for: "cluster-shared-nov"), sidecar.tints[.sharedNovel])
```

- [ ] **Step 2: Run tests and confirm failure**

Run: `swift test --filter GenotypeWorkbookRevisionServiceTests`

Expected: FAIL because current workbook projection lacks candidates/tints.

- [ ] **Step 3: Extend the openpyxl updater and provenance**

Pass candidate JSON, un-nameable JSON, and four hex colors as explicit argv/JSON options. The script must extend `Full Sequencing Results 1` when that established editable-workbook sheet is present (or the full-length `Unified Genotype Pivot` projection otherwise), replace `Candidate Alleles` and `Un-nameable Clusters` deterministically, retain every record, tint only provisional-name cells, save via a staging workbook, atomically replace `artifacts/workbooks/current.xlsx`, and return its checksum/size. Preserve the existing unmatched detail/pivot sheets but refresh their candidate-model labels and metrics. Record exact argv, Python/openpyxl/runtime versions, input/output checksums, revision ID, predecessor, user-visible tint values, status, duration, final path, and stderr in the explicit workbook-update provenance record.

- [ ] **Step 4: Run tests and commit**

Run: `swift test --filter GenotypeWorkbookRevisionServiceTests && swift test --filter FullLengthONTMHCGenotypingPipelineTests`

Expected: PASS.

```bash
git add Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService.swift Sources/LungfishWorkflow/ONTGenotyping/GenotypeWorkbookRevisionService+OverrideScript.swift Tests/LungfishWorkflowTests/GenotypeWorkbookRevisionServiceTests.swift
git commit -m "feat: update MHC candidates in current workbook"
```

### Task 17: Verify and launch changeset 3

**Files:** none unless an in-scope verification failure requires correction.

- [ ] **Step 1: Run focused suites**

```bash
swift test --filter GenotypeResultViewportTests
swift test --filter GenotypeWorkbookRevisionServiceTests
swift test --filter ONTGenotypeResultBundleTests
swift test --filter AppDebugLaunchConfigurationTests
```

Expected: all PASS.

- [ ] **Step 2: Run the full suite and handle only evidenced regressions**

Run: `swift test`

Expected: PASS. If the pre-existing order-dependent `ONTBarcodeDemuxGenotypingPipelineTests.testRunIlluminaModeConsumesPreparedSampleBundlesWithoutMergingReads` hangs again, stop the suite, rerun that test alone, record both outcomes, and do not broaden this feature to repair it without evidence that this branch caused the regression.

- [ ] **Step 3: Build, verify identity, and launch**

```bash
scripts/build-app.sh --configuration debug
test "$(/usr/bin/plutil -extract CFBundleName raw -o - build/Debug/Lungfish.app/Contents/Info.plist)" = "Lungfish Debug"
test "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - build/Debug/Lungfish.app/Contents/Info.plist)" = "com.lungfish.browser.debug"
test -x build/Debug/Lungfish.app/Contents/MacOS/lungfish-cli
open -n build/Debug/Lungfish.app
```

Expected: all checks exit 0 and a fresh Lungfish Debug launches.

## Real four-sample validation

### Task 18: Run the bundled CLI on the exemplar and open the result

**Files:**
- Create: `docs/superpowers/validation/2026-07-19-full-length-mhc-candidate-genotyping-viewport.md`

- [ ] **Step 1: Choose a new output without modifying the original result**

```bash
validation_output='/Volumes/iWES_WNPRC/32355/32355.lungfish/Analyses/Full-length ONT MHC genotyping results/2026-07-19-candidate-debug.lungfishgenotype'
test ! -e "$validation_output"
```

Expected: exit 0. If it exists, select a new explicit timestamped `candidate-debug` name; do not delete or overwrite any analysis.

- [ ] **Step 2: Run the same CLI options as the original exemplar**

```bash
build/Debug/Lungfish.app/Contents/MacOS/lungfish-cli fastq full-length-ont-mhc-genotype \
  '/Volumes/iWES_WNPRC/32355/32355.lungfish/32355/CR1178.lungfishfastq' \
  '/Volumes/iWES_WNPRC/32355/32355.lungfish/32355/CR1178b.lungfishfastq' \
  '/Volumes/iWES_WNPRC/32355/32355.lungfish/32355/CR1182.lungfishfastq' \
  '/Volumes/iWES_WNPRC/32355/32355.lungfish/32355/CR1182b.lungfishfastq' \
  --reference '/Volumes/iWES_WNPRC/32355/32355.lungfish/Reference Sequences/IPD-MHC_NHKIR_classI_Mafa.lungfishref' \
  --output-dir "$validation_output" \
  --output-name 2026-07-19-candidate-debug \
  --threads 14 \
  --min-length 2000 \
  --max-length 4000 \
  --savont-quality-value-cutoff 90 \
  --savont-min-cluster-size 3 \
  --min-unmatched-reads 5 \
  --cdna-threshold 2000 \
  --project '/Volumes/iWES_WNPRC/32355/32355.lungfish/32355.lungfish'
```

Expected: exit 0 and a new result bundle; the original `2026-07-19.lungfishgenotype` remains byte-for-byte untouched.

- [ ] **Step 3: Validate BAMs, classification, Excel, and provenance**

```bash
samtools quickcheck "$validation_output/artifacts/alignments/genotyping-evidence.bam"
samtools quickcheck "$validation_output/artifacts/alignments/unmatched-to-reference.bam"
samtools idxstats "$validation_output/artifacts/alignments/genotyping-evidence.bam" >/dev/null
samtools idxstats "$validation_output/artifacts/alignments/unmatched-to-reference.bam" >/dev/null
samtools view -c -r CR1178 "$validation_output/artifacts/alignments/genotyping-evidence.bam"
samtools view -c -r CR1178b "$validation_output/artifacts/alignments/genotyping-evidence.bam"
samtools view -c -r CR1182 "$validation_output/artifacts/alignments/genotyping-evidence.bam"
samtools view -c -r CR1182b "$validation_output/artifacts/alignments/genotyping-evidence.bam"
jq -e 'all(.candidates[]; (.provisional_name | contains("_0nt_nov") | not))' "$validation_output/candidate-alleles.json"
jq -e 'all(.candidates[]; (.provisional_name | contains("_extension") | not) and (.provisional_name | test("_[0-9]+SNP$") | not))' "$validation_output/candidate-alleles.json"
```

Expected: BAM/index checks succeed; every sample read-group count is nonzero when the exemplar contains mapped clusters; no invalid legacy candidate suffix exists. Inspect both `.xlsx` files with openpyxl and assert the three sheets, all candidate/un-nameable IDs, and four candidate fills. Audit provenance against every declared artifact checksum and final stored path.

- [ ] **Step 4: Open the new bundle in Lungfish Debug and exercise the explicit update**

```bash
open -n build/Debug/Lungfish.app --args "$validation_output"
```

Expected: known/shared/singleton groups all display initially; nov/ext singleton/shared names have four distinct tints; colliding labels are separate rows with stable cluster IDs; changing filters does not edit Excel; changing a tint reaches `current.xlsx` only after Update Current Workbook.

- [ ] **Step 5: Record validation evidence and commit**

Write the exact output path, CLI command, tool versions, elapsed time, candidate counts by class/support, un-nameable reason counts, BAM quickcheck/index/read-group results, workbook checks, provenance audit, UI observations, and any pre-existing full-suite hang to the validation note.

```bash
git add docs/superpowers/validation/2026-07-19-full-length-mhc-candidate-genotyping-viewport.md
git commit -m "test: validate full-length MHC candidate workflow"
```

## Completion gate

- [ ] Run fresh focused tests:

```bash
swift test --filter FullLengthONTMHCSAMMetricsTests
swift test --filter FullLengthONTMHCCohortAlignmentBuilderTests
swift test --filter FullLengthONTMHCCandidateClassifierTests
swift test --filter FullLengthONTMHCCandidateArtifactWriterTests
swift test --filter FullLengthONTMHCGenotypingPipelineTests
swift test --filter GenotypeWorkbookRevisionServiceTests
swift test --filter ONTGenotypeResultBundleTests
swift test --filter MHCReferenceRecordCatalogTests
swift test --filter GenotypeResultViewportTests
swift test --filter FastqFullLengthONTMHCGenotypingCommandTests
swift test --filter AppDebugLaunchConfigurationTests
```

- [ ] Run `git diff --check` and `git status --short`; expected: no whitespace errors and no unexplained files.
- [ ] Confirm every new bundle-relative manifest path resolves inside the final bundle and matches the recorded SHA-256/size.
- [ ] Confirm only two durable BAM/BAI pairs exist; temporary per-sample BAMs are absent unless `--keep-intermediates` was explicitly used.
- [ ] Confirm legacy bundles load without candidate controls and all non-full-length genotype surfaces retain their baseline behavior.
- [ ] Confirm the last launched build identifies itself as `Lungfish Debug` and contains the exact bundled CLI used for real validation.

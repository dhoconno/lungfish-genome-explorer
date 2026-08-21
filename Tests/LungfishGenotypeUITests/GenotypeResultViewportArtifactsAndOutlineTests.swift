import XCTest
import AppKit
import SwiftUI
import CryptoKit
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
import LungfishTestSupport

// Artifacts lens, outline/review queue, and selected-sample workbench
@MainActor
final class GenotypeResultViewportArtifactsAndOutlineTests: GenotypeResultViewportTestCase {
    func testArtifactsLensListsValidatedCandidateFASTAAndGenBankArtifactsWhenDeclared() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeCandidateGenBankLens-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let candidateFASTAURL = bundleURL.appendingPathComponent("artifacts/candidates/candidate_alleles.fasta")
        let unnameableFASTAURL = bundleURL.appendingPathComponent("artifacts/candidates/unnameable_unmatched_clusters.fasta")
        let candidateURL = bundleURL.appendingPathComponent("artifacts/candidates/candidate_alleles.gb")
        let unnameableURL = bundleURL.appendingPathComponent("artifacts/candidates/unnameable_unmatched_clusters.gb")
        let candidateEMBLURL = bundleURL.appendingPathComponent("artifacts/candidates/candidate_alleles.embl")
        let unnameableEMBLURL = bundleURL.appendingPathComponent("artifacts/candidates/unnameable_unmatched_clusters.embl")
        let candidateGenBankArtifactURLs = ONTMHCCandidateGenBankArtifactURLs(
            candidateAlleles: candidateURL,
            unnameableClusters: unnameableURL,
            candidateFASTA: candidateFASTAURL,
            unnameableFASTA: unnameableFASTAURL,
            candidateEMBL: candidateEMBLURL,
            unnameableEMBL: unnameableEMBLURL
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            mhcCandidateGenBankArtifactURLs: candidateGenBankArtifactURLs
        ))

        controller.testingSelectLens(.audit)

        let lensText = visibleText(in: controller.view)
        XCTAssertTrue(lensText.contains("Candidate Alleles FASTA"))
        XCTAssertTrue(lensText.contains("Un-nameable Clusters FASTA"))
        XCTAssertTrue(lensText.contains("Candidate Alleles GenBank"))
        XCTAssertTrue(lensText.contains("Un-nameable Clusters GenBank"))
        XCTAssertTrue(lensText.contains("Candidate Alleles EMBL"))
        XCTAssertTrue(lensText.contains("Un-nameable Clusters EMBL"))
    }


    func testArtifactsLensOmitsCandidateGenBankArtifactsWhenAbsent() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: []))

        controller.testingSelectLens(.audit)

        let lensText = visibleText(in: controller.view)
        XCTAssertFalse(lensText.contains("Candidate Alleles FASTA"))
        XCTAssertFalse(lensText.contains("Un-nameable Clusters FASTA"))
        XCTAssertFalse(lensText.contains("Candidate Alleles GenBank"))
        XCTAssertFalse(lensText.contains("Un-nameable Clusters GenBank"))
        XCTAssertFalse(lensText.contains("Candidate Alleles EMBL"))
        XCTAssertFalse(lensText.contains("Un-nameable Clusters EMBL"))
        XCTAssertFalse(lensText.contains("Genotyping Evidence BAM"))
        XCTAssertFalse(lensText.contains("Genotyping Evidence BAI"))
        XCTAssertFalse(lensText.contains("Reciprocal Evidence BAM"))
        XCTAssertFalse(lensText.contains("Reciprocal Evidence BAI"))
    }


    func testArtifactsLensListsValidatedMHCAlignmentArtifactsWhenDeclared() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMHCAlignmentArtifactLens-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("example.lungfishgenotype", isDirectory: true)
        let genotypingBAMURL = bundleURL.appendingPathComponent("artifacts/alignments/genotyping.bam")
        let genotypingBAIURL = bundleURL.appendingPathComponent("artifacts/alignments/genotyping.bam.bai")
        let reciprocalBAMURL = bundleURL.appendingPathComponent("artifacts/alignments/reciprocal.bam")
        let reciprocalBAIURL = bundleURL.appendingPathComponent("artifacts/alignments/reciprocal.bam.bai")
        let alignmentArtifactURLs = ONTMHCAlignmentArtifactURLs(
            genotypingBAM: genotypingBAMURL,
            genotypingBAI: genotypingBAIURL,
            reciprocalBAM: reciprocalBAMURL,
            reciprocalBAI: reciprocalBAIURL
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            kind: "full-length-ont-mhc-genotype",
            mhcAlignmentArtifactURLs: alignmentArtifactURLs
        ))

        controller.testingSelectLens(.audit)

        let lensText = visibleText(in: controller.view)
        XCTAssertTrue(lensText.contains("Genotyping Evidence BAM"))
        XCTAssertTrue(lensText.contains(genotypingBAMURL.standardizedFileURL.path))
        XCTAssertTrue(lensText.contains("Genotyping Evidence BAI"))
        XCTAssertTrue(lensText.contains(genotypingBAIURL.standardizedFileURL.path))
        XCTAssertTrue(lensText.contains("Reciprocal Evidence BAM"))
        XCTAssertTrue(lensText.contains(reciprocalBAMURL.standardizedFileURL.path))
        XCTAssertTrue(lensText.contains("Reciprocal Evidence BAI"))
        XCTAssertTrue(lensText.contains(reciprocalBAIURL.standardizedFileURL.path))
    }


    func testArtifactsLensListsOnlyGenotypingEvidenceForNonFullLengthResult() {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeNonMHCAlignmentArtifactLens-\(UUID().uuidString)", isDirectory: true)
        let alignmentArtifactURLs = ONTMHCAlignmentArtifactURLs(
            genotypingBAM: bundleURL.appendingPathComponent("genotyping.bam"),
            genotypingBAI: bundleURL.appendingPathComponent("genotyping.bam.bai"),
            reciprocalBAM: bundleURL.appendingPathComponent("reciprocal.bam"),
            reciprocalBAI: bundleURL.appendingPathComponent("reciprocal.bam.bai")
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            kind: "ont-barcode-genotype",
            mhcAlignmentArtifactURLs: alignmentArtifactURLs
        ))

        controller.testingSelectLens(.audit)

        let lensText = visibleText(in: controller.view)
        XCTAssertTrue(lensText.contains("Genotyping Evidence BAM"))
        XCTAssertTrue(lensText.contains("Genotyping Evidence BAI"))
        XCTAssertFalse(lensText.contains("Reciprocal Evidence BAM"))
        XCTAssertFalse(lensText.contains("Reciprocal Evidence BAI"))
    }


    func testGenotypeOnlyMiSeqPresentsProvisionalExon2SequenceAndArtifacts()
        throws
    {
        let genotype = "Mafa-A1*007:08:01:01_1nt_nov"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 11)
        let provisional = ONTGenotypeProvisionalExon2Sequence(
            genotype: genotype,
            locus: call.locusGroup,
            sequence: "AACCGGTT",
            sequenceSHA256: String(repeating: "a", count: 64),
            sampleSupport: [
                .init(sample: "AnimalA", passedAlignments: 12, passedUniqueReads: 11),
            ]
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MiSeqProvisional-\(UUID().uuidString).lungfishgenotype")
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            .empty(generatedAt: "2026-07-28T00:00:00Z"),
            forBundleAt: bundleURL
        )
        let manifest = ONTGenotypeResultBundleManifest(
            kind: GenotypeResultWorkflowKind
                .miSeqAmpliconMHCGenotype.rawValue,
            workflowKind: .miSeqAmpliconMHCGenotype,
            workflowMode: .genotypeOnly,
            outputName: "miseq-provisional",
            analysisName: "MiSeq Provisional",
            primaryWorkbookPath: "result.xlsx",
            longSummaryCSVPath: "calls.csv",
            sampleSummaryCSVPath: "samples.csv",
            statsJSONPath: "stats.json",
            provenancePath: "provenance.json"
        )
        try ONTGenotypeResultBundle.writeManifest(
            manifest,
            to: bundleURL
        )
        let catalogURL = bundleURL.appendingPathComponent(
            "artifacts/sequences/observed-provisional-exon2.json"
        )
        let fastaURL = bundleURL.appendingPathComponent(
            "artifacts/sequences/observed-provisional-exon2.fasta"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [call],
            mhcAlignmentArtifactURLs: .init(
                genotypingBAM: bundleURL.appendingPathComponent("evidence.bam"),
                genotypingBAI: bundleURL.appendingPathComponent("evidence.bam.bai"),
                reciprocalBAM: nil,
                reciprocalBAI: nil
            ),
            provisionalExon2SequencesByGenotype: [genotype: provisional],
            provisionalExon2ArtifactURLs: .init(
                catalogJSON: catalogURL,
                sequencesFASTA: fastaURL
            ),
            manifest: manifest
        ))

        controller.testingShowMatrixTargetSelection([
            .column(sample: "AnimalA"),
        ])
        XCTAssertNotNil(controller.testingSampleWorkbenchLayoutMode)
        controller.testingUpdateManualHaplotypeLabel("Provisional-A-H1")
        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertTrue(controller.testingManualHaplotypeEditorCanSave)
        controller.testingSaveManualHaplotypeDraft()
        XCTAssertNil(controller.testingManualHaplotypeEditorPersistenceError)
        XCTAssertFalse(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertEqual(
            controller.testingComparisonMatrix
                .testingManualHaplotypeBandValues(
                    sample: "AnimalA"
                ).first,
            "Provisional-A-H1 · —"
        )

        let matrix = controller.testingComparisonMatrix
        let rowID = GenotypeCandidateMatrixRowID.known(
            locus: call.locusGroup,
            genotype: genotype
        )
        XCTAssertNotNil(matrix.testingBackgroundColor(rowID: rowID, column: .alleleName))
        XCTAssertTrue(matrix.testingAlleleIdentityToolTip(genotype: genotype)?.contains(
            "Provisional exon 2"
        ) == true)
        XCTAssertTrue(matrix.testingReviewLegendText.contains("Provisional exon 2"))
        XCTAssertEqual(
            matrix.testingReviewLegendProvisionalSwatchColor,
            NSColor.systemOrange
        )
        XCTAssertNotEqual(
            matrix.testingBackgroundColor(rowID: rowID, column: .alleleName),
            matrix.testingBackgroundColor(rowID: rowID, column: .sample("AnimalA"))
        )

        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalA")
        controller.testingSelectAlleleSequenceFormat(.fasta)
        XCTAssertTrue(controller.testingAlleleSequenceText.contains(">\(genotype)"))
        XCTAssertTrue(controller.testingAlleleSequenceText.contains("AACCGGTT"))
        controller.testingSelectAlleleSequenceFormat(.genBank)
        XCTAssertFalse(controller.testingAlleleSequenceText.contains("ACCESSION"))
        controller.testingSelectAlleleSequenceFormat(.embl)
        XCTAssertFalse(controller.testingAlleleSequenceText.contains("\nAC   "))
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0 == ("Designation", "Provisional exon 2")
        })
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0.0 == "Interpretation" && $0.1.contains("not an IPD-qualified")
        })
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains {
            $0 == ("AnimalA Support", "11 unique reads; 12 alignments")
        })
        XCTAssertEqual(controller.testingProvisionalExon2SequenceRecordBuildCount, 1)
        XCTAssertEqual(controller.testingProvisionalExon2SequenceCacheCount, 1)
        for _ in 0..<25 {
            controller.testingSelectMatrixCell(
                genotype: genotype,
                sample: "AnimalA"
            )
        }
        XCTAssertEqual(controller.testingProvisionalExon2SequenceRecordBuildCount, 1)
        XCTAssertEqual(controller.testingProvisionalExon2SequenceCacheCount, 1)
        XCTAssertEqual(controller.testingAlleleSequenceDetailMountCount, 1)

        controller.testingSetQuickFilterSearchText("Provisional exon 2")
        XCTAssertEqual(controller.testingVisibleGenotypes, [genotype])
    }


    func testProvisionalExon2PresentationClearsWhenAIHaplotypingCompletes() {
        let genotype = "Mafa-A1*007:08:01:01_1nt_nov"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 11)
        let provisional = ONTGenotypeProvisionalExon2Sequence(
            genotype: genotype,
            locus: call.locusGroup,
            sequence: "AACCGGTT",
            sequenceSHA256: String(repeating: "a", count: 64),
            sampleSupport: [
                .init(sample: "AnimalA", passedAlignments: 12, passedUniqueReads: 11),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [call],
            provisionalExon2SequencesByGenotype: [genotype: provisional]
        ))
        controller.testingSelectMatrixCell(genotype: genotype, sample: "AnimalA")
        XCTAssertFalse(controller.testingAlleleSequenceText.isEmpty)

        controller.applyAIHaplotypingCompleted(result: makeResult(
            samples: [],
            calls: [call],
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis(),
            provisionalExon2SequencesByGenotype: [genotype: provisional]
        ))

        let matrix = controller.testingComparisonMatrix
        let rowID = GenotypeCandidateMatrixRowID.known(
            locus: call.locusGroup,
            genotype: genotype
        )
        XCTAssertFalse(matrix.testingReviewLegendText.contains("Provisional exon 2"))
        XCTAssertNil(matrix.testingBackgroundColor(rowID: rowID, column: .alleleName))
        XCTAssertEqual(controller.testingAlleleSequenceText, "")
    }


    func testProvisionalExon2TintStaysBelowAnalystStyleAndReadReviewChrome() throws {
        let genotype = "Mafa-A1*007:08:01:01_1nt_nov"
        let call = makeCall(sample: "AnimalA", genotype: genotype, reads: 11)
        let provisional = ONTGenotypeProvisionalExon2Sequence(
            genotype: genotype,
            locus: call.locusGroup,
            sequence: "AACCGGTT",
            sequenceSHA256: String(repeating: "a", count: 64),
            sampleSupport: [
                .init(
                    sample: "AnimalA",
                    passedAlignments: 12,
                    passedUniqueReads: 11
                ),
            ]
        )
        let cellTarget = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: call.locusGroup,
            genotype: genotype,
            sample: "AnimalA"
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-26T00:00:00Z"
        )
        sidecar.matrixStyles = [
            .init(
                target: .row(locus: call.locusGroup, genotype: genotype),
                style: .init(fillColor: "#123456"),
                author: "test",
                timestamp: "2026-07-26T00:00:01Z"
            ),
        ]
        sidecar.matrixReviews = [
            .init(
                target: cellTarget,
                disposition: .falsePositive,
                author: "test",
                timestamp: "2026-07-26T00:00:02Z"
            ),
        ]
        sidecar.matrixComments = [
            .init(
                target: cellTarget,
                body: "Analyst note.",
                author: "test",
                timestamp: "2026-07-26T00:00:03Z"
            ),
        ]
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(
            result: makeResult(
                samples: [],
                calls: [call],
                provisionalExon2SequencesByGenotype: [genotype: provisional]
            ),
            sidecar: sidecar
        )

        let rowID = GenotypeCandidateMatrixRowID.known(
            locus: call.locusGroup,
            genotype: genotype
        )
        let identityColor = try XCTUnwrap(
            matrix.testingBackgroundColor(rowID: rowID, column: .alleleName)
        )
        XCTAssertEqual(identityColor.redComponent, 0x12 / 255.0, accuracy: 0.000_000_1)
        XCTAssertEqual(identityColor.greenComponent, 0x34 / 255.0, accuracy: 0.000_000_1)
        XCTAssertEqual(identityColor.blueComponent, 0x56 / 255.0, accuracy: 0.000_000_1)
        let semantic = try XCTUnwrap(
            matrix.testingSemanticCellState(
                genotype: genotype,
                sample: "AnimalA"
            )
        )
        XCTAssertEqual(semantic.text.value, "[11]")
        XCTAssertTrue(semantic.text.isItalic)
        XCTAssertTrue(semantic.hasNativeCellCommentMarker)
    }


    func testArtifactsLensMHCAlignmentLabelsFitWithoutClipping() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMHCAlignmentArtifactLabelLayout-\(UUID().uuidString)", isDirectory: true)
        let alignmentArtifactURLs = ONTMHCAlignmentArtifactURLs(
            genotypingBAM: bundleURL.appendingPathComponent("genotyping.bam"),
            genotypingBAI: bundleURL.appendingPathComponent("genotyping.bam.bai"),
            reciprocalBAM: bundleURL.appendingPathComponent("reciprocal.bam"),
            reciprocalBAI: bundleURL.appendingPathComponent("reciprocal.bam.bai")
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [],
            kind: "full-length-ont-mhc-genotype",
            mhcAlignmentArtifactURLs: alignmentArtifactURLs
        ))
        controller.testingSelectLens(.audit)
        controller.view.layoutSubtreeIfNeeded()

        for label in [
            "Genotyping Evidence BAM",
            "Genotyping Evidence BAI",
            "Reciprocal Evidence BAM",
            "Reciprocal Evidence BAI",
        ] {
            let layout = try XCTUnwrap(controller.testingArtifactLabelLayout(label: label))
            XCTAssertGreaterThanOrEqual(
                layout.renderedWidth,
                layout.intrinsicWidth,
                "\(label) is clipped"
            )
        }
    }


    func testResultViewportOmitsSummaryStatisticsStripForEveryLens() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: []))

        for lens in GenotypeResultViewController.Lens.allCases {
            controller.testingSelectLens(lens)
            XCTAssertFalse(controller.testingHasSummaryStatisticsStrip)
        }
    }


    func testAnchorLensShowsDerivedAnchorSummaryAndCaveat() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "01_M1_A_01",
                passedAlignments: 40,
                passedUniqueReads: 40,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "02_M1_B_01",
                passedAlignments: 30,
                passedUniqueReads: 30,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]

        controller.configure(result: makeResult(samples: [], calls: calls))
        controller.testingSelectLens(.summary)

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertTrue(controller.testingAnchorLensText.contains("M1"))
        XCTAssertTrue(controller.testingAnchorLensText.contains("MHC-A, MHC-B"))
        XCTAssertTrue(controller.testingAnchorLensText.localizedCaseInsensitiveContains("not phased"))
    }


    func testHaplotypeLensShowsExplicitDefinitionAndReviewStatuses() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["01_Mafa_A1_063g"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "ERR: TMH (M1B, M2B, M3B)",
                            haplotype2: "ERR: TMH (M1B, M2B, M3B)",
                            status: .tooManyHaplotypes,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 4,
                            observedGenotypes: ["B1", "B2", "B3", "B4"]
                        ),
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(
            samples: [],
            calls: [],
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: analysis
        ))
        controller.testingSelectLens(.review)

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("Mauritian cynomolgus macaques"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("DW472"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("M1A/-"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("Review"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("ERR: TMH"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("Review in Analyst"))
    }


    func testHaplotypeLensTreatsWholeMHCHomozygoteAsSimpleDespiteMultipleDiagnosticFamilies() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW474",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 4,
                            observedGenotypes: [
                                "11_M1_E_02g3",
                                "02_M1_G_02_07_2mis_156bp",
                                "04_M1_AG_05_3mis_156bp",
                                "01_M1_F_01_w_06",
                            ]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 3,
                            observedGenotypes: [
                                "12_M3_B_075_01",
                                "12_M3_B_079_05",
                                "12_M3_B_165_01",
                            ]
                        ),
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingSelectLens(.review)

        XCTAssertTrue(controller.testingHaplotypeLensText.contains("DW474"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("Simple"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("None"))
        XCTAssertFalse(controller.testingHaplotypeLensText.contains("MHC-A: called"))
        XCTAssertFalse(controller.testingHaplotypeLensText.contains("MHC-B: called"))
    }


    func testHaplotypeLensKeepsMixedFamilyHomozygoteInReview() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW-mixed",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 3,
                            observedGenotypes: [
                                "01_M1_F_01_w_06",
                                "02_M1_G_02_07_2mis_156bp",
                                "02_M2_G_02_06_156bp",
                            ]
                        )
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))
        controller.testingSelectLens(.review)

        XCTAssertTrue(controller.testingHaplotypeLensText.contains("DW-mixed"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("Review"))
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("MHC-A: called"))
    }


    func testOutlineRendersSingleHaplotypeHomozygoteInBothSlots() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW474",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 4,
                            observedGenotypes: ["01_M1_F_01_w_06"]
                        )
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))

        let slot = try XCTUnwrap(controller.testingOutlineSlots(sample: "DW474").first { $0.locus == "MHC-A" })
        XCTAssertEqual(slot.h1.testingLabel, "M1A")
        XCTAssertEqual(slot.h2.testingLabel, "M1A")
    }


    func testSelectingReviewCellMarksOutlineSampleAndLocus() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "M2A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["A1", "A2"]
                        ),
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "M4B",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["B1", "B2"]
                        ),
                    ]
                )
            ]
        )
        controller.configure(result: makeResult(samples: [], calls: [], haplotypeAnalysis: analysis))

        controller.testingSelectCellEvidence(animalId: "DW472", locus: "MHC-B")

        XCTAssertEqual(controller.testingOutlineSelectedSample, "DW472")
        XCTAssertEqual(controller.testingOutlineSelectedLocus, "MHC-B")
    }


    func testRedrawOnlyDisplayChangePreservesOutlineSelectionState() throws {
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test.definition",
            definitionSetName: "Test definition",
            speciesName: "Test species",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "M4B",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["B1", "B2"]
                        ),
                    ]
                ),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [], calls: [], haplotypeAnalysis: analysis
        ))
        var selection: GenotypeResultSelectionState?
        controller.onSelectionStateChanged = { selection = $0 }
        controller.testingSelectCellEvidence(animalId: "DW472", locus: "MHC-B")
        let initial = try XCTUnwrap(selection)
        XCTAssertEqual(initial.animalId, "DW472")
        XCTAssertTrue(initial.matrixTargets.isEmpty)

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            viewportLens: .review,
            layout: .listTrailing
        ))
        controller.notifySelectionStateIfAvailable()

        let retained = try XCTUnwrap(selection)
        XCTAssertEqual(retained.animalId, initial.animalId)
        XCTAssertEqual(retained.title, initial.title)
        XCTAssertEqual(retained.matrixTargets, initial.matrixTargets)
    }


    func testDisplayStateCanSwitchViewportToHaplotypes() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M2A",
                            haplotype2: "M3A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["A1", "A2"]
                        )
                    ]
                )
            ]
        )

        controller.configure(result: makeResult(
            samples: [],
            calls: [],
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: analysis
        ))
        controller.testingApplyDisplayState(GenotypeResultDisplayState(viewportLens: .review))

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
        XCTAssertTrue(controller.testingHaplotypeLensText.contains("DW472"))
    }


    func testHaplotypeLensCanFocusSampleInAnalystMatrix() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "DW472",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M2A",
                            haplotype2: "M3A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["A1", "A2"]
                        )
                    ]
                )
            ]
        )
        let call = ONTGenotypeCall(
            sample: "DW472",
            genotype: "01_Mafa_A1_063g",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        controller.configure(result: makeResult(samples: [], calls: [call], haplotypeAnalysis: analysis))
        controller.testingSelectLens(.review)

        controller.testingReviewHaplotypeSample("DW472")

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingVisibleGenotypes, ["01_Mafa_A1_063g"])
    }


    func testConfirmingReviewCallMarksLocusResolvedAndAdvancesQueue() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeReviewConfirm-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                reviewSample("DW001"),
                reviewSample("DW002"),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(sample: "DW001", genotype: "12_M1_B_001_01", reads: 100),
                makeCall(sample: "DW002", genotype: "12_M1_B_001_01", reads: 100),
            ],
            haplotypeAnalysis: analysis
        ))
        controller.testingSelectCellEvidence(animalId: "DW001", locus: "MHC-B")

        XCTAssertEqual(controller.testingCurrentSelectedSample, "DW001")
        XCTAssertEqual(controller.testingCurrentCallEvidenceSample, "DW001")

        controller.testingConfirmCurrentCallEvidence()

        XCTAssertEqual(controller.testingOutlineIssueCount(sample: "DW001"), 0)
        XCTAssertEqual(controller.testingCurrentSelectedSample, "DW002")
        XCTAssertEqual(controller.testingCurrentCallEvidenceSample, "DW002")
        let sidecar = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleURL)
        XCTAssertTrue(sidecar.callStatusFlags.contains {
            $0.sample == "DW001" && $0.locus == "MHC-B" && $0.value == .confirmed
        })
    }


    func testConfirmingReviewCallAdvancesWithinSameSampleBeforeNextSample() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeReviewConfirmMultiLocus-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                reviewSample("DW001", loci: ["MHC-B", "MHC-DRB"]),
                reviewSample("DW002", loci: ["MHC-B"]),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(sample: "DW001", genotype: "12_M1_B_001_01", reads: 100),
                makeCall(sample: "DW001", genotype: "13_M1_DRB_W5_01", reads: 100),
                makeCall(sample: "DW002", genotype: "12_M1_B_001_01", reads: 100),
            ],
            haplotypeAnalysis: analysis
        ))
        controller.testingSelectCellEvidence(animalId: "DW001", locus: "MHC-B")

        controller.testingConfirmCurrentCallEvidence()
        controller.testingConfirmCurrentCallEvidence()

        let sidecar = try ONTGenotypeResultBundleData.loadAnnotationSidecarIfPresent(forBundleAt: bundleURL)
        XCTAssertTrue(sidecar.callStatusFlags.contains {
            $0.sample == "DW001" && $0.locus == "MHC-B" && $0.value == .confirmed
        })
        XCTAssertTrue(sidecar.callStatusFlags.contains {
            $0.sample == "DW001" && $0.locus == "MHC-DRB" && $0.value == .confirmed
        })
        XCTAssertFalse(sidecar.callStatusFlags.contains {
            $0.sample == "DW002" && $0.locus == "MHC-B" && $0.value == .confirmed
        })
        XCTAssertEqual(controller.testingCurrentSelectedSample, "DW002")
        XCTAssertEqual(controller.testingOutlineIssueCount(sample: "DW001"), 0)
    }


    func testReviewLensUsesNeedsReviewCohortIncludingLowSupportSamples() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeReviewNeedsReview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let lowCalls = [
            makeCall(sample: "LowSupport", genotype: "12_M3_B_075_01", reads: 2),
            makeCall(sample: "LowSupport", genotype: "12_M3_B_165_01", reads: 2),
        ]
        let okCalls = [
            makeCall(sample: "OKSample", genotype: "12_M3_B_075_01", reads: 100),
            makeCall(sample: "OKSample", genotype: "12_M3_B_165_01", reads: 80),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                calledReviewSample("LowSupport"),
                calledReviewSample("OKSample"),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "LowSupport",
                    passedAlignments: 10,
                    passedUniqueReads: 4,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: lowCalls
                ),
                ONTGenotypeSampleResult(
                    sample: "OKSample",
                    passedAlignments: 1_200,
                    passedUniqueReads: 1_200,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: okCalls
                ),
            ],
            calls: lowCalls + okCalls,
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: analysis
        ))

        controller.testingSelectLens(.review)

        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LowSupport"])
        XCTAssertEqual(controller.testingSavedCohortChipTitle, "Saved: Needs review")
    }


    func testTransitionToGenotypeOnlyClearsSmartCohortAndSkipsHaplotypeWork() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeCapabilityTransition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("result.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let call = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "test",
            definitionSetName: "Test",
            speciesName: "Test",
            samples: []
        )
        let cohort = GenotypeCohortSmartFilter(
            name: "Animal A",
            scope: "bundle",
            isStarred: true,
            predicate: .animalIdIn(["AnimalA"])
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [call],
            haplotypeAnalysis: analysis
        ))
        controller.testingApplySmartCohort(cohort)
        XCTAssertTrue(controller.testingHasHaplotypingResult)
        XCTAssertEqual(controller.testingActiveSmartCohort, cohort)
        XCTAssertEqual(controller.testingSavedCohortChipTitle, "Saved: Animal A")
        controller.testingResetHaplotypeCapabilityWorkCounters()

        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [call],
            haplotypeAnalysis: nil
        ))

        XCTAssertFalse(controller.testingHasHaplotypingResult)
        XCTAssertNil(controller.testingActiveSmartCohort)
        XCTAssertNil(controller.testingSavedCohortChipTitle)
        XCTAssertEqual(controller.testingCohortSubjectBuildCount, 0)
        XCTAssertEqual(controller.testingHaplotypeWorkCount, 0)
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA"])

        controller.testingApplySmartCohort(cohort)
        try controller.testingSaveCurrentFilterAsSmartCohort()
        XCTAssertNil(controller.testingActiveSmartCohort)
        XCTAssertEqual(controller.testingCohortSubjectBuildCount, 0)
        XCTAssertEqual(controller.testingHaplotypeWorkCount, 0)
    }


    func testGenotypeOnlyViewportConfigurePreservesEveryPreexistingBundleByte() throws {
        func recursiveBytes(at root: URL) throws -> [String: Data] {
            let keys: [URLResourceKey] = [.isRegularFileKey]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys
            ) else { return [:] }
            var bytes: [String: Data] = [:]
            for case let url as URL in enumerator {
                guard try url.resourceValues(forKeys: Set(keys))
                    .isRegularFile == true else { continue }
                bytes[String(url.path.dropFirst(root.path.count + 1))] =
                    try Data(contentsOf: url)
            }
            return bytes
        }

        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "genotype-only-nonseeding-viewport-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("custom", isDirectory: true),
            withIntermediateDirectories: true
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-26T00:00:00Z"
        )
        sidecar.smartCohorts = [
            GenotypeCohortSmartFilter(
                name: "Only analyst cohort",
                scope: "bundle",
                isStarred: true,
                predicate: .animalIdIn(["AnimalA"])
            ),
        ]
        let annotationURL = bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        try sidecar.encoded().write(to: annotationURL)
        try Data("preexisting provenance".utf8).write(
            to: ProvenanceRecorder.fileSidecarURL(for: annotationURL)
        )
        try Data("opaque artifact".utf8).write(
            to: bundleURL.appendingPathComponent("custom/opaque.bin")
        )
        let before = try recursiveBytes(at: bundleURL)
        let call = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
        let controller = GenotypeResultViewController()
        _ = controller.view

        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [call],
            haplotypeAnalysis: nil
        ))

        XCTAssertEqual(try recursiveBytes(at: bundleURL), before)
    }


    func testAICompletionWithoutAnalysisClearsUnsupportedHaplotypeState() {
        let call = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
        let cohort = GenotypeCohortSmartFilter(
            name: "Animal A",
            scope: "bundle",
            isStarred: true,
            predicate: .animalIdIn(["AnimalA"])
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [call],
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis()
        ))
        controller.testingApplySmartCohort(cohort)
        XCTAssertEqual(controller.testingActiveSmartCohort, cohort)
        XCTAssertEqual(controller.testingSavedCohortChipTitle, "Saved: Animal A")
        controller.testingResetHaplotypeCapabilityWorkCounters()

        controller.applyAIHaplotypingCompleted(result: makeResult(
            samples: [],
            calls: [call],
            haplotypeAnalysis: nil
        ))

        XCTAssertFalse(controller.testingHasHaplotypingResult)
        XCTAssertNil(controller.testingActiveSmartCohort)
        XCTAssertNil(controller.testingSavedCohortChipTitle)
        XCTAssertEqual(controller.testingCohortSubjectBuildCount, 0)
        XCTAssertEqual(controller.testingHaplotypeWorkCount, 0)
        XCTAssertEqual(controller.testingVisibleLensIdentifier, "summary")
        XCTAssertEqual(controller.testingSummaryViewMode, .matrix)
        XCTAssertEqual(controller.testingVisibleMatrixSamples, ["AnimalA"])
    }


    func testOutlineCellSelectionShowsEvidenceWithoutActivatingNeedsReviewCohort() throws {
        let lowCalls = [
            makeCall(sample: "LowSupport", genotype: "12_M3_B_075_01", reads: 2),
            makeCall(sample: "LowSupport", genotype: "12_M3_B_165_01", reads: 2),
        ]
        let okCalls = [
            makeCall(sample: "OKSample", genotype: "12_M3_B_075_01", reads: 100),
            makeCall(sample: "OKSample", genotype: "12_M3_B_165_01", reads: 80),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                calledReviewSample("LowSupport"),
                calledReviewSample("OKSample"),
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [
                ONTGenotypeSampleResult(
                    sample: "LowSupport",
                    passedAlignments: 10,
                    passedUniqueReads: 4,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: lowCalls
                ),
                ONTGenotypeSampleResult(
                    sample: "OKSample",
                    passedAlignments: 1_200,
                    passedUniqueReads: 1_200,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: okCalls
                ),
            ],
            calls: lowCalls + okCalls,
            kind: GenotypeResultWorkflowKind.fullLengthONTMHCGenotype.rawValue,
            haplotypeAnalysis: analysis
        ))

        controller.testingSelectCellEvidence(animalId: "OKSample", locus: "MHC-B")

        XCTAssertEqual(controller.testingVisibleLensIdentifier, "review")
        XCTAssertEqual(controller.testingCurrentCallEvidenceSample, "OKSample")
        XCTAssertNil(controller.testingSavedCohortChipTitle)
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LowSupport", "OKSample"])
    }


    func testReviewLensDoesNotAutoSelectBottomEvidence() throws {
        let calls = [
            makeCall(sample: "LF2823", genotype: "05_M1_A1_063", reads: 120),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2823",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "M4A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["05_M1_A1_063"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "LF2823",
                passedAlignments: 120,
                passedUniqueReads: 120,
                sampleTotalReads: 10_000,
                sampleUniqueRetainedPercent: 1.2,
                calls: calls
            )
        ], calls: calls, haplotypeAnalysis: analysis))

        controller.testingSelectLens(.review)

        XCTAssertNil(controller.testingCurrentSelectedSample)
        XCTAssertNil(controller.testingCurrentCallEvidenceSample)
        XCTAssertTrue(controller.testingCallEvidencePaneHidden)
    }


    func testQuickSearchFiltersOutlineBySampleAndHaplotype() throws {
        let calls = [
            makeCall(sample: "LF2823", genotype: "05_M1_A1_063", reads: 120),
            makeCall(sample: "LF2830", genotype: "05_M2_A1_031", reads: 140),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2823",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "M4A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["05_M1_A1_063"]
                        )
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2830",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M2A",
                            haplotype2: "M5A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["05_M2_A1_031"]
                        )
                    ]
                ),
            ]
        )
        let samples = ["LF2823", "LF2830"].map { sample in
            ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: 120,
                passedUniqueReads: 120,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: calls.filter { $0.sample == sample }
            )
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: samples, calls: calls, haplotypeAnalysis: analysis))

        controller.testingSetQuickFilterSearchText("2823")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823"])

        controller.testingSetQuickFilterSearchText("M2")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2830"])

        controller.testingSetQuickFilterSearchText("M1A")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823"])
    }


    func testReviewLensQuickSearchFiltersOutlineBySampleHaplotypeAndAllele() throws {
        let calls = [
            makeCall(sample: "LF2823", genotype: "05_M4_A1_031", reads: 120),
            makeCall(sample: "LF2830", genotype: "12_M4_B_075_01", reads: 140),
            makeCall(sample: "LF2838", genotype: "12_M3_B_075_01", reads: 160),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2823",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M4A",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["05_M4_A1_031"]
                        )
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2830",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M4B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["12_M4_B_075_01"]
                        )
                    ]
                ),
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2838",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-B",
                            sourceLocus: "Mafa-B",
                            haplotype1: "M3B",
                            haplotype2: "-",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 1,
                            observedGenotypes: ["12_M3_B_075_01"]
                        )
                    ]
                ),
            ]
        )
        let samples = ["LF2823", "LF2830", "LF2838"].map { sample in
            ONTGenotypeSampleResult(
                sample: sample,
                passedAlignments: 120,
                passedUniqueReads: 120,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: calls.filter { $0.sample == sample }
            )
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: samples, calls: calls, haplotypeAnalysis: analysis))
        controller.testingSelectLens(.review)

        controller.testingSetQuickFilterSearchText("2823")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823"])

        controller.testingSetQuickFilterSearchText("M4")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823", "LF2830"])

        controller.testingSetQuickFilterSearchText("M4A")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823"])

        controller.testingSetQuickFilterSearchText("05_M4_A1_031")
        XCTAssertEqual(controller.testingVisibleOutlineSamples, ["LF2823"])
    }


    func testCallEvidenceHeaderCarriesSampleReadCounts() throws {
        let calls = [
            makeCall(sample: "LF2823", genotype: "05_M1_A1_063", reads: 60),
            makeCall(sample: "LF2823", genotype: "05_M4_A1_031", reads: 40),
        ]
        let analysis = GenotypeHaplotypeAnalysis(
            assayID: "MHC-exon2-miSeq",
            definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            definitionSetName: "Mauritian cynomolgus macaques",
            speciesName: "Mauritian cynomolgus macaques",
            samples: [
                GenotypeHaplotypeSampleAnalysis(
                    sample: "LF2823",
                    calls: [
                        GenotypeHaplotypeLocusCall(
                            locus: "MHC-A",
                            sourceLocus: "Mafa-A",
                            haplotype1: "M1A",
                            haplotype2: "M4A",
                            status: .called,
                            matchedHaplotypes: [],
                            observedGenotypeCount: 2,
                            observedGenotypes: ["05_M1_A1_063", "05_M4_A1_031"]
                        )
                    ]
                )
            ]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [
                ONTGenotypeSampleResult(
                    sample: "LF2823",
                    passedAlignments: 150,
                    passedUniqueReads: 100,
                    sampleTotalReads: 884_000,
                    sampleUniqueRetainedPercent: 0.011,
                    calls: calls
                )
            ],
            calls: calls,
            haplotypeAnalysis: analysis,
            stats: ONTGenotypeRunStats(totalInputReads: 884_000, retainedUniqueReads: 150, assignedUniqueRetainedReads: 100)
        ))

        let evidence = try XCTUnwrap(controller.callEvidence(sample: "LF2823", locus: "MHC-A"))
        XCTAssertEqual(evidence.sampleTotalReads, 884_000)
        XCTAssertEqual(evidence.sampleFullLengthReads, 100)
        XCTAssertEqual(evidence.sampleAssignedGenotypeReads, 100)
    }


    func testLocusFilterKeepsAGSeparateFromClassicalA() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            ONTGenotypeCall(
                sample: "DW472",
                genotype: "01_Mafa_A1_063g|A1_063_01,_A1_063_02",
                passedAlignments: 148,
                passedUniqueReads: 148,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "DW472",
                genotype: "18_Mafa_AG_05_AG_06g|AG_05_02_01,_AG_06_04",
                passedAlignments: 204,
                passedUniqueReads: 204,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]

        controller.configure(result: makeResult(samples: [], calls: calls))

        XCTAssertEqual(controller.testingLocusFilterTitles, ["All Loci", "MHC-A", "MHC-AG"])
    }


    func testMatrixDefaultsToAlleleNameSort() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "02_Mafa_A2_001_01",
                passedAlignments: 300,
                passedUniqueReads: 300,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                passedAlignments: 20,
                passedUniqueReads: 20,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]

        controller.configure(result: makeResult(samples: [], calls: calls))

        XCTAssertEqual(controller.testingVisibleGenotypes, [
            "01_Mafa_A1_001_01",
            "02_Mafa_A2_001_01",
        ])
    }


    func testSelectingRowDoesNotBecomeLocusFilter() {
        let controller = GenotypeResultViewController()
        _ = controller.view
        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "01_Mafa_A1_001_01",
                passedAlignments: 20,
                passedUniqueReads: 20,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "04_Mafa_B_001_01",
                passedAlignments: 30,
                passedUniqueReads: 30,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            ),
        ]

        controller.configure(result: makeResult(samples: [], calls: calls))
        controller.testingSelectFirstSampleCell(sample: "AnimalA")
        controller.testingSetComparisonFilter("")

        XCTAssertEqual(controller.testingVisibleGenotypes, [
            "01_Mafa_A1_001_01",
            "04_Mafa_B_001_01",
        ])
    }


    func testComparisonMatrixExportSnapshotUsesCohortSampleColumns() {
        let matrix = GenotypeComparisonMatrixView()
        let calls = [
            makeCall(sample: "DW472", genotype: "12_M3_B_075_01", reads: 148),
            makeCall(sample: "DW474", genotype: "12_M3_B_075_01", reads: 119),
        ]
        matrix.configure(result: makeResult(samples: [
            ONTGenotypeSampleResult(
                sample: "DW472",
                passedAlignments: 148,
                passedUniqueReads: 148,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [calls[0]]
            ),
            ONTGenotypeSampleResult(
                sample: "DW474",
                passedAlignments: 119,
                passedUniqueReads: 119,
                sampleTotalReads: nil,
                sampleUniqueRetainedPercent: nil,
                calls: [calls[1]]
            ),
        ], calls: calls))

        matrix.applyCohortFilter(["DW472"])
        let snapshot = matrix.exportSnapshot(
            bundleURL: URL(fileURLWithPath: "/tmp/example.lungfishgenotype"),
            analysisName: "Example",
            lens: "summary.matrix"
        )

        XCTAssertEqual(snapshot.sampleNames, ["DW472"])
        XCTAssertEqual(snapshot.rows.first?.sampleReads, ["DW472": 148])
    }

    // MARK: - Sample column windowing


    func testGenBankMatrixDefaultsToAlleleAndOffersEveryReferenceField() {
        GenotypeComparisonMatrixView.testingResetPersistedReferenceVisibility()
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)],
            referenceMetadata: makeGenBankReferenceMetadata()
        ))

        XCTAssertFalse(matrix.testingPinnedColumnTitles.contains("Genotype"))
        XCTAssertTrue(matrix.testingPinnedColumnTitles.contains("Allele"))
        XCTAssertEqual(matrix.testingReferenceValue(genotype: "NHP01222", fieldKey: "feature.allele"), "Mafa-A1*001:01")
        XCTAssertEqual(
            matrix.testingAvailableReferenceColumnTitles,
            ["Allele", "Organism", "Product", "Definition"]
        )
    }


    func testGenBankMatrixCanToggleAnyReferenceFieldAndFiltersHiddenFields() {
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73),
                makeCall(sample: "AnimalA", genotype: "NHP99999", reads: 41),
            ],
            referenceMetadata: makeGenBankReferenceMetadata()
        ))

        matrix.testingSetReferenceColumnVisible(fieldKey: "feature.product", visible: true)
        XCTAssertTrue(matrix.testingPinnedColumnTitles.contains("Product"))

        matrix.testingSetFilter("class I A1 antigen")
        XCTAssertEqual(matrix.testingVisibleGenotypes, ["NHP01222"])
    }


    func testGenBankMatrixSortsMissingReferenceValuesDeterministically() {
        let metadata = makeGenBankReferenceMetadata()
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: "NHP-Z", reads: 10),
                makeCall(sample: "AnimalA", genotype: "NHP-A", reads: 10),
            ],
            referenceMetadata: ONTGenotypeReferenceMetadata(
                fields: metadata.fields,
                recordsBySequenceName: ["NHP-Z": [:], "NHP-A": [:]],
                alleleFieldKey: metadata.alleleFieldKey
            )
        ))

        XCTAssertEqual(matrix.testingVisibleGenotypes, ["NHP-A", "NHP-Z"])
    }


    func testFASTAMatrixKeepsGenotypeColumnVisible() {
        let matrix = GenotypeComparisonMatrixView()
        matrix.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "FASTA_001", reads: 20)]
        ))

        XCTAssertTrue(matrix.testingPinnedColumnTitles.contains("Genotype"))
        XCTAssertTrue(matrix.testingAvailableReferenceColumnTitles.isEmpty)
    }


    func testKnownRowUsesGraphicalAlleleDetailWithoutAggregateEvidence() throws {
        let rawReferenceID = "NHP01222"
        let record = makeMHCReferenceVisualizationRecord(
            rawReferenceID: rawReferenceID,
            alleleName: "Mafa-A1*001:01"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        var selection: GenotypeResultSelectionState?
        controller.onSelectionStateChanged = { selection = $0 }
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: rawReferenceID, reads: 73)],
            referenceMetadata: makeGenBankReferenceMetadata(),
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(schemaVersion: 1, records: [record])
        ))

        controller.testingSelectMatrixRows(genotypes: [rawReferenceID], sample: nil)

        let detail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        XCTAssertEqual(detail.currentMode, .overview)
        XCTAssertEqual(text("knownAlleleAlleleLabel", in: detail), "Mafa-A1*001:01")
        XCTAssertEqual(text("knownAlleleRawReferenceID", in: detail), rawReferenceID)
        XCTAssertTrue(descendants(of: detail).compactMap { $0 as? NSTableView }.isEmpty)
        assertNoKnownAggregateEvidence(in: visibleText(in: detail))
        let state = try XCTUnwrap(selection)
        XCTAssertEqual(state.detailRows.first?.0, "Selection Type")
        XCTAssertTrue(state.detailRows.contains { $0 == ("Allele", "Mafa-A1*001:01") })
        XCTAssertTrue(state.detailRows.contains { $0 == ("Reference Sequence", rawReferenceID) })
        assertNoKnownAggregateEvidence(in: state.detailRows.map { "\($0.0) \($0.1)" }.joined(separator: "\n"))
    }


    func testReciprocalKnownRowUsingDisplayAlleleNameResolvesGraphicalRecordByAlias() throws {
        let rawReferenceID = "NHP01222"
        let displayAlleleName = "Mafa-A1*001:01"
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: displayAlleleName, reads: 73)],
            referenceMetadata: makeGenBankReferenceMetadata(),
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [makeMHCReferenceVisualizationRecord(
                    rawReferenceID: rawReferenceID,
                    alleleName: displayAlleleName
                )]
            )
        ))

        controller.testingSelectMatrixRows(genotypes: [displayAlleleName], sample: nil)

        let detail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        XCTAssertEqual(text("knownAlleleAlleleLabel", in: detail), displayAlleleName)
        XCTAssertEqual(text("knownAlleleRawReferenceID", in: detail), rawReferenceID)
    }


    func testSupportedKnownCellReusesGraphicalDetailAndRowClearsObservedSample() throws {
        let rawReferenceID = "NHP01222"
        let call = makeCall(sample: "AnimalA", genotype: rawReferenceID, reads: 73)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [ONTGenotypeSampleResult(
                sample: "AnimalA", passedAlignments: 73, passedUniqueReads: 73,
                sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [call]
            )],
            calls: [call],
            referenceMetadata: makeGenBankReferenceMetadata(),
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [makeMHCReferenceVisualizationRecord(rawReferenceID: rawReferenceID, alleleName: "Mafa-A1*001:01")]
            )
        ))
        controller.testingSelectMatrixRows(genotypes: [rawReferenceID], sample: nil)
        let rowDetail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))

        controller.testingSelectMatrixCell(genotype: rawReferenceID, sample: "AnimalA")

        let cellDetail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        XCTAssertTrue(rowDetail === cellDetail)
        XCTAssertEqual(text("knownAlleleObservedSample", in: cellDetail), "Observed in sample AnimalA")
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Sample", "AnimalA") })
        assertNoKnownAggregateEvidence(in: visibleText(in: cellDetail))
        assertNoKnownAggregateEvidence(in: controller.testingCurrentSelectionDetailRows.map { $0.0 }.joined(separator: "\n"))

        controller.testingSelectMatrixRows(genotypes: [rawReferenceID], sample: nil)

        let returnedRowDetail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        XCTAssertTrue(rowDetail === returnedRowDetail)
        XCTAssertFalse(visibleText(in: returnedRowDetail).contains("Observed in sample"))
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == "Sample" })
    }


    func testRepeatedKnownRowAndCellSelectionsStayBoundedForLargeCohort() throws {
        let firstID = "NHP01222"
        let secondID = "NHP99999"
        let sampleNames = (0..<240).map { String(format: "Animal%03d", $0) }
        let calls = sampleNames.flatMap { sample in
            [
                makeCall(sample: sample, genotype: firstID, reads: 10),
                makeCall(sample: sample, genotype: secondID, reads: 9),
            ]
        }
        let samples = sampleNames.map { sample in
            let sampleCalls = calls.filter { $0.sample == sample }
            return ONTGenotypeSampleResult(
                sample: sample, passedAlignments: 19, passedUniqueReads: 19,
                sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: sampleCalls
            )
        }
        let records = [
            makeMHCReferenceVisualizationRecord(rawReferenceID: firstID, alleleName: "Mafa-A1*001:01"),
            makeMHCReferenceVisualizationRecord(rawReferenceID: secondID, alleleName: "Mafa-B*002:01"),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: samples,
            calls: calls,
            referenceMetadata: makeGenBankReferenceMetadata(),
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(schemaVersion: 1, records: records)
        ))
        controller.testingSelectMatrixRows(genotypes: [firstID], sample: nil)
        let detail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        let baselineDescendantCount = descendants(of: detail).count
        let baselineContentConstraintIdentifiers = detail.testingActiveContentConstraintIdentifiers
        let baselineOverviewConfigurationCount = detail.testingOverviewConfigurationCount
        var maximumDescendantCount = baselineDescendantCount

        let start = CFAbsoluteTimeGetCurrent()
        for iteration in 0..<12 {
            controller.testingSelectMatrixCell(genotype: firstID, sample: sampleNames[0])
            controller.testingSelectMatrixRows(genotypes: [secondID], sample: nil)
            controller.testingSelectMatrixCell(genotype: secondID, sample: sampleNames[239])
            controller.testingSelectMatrixRows(genotypes: [firstID], sample: nil)
            let current = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
            XCTAssertTrue(detail === current)
            XCTAssertEqual(
                current.testingActiveContentConstraintIdentifiers,
                baselineContentConstraintIdentifiers,
                "Reconfiguring an already-visible overview must not replace its layout constraints."
            )
            XCTAssertEqual(
                current.testingOverviewConfigurationCount,
                baselineOverviewConfigurationCount + ((iteration + 1) * 2),
                "Only a changed reference allele should rebuild graphical feature lanes."
            )
            maximumDescendantCount = max(maximumDescendantCount, descendants(of: current).count)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertEqual(maximumDescendantCount, baselineDescendantCount)
        XCTAssertEqual(controller.testingDetailArrangedSubviewCount, 1)
        XCTAssertLessThan(elapsed, 5, "Repeated known selections took \(elapsed) seconds")
        assertNoKnownAggregateEvidence(in: visibleText(in: detail))
    }


    func testKnownDetailIsMountedOnlyOnceAcrossKnownRowChanges() throws {
        let firstID = "NHP01222"
        let secondID = "NHP99999"
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [
                makeCall(sample: "AnimalA", genotype: firstID, reads: 10),
                makeCall(sample: "AnimalA", genotype: secondID, reads: 9),
            ],
            referenceMetadata: makeGenBankReferenceMetadata(),
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [
                    makeMHCReferenceVisualizationRecord(
                        rawReferenceID: firstID,
                        alleleName: "Mafa-A1*001:01"
                    ),
                    makeMHCReferenceVisualizationRecord(
                        rawReferenceID: secondID,
                        alleleName: "Mafa-B*002:01"
                    ),
                ]
            )
        ))
        controller.testingSelectMatrixRows(genotypes: [firstID], sample: nil)
        let detail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        XCTAssertEqual(controller.testingKnownAlleleDetailMountCount, 1)

        controller.testingSelectMatrixRows(genotypes: [secondID], sample: nil)

        XCTAssertTrue(detail === onlyKnownAlleleDetail(in: controller.view))
        XCTAssertEqual(
            controller.testingKnownAlleleDetailMountCount,
            1,
            "Changing known rows must update the persistent detail view without remounting it."
        )
    }


    func testKnownSelectionUsesIndexedCellSupportWithoutEvidenceWorkOrReloading() async throws {
        let rawReferenceID = "NHP01222"
        let sampleNames = (0..<600).map { String(format: "Animal%03d", $0) }
        let calls = sampleNames.map {
            makeCall(sample: $0, genotype: rawReferenceID, reads: 10)
        }
        let result = makeResult(
            samples: [],
            calls: calls,
            referenceMetadata: makeGenBankReferenceMetadata(),
            mhcReferenceVisualizations: ONTMHCReferenceVisualizationArtifact(
                schemaVersion: 1,
                records: [makeMHCReferenceVisualizationRecord(
                    rawReferenceID: rawReferenceID,
                    alleleName: "Mafa-A1*001:01"
                )]
            )
        )
        let loaderSpy = KnownSelectionResultLoaderSpy(result: result)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.genotypeResultLoader = { url in
            await loaderSpy.load(url)
        }
        controller.configure(result: result)
        let baseline = controller.testingKnownSelectionDiagnostics

        for _ in 0..<10 {
            controller.testingSelectMatrixCell(
                genotype: rawReferenceID,
                sample: sampleNames.last!
            )
            controller.testingSelectMatrixRows(genotypes: [rawReferenceID], sample: nil)
        }

        let diagnostics = controller.testingKnownSelectionDiagnostics
        XCTAssertEqual(
            diagnostics.indexedCellSupportLookupCount,
            baseline.indexedCellSupportLookupCount + 10
        )
        XCTAssertEqual(
            diagnostics.aggregateEvidenceHelperEntryCount,
            baseline.aggregateEvidenceHelperEntryCount
        )
        let loaderInvocationCount = await loaderSpy.currentInvocationCount()
        XCTAssertEqual(loaderInvocationCount, 0)

        let detail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        let storedCallbacks = Mirror(reflecting: detail).children.compactMap { child -> String? in
            let typeName = String(reflecting: type(of: child.value))
            return typeName.contains("->") ? child.label ?? typeName : nil
        }
        XCTAssertTrue(
            storedCallbacks.isEmpty,
            "Known detail configuration must remain value-only, without disk/BAM/SQLite/FASTA callbacks: \(storedCallbacks)"
        )
        assertNoKnownAggregateEvidence(in: visibleText(in: detail))
        let forbiddenStateLabels: Set<String> = [
            "Support", "Samples", "Top Sample", "Unique Reads", "Alignments",
            "Support Metric", "Aggregate Samples", "Aggregate Unique Reads", "Aggregate Alignments",
        ]
        XCTAssertTrue(forbiddenStateLabels.isDisjoint(
            with: Set(controller.testingCurrentSelectionDetailRows.map(\.0))
        ))
    }


    func testLegacyKnownRowUsesFallbackMetadataAndFreshAnalysisNote() throws {
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)],
            referenceMetadata: makeGenBankReferenceMetadata()
        ))

        controller.testingSelectMatrixRows(genotypes: ["NHP01222"], sample: nil)

        let detail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        let detailText = visibleText(in: detail)
        XCTAssertEqual(detail.currentMode, .overview)
        XCTAssertEqual(text("knownAlleleAlleleLabel", in: detail), "Mafa-A1*001:01")
        XCTAssertEqual(text("knownAlleleRawReferenceID", in: detail), "NHP01222")
        XCTAssertEqual(
            text("knownAlleleFallbackNote", in: detail),
            "A fresh analysis is required to generate graphical reference records."
        )
        for value in [
            "Macaca fascicularis",
            "MHC class I A1 antigen",
            "Mafa-A1 complete coding sequence",
        ] {
            XCTAssertTrue(detailText.contains(value), "Missing GenBank value: \(value)")
        }
        assertNoKnownAggregateEvidence(in: detailText)
        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Reference Sequence", "NHP01222") })
        XCTAssertTrue(rows.contains { $0 == ("Allele", "Mafa-A1*001:01") })
        XCTAssertTrue(rows.contains { $0 == ("Organism", "Macaca fascicularis") })
        XCTAssertTrue(rows.contains { $0 == ("Product", "MHC class I A1 antigen") })
        XCTAssertTrue(rows.contains { $0 == ("Definition", "Mafa-A1 complete coding sequence") })
        assertNoKnownAggregateEvidence(in: rows.map { $0.0 }.joined(separator: "\n"))

        controller.testingSelectMatrixCell(genotype: "NHP01222", sample: "AnimalA")

        let cellDetail = try XCTUnwrap(onlyKnownAlleleDetail(in: controller.view))
        XCTAssertTrue(detail === cellDetail)
        XCTAssertEqual(text("knownAlleleObservedSample", in: cellDetail), "Observed in sample AnimalA")
        assertNoKnownAggregateEvidence(in: visibleText(in: cellDetail))
    }


    func testSelectedFASTARowFallsBackToGenotypeWithoutGenBankSection() {
        let genotype = "01_Mafa_A1_001_01_FULL_FASTA_LABEL"
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: genotype, reads: 20)]
        ))

        controller.testingSelectMatrixRows(genotypes: [genotype], sample: nil)

        let detail = onlyKnownAlleleDetail(in: controller.view)
        XCTAssertEqual(text("knownAlleleAlleleLabel", in: detail), genotype)
        XCTAssertEqual(text("knownAlleleRawReferenceID", in: detail), genotype)
        XCTAssertEqual(
            text("knownAlleleFallbackNote", in: detail),
            "A fresh analysis is required to generate graphical reference records."
        )
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == "Reference Sequence" })
    }


    func testSelectedColumnShowsSampleMetricsAndOnlyVisibleSupportedAlleles() {
        let retained = ONTGenotypeCall(
            sample: "AnimalA", genotype: "NHP01222", passedAlignments: 45, passedUniqueReads: 30,
            sampleTotalReads: nil, sampleUniqueRetainedReads: 40, sampleUniqueRetainedPercent: nil,
            overallInputReads: nil, overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil
        )
        let filtered = ONTGenotypeCall(
            sample: "AnimalA", genotype: "NHP99999", passedAlignments: 12, passedUniqueReads: 10,
            sampleTotalReads: nil, sampleUniqueRetainedReads: 40, sampleUniqueRetainedPercent: nil,
            overallInputReads: nil, overallUniqueRetainedReads: nil, overallUniqueRetainedPercent: nil
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [ONTGenotypeSampleResult(
                sample: "AnimalA", passedAlignments: 57, passedUniqueReads: 40,
                sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [retained, filtered]
            )],
            calls: [retained, filtered],
            referenceMetadata: makeGenBankReferenceMetadata()
        ))
        controller.testingSetComparisonFilter("Mafa-A1")

        controller.testingSelectMatrixColumn(sample: "AnimalA")

        let text = controller.testingDetailText
        XCTAssertTrue(text.contains("Selected Sample"))
        XCTAssertTrue(text.contains("AnimalA"))
        XCTAssertTrue(text.contains("Mafa-A1*001:01"))
        XCTAssertFalse(text.contains("Mafa-B*002:01"))
        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Retained Unique Reads", "40") })
        XCTAssertTrue(rows.contains { $0 == ("Call-support check", "Low support") })
        XCTAssertTrue(rows.contains { $0 == ("Read support", "30") })
        XCTAssertFalse(rows.contains { ["QC", "Alignments", "Locus", "Unique Reads", "Support"].contains($0.0) })
    }


    func testEvidenceRowsUseExactCurrentMatrixOrderWithoutSecondSort() {
        let first = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 10
        )
        let second = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_002_01",
            reads: 20
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 30,
                    passedUniqueReads: 1_200,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: [first, second]
                ),
            ],
            calls: [first, second]
        ))

        controller.testingSelectMatrixColumn(sample: "AnimalA")

        let evidence = controller.testingCurrentSelectionDetailRows.filter {
            $0.0 == "Allele" || $0.0 == "Read support"
        }
        XCTAssertEqual(evidence.map { "\($0.0)=\($0.1)" }, [
            "Allele=01_Mafa_A1_001_01",
            "Read support=10",
            "Allele=01_Mafa_A1_002_01",
            "Read support=20",
        ])
    }


    func testPublishedSelectedSampleStateRowsUseCallSupportCheckAndTwoColumnEvidence() {
        let first = makeCall(
            sample: "AnimalA",
            genotype: "NHP01222",
            reads: 10
        )
        let second = makeCall(
            sample: "AnimalA",
            genotype: "NHP99999",
            reads: 20
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 30,
                    passedUniqueReads: 1_200,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: [first, second]
                ),
            ],
            calls: [first, second],
            referenceMetadata: makeGenBankReferenceMetadata()
        ))
        controller.testingSetComparisonFilter("Mafa-A1")

        controller.testingSelectMatrixColumn(sample: "AnimalA")

        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains {
            $0 == ("Call-support check", "Meets thresholds")
        })
        XCTAssertEqual(rows.filter { $0.0 == "Allele" }.count, 1)
        XCTAssertEqual(rows.filter { $0.0 == "Read support" }.count, 1)
        XCTAssertFalse(rows.contains {
            ["QC", "Locus", "Unique Reads", "Alignments", "Support"]
                .contains($0.0)
        })
    }


    func testEvidenceRetainsProvisionalExonTwoAndAnnotationPresentation()
        throws
    {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "EvidencePresentation-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let store = try GenotypeAnnotationStore(
            bundleURL: bundleURL,
            author: "Analyst"
        )
        let genotype = "Mafa-A1*007:08:01:01_1nt_nov"
        let call = makeCall(
            sample: "AnimalA",
            genotype: genotype,
            reads: 42
        )
        let rowTarget = GenotypeAnnotationSidecar.MatrixTarget.row(
            locus: call.locusGroup,
            genotype: genotype
        )
        let cellTarget = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: call.locusGroup,
            genotype: genotype,
            sample: "AnimalA"
        )
        try store.addMatrixComment(
            target: rowTarget,
            body: "Review provisional sequence"
        )
        try store.addMatrixComment(
            target: .column(sample: "AnimalA"),
            body: "Retained sample annotation"
        )
        try store.addMatrixComment(
            target: cellTarget,
            body: "Supported call needs review"
        )
        let annotationsURL = bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        var sidecar = try GenotypeAnnotationSidecar.decode(
            Data(contentsOf: annotationsURL)
        )
        sidecar.matrixReviews = [
            .init(
                target: cellTarget,
                disposition: .falsePositive,
                author: "Analyst",
                timestamp: "2026-07-29T00:00:00Z"
            ),
        ]
        try sidecar.encoded().write(to: annotationsURL)
        let extensionCandidate = makeCandidate(
            id: "extension-candidate",
            name: "Mafa-A1*007:06_ext",
            classification: .extension,
            support: .singleton,
            samples: ["AnimalA"]
        )
        let partialExtensionCandidate = makeCandidate(
            id: "partial-extension-candidate",
            name: "Mafa-A1*007:06_partial_ext",
            classification: .partialExtension,
            support: .singleton,
            samples: ["AnimalA"]
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeCandidateResult(
            bundleURL: bundleURL,
            calls: [call],
            candidates: [extensionCandidate, partialExtensionCandidate],
            observations: [
                makeCandidateObservation(
                    cluster: "extension-candidate",
                    sample: "AnimalA",
                    reads: 21
                ),
                makeCandidateObservation(
                    cluster: "partial-extension-candidate",
                    sample: "AnimalA",
                    reads: 19
                ),
            ],
            provisionalExon2SequencesByGenotype: [
                genotype: ONTGenotypeProvisionalExon2Sequence(
                    genotype: genotype,
                    locus: "MHC-A",
                    sequence: "ACGT",
                    sequenceSHA256: String(repeating: "0", count: 64),
                    sampleSupport: [
                        .init(
                            sample: "AnimalA",
                            passedAlignments: 42,
                            passedUniqueReads: 42
                        ),
                    ]
                ),
            ]
        ))

        controller.testingSelectMatrixColumn(sample: "AnimalA")

        let rows = controller.testingSupportedAllelesSnapshotRows
        XCTAssertEqual(
            rows.map(\.allele),
            controller.testingComparisonMatrix
                .visibleSampleAlleleDetails(sample: "AnimalA")
                .map(\.sharedCall.genotype)
        )
        let provisional = try XCTUnwrap(rows.first {
            $0.allele == genotype
        })
        XCTAssertEqual(provisional.readSupport, "[42]")
        XCTAssertTrue(provisional.readSupportIsItalic)
        XCTAssertTrue(provisional.readSupportIsSecondary)
        XCTAssertEqual(provisional.qualifiers, [
            "Provisional exon 2",
            "False positive",
            "Allele row comment",
            "Sample comment",
            "Cell comment",
        ])
        XCTAssertTrue(provisional.accessibilityLabel.contains(
            "Designation: Provisional exon 2."
        ))
        XCTAssertTrue(provisional.accessibilityLabel.contains(
            "Review: false positive."
        ))
        XCTAssertTrue(provisional.accessibilityLabel.contains(
            "Comments: allele row 1, sample column 1, cell 1."
        ))

        let extensionRow = try XCTUnwrap(rows.first {
            $0.allele == extensionCandidate.provisionalName
        })
        XCTAssertEqual(extensionRow.qualifiers, [
            "Extension candidate",
            "Sample comment",
        ])
        XCTAssertTrue(extensionRow.accessibilityLabel.contains(
            "Candidate classification: extension."
        ))
        let partialExtensionRow = try XCTUnwrap(rows.first {
            $0.allele == partialExtensionCandidate.provisionalName
        })
        XCTAssertEqual(partialExtensionRow.qualifiers, [
            "Partial extension candidate",
            "Sample comment",
        ])
        XCTAssertTrue(partialExtensionRow.accessibilityLabel.contains(
            "Candidate classification: partial extension."
        ))

        // A false-negative cell cannot be present in this evidence panel:
        // the Supported Alleles contract only contains cells with read support.
        XCTAssertFalse(rows.flatMap(\.qualifiers).contains("False negative"))
        XCTAssertEqual(
            GenotypeSupportedAllelesSnapshot.columnTitles,
            ["Allele", "Read support"]
        )
        XCTAssertEqual(
            controller.testingCurrentSelectionDetailRows.filter {
                $0.0 == "Allele" || $0.0 == "Read support"
            }.map { "\($0.0)=\($0.1)" },
            rows.flatMap {
                [
                    "Allele=\($0.allele)",
                    "Read support=\($0.readSupport)",
                ]
            }
        )
    }


    func testSelectedSampleWorkbenchFillsDetailPaneAcrossLayoutsAndViewportWidths()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SelectedSampleWorkbenchGeometry-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let call = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
        let result = makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 45,
                    passedUniqueReads: 42,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: [call]
                ),
            ],
            calls: [call]
        )

        for layout in [
            GenotypeResultPanelLayout.listTop,
            .listLeading,
            .listTrailing,
        ] {
            for width in [280, 420, 779, 841, 1_200, 1_720, 2_300] {
                let controller = GenotypeResultViewController()
                controller.view.frame = NSRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(width),
                    height: 900
                )
                controller.configure(result: result)
                controller.testingApplyDisplayStateImmediately(
                    GenotypeResultDisplayState(
                        summaryViewMode: .matrix,
                        layout: layout
                    )
                )
                controller.testingSelectMatrixColumn(sample: "AnimalA")
                controller.view.layoutSubtreeIfNeeded()

                let workbenchFrame = try XCTUnwrap(
                    controller.testingSampleWorkbenchFrame,
                    "\(layout) at \(width)"
                )
                XCTAssertNotNil(
                    controller.testingSampleWorkbenchLayoutMode,
                    "\(layout) at \(width)"
                )
                XCTAssertEqual(
                    workbenchFrame.width,
                    controller.testingDetailStackWidth,
                    accuracy: 1,
                    "\(layout) at \(width)"
                )
                XCTAssertGreaterThanOrEqual(
                    workbenchFrame.minX,
                    controller.testingDetailStackFrame.minX - 1,
                    "\(layout) at \(width)"
                )
                XCTAssertLessThanOrEqual(
                    workbenchFrame.maxX,
                    controller.testingDetailStackFrame.maxX + 1,
                    "\(layout) at \(width)"
                )
                if layout == .listTop, width == 1_720 {
                    let supportedAllelesList = try XCTUnwrap(
                        descendants(of: controller.view)
                            .compactMap {
                                $0 as?
                                    GenotypeSupportedAllelesListHostView
                            }
                            .first
                    )
                    XCTAssertGreaterThanOrEqual(
                        supportedAllelesList.bounds.width,
                        500,
                        "Supported Alleles collapsed despite a wide "
                            + "sample-detail pane."
                    )
                }
            }
        }
    }


    func testSelectedSampleEvidenceIsNotVerticallyCompressedInDetailScrollPane()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SelectedSampleEvidenceGeometry-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let calls = (1...12).map { index in
            makeCall(
                sample: "CR1178",
                genotype: "Mafa-A1*\(String(format: "%03d", index)):01:01:01",
                reads: index * 50
            )
        }
        let controller = GenotypeResultViewController()
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 1_020,
                height: 720
            ),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = controller.view
        controller.view.frame = window.contentView?.bounds ?? .zero
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "CR1178",
                    passedAlignments: 14_734,
                    passedUniqueReads: 14_734,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: calls
                ),
            ],
            calls: calls
        ))
        controller.testingApplyDisplayStateImmediately(
            GenotypeResultDisplayState(
                summaryViewMode: .matrix,
                layout: .listTop
            )
        )
        controller.testingSelectMatrixColumn(sample: "CR1178")
        window.makeKeyAndOrderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let trailingHost = try XCTUnwrap(
            ([controller.view] + descendants(of: controller.view)).first {
                $0.accessibilityIdentifier()
                    == "sample-curation-trailing-pane"
            }
        )
        let intrinsicHeight = trailingHost.intrinsicContentSize.height
        XCTAssertGreaterThan(
            intrinsicHeight,
            0,
            "The supported-alleles host must publish its measured height."
        )
        XCTAssertGreaterThanOrEqual(
            trailingHost.bounds.height + 0.5,
            intrinsicHeight,
            "The detail scroll pane compressed Supported Alleles from "
                + "\(intrinsicHeight) points to "
                + "\(trailingHost.bounds.height), which lets its content "
                + "draw over the sample summary."
        )
    }


    func testSelectedSampleWorkbenchResizePreservesDraftAndEditorIdentities()
        throws
    {
        let settings = AppSettings.shared
        let originalTextSize = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = originalTextSize
            settings.save()
        }
        settings.contentTextSizePreference = .custom(100)
        settings.save()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SelectedSampleWorkbenchIdentity-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let targetCall = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
        let sourceCall = makeCall(
            sample: "AnimalB",
            genotype: "01_Mafa_A1_001_01",
            reads: 21
        )
        let controller = GenotypeResultViewController()
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 841,
                height: 900
            ),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = controller.view
        controller.view.frame = NSRect(
            x: 0,
            y: 0,
            width: 841,
            height: 900
        )
        window.makeKeyAndOrderFront(nil)
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [targetCall, sourceCall]
        ))
        controller.testingApplyDisplayStateImmediately(
            GenotypeResultDisplayState(
                summaryViewMode: .matrix,
                layout: .listTop
            )
        )
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.view.layoutSubtreeIfNeeded()
        controller.testingUpdateManualHaplotypeLabel("Draft A")
        let focusedCombo = try XCTUnwrap(
            controller.testingFirstManualHaplotypeComboBox
        )
        XCTAssertTrue(window.makeFirstResponder(focusedCombo))

        let workbenchIdentity = try XCTUnwrap(
            controller.testingSampleWorkbenchIdentity
        )
        let hostIdentity = try XCTUnwrap(
            controller.testingManualHaplotypeEditorHostIdentity
        )
        let modelIdentity = try XCTUnwrap(
            controller.testingManualHaplotypeEditorModelIdentity
        )
        let comboIdentities =
            controller.testingManualHaplotypeComboIdentities
        let trailingIdentity = try XCTUnwrap(
            controller.testingSampleCurationTrailingModelIdentity
        )
        let comparisonIdentity = try XCTUnwrap(
            controller.testingSampleComparisonModelIdentity
        )
        XCTAssertTrue(
            controller.testingPerformManualHaplotypeCompareAction()
        )
        flushMountedController(controller)
        XCTAssertTrue(
            controller.testingPerformSampleComparisonSourceSelection(
                "AnimalB"
            )
        )
        flushMountedController(controller)
        XCTAssertTrue(window.makeFirstResponder(focusedCombo))
        let controlIdentities =
            controller.testingSampleCurationControlIdentities
        XCTAssertTrue(
            Set([
                "manual-haplotype-compare-copy",
                "sample-comparison-back-to-evidence",
                "sample-comparison-source-search",
                "sample-comparison-stage-selected",
            ]).isSubset(of: Set(controlIdentities.keys))
        )

        for scale in [100, 200] {
            settings.contentTextSizePreference = .custom(scale)
            settings.save()
            for width in [420, 779, 841, 1_200] {
                controller.view.frame.size.width = CGFloat(width)
                controller.view.layoutSubtreeIfNeeded()

                XCTAssertEqual(
                    controller.testingSampleWorkbenchIdentity,
                    workbenchIdentity
                )
                XCTAssertEqual(
                    controller.testingManualHaplotypeEditorHostIdentity,
                    hostIdentity
                )
                XCTAssertEqual(
                    controller.testingManualHaplotypeEditorModelIdentity,
                    modelIdentity
                )
                XCTAssertEqual(
                    controller.testingSampleCurationTrailingModelIdentity,
                    trailingIdentity
                )
                XCTAssertEqual(
                    controller.testingSampleComparisonModelIdentity,
                    comparisonIdentity
                )
                XCTAssertEqual(
                    controller.testingManualHaplotypeComboIdentities,
                    comboIdentities
                )
                XCTAssertEqual(
                    controller.testingSampleCurationControlIdentities,
                    controlIdentities
                )
                XCTAssertEqual(
                    controller.testingManualHaplotypeDraftLabel(
                        locus: .a,
                        slot: .h1
                    ),
                    "Draft A"
                )
                XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
                XCTAssertTrue(
                    window.firstResponder === focusedCombo
                        || focusedCombo.currentEditor()
                            === window.firstResponder
                )

                XCTAssertTrue(
                    controller.testingPerformBackToSampleEvidenceAction()
                )
                flushMountedController(controller)
                XCTAssertEqual(
                    controller.testingSampleCurationTrailingMode,
                    .evidence
                )
                XCTAssertTrue(
                    controller.testingPerformManualHaplotypeCompareAction()
                )
                flushMountedController(controller)
                XCTAssertEqual(
                    controller.testingSampleCurationTrailingMode,
                    .compareAndCopy
                )
            }
        }
    }


    func testSelectedSampleWorkbenchHeaderKeepsEveryMetricReadableAtNarrowWidths()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SelectedSampleHeaderNarrow-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let call = makeCall(
            sample: "AnimalA Long Sample Name",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
        let controller = GenotypeResultViewController()
        controller.view.frame = NSRect(
            x: 0,
            y: 0,
            width: 420,
            height: 1_000
        )
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA Long Sample Name",
                    passedAlignments: 45,
                    passedUniqueReads: 42,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: [call]
                ),
            ],
            calls: [call]
        ))
        controller.testingApplyDisplayStateImmediately(
            GenotypeResultDisplayState(
                summaryViewMode: .matrix,
                layout: .listTop
            )
        )
        controller.testingSelectMatrixColumn(
            sample: "AnimalA Long Sample Name"
        )
        controller.view.layoutSubtreeIfNeeded()

        let identities =
            controller.testingSampleHeaderMetricIdentities
        for width in [420, 280] {
            controller.view.frame.size.width = CGFloat(width)
            controller.view.layoutSubtreeIfNeeded()

            XCTAssertEqual(
                controller.testingSampleHeaderLayoutMode,
                .stacked
            )
            XCTAssertEqual(
                controller.testingSampleHeaderMetricValues,
                [
                    "Selected Sample": "AnimalA Long Sample Name",
                    "Retained Unique Reads": "42",
                    "Passed Alignments": "45",
                    "Call-support check": "Low support",
                ]
            )
            XCTAssertEqual(
                controller.testingSampleHeaderMetricIdentities,
                identities
            )
            XCTAssertTrue(
                controller.testingSampleHeaderMetricFramesAreContained
            )
            XCTAssertTrue(
                controller.testingSampleHeaderFieldsAllowWrapping
            )
            XCTAssertEqual(
                controller.testingSampleHeaderSemanticElementCounts,
                [1, 1, 1, 1]
            )
        }
    }


    func testSelectedSampleWorkbenchRespondsToLiveContentTypographyChanges()
        throws
    {
        let settings = AppSettings.shared
        let original = settings.contentTextSizePreference
        defer {
            settings.contentTextSizePreference = original
            settings.save()
        }
        settings.contentTextSizePreference = .custom(100)
        settings.save()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SelectedSampleWorkbenchTypography-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let call = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
        let controller = GenotypeResultViewController()
        controller.view.frame = NSRect(
            x: 0,
            y: 0,
            width: 1_200,
            height: 900
        )
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 45,
                    passedUniqueReads: 42,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: [call]
                ),
            ],
            calls: [call]
        ))
        controller.testingApplyDisplayStateImmediately(
            GenotypeResultDisplayState(
                summaryViewMode: .matrix,
                layout: .listTop
            )
        )
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            controller.testingSampleWorkbenchLayoutMode,
            .sideBySide
        )
        XCTAssertEqual(
            controller.testingSampleHeaderLayoutMode,
            .sideBySide
        )
        let headerMetricIdentities =
            controller.testingSampleHeaderMetricIdentities

        settings.contentTextSizePreference = .custom(200)
        settings.save()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            controller.testingSampleWorkbenchLayoutMode,
            .stacked
        )
        XCTAssertEqual(
            controller.testingSampleHeaderLayoutMode,
            .sideBySide
        )
        XCTAssertEqual(
            controller.testingSampleHeaderMetricIdentities,
            headerMetricIdentities
        )
        XCTAssertEqual(
            controller.testingSampleHeaderMetricValues,
            [
                "Selected Sample": "AnimalA",
                "Retained Unique Reads": "42",
                "Passed Alignments": "45",
                "Call-support check": "Low support",
            ]
        )
        XCTAssertTrue(
            controller.testingSampleHeaderMetricFramesAreContained
        )
        XCTAssertTrue(
            controller.testingSampleHeaderFieldsAllowWrapping
        )
        XCTAssertEqual(
            controller.testingSampleHeaderSemanticElementCounts,
            [1, 1, 1, 1]
        )
    }


    func testSelectedSampleWorkbenchIsTornDownForOtherSelectionSurfaces() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SelectedSampleWorkbenchTeardown-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let call = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [call]
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        XCTAssertNotNil(controller.testingSampleWorkbenchIdentity)

        controller.testingSelectMatrixRows(
            genotypes: [call.genotype],
            sample: nil
        )

        XCTAssertNil(controller.testingSampleWorkbenchIdentity)
        XCTAssertNil(controller.testingSampleWorkbenchLayoutMode)
    }


    func testDirectHaplotypedResultReplacementPhysicallyRemovesManualWorkbenchAndRejectsStaleSave()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualWorkbenchDirectReplacement-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let call = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [call]
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        let staleModel = try XCTUnwrap(
            controller.testingRetainedManualHaplotypeEditorModel
        )
        XCTAssertEqual(controller.testingMountedSampleWorkbenchCount, 1)

        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [call],
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis()
        ))

        XCTAssertEqual(controller.testingMountedSampleWorkbenchCount, 0)
        XCTAssertNil(controller.testingSampleWorkbenchIdentity)
        XCTAssertNil(controller.testingManualHaplotypeEditorSample)
        staleModel.updateLabel(
            "Must Not Save",
            locus: .a,
            slot: .h1
        )
        staleModel.save()
        XCTAssertNotNil(staleModel.persistenceErrorMessage)
        XCTAssertTrue(controller.testingManualHaplotypeAssignments.isEmpty)
    }


    func testAIHaplotypingCompletionPhysicallyRemovesManualWorkbenchAndRejectsStaleSave()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManualWorkbenchAICompletion-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let call = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 42
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [call]
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        let staleModel = try XCTUnwrap(
            controller.testingRetainedManualHaplotypeEditorModel
        )
        XCTAssertEqual(controller.testingMountedSampleWorkbenchCount, 1)

        controller.applyAIHaplotypingCompleted(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [call],
            haplotypeAnalysis: makeEmptyHaplotypeAnalysis()
        ))

        XCTAssertEqual(controller.testingMountedSampleWorkbenchCount, 0)
        XCTAssertNil(controller.testingSampleWorkbenchIdentity)
        XCTAssertNil(controller.testingManualHaplotypeEditorSample)
        staleModel.updateLabel(
            "Must Not Save",
            locus: .a,
            slot: .h1
        )
        staleModel.save()
        XCTAssertNotNil(staleModel.persistenceErrorMessage)
        XCTAssertTrue(controller.testingManualHaplotypeAssignments.isEmpty)
    }


    func testSelectedColumnDetailsRefreshWhenRowFilterChanges() {
        let first = makeCall(sample: "AnimalA", genotype: "NHP01222", reads: 73)
        let second = makeCall(sample: "AnimalA", genotype: "NHP99999", reads: 41)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [], calls: [first, second], referenceMetadata: makeGenBankReferenceMetadata()
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        XCTAssertTrue(controller.testingDetailText.contains("Mafa-B*002:01"))

        controller.testingSetComparisonFilter("Mafa-A1")

        XCTAssertTrue(controller.testingDetailText.contains("Mafa-A1*001:01"))
        XCTAssertFalse(controller.testingDetailText.contains("Mafa-B*002:01"))
    }


    func testSelectedSampleComparisonRefreshesProjectionWithoutRemountingModels()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SampleComparisonRefresh-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let first = makeCall(
            sample: "AnimalA",
            genotype: "NHP01222",
            reads: 73
        )
        let second = makeCall(
            sample: "AnimalB",
            genotype: "NHP99999",
            reads: 41
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [first, second],
            referenceMetadata: makeGenBankReferenceMetadata()
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        let workbench = controller.testingSampleWorkbenchIdentity
        let editor = controller.testingManualHaplotypeEditorModelIdentity
        let trailing =
            controller.testingSampleCurationTrailingModelIdentity
        let comparison =
            controller.testingSampleComparisonModelIdentity

        controller.testingShowSampleComparison()
        controller.testingSelectSampleComparisonSource("AnimalB")
        controller.testingSetComparisonFilter("Mafa-A1")

        XCTAssertEqual(
            controller.testingSampleCurationTrailingMode,
            .compareAndCopy
        )
        XCTAssertEqual(controller.testingSampleWorkbenchIdentity, workbench)
        XCTAssertEqual(
            controller.testingManualHaplotypeEditorModelIdentity,
            editor
        )
        XCTAssertEqual(
            controller.testingSampleCurationTrailingModelIdentity,
            trailing
        )
        XCTAssertEqual(
            controller.testingSampleComparisonModelIdentity,
            comparison
        )
        XCTAssertEqual(
            controller.testingSampleComparisonRowIDs,
            controller.testingComparisonMatrix.testingVisibleRows
                .filter {
                    $0.support(for: "AnimalA") != nil
                        || $0.support(for: "AnimalB") != nil
                }
                .map(\.id)
        )
    }


    func testSelectedSampleComparisonTracksMatrixSortWithoutRemountingModels()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SampleComparisonSort-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let first = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 73
        )
        let second = makeCall(
            sample: "AnimalB",
            genotype: "04_Mafa_B_001_01",
            reads: 41
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [first, second]
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingShowSampleComparison()
        controller.testingSelectSampleComparisonSource("AnimalB")
        let workbench = controller.testingSampleWorkbenchIdentity
        let editor = controller.testingManualHaplotypeEditorModelIdentity
        let trailing = controller.testingSampleCurationTrailingModelIdentity
        let comparison = controller.testingSampleComparisonModelIdentity

        controller.testingComparisonMatrix.testingSetSortDescriptor(
            key: "genotype",
            ascending: false
        )

        XCTAssertEqual(controller.testingSampleCurationTrailingMode, .compareAndCopy)
        XCTAssertEqual(controller.testingSampleWorkbenchIdentity, workbench)
        XCTAssertEqual(controller.testingManualHaplotypeEditorModelIdentity, editor)
        XCTAssertEqual(controller.testingSampleCurationTrailingModelIdentity, trailing)
        XCTAssertEqual(controller.testingSampleComparisonModelIdentity, comparison)
        XCTAssertEqual(
            controller.testingSampleComparisonRowIDs,
            controller.testingComparisonMatrix.testingVisibleRows.map(\.id)
        )
    }


    func testSelectedSampleComparisonTracksSupportThresholdWithoutRemountingModels()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SampleComparisonThreshold-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let retained = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 73
        )
        let removed = makeCall(
            sample: "AnimalB",
            genotype: "04_Mafa_B_001_01",
            reads: 9
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [retained, removed]
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingShowSampleComparison()
        controller.testingSelectSampleComparisonSource("AnimalB")
        let workbench = controller.testingSampleWorkbenchIdentity
        let editor = controller.testingManualHaplotypeEditorModelIdentity
        let trailing = controller.testingSampleCurationTrailingModelIdentity
        let comparison = controller.testingSampleComparisonModelIdentity
        var state = controller.testingDisplayState
        state.minimumReads = 20

        controller.testingApplyDisplayStateImmediately(state)

        XCTAssertEqual(controller.testingSampleCurationTrailingMode, .compareAndCopy)
        XCTAssertEqual(controller.testingSampleWorkbenchIdentity, workbench)
        XCTAssertEqual(controller.testingManualHaplotypeEditorModelIdentity, editor)
        XCTAssertEqual(controller.testingSampleCurationTrailingModelIdentity, trailing)
        XCTAssertEqual(controller.testingSampleComparisonModelIdentity, comparison)
        XCTAssertEqual(
            controller.testingSampleComparisonRowIDs,
            controller.testingComparisonMatrix.testingVisibleRows.map(\.id)
        )
        XCTAssertEqual(controller.testingSampleComparisonRowIDs.count, 1)
    }


    func testSelectedSampleComparisonTracksManualRowAndSampleVisibilityWithoutRemountingModels()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SampleComparisonVisibility-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let first = makeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            reads: 73
        )
        let second = makeCall(
            sample: "AnimalB",
            genotype: "04_Mafa_B_001_01",
            reads: 41
        )
        let third = makeCall(
            sample: "AnimalC",
            genotype: "06_Mafa_I_001_01",
            reads: 29
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [first, second, third]
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingShowSampleComparison()
        controller.testingSelectSampleComparisonSource("AnimalB")
        let workbench = controller.testingSampleWorkbenchIdentity
        let editor = controller.testingManualHaplotypeEditorModelIdentity
        let trailing = controller.testingSampleCurationTrailingModelIdentity
        let comparison = controller.testingSampleComparisonModelIdentity
        let hiddenRow = try XCTUnwrap(
            controller.testingComparisonMatrix.testingVisibleRows.last?.id
        )

        controller.testingComparisonMatrix.testingHideRows(Set([hiddenRow]))
        controller.testingComparisonMatrix.testingHideSamples(Set(["AnimalC"]))

        XCTAssertEqual(controller.testingSampleCurationTrailingMode, .compareAndCopy)
        XCTAssertEqual(controller.testingSampleWorkbenchIdentity, workbench)
        XCTAssertEqual(controller.testingManualHaplotypeEditorModelIdentity, editor)
        XCTAssertEqual(controller.testingSampleCurationTrailingModelIdentity, trailing)
        XCTAssertEqual(controller.testingSampleComparisonModelIdentity, comparison)
        XCTAssertEqual(
            controller.testingSampleComparisonRowIDs,
            controller.testingComparisonMatrix.testingVisibleRows.map(\.id)
        )
        XCTAssertFalse(controller.testingSampleComparisonRowIDs.contains(hiddenRow))
        XCTAssertFalse(controller.testingVisibleMatrixSamples.contains("AnimalC"))
    }


    func testSampleComparisonSharedQuickSearchPreservesFullMountedSession()
        throws
    {
        try assertSampleComparisonProjectionPreservesMountedSession {
            controller, _ in
            controller.testingSetQuickFilterSearchText("Mafa-A1")
        }
    }


    func testSampleComparisonNativeSearchPreservesFullMountedSession()
        throws
    {
        try assertSampleComparisonProjectionPreservesMountedSession {
            controller, _ in
            controller.testingSetComparisonFilter("Mafa-A1")
        }
    }


    func testSampleComparisonLocusFilterPreservesFullMountedSession()
        throws
    {
        try assertSampleComparisonProjectionPreservesMountedSession {
            _, matrix in
            matrix.testingSetLocusFilter("MHC-A")
        }
    }


    func testSampleComparisonSortPreservesFullMountedSession() throws {
        try assertSampleComparisonProjectionPreservesMountedSession {
            _, matrix in
            matrix.testingSetSortDescriptor(
                key: "genotype",
                ascending: false
            )
        }
    }


    func testSampleComparisonMinimumReadsPreservesFullMountedSession()
        throws
    {
        try assertSampleComparisonProjectionPreservesMountedSession {
            controller, _ in
            var state = controller.testingDisplayState
            state.minimumReads = 10
            controller.testingApplyDisplayStateImmediately(state)
        }
    }


    func testSampleComparisonMinimumPercentPreservesFullMountedSession()
        throws
    {
        try assertSampleComparisonProjectionPreservesMountedSession {
            controller, _ in
            var state = controller.testingDisplayState
            state.matrixMinimumPercent = 10
            state.matrixPercentDenominator = .sampleRetained
            controller.testingApplyDisplayStateImmediately(state)
        }
    }


    func testSampleComparisonPercentBasisPreservesFullMountedSession()
        throws
    {
        try assertSampleComparisonProjectionPreservesMountedSession(
            prepare: { controller, _ in
                var state = controller.testingDisplayState
                state.matrixMinimumPercent = 10
                state.matrixPercentDenominator = .sampleRetained
                controller.testingApplyDisplayStateImmediately(state)
            },
            trigger: { controller, _ in
                var state = controller.testingDisplayState
                state.matrixPercentDenominator = .viewedLocus
                controller.testingApplyDisplayStateImmediately(state)
            }
        )
    }


    func testSampleComparisonManualRowVisibilityPreservesFullMountedSession()
        throws
    {
        try assertSampleComparisonProjectionPreservesMountedSession {
            _, matrix in
            if let row = matrix.testingVisibleRows.last?.id {
                matrix.testingHideRows(Set([row]))
            }
        }
    }


    func testSampleComparisonManualSampleVisibilityPreservesFullMountedSession()
        throws
    {
        try assertSampleComparisonProjectionPreservesMountedSession {
            _, matrix in
            matrix.testingHideSamples(Set(["AnimalC"]))
        }
    }


    func testAnnotationOnlyReviewAndCommentRefreshDirtyComparisonInPlace()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SampleComparisonAnnotation-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let shared = "01_Mafa_A1_SHARED"
        let targetOnly = "02_Mafa_A1_TARGET_ONLY"
        let calls = [
            makeCall(sample: "AnimalA", genotype: shared, reads: 21),
            makeCall(sample: "AnimalB", genotype: shared, reads: 13),
            makeCall(sample: "AnimalA", genotype: targetOnly, reads: 7),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: calls
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        controller.testingShowSampleComparison()
        controller.testingSelectSampleComparisonSource("AnimalB")
        controller.testingUpdateManualHaplotypeLabel("Dirty draft")
        let workbench = controller.testingSampleWorkbenchIdentity
        let editor = controller.testingManualHaplotypeEditorModelIdentity
        let trailing = controller.testingSampleCurationTrailingModelIdentity
        let comparison = controller.testingSampleComparisonModelIdentity
        let sharedTarget = GenotypeAnnotationSidecar.MatrixTarget.cell(
            locus: "MHC-A",
            genotype: shared,
            sample: "AnimalB"
        )
        let falseNegativeTarget =
            GenotypeAnnotationSidecar.MatrixTarget.cell(
                locus: "MHC-A",
                genotype: targetOnly,
                sample: "AnimalB"
            )

        controller.applyMatrixReview(.init(
            targets: [sharedTarget],
            intent: .set(.falsePositive)
        ))
        controller.applyMatrixReview(.init(
            targets: [falseNegativeTarget],
            intent: .set(.falseNegative)
        ))
        controller.editMatrixComment(.init(
            targets: [sharedTarget],
            intent: .upsert(body: "Source review note")
        ))

        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertEqual(controller.testingSampleCurationTrailingMode, .compareAndCopy)
        XCTAssertEqual(controller.testingSampleWorkbenchIdentity, workbench)
        XCTAssertEqual(controller.testingManualHaplotypeEditorModelIdentity, editor)
        XCTAssertEqual(controller.testingSampleCurationTrailingModelIdentity, trailing)
        XCTAssertEqual(controller.testingSampleComparisonModelIdentity, comparison)
        let summaries = controller.testingSampleComparisonRows
            .compactMap(\.indicatorSummary)
            .joined(separator: "\n")
        XCTAssertTrue(summaries.contains("Source: FP, comment"))
        XCTAssertTrue(summaries.contains("Source: FN"))
    }


    func testMountedCompareBrowseAndStageHasNoPersistenceOrProjectionSideEffects()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SampleComparisonNoPersistence-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent(
            "example.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        var sidecar = GenotypeAnnotationSidecar.empty(
            generatedAt: "2026-07-29T00:00:00Z"
        )
        sidecar.manualHaplotypeAssignments = [
            ManualHaplotypeAssignment(
                sample: "AnimalB",
                locus: "MHC-A",
                slot: .h1,
                label: "Source H1",
                colorTokenIndex: 1,
                diagnosticAlleles: [],
                notes: ""
            ),
        ]
        try ONTGenotypeResultBundleData.writeAnnotationSidecar(
            sidecar,
            forBundleAt: bundleURL
        )
        let result = makeResult(
            bundleURL: bundleURL,
            samples: [],
            calls: [
                makeCall(
                    sample: "AnimalA",
                    genotype: "01_Mafa_A1_SHARED",
                    reads: 21
                ),
                makeCall(
                    sample: "AnimalB",
                    genotype: "01_Mafa_A1_SHARED",
                    reads: 13
                ),
            ]
        )
        try ONTGenotypeResultBundle.writeManifest(
            result.manifest,
            to: bundleURL
        )
        let controller = GenotypeResultViewController()
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: 1_200,
                height: 900
            ),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        controller.configure(result: result)
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        flushMountedController(controller)
        let sidecarURL = bundleURL.appendingPathComponent(
            GenotypeAnnotationSidecar.filename
        )
        let sidecarBefore = try Data(contentsOf: sidecarURL)
        let assignmentsBefore = controller.testingManualHaplotypeAssignments
        var sidecarPublicationCount = 0
        var workbookActions: [GenotypeCurrentWorkbookUIRequest.Action] = []
        controller.onAnnotationSidecarChanged = { _ in
            sidecarPublicationCount += 1
        }
        controller.onCurrentWorkbookSyncRequested = {
            workbookActions.append($0.action)
        }
        controller.testingResetProjectionPerformanceCounters()
        let performanceBefore = controller.testingProjectionPerformanceSnapshot

        XCTAssertTrue(controller.testingPerformManualHaplotypeCompareAction())
        flushMountedController(controller)
        XCTAssertTrue(
            controller.testingPerformSampleComparisonSourceSelection(
                "AnimalB"
            )
        )
        flushMountedController(controller)
        controller.testingSetSampleComparisonAssignmentSelected(
            true,
            locus: .a,
            slot: .h1
        )
        controller.testingRequestStageSelectedSampleAssignments()
        controller.testingConfirmStageSelectedSampleAssignments()
        flushMountedController(controller)

        XCTAssertTrue(controller.testingManualHaplotypeEditorIsDirty)
        XCTAssertEqual(
            controller.testingManualHaplotypeDraftLabel(
                locus: .a,
                slot: .h1
            ),
            "Source H1"
        )
        XCTAssertEqual(controller.testingManualHaplotypeWorkbookDirtyMarkCount, 0)
        XCTAssertEqual(controller.testingManualHaplotypeAssignments, assignmentsBefore)
        XCTAssertEqual(try Data(contentsOf: sidecarURL), sidecarBefore)
        XCTAssertEqual(sidecarPublicationCount, 0)
        XCTAssertTrue(workbookActions.isEmpty)
        XCTAssertEqual(
            controller.testingProjectionPerformanceSnapshot,
            performanceBefore
        )
    }


    func testMultiRowSelectionPrunesHiddenNonAnchorAndAnchorRows() {
        let first = "01_Mafa_A1_KEEP_A"
        let second = "02_Mafa_A1_KEEP_B"
        let third = "03_Mafa_A1_DROP"
        let calls = [first, second, third].map { makeCall(sample: "AnimalA", genotype: $0, reads: 10) }

        let nonAnchorController = GenotypeResultViewController()
        _ = nonAnchorController.view
        nonAnchorController.configure(result: makeResult(samples: [], calls: calls))
        nonAnchorController.testingSelectMatrixRows(genotypes: [first, third, second], sample: nil)
        nonAnchorController.testingSetComparisonFilter("KEEP")
        XCTAssertEqual(Set(nonAnchorController.testingCurrentSelectionMatrixTargets), Set([
            .row(locus: "MHC-A", genotype: first), .row(locus: "MHC-A", genotype: second),
        ]))
        XCTAssertFalse(nonAnchorController.testingDetailText.contains(third))

        let anchorController = GenotypeResultViewController()
        _ = anchorController.view
        anchorController.configure(result: makeResult(samples: [], calls: calls))
        anchorController.testingSelectMatrixRows(genotypes: [first, second, third], sample: nil)
        anchorController.testingSetComparisonFilter("KEEP")
        XCTAssertEqual(Set(anchorController.testingCurrentSelectionMatrixTargets), Set([
            .row(locus: "MHC-A", genotype: first), .row(locus: "MHC-A", genotype: second),
        ]))
        XCTAssertTrue(anchorController.testingDetailText.contains(first))
        XCTAssertTrue(anchorController.testingDetailText.contains(second))
    }


    func testMultiCellSelectionPrunesRowsAndSamplesWhileKeepingVisibleEmptyCells() {
        let first = "01_Mafa_A1_KEEP"
        let second = "02_Mafa_A1_DROP"
        let callA = makeCall(sample: "AnimalA", genotype: first, reads: 10)
        let callB = makeCall(sample: "AnimalB", genotype: second, reads: 20)
        let samples = [
            ONTGenotypeSampleResult(sample: "AnimalA", passedAlignments: 10, passedUniqueReads: 10, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [callA]),
            ONTGenotypeSampleResult(sample: "AnimalB", passedAlignments: 20, passedUniqueReads: 20, sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [callB]),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: samples, calls: [callA, callB]))
        controller.testingClickMatrixCell(genotype: first, sample: "AnimalA")
        controller.testingClickMatrixCell(genotype: second, sample: "AnimalB", modifiers: .command)
        controller.testingClickMatrixCell(genotype: first, sample: "AnimalB", modifiers: .command)

        controller.testingSetComparisonFilter("KEEP")
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: first, sample: "AnimalB"),
        ]))
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Evidence", "No supporting reads") })

        controller.testingSetComparisonFilter("")
        controller.testingClickMatrixCell(genotype: first, sample: "AnimalA")
        controller.testingClickMatrixCell(genotype: second, sample: "AnimalB", modifiers: .command)
        controller.testingApplyDisplayState(GenotypeResultDisplayState(matrixSampleFilterText: "AnimalB"))
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets, [
            .cell(locus: "MHC-A", genotype: second, sample: "AnimalB"),
        ])
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Unique Reads", "20") })
    }


    func testMixedSelectionPrunesEveryTargetKindAcrossSequentialFilters() {
        let keep = "01_Mafa_A1_KEEP"
        let drop = "02_Mafa_A1_DROP"
        let calls = [
            makeCall(sample: "AnimalA", genotype: keep, reads: 10),
            makeCall(sample: "AnimalB", genotype: keep, reads: 20),
            makeCall(sample: "AnimalA", genotype: drop, reads: 30),
            makeCall(sample: "AnimalB", genotype: drop, reads: 40),
        ]
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: calls))
        controller.testingClickMatrixSelectAllChiclet()
        controller.testingClickMatrixCell(genotype: keep, sample: "AnimalA", modifiers: .command)
        controller.testingClickMatrixCell(genotype: keep, sample: "AnimalB", modifiers: .command)

        controller.testingSetComparisonFilter("KEEP")
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .row(locus: "MHC-A", genotype: keep),
            .cell(locus: "MHC-A", genotype: keep, sample: "AnimalA"),
            .cell(locus: "MHC-A", genotype: keep, sample: "AnimalB"),
            .column(sample: "AnimalA"),
            .column(sample: "AnimalB"),
        ]))

        controller.testingApplyDisplayState(GenotypeResultDisplayState(matrixSampleFilterText: "AnimalB"))
        XCTAssertEqual(Set(controller.testingCurrentSelectionMatrixTargets), Set([
            .row(locus: "MHC-A", genotype: keep),
            .cell(locus: "MHC-A", genotype: keep, sample: "AnimalB"),
            .column(sample: "AnimalB"),
        ]))
    }


    func testSelectedColumnReadSupportDoesNotBecomeFractionWhenDenominatorChanges() {
        let selected = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_SELECTED", reads: 25)
        let other = makeCall(sample: "AnimalA", genotype: "02_Mafa_A1_OTHER", reads: 75)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [ONTGenotypeSampleResult(
                sample: "AnimalA", passedAlignments: 200, passedUniqueReads: 200,
                sampleTotalReads: nil, sampleUniqueRetainedPercent: nil, calls: [selected, other]
            )],
            calls: [selected, other]
        ))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Read support", "25") })
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == "Support" })
        var selectionPublicationCount = 0
        controller.onSelectionStateChanged = { _ in selectionPublicationCount += 1 }

        controller.testingApplyDisplayState(GenotypeResultDisplayState(
            supportDenominator: .sampleRetained
        ))

        XCTAssertEqual(selectionPublicationCount, 1)
        XCTAssertTrue(controller.testingCurrentSelectionDetailRows.contains { $0 == ("Read support", "25") })
        XCTAssertFalse(controller.testingCurrentSelectionDetailRows.contains { $0.0 == "Support" })
    }


    func testSelectedLargeColumnPublishesEveryAlleleWithBoundedDetailSubviews() {
        let alleleCount = 1_001
        let calls = (0..<alleleCount).map { index in
            makeCall(
                sample: "AnimalA",
                genotype: String(format: "%04d_Mafa_A1_%04d", index, index),
                reads: 1
            )
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: calls))

        controller.testingSelectMatrixColumn(sample: "AnimalA")

        XCTAssertEqual(
            controller.testingCurrentSelectionDetailRows.filter { $0.0 == "Allele" }.count,
            alleleCount
        )
        XCTAssertLessThanOrEqual(controller.testingDetailArrangedSubviewCount, 12)
        XCTAssertTrue(controller.testingDetailText.contains(calls.first!.genotype))
        XCTAssertTrue(controller.testingDetailText.contains(calls.last!.genotype))
    }


    func testSelectedLargeMultiRowAndCellDetailsStayBounded() {
        let count = 1_001
        let calls = (0..<count).map { index in
            makeCall(sample: "AnimalA", genotype: String(format: "%04d_Mafa_A1_%04d", index, index), reads: index + 1)
        }
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: calls))
        let rowTargets = calls.reversed().map {
            GenotypeAnnotationSidecar.MatrixTarget.row(locus: "MHC-A", genotype: $0.genotype)
        }
        controller.testingShowMatrixTargetSelection(rowTargets)
        XCTAssertEqual(controller.testingCurrentSelectionDetailRows.filter { $0.0.hasPrefix("Allele ") }.count, count)
        XCTAssertLessThanOrEqual(controller.testingDetailArrangedSubviewCount, 6)
        XCTAssertTrue(controller.testingDetailText.contains(calls.first!.genotype))
        XCTAssertTrue(controller.testingDetailText.contains(calls.last!.genotype))

        let cellTargets = calls.reversed().map {
            GenotypeAnnotationSidecar.MatrixTarget.cell(locus: "MHC-A", genotype: $0.genotype, sample: "AnimalA")
        }
        controller.testingShowMatrixTargetSelection(cellTargets)
        XCTAssertEqual(controller.testingCurrentSelectionMatrixTargets.count, count)
        XCTAssertEqual(controller.testingCurrentSelectionDetailRows.filter { $0.0.hasPrefix("Cell ") }.count, count)
        XCTAssertEqual(controller.testingCurrentSelectionDetailRows.filter { $0.0 == "Unique Reads" }.count, count)
        XCTAssertLessThanOrEqual(controller.testingDetailArrangedSubviewCount, 6)
        XCTAssertTrue(controller.testingDetailText.contains(calls.first!.genotype))
        XCTAssertTrue(controller.testingDetailText.contains(calls.last!.genotype))
    }


    func testSelectedColumnOmitsUnavailableSummaryMetricsWhenSampleSummaryMissing() {
        let call = makeCall(sample: "AnimalA", genotype: "01_Mafa_A1_ONLY", reads: 42)
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(samples: [], calls: [call]))
        controller.testingSelectMatrixColumn(sample: "AnimalA")
        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Sample", "AnimalA") })
        XCTAssertTrue(rows.contains { $0 == ("Read support", "42") })
        XCTAssertFalse(rows.contains { ["Retained Unique Reads", "Call-support check"].contains($0.0) })
        XCTAssertFalse(rows.contains { $0.0 == "Alignments" && $0.1 == "Unavailable" })
    }


    func testDuplicateCellEvidenceRowsKeepFirstRecordWithoutCrashing() {
        let genotype = "01_Mafa_A1_DUPLICATE"
        let first = makeCall(sample: "AnimalA", genotype: genotype, reads: 17)
        let duplicate = makeCall(sample: "AnimalA", genotype: genotype, reads: 91)
        let controller = GenotypeResultViewController()
        _ = controller.view

        controller.configure(result: makeResult(samples: [], calls: [first, duplicate]))
        _ = controller.testingVisibleGenotypes
        controller.testingShowMatrixTargetSelection([
            .cell(locus: "MHC-A", genotype: genotype, sample: "AnimalA"),
        ])

        let rows = controller.testingCurrentSelectionDetailRows
        XCTAssertTrue(rows.contains { $0 == ("Locus", "MHC-A") })
        XCTAssertTrue(rows.contains { $0 == ("Unique Reads", "17") })
        XCTAssertTrue(rows.contains { $0 == ("Alignments", "17") })
        XCTAssertTrue(rows.contains { $0 == ("Support", "15.7%") })
        XCTAssertFalse(rows.contains { $0 == ("Unique Reads", "91") })
    }


    func testSelectedAlleleTieUsesRawSequenceOrdinalOrder() {
        let first = "01_Mafa_A1_Z"
        let second = "02_Mafa_A1_A"
        let fields = [
            GenBankRecordDatabase.FieldDefinition(
                key: "feature.allele", displayTitle: "Allele", valueType: "text",
                sourceCategory: "feature", preferredOrder: 0
            ),
        ]
        let metadata = ONTGenotypeReferenceMetadata(
            fields: fields,
            recordsBySequenceName: [
                first: ["feature.allele": "Mafa-A1*same"],
                second: ["feature.allele": "Mafa-A1*same"],
            ],
            alleleFieldKey: "feature.allele"
        )
        let controller = GenotypeResultViewController()
        _ = controller.view
        controller.configure(result: makeResult(
            samples: [],
            calls: [makeCall(sample: "AnimalA", genotype: first, reads: 10), makeCall(sample: "AnimalA", genotype: second, reads: 10)],
            referenceMetadata: metadata
        ))

        controller.testingShowMatrixTargetSelection([
            .row(locus: "MHC-A", genotype: second),
            .row(locus: "MHC-A", genotype: first),
        ])

        XCTAssertEqual(
            controller.testingCurrentSelectionDetailRows.filter { $0.0 == "Reference Sequence" }.map(\.1),
            [first, second]
        )
    }

}

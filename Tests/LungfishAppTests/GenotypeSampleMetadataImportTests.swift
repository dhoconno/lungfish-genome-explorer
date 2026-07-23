import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishWorkflow

@MainActor
final class GenotypeSampleMetadataImportTests: XCTestCase {
    func testImportPersistsGenotypeMetadataAndProvenanceWithFinalBundlePayload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeSampleMetadataImportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundleURL = root.appendingPathComponent("barcode05-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundleURL.appendingPathComponent("genotype-result.json"))

        let sourceURL = root.appendingPathComponent("metadata.tsv")
        let metadata = Data("""
        Sample\tCohort\tAnimal
        AnimalA\ttreated\tmacaque
        """.utf8)
        try metadata.write(to: sourceURL)
        let knownSampleIds: Set<String> = ["AnimalA"]
        let scanResult = try SampleMetadataStore.scanForSampleColumn(
            csvData: metadata,
            knownSampleIds: knownSampleIds
        )
        let bestColumn = try XCTUnwrap(scanResult.bestColumn)

        let result = try SampleMetadataBundleImportService().importMetadata(
            data: metadata,
            sourceURL: sourceURL,
            scanResult: scanResult,
            sampleColumnIndex: bestColumn.index,
            knownSampleIds: knownSampleIds,
            bundleURL: bundleURL
        )

        let finalMetadataURL = bundleURL.appendingPathComponent("metadata/sample_metadata.tsv")
        XCTAssertEqual(result.store.records["AnimalA"]?["Cohort"], "treated")
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalMetadataURL.path))
        let provenanceURL = try XCTUnwrap(result.provenanceURL)
        XCTAssertEqual(provenanceURL, bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        let provenance = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertEqual(provenance.workflowName, "Sample metadata import")
        XCTAssertTrue(provenance.files.contains(where: { $0.path == sourceURL.path && $0.role == .input }))
        XCTAssertTrue(provenance.outputs.contains(where: { $0.path == finalMetadataURL.path && $0.role == .output }))
    }

    func testImportRollsBackMetadataWhenProvenanceLayoutFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeSampleMetadataImportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundleURL = root.appendingPathComponent("barcode05-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundleURL.appendingPathComponent("genotype-result.json"))

        let blockedProvenanceDirectory = bundleURL.appendingPathComponent(
            ProvenanceWriter.bundleProvenanceDirectoryName,
            isDirectory: true
        )
        try "blocked".write(to: blockedProvenanceDirectory, atomically: true, encoding: .utf8)

        let sourceURL = root.appendingPathComponent("metadata.tsv")
        let metadata = Data("""
        Sample\tCohort\tAnimal
        AnimalA\ttreated\tmacaque
        """.utf8)
        try metadata.write(to: sourceURL)
        let knownSampleIds: Set<String> = ["AnimalA"]
        let scanResult = try SampleMetadataStore.scanForSampleColumn(
            csvData: metadata,
            knownSampleIds: knownSampleIds
        )
        let bestColumn = try XCTUnwrap(scanResult.bestColumn)

        XCTAssertThrowsError(
            try SampleMetadataBundleImportService().importMetadata(
                data: metadata,
                sourceURL: sourceURL,
                scanResult: scanResult,
                sampleColumnIndex: bestColumn.index,
                knownSampleIds: knownSampleIds,
                bundleURL: bundleURL
            )
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("metadata").path),
            "Metadata payloads must be removed when provenance cannot be published."
        )
        XCTAssertEqual(try String(contentsOf: blockedProvenanceDirectory, encoding: .utf8), "blocked")
    }

    func testImportPersistsTwelveSMetadataAndProvenanceWithResultPayload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeSampleMetadataImportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundleURL = root.appendingPathComponent("run.lungfish12s", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let manifest = TwelveSAmpliconResultBundleManifest(
            outputName: "run",
            analysisName: "run",
            referencePath: "reference.fa",
            targetTablePath: "targets.tsv",
            countMatrixPath: "sample-target-counts.tsv",
            sampleTablePath: "samples.tsv",
            readFatePath: "read-fate.json",
            provenancePath: ProvenanceWriter.provenanceFilename
        )
        try TwelveSAmpliconResultBundle.writeManifest(manifest, to: bundleURL)
        try """
        sample\tsample_name\tinput_reads\texact_match_reads\tunresolved_reads\tambiguous_exact_reads\tchimera_candidate_reads\texact_match_percent\tunresolved_percent
        SampleA\tSample A\t10\t8\t2\t0\t0\t80.0\t20.0
        """.write(to: bundleURL.appendingPathComponent("samples.tsv"), atomically: true, encoding: .utf8)

        let sourceURL = root.appendingPathComponent("metadata.tsv")
        let metadata = Data("""
        sample\tsite
        SampleA\tHilo
        """.utf8)
        try metadata.write(to: sourceURL)
        let knownSampleIds = try ResultBundleSampleMetadataResolver.knownSampleIDs(in: bundleURL)
        let scanResult = try SampleMetadataStore.scanForSampleColumn(
            csvData: metadata,
            knownSampleIds: knownSampleIds
        )
        let bestColumn = try XCTUnwrap(scanResult.bestColumn)

        let result = try SampleMetadataBundleImportService().importMetadata(
            data: metadata,
            sourceURL: sourceURL,
            scanResult: scanResult,
            sampleColumnIndex: bestColumn.index,
            knownSampleIds: knownSampleIds,
            bundleURL: bundleURL
        )

        XCTAssertEqual(result.store.records["SampleA"]?["site"], "Hilo")
        let provenanceURL = try XCTUnwrap(result.provenanceURL)
        let provenance = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data(contentsOf: provenanceURL)
        )
        XCTAssertTrue(provenance.files.contains {
            $0.path == bundleURL.appendingPathComponent(TwelveSAmpliconResultBundleManifest.filename).path
                && $0.role == .input
        })
        XCTAssertTrue(provenance.files.contains {
            $0.path == bundleURL.appendingPathComponent("samples.tsv").path && $0.role == .input
        })
    }

    func testInspectorMetadataImportUsesGenotypeContextAndRefreshesViewportCallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeSampleMetadataImportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundleURL = root.appendingPathComponent("barcode05-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundleURL.appendingPathComponent("genotype-result.json"))
        let sourceURL = root.appendingPathComponent("metadata.tsv")
        try """
        Sample\tCohort
        AnimalA\ttreated
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let inspector = InspectorViewController()
        _ = inspector.view
        let call = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: nil,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        inspector.updateGenotypeResultDocument(makeResult(bundleURL: bundleURL, calls: [call]))

        var callbackStore: SampleMetadataStore?
        inspector.onGenotypeSampleMetadataImported = { store in
            callbackStore = store
        }

        try inspector.testingImportMetadata(from: sourceURL)

        let documentStore = inspector.viewModel.documentSectionViewModel
            .genotypeResultDocument?
            .sampleMetadataStore
        XCTAssertEqual(documentStore?.records["AnimalA"]?["Cohort"], "treated")
        XCTAssertEqual(callbackStore?.records["AnimalA"]?["Cohort"], "treated")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent("metadata/sample_metadata.tsv").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: bundleURL.appendingPathComponent(ProvenanceWriter.provenanceFilename).path
        ))
    }

    func testInspectorDocumentListsEditableWorkbookAndOriginalWorkbookWhenDistinct() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeWorkbookArtifactRows-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode05-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let originalWorkbookURL = bundleURL.appendingPathComponent("barcode05-mhc.xlsx")
        let currentWorkbookURL = bundleURL.appendingPathComponent("artifacts/workbooks/current.xlsx")
        let unmatchedFASTAURL = bundleURL.appendingPathComponent("deduplicated_unmatched_clusters.fasta")
        let result = ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "barcode05-mhc",
                analysisName: "barcode05-mhc",
                primaryWorkbookPath: originalWorkbookURL.lastPathComponent,
                currentWorkbookPath: "artifacts/workbooks/current.xlsx",
                longSummaryCSVPath: "barcode05-mhc.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "barcode05-mhc.retained-demux-samples.csv",
                statsJSONPath: "barcode05-mhc.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json",
                deduplicatedUnmatchedClustersFASTAPath: unmatchedFASTAURL.lastPathComponent
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: currentWorkbookURL,
                primaryWorkbookURL: originalWorkbookURL,
                longSummaryCSVURL: bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-samples.csv"),
                statsJSONURL: bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-stats.json"),
                provenanceURL: bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json"),
                deduplicatedUnmatchedClustersFASTAURL: unmatchedFASTAURL
            ),
            stats: ONTGenotypeRunStats(totalInputReads: 1000, retainedUniqueReads: 60),
            calls: [],
            samples: []
        )
        let inspector = InspectorViewController()
        _ = inspector.view

        inspector.updateGenotypeResultDocument(result)

        let rows = try XCTUnwrap(inspector.viewModel.documentSectionViewModel.genotypeResultDocument?.artifactRows)
        XCTAssertEqual(rows.first?.label, "Workbook")
        XCTAssertEqual(rows.first?.fileURL, currentWorkbookURL.standardizedFileURL)
        XCTAssertTrue(rows.contains {
            $0.label == "Original Workbook" && $0.fileURL == originalWorkbookURL.standardizedFileURL
        })
        XCTAssertTrue(rows.contains {
            $0.label == "Deduplicated Unmatched FASTA" && $0.fileURL == unmatchedFASTAURL.standardizedFileURL
        })
        XCTAssertFalse(rows.contains { $0.label == "Candidate Alleles GenBank" })
        XCTAssertFalse(rows.contains { $0.label == "Un-nameable Clusters GenBank" })
        XCTAssertFalse(rows.contains { $0.label == "Genotyping Evidence BAM" })
        XCTAssertFalse(rows.contains { $0.label == "Genotyping Evidence BAI" })
        XCTAssertFalse(rows.contains { $0.label == "Reciprocal Evidence BAM" })
        XCTAssertFalse(rows.contains { $0.label == "Reciprocal Evidence BAI" })
    }

    func testInspectorDocumentListsValidatedCandidateGenBankArtifactsWhenDeclared() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeCandidateGenBankArtifactRows-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode05-mhc.lungfishgenotype", isDirectory: true)
        let candidateURL = bundleURL.appendingPathComponent("artifacts/candidates/candidate_alleles.gb")
        let unnameableURL = bundleURL.appendingPathComponent("artifacts/candidates/unnameable_unmatched_clusters.gb")
        let candidateGenBankArtifactURLs = ONTMHCCandidateGenBankArtifactURLs(
            candidateAlleles: candidateURL,
            unnameableClusters: unnameableURL
        )
        let inspector = InspectorViewController()
        _ = inspector.view

        inspector.updateGenotypeResultDocument(makeResult(
            bundleURL: bundleURL,
            calls: [],
            mhcCandidateGenBankArtifactURLs: candidateGenBankArtifactURLs
        ))

        let rows = try XCTUnwrap(inspector.viewModel.documentSectionViewModel.genotypeResultDocument?.artifactRows)
        XCTAssertTrue(rows.contains {
            $0.label == "Candidate Alleles GenBank" && $0.fileURL == candidateURL.standardizedFileURL
        })
        XCTAssertTrue(rows.contains {
            $0.label == "Un-nameable Clusters GenBank" && $0.fileURL == unnameableURL.standardizedFileURL
        })
    }

    func testInspectorDocumentListsValidatedMHCAlignmentArtifactsWhenDeclared() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeMHCAlignmentArtifactRows-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode05-mhc.lungfishgenotype", isDirectory: true)
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
        let inspector = InspectorViewController()
        _ = inspector.view

        inspector.updateGenotypeResultDocument(makeResult(
            bundleURL: bundleURL,
            calls: [],
            mhcAlignmentArtifactURLs: alignmentArtifactURLs
        ))

        let rows = try XCTUnwrap(inspector.viewModel.documentSectionViewModel.genotypeResultDocument?.artifactRows)
        let alignmentLabels = Set([
            "Genotyping Evidence BAM",
            "Genotyping Evidence BAI",
            "Reciprocal Evidence BAM",
            "Reciprocal Evidence BAI",
        ])
        XCTAssertEqual(
            rows.filter { alignmentLabels.contains($0.label) },
            [
                GenotypeResultArtifactRow(
                    label: "Genotyping Evidence BAM",
                    fileURL: genotypingBAMURL.standardizedFileURL
                ),
                GenotypeResultArtifactRow(
                    label: "Genotyping Evidence BAI",
                    fileURL: genotypingBAIURL.standardizedFileURL
                ),
                GenotypeResultArtifactRow(
                    label: "Reciprocal Evidence BAM",
                    fileURL: reciprocalBAMURL.standardizedFileURL
                ),
                GenotypeResultArtifactRow(
                    label: "Reciprocal Evidence BAI",
                    fileURL: reciprocalBAIURL.standardizedFileURL
                ),
            ]
        )
    }

    func testInspectorDocumentExposesCurrentWorkbookUpdateWhenManualHaplotypesChanged() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeWorkbookUpdateState-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode05-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let originalWorkbookURL = bundleURL.appendingPathComponent("barcode05-mhc.xlsx")
        let currentWorkbookURL = bundleURL.appendingPathComponent("artifacts/workbooks/current.xlsx")
        try FileManager.default.createDirectory(at: currentWorkbookURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: originalWorkbookURL)
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: currentWorkbookURL)

        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-06T00:00:00Z")
        sidecar.callOverrides = [
            GenotypeAnnotationSidecar.CallOverride(
                sample: "DW472",
                locus: "MHC-DP",
                slot: .h1,
                originalCall: "M4DP",
                overrideCall: "M3DP",
                reasonTag: .analystJudgment,
                rationale: "Manual review.",
                author: "curator",
                timestamp: "2026-06-06T12:00:00Z"
            )
        ]
        try sidecar.encoded().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))

        let result = ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "barcode05-mhc",
                analysisName: "barcode05-mhc",
                primaryWorkbookPath: originalWorkbookURL.lastPathComponent,
                currentWorkbookPath: "artifacts/workbooks/current.xlsx",
                longSummaryCSVPath: "barcode05-mhc.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "barcode05-mhc.retained-demux-samples.csv",
                statsJSONPath: "barcode05-mhc.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: currentWorkbookURL,
                primaryWorkbookURL: originalWorkbookURL,
                longSummaryCSVURL: bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-samples.csv"),
                statsJSONURL: bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-stats.json"),
                provenanceURL: bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(totalInputReads: 1000, retainedUniqueReads: 60),
            calls: [],
            samples: []
        )
        let inspector = InspectorViewController()
        _ = inspector.view

        inspector.updateGenotypeResultDocument(result)

        let workbookUpdate = try XCTUnwrap(
            inspector.viewModel.documentSectionViewModel.genotypeResultDocument?.currentWorkbookUpdate
        )
        XCTAssertEqual(workbookUpdate.manualChangeCount, 1)
        XCTAssertTrue(workbookUpdate.isEnabled)
        XCTAssertTrue(workbookUpdate.statusText.contains("1 manual haplotype change"))
    }

    func testAnnotationSidecarUpdateUsesLoadedResultWithoutReloadingBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeAnnotationSidecarCachedResult-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode05-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let currentWorkbookURL = bundleURL.appendingPathComponent("artifacts/workbooks/current.xlsx")
        try FileManager.default.createDirectory(at: currentWorkbookURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x50, 0x4b, 0x03, 0x04]).write(to: currentWorkbookURL)

        let calls = [
            ONTGenotypeCall(
                sample: "AnimalA",
                genotype: "12_M3_B_075_01",
                passedAlignments: 1_200,
                passedUniqueReads: 1_200,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            )
        ]
        let result = makeResult(bundleURL: bundleURL, calls: calls)
        let inspector = InspectorViewController()
        _ = inspector.view
        inspector.updateGenotypeResultDocument(result)

        try FileManager.default.removeItem(at: bundleURL)

        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-06-22T00:00:00Z")
        sidecar.callOverrides = [
            GenotypeAnnotationSidecar.CallOverride(
                sample: "AnimalA",
                locus: "MHC-B",
                slot: .h1,
                originalCall: "M3B",
                overrideCall: "M1B",
                reasonTag: .analystJudgment,
                rationale: "Manual review.",
                author: "curator",
                timestamp: "2026-06-22T12:00:00Z"
            )
        ]
        sidecar.smartCohorts = [
            GenotypeCohortSmartFilter(
                name: "Low-support samples",
                description: "Loaded result subjects with low-support QC.",
                scope: "bundle",
                isStarred: true,
                predicate: .qcStatus([.lowSupport])
            )
        ]

        inspector.updateGenotypeAnnotationSidecar(sidecar)

        let document = try XCTUnwrap(inspector.viewModel.documentSectionViewModel.genotypeResultDocument)
        XCTAssertEqual(document.smartCohorts.first?.count, 1)
        XCTAssertEqual(document.qcRows.first(where: { $0.0 == "Low Support" })?.1, "1")
        let workbookUpdate = try XCTUnwrap(document.currentWorkbookUpdate)
        XCTAssertEqual(workbookUpdate.manualChangeCount, 1)
    }

    private func makeResult(
        bundleURL: URL,
        calls: [ONTGenotypeCall],
        mhcCandidateGenBankArtifactURLs: ONTMHCCandidateGenBankArtifactURLs = .empty,
        mhcAlignmentArtifactURLs: ONTMHCAlignmentArtifactURLs = .empty
    ) -> ONTGenotypeResultBundleData {
        ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "barcode05-mhc",
                analysisName: "barcode05-mhc",
                primaryWorkbookPath: "barcode05-mhc.xlsx",
                longSummaryCSVPath: "barcode05-mhc.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "barcode05-mhc.retained-demux-samples.csv",
                statsJSONPath: "barcode05-mhc.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: bundleURL.appendingPathComponent("barcode05-mhc.xlsx"),
                longSummaryCSVURL: bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-samples.csv"),
                statsJSONURL: bundleURL.appendingPathComponent("barcode05-mhc.retained-demux-stats.json"),
                provenanceURL: bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(totalInputReads: 1000, retainedUniqueReads: 60),
            calls: calls,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "AnimalA",
                    passedAlignments: 42,
                    passedUniqueReads: 42,
                    sampleTotalReads: nil,
                    sampleUniqueRetainedPercent: nil,
                    calls: calls
                )
            ],
            haplotypeAnalysis: nil,
            mhcCandidates: nil,
            mhcUnnameableClusters: nil,
            mhcCandidateSequencesByStableClusterID: [:],
            mhcCandidateGenBankArtifactURLs: mhcCandidateGenBankArtifactURLs,
            mhcAlignmentArtifactURLs: mhcAlignmentArtifactURLs,
            integrityWarnings: [],
            referenceMetadata: nil
        )
    }
}

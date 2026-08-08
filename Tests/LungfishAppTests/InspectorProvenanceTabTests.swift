import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI
import LungfishCore
import LungfishIO
import LungfishWorkflow

@MainActor
final class InspectorProvenanceTabTests: XCTestCase {
    func testEveryScientificContentModeIncludesProvenanceTab() {
        let modes: [ViewportContentMode] = [.genomics, .mapping, .assembly, .fastq, .metagenomics, .genotype]

        for mode in modes {
            let viewModel = InspectorViewModel()
            viewModel.contentMode = mode

            XCTAssertTrue(viewModel.availableTabs.contains(.provenance), "Missing provenance tab for \(mode)")
        }
    }

    func testEmptyModeDoesNotAddProvenanceByDefault() {
        let viewModel = InspectorViewModel()
        viewModel.contentMode = .empty

        XCTAssertFalse(viewModel.availableTabs.contains(.provenance))
    }

    func testSidebarSelectionLoadsProvenanceItem() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let vc = InspectorViewController()
        _ = vc.view
        vc.viewModel.contentMode = .fastq

        let item = SidebarItem(title: "Reads", type: .fastqBundle, url: dir)
        vc.testingHandleSidebarSelectionChanged(
            Notification(
                name: .sidebarSelectionChanged,
                object: nil,
                userInfo: ["item": item]
            )
        )

        // currentItem updates synchronously; audit resolves on a detached background task (F6).
        XCTAssertEqual(vc.viewModel.provenanceSectionViewModel.currentItem?.url, dir)
        XCTAssertEqual(vc.viewModel.provenanceSectionViewModel.currentItem?.sidebarType, .fastqBundle)
        try await waitUntilLoadCompletes(vc.viewModel.provenanceSectionViewModel)
        XCTAssertEqual(vc.viewModel.provenanceSectionViewModel.audit.status, .missing)
    }

    func testClearSelectionClearsProvenanceState() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-provenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let vc = InspectorViewController()
        _ = vc.view
        vc.viewModel.contentMode = .fastq

        vc.viewModel.provenanceSectionViewModel.load(
            item: ProvenanceInspectableItem(
                url: dir,
                sidebarType: .fastqBundle,
                contentMode: .fastq,
                displayName: "Reads"
            )
        )
        try await waitUntilLoadCompletes(vc.viewModel.provenanceSectionViewModel)
        vc.clearSelection()

        XCTAssertNil(vc.viewModel.provenanceSectionViewModel.currentItem)
        XCTAssertEqual(vc.viewModel.provenanceSectionViewModel.audit.status, .notRequired)
    }

    func testProvenanceTabIdentifierRestores() {
        let vc = InspectorViewController()
        _ = vc.view

        vc.restoreSelectedTabIdentifier("provenance")

        XCTAssertEqual(vc.restorableSelectedTabIdentifier(), "provenance")
    }

    func testGenotypeAnnotationUpdateRetargetsProvenanceToAnnotationSidecar() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-genotype-provenance-\(UUID().uuidString).lungfishgenotype", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let annotationURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: bundleURL)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-24T00:00:00Z")
        sidecar.append(audit: .init(
            action: "confirmed",
            sample: "DW472",
            locus: "MHC-B",
            slot: nil,
            before: "M2B/M3B",
            after: "M2B/M3B",
            color: nil,
            reason: "confirmed",
            rationale: nil,
            author: "test",
            timestamp: "2026-05-24T00:00:00Z"
        ))
        try sidecar.encoded().write(to: annotationURL)
        let vc = InspectorViewController()
        _ = vc.view
        vc.viewModel.contentMode = .genotype
        vc.viewModel.documentSectionViewModel.updateGenotypeResultDocument(
            GenotypeResultDocumentState(
                title: "barcode08-mhc-haplotypingv1",
                subtitle: nil,
                bundleURL: bundleURL,
                sampleIds: ["DW472"],
                sampleMetadataStore: nil,
                windowStateScope: nil,
                summaryRows: [],
                qcRows: [],
                artifactRows: [],
                auditEntries: []
            )
        )

        vc.updateGenotypeAnnotationSidecar(sidecar)

        XCTAssertEqual(vc.viewModel.provenanceSectionViewModel.currentItem?.url, annotationURL)
        XCTAssertEqual(vc.viewModel.provenanceSectionViewModel.currentItem?.displayName, "Annotations & Audit")
    }

    func testGenotypeDocumentShowsSidecarActiveHaplotypeDefinition() throws {
        let projectRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-active-definition-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let bundleURL = projectRoot
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("ONT genotyping results", isDirectory: true)
            .appendingPathComponent("test.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let custom = GenotypeHaplotypeDefinitionSet(
            id: "custom.inspector.definition",
            assayID: "custom-assay",
            displayName: "Inspector Custom Definition",
            speciesName: "Test macaque",
            speciesCode: "TEST",
            prefix: "",
            locusDefinitions: [
                GenotypeHaplotypeLocusDefinition(
                    locus: "MHC-B",
                    sourceLocus: "Mafa-B",
                    haplotypes: [
                        GenotypeHaplotypeDefinition(name: "NewB", diagnosticAlleles: ["12_M9_B_001_01"])
                    ]
                )
            ]
        )
        try HaplotypeDefinitionStore(projectRoot: projectRoot).save(custom)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-05-24T00:00:00Z")
        sidecar.settings.activeHaplotypeDefinitionSetID = custom.id
        try sidecar.encoded().write(to: bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename))
        let result = makeGenotypeResult(
            bundleURL: bundleURL,
            haplotypeAnalysis: GenotypeHaplotypeAnalysis(
                assayID: "MHC-exon2-miSeq",
                definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
                definitionSetName: "Mauritian cynomolgus macaques",
                speciesName: "Mauritian cynomolgus macaques",
                samples: []
            )
        )
        let vc = InspectorViewController()
        _ = vc.view
        vc.viewModel.contentMode = .genotype

        vc.updateGenotypeResultDocument(result)

        let rows = vc.viewModel.documentSectionViewModel.genotypeResultDocument?.haplotypeDefinitionRows ?? []
        XCTAssertTrue(rows.contains { $0.0 == "Active" && $0.1 == "Inspector Custom Definition" })
        XCTAssertTrue(rows.contains { $0.0 == "Definition ID" && $0.1 == custom.id })
        XCTAssertTrue(
            vc.viewModel.documentSectionViewModel.genotypeResultDocument?
                .hasHaplotypingResult ?? false
        )
    }

    func testGenotypeOnlyDocumentHidesCohortsWithoutRewritingPreseededSidecar() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "inspector-genotype-only-cohorts-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        var sidecar = GenotypeAnnotationSidecar.empty(generatedAt: "2026-07-25T00:00:00Z")
        sidecar.smartCohorts = [
            GenotypeCohortSmartFilter(
                name: "Persisted cohort",
                scope: "bundle",
                isStarred: true,
                predicate: .animalIdIn(["AnimalA"])
            ),
        ]
        let annotationURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        try sidecar.encoded().write(to: annotationURL)
        _ = try GenotypeAnnotationStore(bundleURL: bundleURL, author: "test")
        let bytesBeforeOpen = try Data(contentsOf: annotationURL)
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
        let vc = InspectorViewController()
        _ = vc.view
        vc.viewModel.contentMode = .genotype
        var cohortSubjectBuildCount = 0
        vc.genotypeCohortSubjectBuilder = { result, sidecar, metadataBySample in
            cohortSubjectBuildCount += 1
            return GenotypeCohortSubjectBuilder.buildSubjects(
                result: result,
                sidecar: sidecar,
                metadataBySample: metadataBySample
            )
        }
        let sample = ONTGenotypeSampleResult(
            sample: "AnimalA",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedPercent: nil,
            calls: [call]
        )

        vc.updateGenotypeResultDocument(
            makeGenotypeResult(
                bundleURL: bundleURL,
                haplotypeAnalysis: nil,
                calls: [call],
                samples: [sample]
            )
        )

        let document = try XCTUnwrap(
            vc.viewModel.documentSectionViewModel.genotypeResultDocument
        )
        XCTAssertFalse(document.hasHaplotypingResult)
        XCTAssertTrue(document.smartCohorts.isEmpty)
        XCTAssertEqual(
            document.qcRows.map { "\($0.0)=\($0.1)" },
            ["OK=0", "Low Support=1", "Review=0"]
        )
        XCTAssertEqual(cohortSubjectBuildCount, 0)
        XCTAssertFalse(vc.viewModel.genotypeResultDisplaySectionViewModel.hasHaplotypingResult)
        XCTAssertEqual(try Data(contentsOf: annotationURL), bytesBeforeOpen)
    }

    func testGenotypeOnlyInspectorConfigurePreservesEveryPreexistingBundleByte() throws {
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
                "inspector-genotype-only-nonseeding-\(UUID().uuidString).lungfishgenotype",
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
        let inspector = InspectorViewController()
        _ = inspector.view
        inspector.viewModel.contentMode = .genotype

        inspector.updateGenotypeResultDocument(
            makeGenotypeResult(
                bundleURL: bundleURL,
                haplotypeAnalysis: nil,
                calls: [call]
            )
        )

        XCTAssertEqual(try recursiveBytes(at: bundleURL), before)
    }

    func testAmbiguousLegacyONTBarcodeResultIsNotTreatedAsGenotypeOnly() {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector-ambiguous-legacy-\(UUID().uuidString).lungfishgenotype")
        let call = ONTGenotypeCall(
            sample: "AnimalA",
            genotype: "01_Mafa_A1_001_01",
            passedAlignments: 42,
            passedUniqueReads: 42,
            sampleTotalReads: nil,
            sampleUniqueRetainedReads: 42,
            sampleUniqueRetainedPercent: nil,
            overallInputReads: nil,
            overallUniqueRetainedReads: nil,
            overallUniqueRetainedPercent: nil
        )
        let inspector = InspectorViewController()
        _ = inspector.view
        inspector.viewModel.contentMode = .genotype

        inspector.updateGenotypeResultDocument(makeGenotypeResult(
            bundleURL: bundleURL,
            haplotypeAnalysis: nil,
            calls: [call],
            workflowKind: nil,
            workflowMode: nil
        ))

        XCTAssertFalse(inspector.viewModel.genotypeResultDisplaySectionViewModel.isGenotypeOnlyResult)
    }

    func testMiSeqScientificArtifactsRespectGenotypeOnlyBoundary() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "inspector-miseq-artifacts-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let alignmentURLs = ONTMHCAlignmentArtifactURLs(
            genotypingBAM: bundleURL.appendingPathComponent("evidence.bam"),
            genotypingBAI: bundleURL.appendingPathComponent("evidence.bam.bai"),
            reciprocalBAM: nil,
            reciprocalBAI: nil
        )
        let provisionalURLs = ONTGenotypeProvisionalExon2ArtifactURLs(
            catalogJSON: bundleURL.appendingPathComponent(
                "artifacts/sequences/observed-provisional-exon2.json"
            ),
            sequencesFASTA: bundleURL.appendingPathComponent(
                "artifacts/sequences/observed-provisional-exon2.fasta"
            )
        )
        let inspector = InspectorViewController()
        _ = inspector.view
        inspector.viewModel.contentMode = .genotype

        inspector.updateGenotypeResultDocument(makeGenotypeResult(
            bundleURL: bundleURL,
            haplotypeAnalysis: nil,
            alignmentArtifactURLs: alignmentURLs,
            provisionalExon2ArtifactURLs: provisionalURLs
        ))
        let genotypeOnlyLabels = try XCTUnwrap(
            inspector.viewModel.documentSectionViewModel.genotypeResultDocument
        ).artifactRows.map(\.label)
        XCTAssertTrue(genotypeOnlyLabels.contains("Genotyping Evidence BAM"))
        XCTAssertTrue(genotypeOnlyLabels.contains("Genotyping Evidence BAI"))
        XCTAssertTrue(genotypeOnlyLabels.contains("Observed Provisional Exon 2 JSON"))
        XCTAssertTrue(genotypeOnlyLabels.contains("Observed Provisional Exon 2 FASTA"))
        XCTAssertFalse(genotypeOnlyLabels.contains { $0.contains("Reciprocal Evidence") })
        XCTAssertFalse(genotypeOnlyLabels.contains { $0.contains("Candidate Alleles") })

        inspector.updateGenotypeResultDocument(makeGenotypeResult(
            bundleURL: bundleURL,
            haplotypeAnalysis: GenotypeHaplotypeAnalysis(
                assayID: "MHC-exon2-miSeq",
                definitionSetID: "test",
                definitionSetName: "Test",
                speciesName: "Test",
                samples: []
            ),
            alignmentArtifactURLs: alignmentURLs,
            provisionalExon2ArtifactURLs: provisionalURLs
        ))
        let haplotypedLabels = try XCTUnwrap(
            inspector.viewModel.documentSectionViewModel.genotypeResultDocument
        ).artifactRows.map(\.label)
        XCTAssertTrue(haplotypedLabels.contains("Genotyping Evidence BAM"))
        XCTAssertTrue(haplotypedLabels.contains("Genotyping Evidence BAI"))
        XCTAssertFalse(haplotypedLabels.contains("Observed Provisional Exon 2 JSON"))
        XCTAssertFalse(haplotypedLabels.contains("Observed Provisional Exon 2 FASTA"))
    }

    private func makeGenotypeResult(
        bundleURL: URL,
        haplotypeAnalysis: GenotypeHaplotypeAnalysis?,
        calls: [ONTGenotypeCall] = [],
        samples: [ONTGenotypeSampleResult] = [],
        alignmentArtifactURLs: ONTMHCAlignmentArtifactURLs = .empty,
        provisionalExon2ArtifactURLs:
            ONTGenotypeProvisionalExon2ArtifactURLs = .empty,
        workflowKind: GenotypeResultWorkflowKind? = .miSeqAmpliconMHCGenotype,
        workflowMode: GenotypeResultWorkflowMode? = .genotypeOnly
    ) -> ONTGenotypeResultBundleData {
        ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: ONTGenotypeResultBundleManifest(
                kind: workflowKind?.rawValue ?? "ont-barcode-genotype",
                workflowKind: workflowKind,
                workflowMode: workflowMode,
                outputName: "test",
                analysisName: "Test",
                primaryWorkbookPath: "test.xlsx",
                longSummaryCSVPath: "test.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "test.retained-demux-samples.csv",
                statsJSONPath: "test.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: bundleURL.appendingPathComponent("test.xlsx"),
                longSummaryCSVURL: bundleURL.appendingPathComponent("test.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: bundleURL.appendingPathComponent("test.retained-demux-samples.csv"),
                statsJSONURL: bundleURL.appendingPathComponent("test.retained-demux-stats.json"),
                provenanceURL: bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(totalInputReads: 100, retainedUniqueReads: 50),
            calls: calls,
            samples: samples,
            haplotypeAnalysis: haplotypeAnalysis,
            mhcCandidates: nil,
            mhcUnnameableClusters: nil,
            mhcCandidateSequencesByStableClusterID: [:],
            mhcCandidateGenBankArtifactURLs: .empty,
            mhcAlignmentArtifactURLs: alignmentArtifactURLs,
            mhcReferenceVisualizations: nil,
            integrityWarnings: [],
            referenceMetadata: nil,
            provisionalExon2SequencesByGenotype: [:],
            provisionalExon2ArtifactURLs: provisionalExon2ArtifactURLs
        )
    }

    /// `load(item:)` is synchronous but resolves the sidecar lookup on a detached background
    /// task (see F6); this polls `isLoading` until that task has applied its result back on
    /// the main actor. Idiom: `waitUntil` in `SequenceViewerInteractionAsyncBundleReadTests`.
    private func waitUntilLoadCompletes(
        _ viewModel: ProvenanceInspectorViewModel,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while viewModel.isLoading {
            if Date() >= deadline {
                XCTFail("Timed out waiting for provenance load to complete")
                return
            }
            await Task.yield()
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

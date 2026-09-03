import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow

@MainActor
final class ViralReconDocumentSectionTests: XCTestCase {
    private func makeBundle(
        consensus: [String] = [],
        lineage: [String] = [],
        reports: [String] = []
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viralrecon-inspector-\(UUID().uuidString)", isDirectory: true)
        for (role, names) in [("consensus", consensus), ("lineage", lineage), ("reports", reports)] {
            let directory = root.appendingPathComponent(role, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in names {
                try Data("x".utf8).write(to: directory.appendingPathComponent(name))
            }
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    // MARK: - State construction

    func testStateGroupsBundleOutputsIntoLabelledSections() throws {
        let bundle = try makeBundle(
            consensus: ["S1.consensus.fa"],
            lineage: ["S1.pangolin.csv", "S1.nextclade.csv", "S1.demix.tsv"],
            reports: ["multiqc_report.html", "S1.fastp.html"])

        let state = try XCTUnwrap(ViralReconDocumentStateBuilder.state(
            forBundleAt: bundle,
            sampleName: "S1"))

        XCTAssertEqual(state.title, "S1")
        let labels = state.sections.flatMap { $0.rows.map(\.label) }
        XCTAssertTrue(labels.contains("Consensus Sequence"))
        XCTAssertTrue(labels.contains("Pangolin Lineage"))
        XCTAssertTrue(labels.contains("Nextclade Clade"))
        XCTAssertTrue(labels.contains("Freyja Variant Mix"))
        XCTAssertTrue(labels.contains("Full Run Report"))
        XCTAssertTrue(labels.contains("Read Trimming Report"))
    }

    // Coverage and QC-summary outputs were added to the inventory after the
    // catalogue was written; they must reach the Inspector too, otherwise
    // amplicon dropout stays invisible.
    func testCoverageAndQualitySummaryOutputsAreListed() throws {
        let bundle = try makeBundle(reports: [
            "S1.mosdepth.coverage.tsv",
            "summary_variants_metrics_mqc.csv",
        ])

        let state = try XCTUnwrap(ViralReconDocumentStateBuilder.state(
            forBundleAt: bundle,
            sampleName: "S1"))

        let labels = state.sections.flatMap { $0.rows.map(\.label) }
        XCTAssertTrue(labels.contains("Coverage Depth Table"))
        XCTAssertTrue(labels.contains("Run Quality Summary"))
    }

    // Bench scientists read these labels, so no row may fall back to a raw
    // pipeline filename when the file is one this app knows how to describe.
    func testLabelsAvoidUnexplainedPipelineJargon() throws {
        let bundle = try makeBundle(
            consensus: ["S1.consensus.fa"],
            lineage: ["S1.pangolin.csv"],
            reports: ["multiqc_report.html", "S1.fastp.html"])

        let state = try XCTUnwrap(ViralReconDocumentStateBuilder.state(
            forBundleAt: bundle,
            sampleName: "S1"))

        for row in state.sections.flatMap(\.rows) {
            XCTAssertFalse(
                row.label.contains(".") || row.label.contains("_"),
                "Row label '\(row.label)' looks like a filename rather than plain language")
            XCTAssertFalse(row.detail.isEmpty, "Row '\(row.label)' has no plain-language explanation")
        }
    }

    // A section heading with no rows would claim an output was produced when
    // the pipeline skipped or failed that step.
    func testSectionsWithNoFilesAreOmitted() throws {
        let bundle = try makeBundle(consensus: ["S1.consensus.fa"])

        let state = try XCTUnwrap(ViralReconDocumentStateBuilder.state(
            forBundleAt: bundle,
            sampleName: "S1"))

        XCTAssertEqual(state.sections.map(\.title), ["Consensus"])
    }

    func testBundleWithNoOutputsProducesNoState() throws {
        let bundle = try makeBundle()
        XCTAssertNil(ViralReconDocumentStateBuilder.state(forBundleAt: bundle, sampleName: "S1"))
    }

    // MARK: - View model plumbing

    func testViewModelStoresAndClearsViralReconDocument() throws {
        let bundle = try makeBundle(consensus: ["S1.consensus.fa"])
        let state = try XCTUnwrap(ViralReconDocumentStateBuilder.state(
            forBundleAt: bundle,
            sampleName: "S1"))

        let viewModel = DocumentSectionViewModel()
        viewModel.updateViralReconDocument(state)
        XCTAssertNotNil(viewModel.viralReconDocument)
        XCTAssertTrue(viewModel.hasAnyContent)

        viewModel.updateViralReconDocument(nil)
        XCTAssertNil(viewModel.viralReconDocument)
    }

    // The Viral Recon viewport is the reference bundle it aligned against, so
    // unlike the mapping document this catalogue has to survive the bundle
    // manifest landing in the same view model. Clearing it would drop the
    // bundle's own tracks; being cleared by it would drop the catalogue.
    func testViralReconDocumentCoexistsWithReferenceBundleManifest() throws {
        let bundle = try makeBundle(consensus: ["S1.consensus.fa"])
        let state = try XCTUnwrap(ViralReconDocumentStateBuilder.state(
            forBundleAt: bundle,
            sampleName: "S1"))

        let viewModel = DocumentSectionViewModel()
        viewModel.updateViralReconDocument(state)
        viewModel.update(manifest: nil, bundleURL: bundle)

        XCTAssertNotNil(viewModel.viralReconDocument)
        XCTAssertEqual(viewModel.bundleURL, bundle)
    }

    // Every sibling document mode is mutually exclusive with this one: a
    // mapping result selected after a Viral Recon run must not keep showing
    // the previous run's outputs.
    func testSiblingDocumentModesClearTheViralReconCatalogue() throws {
        let bundle = try makeBundle(consensus: ["S1.consensus.fa"])
        let state = try XCTUnwrap(ViralReconDocumentStateBuilder.state(
            forBundleAt: bundle,
            sampleName: "S1"))

        let viewModel = DocumentSectionViewModel()
        viewModel.updateViralReconDocument(state)
        viewModel.updateMappingDocument(
            MappingDocumentState(
                title: "map",
                subtitle: nil,
                summary: nil,
                sourceData: [],
                contextRows: [],
                artifactRows: []))

        XCTAssertNil(viewModel.viralReconDocument)
    }
}

/// Guards the ordering contract at the Viral Recon call site.
///
/// `displayViralReconAnalysisFromSidebar` opens the run's reference bundle, and
/// that path calls `clearSelection()` partway through. Anything the display
/// method set beforehand is therefore discarded, which is why both the
/// provenance target and the output catalogue have to be applied after the
/// bundle is displayed rather than before it.
@MainActor
final class ViralReconInspectorOrderingTests: XCTestCase {
    func testClearSelectionDiscardsAPreviouslySetProvenanceTarget() {
        let inspector = InspectorViewController()
        let analysis = URL(fileURLWithPath: "/tmp/Analyses/viralrecon-2026-09-02", isDirectory: true)

        inspector.updateProvenanceTarget(
            url: analysis,
            sidebarType: .analysisResult,
            displayName: analysis.lastPathComponent)
        XCTAssertNotNil(inspector.viewModel.provenanceSectionViewModel.currentItem?.url)

        inspector.clearSelection()
        XCTAssertNil(
            inspector.viewModel.provenanceSectionViewModel.currentItem?.url,
            "clearSelection wipes the provenance target, so it must be set after the bundle displays")
    }

    func testClearSelectionDiscardsAPreviouslySetViralReconCatalogue() throws {
        let inspector = InspectorViewController()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("viralrecon-order-\(UUID().uuidString)", isDirectory: true)
        let consensus = root.appendingPathComponent("consensus", isDirectory: true)
        try FileManager.default.createDirectory(at: consensus, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: consensus.appendingPathComponent("S1.consensus.fa"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let state = try XCTUnwrap(ViralReconDocumentStateBuilder.state(forBundleAt: root, sampleName: "S1"))
        inspector.updateViralReconDocument(state)
        XCTAssertNotNil(inspector.viewModel.documentSectionViewModel.viralReconDocument)

        inspector.clearSelection()
        XCTAssertNil(inspector.viewModel.documentSectionViewModel.viralReconDocument)
    }
}

/// Drives the real sidebar display path against a real ingested analysis.
///
/// The unit tests above prove the pieces work; this proves they are connected in
/// an order that survives. Displaying the reference bundle calls
/// `clearSelection()` on the way through, so a call site that populates the
/// Inspector before that point produces exactly nothing, which is the defect
/// this pins.
@MainActor
final class ViralReconInspectorCallSiteTests: XCTestCase {
    private var root: URL!

    private var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/sarscov2")
    }

    /// Builds an ingested Viral Recon analysis directory from the shared fixture.
    private func makeIngestedAnalysis() throws -> URL {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .appendingPathComponent("vr-callsite-\(UUID().uuidString)", isDirectory: true)
        let results = root.appendingPathComponent("results", isDirectory: true)
        let referenceBundle = root.appendingPathComponent("MT192765.1.lungfishref", isDirectory: true)
        let created = root!
        addTeardownBlock { try? FileManager.default.removeItem(at: created) }

        let genomeDirectory = referenceBundle.appendingPathComponent("genome", isDirectory: true)
        try fileManager.createDirectory(at: genomeDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: fixtures.appendingPathComponent("genome.fasta"),
            to: genomeDirectory.appendingPathComponent("sequence.fa"))
        try fileManager.copyItem(
            at: fixtures.appendingPathComponent("genome.fasta.fai"),
            to: genomeDirectory.appendingPathComponent("sequence.fa.fai"))

        let manifest = BundleManifest(
            name: "MT192765.1",
            identifier: "org.ncbi.genbank.mt192765",
            description: nil,
            source: SourceInfo(
                organism: "Severe acute respiratory syndrome coronavirus 2",
                assembly: "MT192765.1",
                assemblyAccession: "MT192765.1",
                database: "NCBI"),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: 29_829,
                chromosomes: [
                    ChromosomeInfo(
                        name: "MT192765.1",
                        length: 29_829,
                        offset: 120,
                        lineBases: 80,
                        lineWidth: 81,
                        aliases: [])
                ]))
        try manifest.save(to: referenceBundle)

        // Outputs the ingest step copies into the bundle by role.
        let consensus = results.appendingPathComponent(
            "variants/ivar/consensus/bcftools", isDirectory: true)
        try fileManager.createDirectory(at: consensus, withIntermediateDirectories: true)
        try Data(">S1\nACGT\n".utf8)
            .write(to: consensus.appendingPathComponent("S1.consensus.fa"))
        let pangolin = consensus.appendingPathComponent("pangolin", isDirectory: true)
        try fileManager.createDirectory(at: pangolin, withIntermediateDirectories: true)
        try Data("taxon,lineage\nS1,B.1\n".utf8)
            .write(to: pangolin.appendingPathComponent("S1.pangolin.csv"))
        let multiqc = results.appendingPathComponent("multiqc", isDirectory: true)
        try fileManager.createDirectory(at: multiqc, withIntermediateDirectories: true)
        try Data("<html></html>".utf8)
            .write(to: multiqc.appendingPathComponent("multiqc_report.html"))

        let ingested = try ViralReconResultIngest.ingest(
            resultsDirectory: results,
            sampleName: "S1",
            referenceBundleURL: referenceBundle,
            into: root.appendingPathComponent("Analyses/viralrecon", isDirectory: true))
        return ingested.bundleDirectory
    }

    func testSelectingAnAnalysisPopulatesTheInspectorWithItsOutputs() throws {
        let analysis = try makeIngestedAnalysis()
        let split = MainSplitViewController()
        _ = split.view

        split.displayViralReconAnalysisFromSidebar(at: analysis)

        // The bundle is displayed on the next runloop, and the Inspector is
        // populated from that completion.
        let settled = expectation(description: "inspector populated")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        let document = try XCTUnwrap(
            split.inspectorController.viewModel.documentSectionViewModel.viralReconDocument,
            "the run's outputs never reached the Inspector")
        XCTAssertEqual(document.title, "S1")
        let labels = document.sections.flatMap { $0.rows.map(\.label) }
        XCTAssertTrue(labels.contains("Consensus Sequence"))
        XCTAssertTrue(labels.contains("Pangolin Lineage"))
        XCTAssertTrue(labels.contains("Full Run Report"))
    }

    func testSelectingAnAnalysisLeavesTheProvenanceTargetOnTheAnalysis() throws {
        let analysis = try makeIngestedAnalysis()
        let split = MainSplitViewController()
        _ = split.view

        split.displayViralReconAnalysisFromSidebar(at: analysis)

        let settled = expectation(description: "inspector populated")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 5)

        XCTAssertEqual(
            split.inspectorController.viewModel.provenanceSectionViewModel.currentItem?.url,
            analysis,
            "the provenance target was wiped by the bundle display")
    }
}

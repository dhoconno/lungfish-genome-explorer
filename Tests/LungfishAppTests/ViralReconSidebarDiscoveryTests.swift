import XCTest
@testable import LungfishApp
@testable import LungfishIO
@testable import LungfishWorkflow

/// Proves a Viral Recon run is discoverable end to end: the ingest step writes
/// into `Analyses/` in the shape the scanner already understands, and the
/// scanner renders a node for it.
///
/// This is the test that was missing. The results integration was fully built
/// and entirely invisible, because nothing ever asserted that the thing ingest
/// wrote was the thing the sidebar reads.
final class ViralReconSidebarDiscoveryTests: XCTestCase {
    private var root: URL!
    private var projectURL: URL!
    private var resultsURL: URL!
    private var referenceBundleURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vr-sidebar-\(UUID().uuidString)", isDirectory: true)
        projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        resultsURL = root.appendingPathComponent("results", isDirectory: true)
        referenceBundleURL = root.appendingPathComponent("MN908947.3.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: referenceBundleURL, withIntermediateDirectories: true)
        try Data().write(to: referenceBundleURL.appendingPathComponent("manifest.json"))
        for relative in ["variants/bowtie2/S1.sorted.bam",
                         "variants/bowtie2/S1.sorted.bam.bai",
                         "variants/ivar/S1.vcf.gz",
                         "variants/ivar/consensus/bcftools/S1.consensus.fa",
                         "multiqc/multiqc_report.html"] {
            let url = resultsURL.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data().write(to: url)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Discovery

    func testIngestedSingleSampleBundleIsDiscoverableAsAnAnalysis() throws {
        let ingested = try ViralReconResultIngest.ingestRun(
            resultsDirectory: resultsURL,
            sampleNames: ["S1"],
            referenceBundleURL: referenceBundleURL,
            projectURL: projectURL)

        let bundleDirectory = try XCTUnwrap(ingested.first).bundleDirectory
        let info = try XCTUnwrap(AnalysesFolder.analysisInfo(for: bundleDirectory),
                                 "an ingested Viral Recon bundle must be recognised as an analysis")
        XCTAssertEqual(info.tool, "viralrecon")
    }

    func testIngestedBundleLandsUnderAnalysesAndIsListed() throws {
        _ = try ViralReconResultIngest.ingestRun(
            resultsDirectory: resultsURL,
            sampleNames: ["S1"],
            referenceBundleURL: referenceBundleURL,
            projectURL: projectURL)

        let analyses = try AnalysesFolder.listAnalyses(in: projectURL)
        XCTAssertEqual(analyses.map(\.tool), ["viralrecon"])
    }

    func testSidebarScannerRendersANodeForTheIngestedBundle() throws {
        _ = try ViralReconResultIngest.ingestRun(
            resultsDirectory: resultsURL,
            sampleNames: ["S1"],
            referenceBundleURL: referenceBundleURL,
            projectURL: projectURL)

        let info = try XCTUnwrap(try AnalysesFolder.listAnalyses(in: projectURL).first)
        let node = try XCTUnwrap(SidebarProjectScanner.buildAnalysisNode(info: info),
                                 "the scanner must render a node for a Viral Recon analysis")
        XCTAssertEqual(node.userInfo["analysisTool"] as? String, "viralrecon")
        XCTAssertEqual(node.type, .analysisResult)
    }

    func testScannerHasAnIconAndItemTypeForViralRecon() {
        XCTAssertNotEqual(SidebarProjectScanner.analysisIcon(for: "viralrecon"), "circle",
                          "Viral Recon needs its own icon, not the fallback")
        XCTAssertEqual(SidebarProjectScanner.analysisItemType(for: "viralrecon"), .analysisResult)
    }

    // MARK: - Multi-sample

    func testMultiSampleRunIngestsAsABatchDiscoverableBySidebar() throws {
        for relative in ["variants/bowtie2/S2.sorted.bam"] {
            let url = resultsURL.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data().write(to: url)
        }

        let ingested = try ViralReconResultIngest.ingestRun(
            resultsDirectory: resultsURL,
            sampleNames: ["S1", "S2"],
            referenceBundleURL: referenceBundleURL,
            projectURL: projectURL)
        XCTAssertEqual(ingested.count, 2)

        let analyses = try AnalysesFolder.listAnalyses(in: projectURL)
        XCTAssertEqual(analyses.count, 1, "a multi-sample run is one batch analysis")
        let info = try XCTUnwrap(analyses.first)
        XCTAssertEqual(info.tool, "viralrecon")
        XCTAssertTrue(info.isBatch)

        let node = try XCTUnwrap(SidebarProjectScanner.buildAnalysisNode(info: info))
        XCTAssertEqual(node.type, .batchGroup)
        XCTAssertEqual(node.children.count, 2)
    }

    // MARK: - Bundle contents

    func testIngestWritesTheResultSidecarAndRoleDirectories() throws {
        let ingested = try ViralReconResultIngest.ingestRun(
            resultsDirectory: resultsURL,
            sampleNames: ["S1"],
            referenceBundleURL: referenceBundleURL,
            projectURL: projectURL)
        let bundleDirectory = try XCTUnwrap(ingested.first).bundleDirectory
        let fileManager = FileManager.default

        XCTAssertTrue(fileManager.fileExists(
            atPath: bundleDirectory.appendingPathComponent("viralrecon-result.json").path))
        for role in ["consensus", "lineage", "reports"] {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                fileManager.fileExists(
                    atPath: bundleDirectory.appendingPathComponent(role).path,
                    isDirectory: &isDirectory) && isDirectory.boolValue,
                "\(role)/ must exist in the ingested bundle")
        }
        XCTAssertTrue(fileManager.fileExists(
            atPath: bundleDirectory.appendingPathComponent("consensus/S1.consensus.fa").path))
        XCTAssertTrue(fileManager.fileExists(
            atPath: bundleDirectory.appendingPathComponent("reports/multiqc_report.html").path))
    }

    func testResultSidecarNamesTheSampleAndItsOutputs() throws {
        let ingested = try ViralReconResultIngest.ingestRun(
            resultsDirectory: resultsURL,
            sampleNames: ["S1"],
            referenceBundleURL: referenceBundleURL,
            projectURL: projectURL)
        let sidecarURL = try XCTUnwrap(ingested.first).bundleDirectory
            .appendingPathComponent("viralrecon-result.json")

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any])
        XCTAssertEqual(json["tool"] as? String, "viralrecon")
        XCTAssertEqual(json["sampleName"] as? String, "S1")
        XCTAssertEqual(json["consensusPath"] as? String, "consensus/S1.consensus.fa")
        XCTAssertEqual(json["referenceBundlePath"] as? String, "MN908947.3.lungfishref")
    }

    // MARK: - Publication

    // Publication is what makes the alignment and variants visible. Firing it
    // into a detached Task discarded every error and let the operation complete
    // before it finished, so a bundle that shows nothing looked like a success.
    func testPublicationFailureReachesTheCaller() async throws {
        // A reference bundle with no readable manifest cannot receive tracks.
        try Data("not json".utf8).write(
            to: referenceBundleURL.appendingPathComponent("manifest.json"))

        let ingested = try ViralReconResultIngest.ingestRun(
            resultsDirectory: resultsURL,
            sampleNames: ["S1"],
            referenceBundleURL: referenceBundleURL,
            projectURL: projectURL)

        do {
            _ = try await ViralReconViewerPublication.publish(
                ingested: try XCTUnwrap(ingested.first))
            XCTFail("publication into an unreadable bundle must not report success")
        } catch {
            // The error reaching here at all is the point: it used to be
            // swallowed by `try?` inside a detached Task.
        }
    }

    func testLiveIngestSurfacesAPublicationFailureRatherThanDiscardingIt() async throws {
        try Data("not json".utf8).write(
            to: referenceBundleURL.appendingPathComponent("manifest.json"))
        // The live ingest looks the reference bundle up by convention, so put
        // it where the catalog expects to find it.
        let expected = ViralReconReferenceCatalog.bundleURL(inProject: projectURL)
        try FileManager.default.createDirectory(at: expected.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: referenceBundleURL, to: expected)

        let context = ViralReconWorkflowExecutionService.ResultIngestContext(
            resultsDirectory: resultsURL,
            runBundleURL: root.appendingPathComponent("run.lungfishrun", isDirectory: true),
            sampleNames: ["S1"],
            projectURL: projectURL)

        do {
            try await ViralReconWorkflowExecutionService.liveResultIngest(context)
            XCTFail("a publication failure must not be reported as a successful ingest")
        } catch {
            // Routed to the caller's warning handler instead of vanishing.
        }
    }

    // One sample failing to publish must not cost the others their tracks, so
    // every sample is attempted before the failure is rethrown.
    func testEverySampleIsIngestedEvenWhenOneFailsToPublish() async throws {
        try Data("not json".utf8).write(
            to: referenceBundleURL.appendingPathComponent("manifest.json"))
        let expected = ViralReconReferenceCatalog.bundleURL(inProject: projectURL)
        try FileManager.default.createDirectory(at: expected.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: referenceBundleURL, to: expected)
        for relative in ["variants/bowtie2/S2.sorted.bam"] {
            let url = resultsURL.appendingPathComponent(relative)
            try Data().write(to: url)
        }

        let context = ViralReconWorkflowExecutionService.ResultIngestContext(
            resultsDirectory: resultsURL,
            runBundleURL: root.appendingPathComponent("run.lungfishrun", isDirectory: true),
            sampleNames: ["S1", "S2"],
            projectURL: projectURL)

        do {
            try await ViralReconWorkflowExecutionService.liveResultIngest(context)
            XCTFail("the publication failure must still be reported")
        } catch {
            // Expected.
        }

        let analyses = try AnalysesFolder.listAnalyses(in: projectURL)
        let batch = try XCTUnwrap(analyses.first { $0.isBatch })
        let samples = try FileManager.default.contentsOfDirectory(atPath: batch.url.path)
            .filter { $0 != AnalysesFolder.metadataFilename }
        XCTAssertEqual(samples.count, 2, "both samples must still have a bundle")
    }

    func testRawOutputIsPreservedNotMoved() throws {
        _ = try ViralReconResultIngest.ingestRun(
            resultsDirectory: resultsURL,
            sampleNames: ["S1"],
            referenceBundleURL: referenceBundleURL,
            projectURL: projectURL)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: resultsURL.appendingPathComponent("variants/bowtie2/S1.sorted.bam").path))
    }
}

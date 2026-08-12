import XCTest
@testable import LungfishApp
@testable import LungfishEsVirituUI
import LungfishCore
import LungfishKit

@MainActor
final class ClassifierFullBAMViewerIntegrationTests: XCTestCase {
    func testMainSplitCreatesTheAppOwnedDetachedEvidenceProvider() {
        let split = MainSplitViewController()
        split.loadViewIfNeeded()

        let provider = split.makeClassifierAlignmentEvidenceViewport()

        XCTAssertEqual(provider.viewer.windowStateScope, split.windowStateScope)
    }

    func testDetachedEvidenceProviderSharesTheParentClassifierMetadataContext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("classifier-detached-context-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        let provider = split.makeClassifierAlignmentEvidenceViewport()
        let consumer = EsVirituResultViewController()
        let entry = EsVirituResultViewController.EsVirituSampleEntry(
            id: "S1", displayName: "S1", detectedVirusCount: 1
        )

        split.installClassifierMetadataPresentation(
            resultURL: root,
            pickerState: ClassifierSamplePickerState(allSamples: ["S1"]),
            entries: [entry],
            strippedPrefix: "",
            workflowName: "EsViritu",
            consumer: consumer
        )

        let context = try XCTUnwrap(split.classifierMetadataPresentationContext)
        XCTAssertTrue(provider.testSampleMetadataPresentationContext === context)
        XCTAssertTrue(
            split.inspectorController.viewModel.documentSectionViewModel.sampleMetadataPresentationContext === context
        )
    }

    func testMissingEvidenceDoesNotCreateAReferenceBundleOrWriteFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("classifier-no-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let split = MainSplitViewController(); split.loadViewIfNeeded()
        let provider = split.makeClassifierAlignmentEvidenceViewport()
        let request = try ClassifierAlignmentEvidenceRequest(
            workflow: .esViritu,
            resultIdentity: .init(stableID: "result", finalResultURL: directory, provenanceID: "prov"),
            bamURL: directory.appendingPathComponent("missing.bam"),
            index: .init(url: directory.appendingPathComponent("missing.bam.bai"), kind: .bai),
            sample: .init(canonicalID: "S1"), contig: .init(name: "ctg", expectedLength: 1),
            referenceCandidate: nil,
            presentation: .init(workflowLabel: "EsViritu", resultLabel: "result", sampleLabel: "S1", contigLabel: "ctg")
        )
        provider.display(request)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("result.lungfishref").path))
    }

    func testSuccessfulValidatedEvidenceDisplayAndClearDoNotWriteAReferenceBundle() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("classifier-success-no-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bam = directory.appendingPathComponent("evidence.bam")
        let index = directory.appendingPathComponent("evidence.bam.bai")
        try Data([0x42, 0x41, 0x4D]).write(to: bam)
        try Data([0x42, 0x41, 0x49]).write(to: index)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let validator = ClassifierAlignmentEvidenceValidator(
            headerReader: { _ in "@SQ\tSN:ctg\tLN:1\n" },
            indexQuery: { _, _, _ in },
            fileManager: .default
        )
        let provider = ClassifierAlignmentEvidenceViewportController(validator: validator)
        let request = try ClassifierAlignmentEvidenceRequest(
            workflow: .nvd,
            resultIdentity: .init(stableID: "result", finalResultURL: directory, provenanceID: "prov"),
            bamURL: bam,
            index: .init(url: index, kind: .bai),
            sample: .init(canonicalID: "S1"), contig: .init(name: "ctg", expectedLength: 1),
            referenceCandidate: nil,
            presentation: .init(workflowLabel: "NVD", resultLabel: "result", sampleLabel: "S1", contigLabel: "ctg")
        )
        provider.display(request)
        for _ in 0..<100 where provider.status == .loading { await Task.yield() }
        XCTAssertEqual(provider.status, .available(referenceStrength: "not provided", reason: nil))
        provider.clear()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("result.lungfishref").path))
    }

    func testRepoOwnedFullBAMFixtureUsesDefaultValidatorAndDetachedViewerWithoutWriting() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = repositoryRoot
            .appendingPathComponent("Tests/Fixtures/classifier-full-viewer", isDirectory: true)
        let bamURL = fixtureURL.appendingPathComponent("evidence.bam")
        let indexURL = fixtureURL.appendingPathComponent("evidence.bam.bai")
        guard FileManager.default.isReadableFile(atPath: bamURL.path),
              FileManager.default.isReadableFile(atPath: indexURL.path) else {
            XCTFail(
                "Required repository fixture is missing or unreadable: "
                    + "Tests/Fixtures/classifier-full-viewer/evidence.bam and evidence.bam.bai. "
                    + "This integration test requires valid indexed BAM evidence and the default samtools-backed validator."
            )
            return
        }
        let before = try FileManager.default.contentsOfDirectory(atPath: fixtureURL.path).sorted()
        let request = try ClassifierAlignmentEvidenceRequest(
            workflow: .esViritu,
            resultIdentity: .init(stableID: "fixture-result", finalResultURL: fixtureURL, provenanceID: "fixture-provenance"),
            bamURL: bamURL,
            index: .init(url: indexURL, kind: .bai),
            sample: .init(canonicalID: "fixture-sample"),
            contig: .init(name: "synthetic-track-A", expectedLength: 120),
            referenceCandidate: nil,
            presentation: .init(
                workflowLabel: "EsViritu", resultLabel: "fixture-result",
                sampleLabel: "fixture-sample", contigLabel: "synthetic-track-A"
            )
        )
        let controller = ClassifierAlignmentEvidenceViewportController()

        controller.display(request)
        for _ in 0..<500 where controller.status == .loading {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(controller.status, .available(referenceStrength: "not provided", reason: nil))

        let source = try XCTUnwrap(controller.viewer.viewerView.testDetachedAlignmentSource)
        XCTAssertEqual(source.provider.alignmentPath, bamURL.path)
        XCTAssertEqual(source.provider.indexPath, indexURL.path)
        XCTAssertNil(source.provider.referenceFastaPath)
        XCTAssertNil(controller.viewer.currentReferenceBundle)
        XCTAssertEqual(controller.viewer.viewerView.excludeFlagsSetting, 0xD04)
        XCTAssertEqual(controller.inspectorCapabilities?.indexPath, indexURL.path)
        XCTAssertEqual(controller.inspectorCapabilities?.readGroups, [])

        let region = GenomicRegion(chromosome: "synthetic-track-A", start: 0, end: 120)
        for _ in 0..<500 where !controller.viewer.viewerView.detachedEvidenceIsCurrent(source) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(controller.viewer.viewerView.detachedEvidenceIsCurrent(source))
        controller.viewer.viewerView.fetchDetachedReads(source: source, region: region)
        for _ in 0..<500 where controller.viewer.viewerView.testIsFetchingReads
            || controller.viewer.viewerView.testCachedAlignedReads.count != 2 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(
            controller.viewer.viewerView.testCachedAlignedReads.map(\.name).sorted(),
            ["item-A", "item-B"]
        )
        XCTAssertNil(controller.viewer.viewerView.testDetachedEvidenceFetchMessage)

        controller.viewer.viewerView.fetchDetachedDepth(source: source, region: region)
        for _ in 0..<500 where controller.viewer.viewerView.testIsFetchingDepth
            || controller.viewer.viewerView.testCachedDepthPoints.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let depthByPosition = Dictionary(
            uniqueKeysWithValues: controller.viewer.viewerView.testCachedDepthPoints.map { ($0.position, $0.depth) }
        )
        XCTAssertEqual(depthByPosition[9], 1)
        XCTAssertEqual(depthByPosition[14], 2)
        XCTAssertEqual(depthByPosition[23], 1)
        XCTAssertNil(controller.viewer.viewerView.testDetachedEvidenceFetchMessage)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixtureURL.path).sorted(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixtureURL.appendingPathComponent("fixture-result.lungfishref").path))
    }

    func testAllClassifierHostHidePathsClearTheirLeafEvidence() throws {
        let paths = [
            "Sources/LungfishApp/Views/Viewer/ViewerViewController+EsViritu.swift",
            "Sources/LungfishApp/Views/Viewer/ViewerViewController+TaxTriage.swift",
            "Sources/LungfishApp/Views/Viewer/ViewerViewController+Nvd.swift",
        ]
        for path in paths {
            let source = try String(contentsOfFile: path, encoding: .utf8)
            XCTAssertTrue(source.contains("clearClassifierAlignmentEvidence()"), path)
        }
    }
}

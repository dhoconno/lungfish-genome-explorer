import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO

@MainActor
final class InspectorMappingModeTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("inspector_mapping_mode_tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testMappingModeUsesBundleSelectedItemViewAndAnalysisInspectorTabs() {
        let viewModel = InspectorViewModel()
        viewModel.contentMode = .mapping

        XCTAssertEqual(viewModel.availableTabs, [.bundle, .selectedItem, .view, .analysis])
    }

    func testMappingModeExposesSeparateViewAndAnalysisTabs() {
        let viewModel = InspectorViewModel()
        viewModel.contentMode = .mapping

        XCTAssertEqual(
            viewModel.availableTabs.map(\.displayLabel),
            ["Bundle", "Selected Item", "View", "Analysis"]
        )
    }

    func testMappingAlignmentSectionBindsEmbeddedBundleForWorkflowState() throws {
        let vc = InspectorViewController()
        _ = vc.view
        let bundle = try makeReferenceBundle()

        vc.updateMappingAlignmentSection(from: bundle, applySettings: { _ in })

        XCTAssertEqual(vc.selectionSectionViewModel.referenceBundle?.url, bundle.url)
        XCTAssertEqual(vc.viewModel.documentSectionViewModel.bundleURL, bundle.url)
    }

    func testMappingAlignmentSectionImmediatelyAppliesCurrentReadStylePayload() throws {
        let vc = InspectorViewController()
        _ = vc.view
        let bundle = try makeReferenceBundle()

        vc.readStyleSectionViewModel.showReads = false
        vc.readStyleSectionViewModel.maxReadRows = 123
        vc.readStyleSectionViewModel.limitReadRows = true
        vc.readStyleSectionViewModel.verticallyCompressContig = false
        vc.readStyleSectionViewModel.consensusMinDepth = 21
        vc.readStyleSectionViewModel.consensusMaskingMinDepth = 13

        var deliveredPayload: [AnyHashable: Any]?
        vc.updateMappingAlignmentSection(from: bundle) { payload in
            deliveredPayload = payload
        }

        XCTAssertEqual(deliveredPayload?[NotificationUserInfoKey.showReads] as? Bool, false)
        XCTAssertEqual(deliveredPayload?[NotificationUserInfoKey.maxReadRows] as? Int, 123)
        XCTAssertEqual(deliveredPayload?[NotificationUserInfoKey.limitReadRows] as? Bool, true)
        XCTAssertEqual(deliveredPayload?[NotificationUserInfoKey.verticalCompressContig] as? Bool, false)
        XCTAssertEqual(deliveredPayload?[NotificationUserInfoKey.consensusMinDepth] as? Int, 21)
        XCTAssertEqual(deliveredPayload?[NotificationUserInfoKey.consensusMaskingMinDepth] as? Int, 13)
    }

    func testMappingAlignmentSectionWiresFilteredAlignmentWorkflowLaunch() throws {
        let vc = InspectorViewController()
        _ = vc.view
        let bundle = try makeReferenceBundle()

        vc.updateMappingAlignmentSection(from: bundle, applySettings: { _ in })

        XCTAssertNotNil(
            vc.readStyleSectionViewModel.onCreateFilteredAlignmentRequested,
            "Mapping mode should wire BAM filtering launches through the Inspector workflow handler"
        )
        XCTAssertNotNil(
            vc.readStyleSectionViewModel.onConvertMappedReadsToAnnotationsRequested,
            "Mapping mode should wire mapped-read annotation conversion through the Inspector workflow handler"
        )
    }

    func testEmptySidebarDeselectionPreservesActiveBundleContextForInspectorActions() throws {
        let vc = InspectorViewController()
        _ = vc.view
        let bundle = try makeReferenceBundle()

        vc.updateMappingAlignmentSection(from: bundle, applySettings: { _ in })
        NotificationCenter.default.post(
            name: .sidebarSelectionChanged,
            object: nil,
            userInfo: ["items": [SidebarItem]()]
        )

        XCTAssertEqual(vc.selectionSectionViewModel.referenceBundle?.url, bundle.url)
        XCTAssertEqual(vc.viewModel.documentSectionViewModel.bundleURL, bundle.url)
    }

    func testClearSelectionClearsBundleContextAndAlignmentStats() throws {
        let vc = InspectorViewController()
        _ = vc.view
        let bundle = try makeReferenceBundle()

        vc.updateMappingAlignmentSection(from: bundle, applySettings: { _ in })
        vc.readStyleSectionViewModel.hasAlignmentTracks = true
        vc.readStyleSectionViewModel.totalMappedReads = 99
        vc.readStyleSectionViewModel.trackNames = ["reads"]

        vc.clearSelection()

        XCTAssertNil(vc.selectionSectionViewModel.referenceBundle)
        XCTAssertNil(vc.viewModel.documentSectionViewModel.bundleURL)
        XCTAssertFalse(vc.readStyleSectionViewModel.hasAlignmentTracks)
        XCTAssertEqual(vc.readStyleSectionViewModel.totalMappedReads, 0)
        XCTAssertEqual(vc.readStyleSectionViewModel.trackNames, [])
    }

    private func makeReferenceBundle() throws -> ReferenceBundle {
        let bundleURL = tempDir.appendingPathComponent("fixture.lungfishref", isDirectory: true)
        let genomeURL = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeURL, withIntermediateDirectories: true)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Fixture",
            identifier: "org.test.fixture",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: "genome/sequence.fa.gz.gzi",
                totalLength: 100,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 100, offset: 0, lineBases: 80, lineWidth: 81)
                ]
            ),
            annotations: []
        )
        try manifest.save(to: bundleURL)
        return ReferenceBundle(url: bundleURL, manifest: manifest)
    }
}

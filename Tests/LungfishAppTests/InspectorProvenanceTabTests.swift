import XCTest
@testable import LungfishApp
import LungfishCore

@MainActor
final class InspectorProvenanceTabTests: XCTestCase {
    func testEveryScientificContentModeIncludesProvenanceTab() {
        let modes: [ViewportContentMode] = [.genomics, .mapping, .assembly, .fastq, .metagenomics]

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

    func testSidebarSelectionLoadsProvenanceItem() throws {
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

        XCTAssertEqual(vc.viewModel.provenanceSectionViewModel.currentItem?.url, dir)
        XCTAssertEqual(vc.viewModel.provenanceSectionViewModel.currentItem?.sidebarType, .fastqBundle)
        XCTAssertEqual(vc.viewModel.provenanceSectionViewModel.audit.status, .missing)
    }

    func testClearSelectionClearsProvenanceState() throws {
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
}

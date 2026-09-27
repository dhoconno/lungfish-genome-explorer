import AppKit
import XCTest
import ViewInspector
@testable import LungfishApp
import LungfishCore
import LungfishWorkflow

@MainActor
final class ManualScreenshotProductFixTests: XCTestCase {
    func testVariantProvenanceSourceSelectionAndNavigationReset() {
        let bundleURL = URL(fileURLWithPath: "/tmp/reference.lungfishref")
        let model = ProvenanceInspectorViewModel()
        let item = ProvenanceInspectableItem(url: bundleURL, sidebarType: .referenceBundle,
                                            contentMode: .mapping, displayName: "Reference")
        let tracks = [
            VariantTrackInfo(id: "a", name: "HG002 bcftools", path: "variants/a.vcf.gz", indexPath: "variants/a.vcf.gz.tbi"),
            VariantTrackInfo(id: "b", name: "HG002 LoFreq", path: "variants/b.vcf.gz", indexPath: "variants/b.vcf.gz.tbi"),
        ]
        model.load(item: item)
        model.configureVariantSources(bundleItem: item, tracks: tracks)
        XCTAssertEqual(model.sources.map(\.name), ["Bundle", "HG002 bcftools", "HG002 LoFreq"])
        model.selectSource(id: model.sources[1].id)
        XCTAssertEqual(model.currentItem?.url, bundleURL.appendingPathComponent("variants/a.vcf.gz"))
        model.selectSource(id: model.sources[2].id)
        XCTAssertEqual(model.currentItem?.url, bundleURL.appendingPathComponent("variants/b.vcf.gz"))
        model.selectSource(id: model.sources[0].id)
        XCTAssertEqual(model.currentItem?.url, bundleURL)
        model.load(item: .init(url: URL(fileURLWithPath: "/tmp/other.fastq"), sidebarType: .fastqBundle,
                               contentMode: .fastq, displayName: "Other"))
        XCTAssertTrue(model.sources.isEmpty)
        model.clear()
    }

    func testTrackPickerResolvesEachTracksOwnStoredSidecar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".lungfishref")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("variants"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tracks = ["bcftools", "lofreq"].map {
            VariantTrackInfo(id: $0, name: $0, path: "variants/\($0).vcf", indexPath: "variants/\($0).vcf.tbi")
        }
        for track in tracks {
            let url = root.appendingPathComponent(track.path)
            try Data("##fileformat=VCFv4.2\n".utf8).write(to: url)
            let output = try ProvenanceFileDescriptor.file(url: url, role: .output)
            let envelope = ProvenanceEnvelope(
                workflowName: track.name, workflowVersion: "1", toolName: track.name, toolVersion: "1",
                argv: [track.name, "--output", url.path], runtimeIdentity: ProvenanceRuntimeIdentity.fixture(),
                files: [output], output: output, outputs: [output], wallTimeSeconds: 1, exitStatus: 0
            )
            try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar:
                root.appendingPathComponent("variants/\(track.id).lungfish-provenance.json"))
        }
        let model = ProvenanceInspectorViewModel()
        let item = ProvenanceInspectableItem(url: root, sidebarType: .referenceBundle,
                                            contentMode: .mapping, displayName: "Reference")
        model.load(item: item)
        model.configureVariantSources(bundleItem: item, tracks: tracks)
        for track in tracks {
            model.selectSource(id: root.appendingPathComponent(track.path).path)
            XCTAssertNil(model.resolvedEnvelope, "A new source must not export the previous envelope")
            XCTAssertTrue(model.copyableText.isEmpty, "A new source must not copy the previous track's text")
            XCTAssertTrue(model.rawJSON.isEmpty, "Raw JSON must not display the previous track")
            let copy = try ProvenanceSection(viewModel: model).inspect()
                .find(viewWithAccessibilityIdentifier: "provenance-copy-text")
            XCTAssertTrue(copy.isDisabled())
            // The lookup runs a coverage audit plus a sidecar walk on a
            // detached task; alone it takes a few seconds, under the parallel
            // gate's load it has exceeded 10 s. Generous deadline, same checks.
            let deadline = Date().addingTimeInterval(120)
            while model.isLoading && Date() < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertFalse(model.isLoading)
            XCTAssertEqual(model.resolvedEnvelope?.workflowName, track.name)
            XCTAssertFalse(model.copyableText.isEmpty)
            XCTAssertEqual(model.resolvedSidecarURL?.lastPathComponent, "\(track.id).lungfish-provenance.json")
        }
        model.clear()
    }

    func testLongCommandHeightExpandsAndShrinksWithAvailableWidth() {
        let command = Array(repeating: "--input /tmp/fixture-reads.fastq", count: 20).joined(separator: " ")
        let narrow = OperationsPanelViewController.commandTextHeight(command, columnWidth: 240)
        let wide = OperationsPanelViewController.commandTextHeight(command, columnWidth: 1000)
        XCTAssertGreaterThan(narrow, wide)
        XCTAssertGreaterThan(wide, 28, "Long commands must remain readable beyond the old two-line cap")
    }

    func testOperationsDetailsColumnUsesWindowWidth() throws {
        let controller = OperationsPanelViewController()
        let view = controller.view
        func table(in view: NSView) -> NSTableView? {
            if let result = view as? NSTableView { return result }
            return view.subviews.compactMap { table(in: $0) }.first
        }
        let tableView = try XCTUnwrap(table(in: view))
        view.setFrameSize(NSSize(width: 1400, height: 900))
        view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        let title = try XCTUnwrap(tableView.tableColumn(withIdentifier: .init("title")))
        XCTAssertGreaterThan(title.width, 800)
        view.setFrameSize(NSSize(width: 700, height: 500))
        view.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        XCTAssertLessThan(title.width, 400)
        XCTAssertGreaterThanOrEqual(title.width, title.minWidth)
    }
}

import AppKit
import Darwin
import SwiftUI
import XCTest
import LungfishIO
import LungfishCore
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class PrimerAnalysisInspectorTests: XCTestCase {
    func testVerifiedAnalysisUsesNativeInspectorTabsAndReadOnlyProvenance() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundleURL)
        let before = try bytes(in: fixture.bundleURL)
        let inspector = InspectorViewController()
        inspector.loadViewIfNeeded()

        inspector.beginPrimerAnalysisDocument(at: fixture.bundleURL)
        inspector.updatePrimerAnalysisDocument(snapshot)

        XCTAssertEqual(inspector.viewModel.availableTabs, [.bundle, .files, .provenance])
        XCTAssertEqual(inspector.viewModel.primerAnalysisDocument?.bundleURL, fixture.bundleURL.standardizedFileURL)
        XCTAssertEqual(inspector.viewModel.primerAnalysisDocument?.files.count, snapshot.bundle.manifest.artifacts.count + 1)
        let provenance = inspector.viewModel.provenanceSectionViewModel
        XCTAssertEqual(provenance.currentItem?.url, fixture.bundleURL)
        XCTAssertEqual(provenance.resolvedEnvelope?.id, snapshot.provenance.id)
        XCTAssertEqual(provenance.resolvedSidecarURL, try snapshot.bundle.artifactURL(forRelativePath: snapshot.bundle.manifest.provenance.relativePath))
        XCTAssertEqual(provenance.audit.status, .present)
        XCTAssertEqual(provenance.sources.count, 4)
        XCTAssertEqual(snapshot.derivedProvenance.map(\.toolName), ["Lungfish Primer Order Sheet"])
        XCTAssertEqual(snapshot.workflowProvenance.map(\.toolName), ["Lungfish Primer Normalization"])
        for source in provenance.sources.dropFirst() {
            provenance.selectSource(id: source.id)
            XCTAssertEqual(provenance.resolvedEnvelope?.toolName, source.verifiedRecord?.envelope.toolName)
            XCTAssertEqual(provenance.resolvedSidecarURL, source.verifiedRecord?.sidecarURL)
            XCTAssertFalse(provenance.isLoading)
        }
        XCTAssertEqual(try bytes(in: fixture.bundleURL), before)
    }

    func testShowInInspectorTargetsExistingSelectedBundle() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspector = InspectorViewController()
        inspector.beginPrimerAnalysisDocument(at: fixture.bundleURL)
        inspector.updatePrimerAnalysisDocument(try PrimerAnalysisViewerSnapshot.load(from: fixture.bundleURL))
        inspector.viewModel.selectedTab = .files

        inspector.handleShowInspectorRequested(Notification(name: .showInspectorRequested,
            userInfo: [NotificationUserInfoKey.inspectorTab: "document"]))

        XCTAssertEqual(inspector.viewModel.selectedTab, .bundle)
        XCTAssertEqual(inspector.viewModel.primerAnalysisDocument?.bundleURL, fixture.bundleURL.standardizedFileURL)
        XCTAssertFalse(inspector.viewModel.primerAnalysisDocument?.files.isEmpty ?? true)
    }

    func testClearSelectionInvalidatesPrimerFilesAndProvenanceTabs() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspector = InspectorViewController()
        inspector.beginPrimerAnalysisDocument(at: fixture.bundleURL)
        inspector.updatePrimerAnalysisDocument(try PrimerAnalysisViewerSnapshot.load(from: fixture.bundleURL))
        inspector.viewModel.selectedTab = .files

        inspector.clearSelection()

        XCTAssertNil(inspector.viewModel.primerAnalysisDocument)
        XCTAssertFalse(inspector.viewModel.availableTabs.contains(.files))
        XCTAssertFalse(inspector.viewModel.availableTabs.contains(.provenance))
        XCTAssertTrue(inspector.viewModel.availableTabs.contains(inspector.viewModel.selectedTab))
        XCTAssertNil(inspector.viewModel.provenanceSectionViewModel.resolvedEnvelope)
    }

    func testSupersededBundleSnapshotCannotPopulateInspector() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundleURL)
        let inspector = InspectorViewController()
        let secondURL = fixture.root.appendingPathComponent("second.lungfishprimeranalysis")
        inspector.beginPrimerAnalysisDocument(at: secondURL)

        inspector.updatePrimerAnalysisDocument(snapshot)

        XCTAssertEqual(inspector.viewModel.primerAnalysisDocument?.bundleURL, secondURL)
        XCTAssertTrue(inspector.viewModel.primerAnalysisDocument?.files.isEmpty == true)
        XCTAssertNil(inspector.viewModel.provenanceSectionViewModel.resolvedEnvelope)
    }

    func testFailedAnalysisShowsNoVerifiedFilesOrProvenance() {
        let inspector = InspectorViewController()
        let url = URL(fileURLWithPath: "/invalid.lungfishprimeranalysis")
        inspector.beginPrimerAnalysisDocument(at: url)
        inspector.failPrimerAnalysisDocument(at: url, message: "Integrity mismatch")
        XCTAssertEqual(inspector.viewModel.primerAnalysisDocument?.errorMessage, "Integrity mismatch")
        XCTAssertFalse(inspector.viewModel.primerAnalysisDocument?.isLoading ?? true)
        XCTAssertNil(inspector.viewModel.provenanceSectionViewModel.resolvedEnvelope)
        XCTAssertEqual(inspector.viewModel.provenanceSectionViewModel.audit.status, .invalid)
    }

    func testVerifiedProvenanceSourceSwitchRetainsRecordsWithoutDiscovery() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let snapshot = try PrimerAnalysisViewerSnapshot.load(from: fixture.bundleURL)
        let model = ProvenanceInspectorViewModel()
        let firstURL = fixture.bundleURL.appendingPathComponent("provenance/first.json")
        let secondURL = fixture.bundleURL.appendingPathComponent("provenance/second.json")
        let records = [firstURL, secondURL].map { url in
            ProvenanceSource(id: url.path, name: url.lastPathComponent, item: .init(
                url: url, sidebarType: .primerAnalysisBundle, contentMode: .empty, displayName: url.lastPathComponent),
                verifiedRecord: .init(envelope: snapshot.provenance, sidecarURL: url))
        }
        model.configureVerifiedSources(records)

        model.selectSource(id: secondURL.path)

        XCTAssertEqual(model.selectedSourceID, secondURL.path)
        XCTAssertEqual(model.sources.map(\.id), records.map(\.id))
        XCTAssertEqual(model.resolvedEnvelope?.id, snapshot.provenance.id)
        XCTAssertEqual(model.resolvedSidecarURL, secondURL)
        XCTAssertFalse(model.isLoading)
        // This path intentionally does not exist: the validated record is displayed
        // directly, so selecting it must not trigger a filesystem discovery/repair.
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testRenderNativePrimerInspectorTabs() async throws {
        guard let path = ProcessInfo.processInfo.environment["LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set LUNGFISH_PRIMER_VIEWER_SNAPSHOT_DIR for visual verification")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let inspector = InspectorViewController()
        inspector.beginPrimerAnalysisDocument(at: fixture.bundleURL)
        inspector.updatePrimerAnalysisDocument(try PrimerAnalysisViewerSnapshot.load(from: fixture.bundleURL))
        for tab in inspector.viewModel.availableTabs {
            inspector.viewModel.selectedTab = tab
            let host = NSHostingView(rootView: InspectorView(viewModel: inspector.viewModel))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 820),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.appearance = NSAppearance(named: .aqua)
            host.frame = NSRect(x: 0, y: 0, width: 380, height: 820)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent("primer-inspector-\(tab.rawValue).png"))
            window.close()
        }
    }

    private func makeFixture() throws -> (root: URL, bundleURL: URL) {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("source.txt")
        let output = root.appendingPathComponent("result.txt")
        try Data("input\n".utf8).write(to: input)
        try Data("result\n".utf8).write(to: output)
        let nativeProvenance = root.appendingPathComponent("tool.json")
        let derivedProvenance = root.appendingPathComponent("derived.json")
        let workflowProvenance = root.appendingPathComponent("workflow.json")
        for (url, toolName) in [(nativeProvenance, "PrimalScheme3-LGE (custom fork)"),
                                (workflowProvenance, "Lungfish Primer Normalization"),
                                (derivedProvenance, "Lungfish Primer Order Sheet")] {
            _ = try ProvenanceWriter(signingProvider: nil).write(.init(
                workflowName: "Fixture scientific step", workflowVersion: "test", toolName: toolName,
                toolVersion: "test", argv: ["primer-inspector-test"], wallTimeSeconds: 1, exitStatus: 0),
                toSidecar: url)
        }
        let bundleURL = root.appendingPathComponent("saved.lungfishprimeranalysis")
        let inputID = UUID()
        _ = try PrimerAnalysisBundleWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(.init(
            analysisID: UUID(), runID: UUID(), grouping: .independent,
            inputs: [.init(id: inputID, label: "Target", artifactPaths: ["inputs/source.txt"])],
            results: [.init(id: UUID(), label: "Scheme", inputIDs: [inputID], artifactPaths: ["native/result.txt"])],
            artifacts: [
                .init(sourceURL: input, relativePath: "inputs/source.txt", role: "input", format: "text"),
                .init(sourceURL: output, relativePath: "native/result.txt", role: "nativeOutput", format: "text"),
                .init(sourceURL: nativeProvenance, relativePath: "execution-provenance/tool.json", role: "toolProvenance", format: "json"),
                .init(sourceURL: workflowProvenance, relativePath: "execution-provenance/workflow.json", role: "workflowProvenance", format: "json"),
                .init(sourceURL: derivedProvenance, relativePath: "execution-provenance/derived.json", role: "derivedProvenance", format: "json")
            ], destinationURL: bundleURL,
            invocation: .init(argv: ["primer-inspector-test"], callerVersion: "1", explicitOptions: [:],
                runtimeIdentity: .init(appVersion: "test", executablePath: "/test/primer-inspector-test", processIdentifier: 1,
                    operatingSystemVersion: "test", architecture: "arm64", user: nil, dependencySet: "test"))))
        return (root, bundleURL)
    }

    private func bytes(in root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(root.path.count))] = try Data(contentsOf: url)
        }
        return result
    }
}

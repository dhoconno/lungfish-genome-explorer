import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

@MainActor
final class WorkflowBuilderAppIntegrationTests: XCTestCase {

    func testWorkflowBuilderMenuActionOpensReusableWindow() throws {
        let _ = NSApplication.shared
        closeWorkflowBuilderWindows()
        addTeardownBlock { @MainActor in
            self.closeWorkflowBuilderWindows()
        }

        let delegate = AppDelegate()

        delegate.showWorkflowBuilder(nil)
        let firstWindow = try XCTUnwrap(workflowBuilderWindow())
        XCTAssertEqual(firstWindow.accessibilityIdentifier(), "WorkflowBuilderWindow")
        XCTAssertEqual(firstWindow.frame.width, 1024, accuracy: 1)
        XCTAssertEqual(firstWindow.frame.height, 720, accuracy: 1)

        firstWindow.performClose(nil)
        delegate.showWorkflowBuilder(nil)

        let reopenedWindow = try XCTUnwrap(workflowBuilderWindow())
        XCTAssertTrue(reopenedWindow === firstWindow)
        XCTAssertTrue(reopenedWindow.isVisible)

        reopenedWindow.close()
    }

    func testWorkflowBuilderToolbarIncludesRunButton() throws {
        let controller = WorkflowBuilderViewController()
        controller.loadViewIfNeeded()
        let toolbar = NSToolbar(identifier: "WorkflowBuilderToolbar")

        XCTAssertTrue(controller.toolbarDefaultItemIdentifiers(toolbar).contains(.workflowRun))

        let item = try XCTUnwrap(
            controller.toolbar(toolbar, itemForItemIdentifier: .workflowRun, willBeInsertedIntoToolbar: true)
        )
        XCTAssertEqual(item.label, "Run")
        XCTAssertEqual(item.action, #selector(WorkflowBuilderViewController.runWorkflow(_:)))
        XCTAssertNotNil(item.image)
    }

    func testWorkflowBundleSaveWritesGraphAndProvenanceDirectory() throws {
        let controller = WorkflowBuilderViewController()
        controller.loadViewIfNeeded()
        let tempDirectory = try makeTemporaryDirectory()
        let requestedURL = tempDirectory.appendingPathComponent("workflow.json", isDirectory: false)

        let savedURL = try controller.saveWorkflowBundleForTesting(to: requestedURL)

        XCTAssertEqual(savedURL.pathExtension, "lungfishflow")
        XCTAssertEqual(controller.workflowURL, savedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestedURL.path))

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.appendingPathComponent("graph.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.appendingPathComponent("provenance.json").path))
    }

    func testCanvasReportsDeletableSelectionState() throws {
        let canvas = WorkflowCanvasView()
        var graph = canvas.graph
        let node = graph.addNode(type: .fastpTrim, position: .zero)
        canvas.graph = graph

        XCTAssertFalse(canvas.hasDeletableSelection)

        canvas.selectNode(node.id)
        XCTAssertTrue(canvas.hasDeletableSelection)

        canvas.selectNode(WorkflowGraph.sampleInputAnchorID)
        XCTAssertFalse(canvas.hasDeletableSelection)
    }

    func testCanvasUpdatesSelectedNodeParameters() throws {
        let canvas = WorkflowCanvasView()
        var graph = canvas.graph
        let node = graph.addNode(type: .fastpTrim, position: .zero)
        canvas.graph = graph
        canvas.selectNode(node.id)

        try canvas.updateSelectedNode { selected in
            selected.label = "Trim tuned"
            selected.parameters["quality"] = "20"
        }

        let updated = try XCTUnwrap(canvas.graph.getNode(node.id))
        XCTAssertEqual(updated.label, "Trim tuned")
        XCTAssertEqual(updated.parameters["quality"], "20")
    }

    func testCanvasDeletesSelectedConnectionAndReportsModification() throws {
        let canvas = WorkflowCanvasView()
        var graph = canvas.graph
        let input = try graph.addStableNode(
            id: UUID(),
            type: .fastqBundleInput,
            position: .zero,
            parameters: ["bundle_path": "@/Imports/sample.lungfishfastq"]
        )
        let trim = graph.addNode(type: .fastpTrim, position: CGPoint(x: 240, y: 0))
        let connection = try graph.addConnection(
            sourceNodeId: input.id,
            sourcePortId: "reads",
            targetNodeId: trim.id,
            targetPortId: "reads"
        )
        canvas.graph = graph

        let delegate = WorkflowCanvasDelegateSpy()
        canvas.delegate = delegate
        canvas.selectConnection(connection.id)

        XCTAssertEqual(canvas.selectedConnectionIDsForTesting, [connection.id])
        XCTAssertTrue(canvas.hasDeletableSelection)

        canvas.deleteSelection()

        XCTAssertNil(canvas.graph.getConnection(connection.id))
        XCTAssertTrue(canvas.selectedConnectionIDsForTesting.isEmpty)
        XCTAssertEqual(delegate.modifiedCount, 1)
    }

    func testInspectorEditsSelectedNodeLabelAndParameters() throws {
        let inspector = WorkflowNodeInspectorView()
        var node = WorkflowNode(
            type: .fastpTrim,
            position: .zero,
            parameters: ["quality": "15"]
        )
        var captured: WorkflowNode?
        inspector.onNodeChanged = { captured = $0 }

        inspector.inspect(node: node, activeProjectURL: nil)
        inspector.testingSetLabel("Trim strict")
        inspector.testingSetParameter("quality", value: "25")

        node = try XCTUnwrap(captured)
        XCTAssertEqual(node.label, "Trim strict")
        XCTAssertEqual(node.parameters["quality"], "25")
    }

    func testInspectorRejectsInputBundleOutsideProject() throws {
        let project = URL(fileURLWithPath: "/tmp/Project.lungfish", isDirectory: true)
        let inspector = WorkflowNodeInspectorView()
        inspector.inspect(
            node: WorkflowNode(type: .fastqBundleInput, position: .zero),
            activeProjectURL: project
        )

        XCTAssertThrowsError(
            try inspector.testingChooseBundle(URL(fileURLWithPath: "/tmp/Other/sample.lungfishfastq", isDirectory: true))
        )
    }

    func testInspectorStoresInputBundleAsProjectRelativePath() throws {
        let project = try makeTemporaryDirectory().appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let inspector = WorkflowNodeInspectorView()
        var captured: WorkflowNode?
        inspector.onNodeChanged = { captured = $0 }
        inspector.inspect(
            node: WorkflowNode(type: .fastqBundleInput, position: .zero),
            activeProjectURL: project
        )

        try inspector.testingChooseBundle(bundle)

        XCTAssertEqual(captured?.parameters["bundle_path"], "@/Imports/sample.lungfishfastq")
        let pathControl = try XCTUnwrap(inspector.firstSubview(of: NSPathControl.self))
        XCTAssertEqual(pathControl.url?.standardizedFileURL, bundle.standardizedFileURL)
    }

    func testInspectorRejectsRegularFileWithFastqBundleExtension() throws {
        let project = try makeTemporaryDirectory().appendingPathComponent("Project.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let fakeBundle = imports.appendingPathComponent("not-a-bundle.lungfishfastq", isDirectory: false)
        try Data("not a bundle".utf8).write(to: fakeBundle)

        let inspector = WorkflowNodeInspectorView()
        inspector.inspect(
            node: WorkflowNode(type: .fastqBundleInput, position: .zero),
            activeProjectURL: project
        )

        XCTAssertThrowsError(try inspector.testingChooseBundle(fakeBundle)) { error in
            XCTAssertEqual(error as? WorkflowNodeInspectorError, .invalidBundleType)
        }
    }

    func testInspectorRejectsSymlinkedBundleEscapingProject() throws {
        let root = try makeTemporaryDirectory()
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        let outsideBundle = root
            .appendingPathComponent("Outside", isDirectory: true)
            .appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        let symlink = imports.appendingPathComponent("linked.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideBundle, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideBundle)

        let inspector = WorkflowNodeInspectorView()
        inspector.inspect(
            node: WorkflowNode(type: .fastqBundleInput, position: .zero),
            activeProjectURL: project
        )

        XCTAssertThrowsError(try inspector.testingChooseBundle(symlink)) { error in
            XCTAssertEqual(error as? WorkflowNodeInspectorError, .bundleOutsideProject)
        }
    }

    func testBuilderInspectorUpdatesSelectedCanvasNode() throws {
        let controller = WorkflowBuilderViewController()
        controller.loadViewIfNeeded()

        let canvas = try XCTUnwrap(controller.view.firstSubview(of: WorkflowCanvasView.self))
        let inspector = try XCTUnwrap(controller.view.firstSubview(of: WorkflowNodeInspectorView.self))
        var graph = controller.graph
        let node = graph.addNode(type: .fastpTrim, position: .zero)
        controller.graph = graph

        canvas.selectNode(node.id)
        inspector.testingSetLabel("Trim strict")
        XCTAssertEqual(canvas.selectedNodeIDsForTesting, [node.id])
        inspector.testingSetParameter("quality", value: "25")
        XCTAssertEqual(canvas.selectedNodeIDsForTesting, [node.id])

        let updated = try XCTUnwrap(controller.graph.getNode(node.id))
        XCTAssertEqual(updated.label, "Trim strict")
        XCTAssertEqual(updated.parameters["quality"], "25")
    }

    func testBuilderConfigureRunContextPreservesSelectedInspectorNode() throws {
        let controller = WorkflowBuilderViewController()
        controller.loadViewIfNeeded()

        let canvas = try XCTUnwrap(controller.view.firstSubview(of: WorkflowCanvasView.self))
        let inspector = try XCTUnwrap(controller.view.firstSubview(of: WorkflowNodeInspectorView.self))
        var graph = controller.graph
        let node = graph.addNode(type: .fastpTrim, position: .zero)
        controller.graph = graph

        canvas.selectNode(node.id)
        controller.configureRunContext(
            projectURL: try makeTemporaryDirectory().appendingPathComponent("Project.lungfish", isDirectory: true),
            preferredSampleURL: nil
        )
        inspector.testingSetParameter("quality", value: "30")

        XCTAssertEqual(controller.graph.getNode(node.id)?.parameters["quality"], "30")
    }

    private func workflowBuilderWindow() -> NSWindow? {
        NSApp.windows.first { $0.accessibilityIdentifier() == "WorkflowBuilderWindow" }
    }

    private func closeWorkflowBuilderWindows() {
        for window in NSApp.windows where window.accessibilityIdentifier() == "WorkflowBuilderWindow" {
            window.close()
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-workflow-builder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}

@MainActor
private final class WorkflowCanvasDelegateSpy: WorkflowCanvasViewDelegate {
    var modifiedCount = 0

    func canvasView(_ canvasView: WorkflowCanvasView, didSelectNode node: WorkflowNode?) {}

    func canvasView(_ canvasView: WorkflowCanvasView, didSelectConnection connection: WorkflowConnection?) {}

    func canvasViewDidModifyGraph(_ canvasView: WorkflowCanvasView) {
        modifiedCount += 1
    }
}

private extension NSView {
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        if let view = self as? T {
            return view
        }
        for subview in subviews {
            if let match = subview.firstSubview(of: type) {
                return match
            }
        }
        return nil
    }
}

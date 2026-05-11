import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishWorkflow

@MainActor
final class WorkflowBuilderAppIntegrationTests: XCTestCase {

    func testWorkflowBuilderMenuActionOpensReusableWindow() throws {
        let _ = NSApplication.shared
        AppSettings.shared.experimentalFeaturesEnabled = true
        closeWorkflowBuilderWindows()
        addTeardownBlock { @MainActor in
            self.closeWorkflowBuilderWindows()
            AppSettings.shared.experimentalFeaturesEnabled = AppSettings.defaultExperimentalFeaturesEnabled
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

    func testWorkflowBuilderShowsExperimentalBanner() throws {
        let controller = WorkflowBuilderViewController()
        controller.loadViewIfNeeded()

        let banner = try XCTUnwrap(
            controller.view.firstSubview(withAccessibilityIdentifier: WorkflowBuilderAccessibilityID.experimentalBanner)
        )

        XCTAssertFalse(banner.isHidden)
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

    func testBuilderWorkflowLibraryLoadsProjectWorkflowsAndSelection() throws {
        let projectURL = try makeTemporaryDirectory().appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let alphaURL = try WorkflowLibraryStore.createWorkflow(WorkflowGraph(name: "Alpha Workflow"), in: projectURL)
        _ = try WorkflowLibraryStore.createWorkflow(WorkflowGraph(name: "Beta Workflow"), in: projectURL)

        let controller = WorkflowBuilderViewController()
        controller.loadViewIfNeeded()
        controller.configureRunContext(projectURL: projectURL, preferredSampleURL: nil)
        let library = try XCTUnwrap(controller.view.firstSubview(of: WorkflowLibraryView.self))

        XCTAssertEqual(library.workflowNamesForTesting, ["Alpha Workflow", "Beta Workflow"])

        library.testingSelectWorkflow(named: "Alpha Workflow")

        XCTAssertEqual(controller.graph.name, "Alpha Workflow")
        XCTAssertEqual(controller.workflowURL, alphaURL)
    }

    func testBuilderWorkflowLibraryCreatesDuplicatesAndDeletesWorkflows() throws {
        let projectURL = try makeTemporaryDirectory().appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let controller = WorkflowBuilderViewController()
        controller.loadViewIfNeeded()
        controller.configureRunContext(projectURL: projectURL, preferredSampleURL: nil)

        let createdURL = try controller.createWorkflowInLibraryForTesting(named: "QC Workflow")
        XCTAssertEqual(controller.workflowURL, createdURL)
        XCTAssertEqual(controller.graph.name, "QC Workflow")

        let duplicatedURL = try controller.duplicateSelectedWorkflowInLibraryForTesting()
        XCTAssertEqual(controller.workflowURL, duplicatedURL)
        XCTAssertEqual(controller.graph.name, "QC Workflow Copy")

        try controller.deleteSelectedWorkflowInLibraryForTesting()

        XCTAssertNil(controller.workflowURL)
        XCTAssertEqual(controller.graph.name, "New Workflow")
        XCTAssertEqual(try WorkflowLibraryStore.listWorkflows(in: projectURL).map(\.name), ["QC Workflow"])
    }

    func testBuilderWorkflowLibraryRenamesSelectedWorkflow() throws {
        let projectURL = try makeTemporaryDirectory().appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let controller = WorkflowBuilderViewController()
        controller.loadViewIfNeeded()
        controller.configureRunContext(projectURL: projectURL, preferredSampleURL: nil)
        _ = try controller.createWorkflowInLibraryForTesting(named: "Untitled Workflow")

        let renamedURL = try controller.renameSelectedWorkflowInLibraryForTesting(to: "VSP2 Builder Exemplar")

        XCTAssertEqual(controller.workflowURL, renamedURL)
        XCTAssertEqual(controller.graph.name, "VSP2 Builder Exemplar")
        XCTAssertEqual(try WorkflowLibraryStore.listWorkflows(in: projectURL).map(\.name), ["VSP2 Builder Exemplar"])
    }

    func testWorkflowLibraryViewExposesRenameThroughContextMenuAndInlineEditing() throws {
        let projectURL = try makeTemporaryDirectory().appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        _ = try WorkflowLibraryStore.createWorkflow(WorkflowGraph(name: "QC Workflow"), in: projectURL)

        let library = WorkflowLibraryView()
        library.setEntries(try WorkflowLibraryStore.listWorkflows(in: projectURL), selectedBundleURL: nil)
        library.testingSelectWorkflow(named: "QC Workflow")

        XCTAssertTrue(library.contextMenuTitlesForTesting.contains("Rename"))
        XCTAssertTrue(library.isNameColumnEditableForTesting)
        XCTAssertTrue(library.contextMenuActionsTargetLibraryForTesting)
    }

    func testWorkflowLibraryViewSelectsRightClickedRowBeforeContextMenuActions() throws {
        let projectURL = try makeTemporaryDirectory().appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        _ = try WorkflowLibraryStore.createWorkflow(WorkflowGraph(name: "Alpha Workflow"), in: projectURL)
        _ = try WorkflowLibraryStore.createWorkflow(WorkflowGraph(name: "Beta Workflow"), in: projectURL)

        let library = WorkflowLibraryView()
        library.setEntries(try WorkflowLibraryStore.listWorkflows(in: projectURL), selectedBundleURL: nil)

        library.testingSelectContextMenuRow(at: 1)

        XCTAssertEqual(library.selectedEntryForTesting?.name, "Beta Workflow")
    }

    func testBuilderCreatingLibraryWorkflowPreservesDirtyCurrentGraph() throws {
        let projectURL = try makeTemporaryDirectory().appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let controller = WorkflowBuilderViewController()
        controller.loadViewIfNeeded()
        controller.configureRunContext(projectURL: projectURL, preferredSampleURL: nil)
        controller.graph = WorkflowGraph(name: "Dirty Workflow")
        controller.canvasViewDidModifyGraph(WorkflowCanvasView())

        _ = try controller.createWorkflowInLibraryForTesting(named: "Next Workflow")

        XCTAssertEqual(try WorkflowLibraryStore.listWorkflows(in: projectURL).map(\.name), ["Dirty Workflow", "Next Workflow"])
    }

    func testBuilderDuplicateIncludesDirtyCurrentWorkflowEdits() throws {
        let projectURL = try makeTemporaryDirectory().appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)

        let controller = WorkflowBuilderViewController()
        controller.loadViewIfNeeded()
        controller.configureRunContext(projectURL: projectURL, preferredSampleURL: nil)
        _ = try controller.createWorkflowInLibraryForTesting(named: "QC Workflow")
        var edited = controller.graph
        edited.name = "QC Workflow Edited"
        controller.graph = edited
        controller.canvasViewDidModifyGraph(WorkflowCanvasView())

        let duplicateURL = try controller.duplicateSelectedWorkflowInLibraryForTesting()

        XCTAssertEqual(try WorkflowLibraryStore.loadWorkflow(from: duplicateURL).name, "QC Workflow Edited Copy")
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

    func testExplicitFastqBundleWorkflowResolvesInputNodeAsRunSample() throws {
        let projectURL = try makeTemporaryDirectory().appendingPathComponent("Project.lungfish", isDirectory: true)
        let inputBundleURL = projectURL
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: inputBundleURL, withIntermediateDirectories: true)

        let controller = WorkflowBuilderViewController()
        controller.loadViewIfNeeded()
        controller.configureRunContext(projectURL: projectURL, preferredSampleURL: nil)
        controller.graph = try VSP2WorkflowTemplate.makeGraph(inputBundleRelativePath: "@/Imports/sample.lungfishfastq")

        XCTAssertEqual(
            controller.explicitFASTQBundleInputURLForTesting(projectURL: projectURL),
            inputBundleURL.standardizedFileURL
        )
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

    func testCanvasDragsNodeFromCardBodyThroughCanvasInteraction() throws {
        let canvas = WorkflowCanvasView()
        var graph = WorkflowGraph(name: "Drag Test")
        let node = graph.addNode(type: .fastpDedup, position: CGPoint(x: 120, y: 160))
        canvas.graph = graph
        canvas.snapToGrid = false

        let frame = try XCTUnwrap(canvas.nodeFrameForTesting(node.id))
        canvas.testingMouseDown(at: CGPoint(x: frame.midX, y: frame.midY))
        canvas.testingMouseDragged(to: CGPoint(x: frame.midX + 48, y: frame.midY + 32))
        canvas.testingMouseUp(at: CGPoint(x: frame.midX + 48, y: frame.midY + 32))

        let moved = try XCTUnwrap(canvas.graph.getNode(node.id))
        XCTAssertEqual(moved.position.x, 168, accuracy: 0.001)
        XCTAssertEqual(moved.position.y, 192, accuracy: 0.001)
    }

    func testCanvasConnectsOperationOutputToOperationInputByDraggingPorts() throws {
        let canvas = WorkflowCanvasView()
        var graph = WorkflowGraph(name: "Connection Test")
        let dedup = graph.addNode(type: .fastpDedup, position: CGPoint(x: 120, y: 120))
        let align = graph.addNode(type: .alignment, position: CGPoint(x: 380, y: 120))
        canvas.graph = graph

        let sourcePoint = try XCTUnwrap(canvas.portPointForTesting(nodeID: dedup.id, portID: "deduplicated", direction: .output))
        let targetPoint = try XCTUnwrap(canvas.portPointForTesting(nodeID: align.id, portID: "reads", direction: .input))

        canvas.testingMouseDown(at: sourcePoint)
        canvas.testingMouseDragged(to: targetPoint)
        canvas.testingMouseUp(at: targetPoint)

        let connection = try XCTUnwrap(canvas.graph.allConnections.first)
        XCTAssertEqual(connection.sourceNodeId, dedup.id)
        XCTAssertEqual(connection.sourcePortId, "deduplicated")
        XCTAssertEqual(connection.targetNodeId, align.id)
        XCTAssertEqual(connection.targetPortId, "reads")
    }

    func testCanvasConnectsWhenDraggingFromInputPortToOutputPort() throws {
        let canvas = WorkflowCanvasView()
        var graph = WorkflowGraph(name: "Reverse Connection Test")
        let dedup = graph.addNode(type: .fastpDedup, position: CGPoint(x: 120, y: 120))
        let align = graph.addNode(type: .alignment, position: CGPoint(x: 380, y: 120))
        canvas.graph = graph

        let inputPoint = try XCTUnwrap(canvas.portPointForTesting(nodeID: align.id, portID: "reads", direction: .input))
        let outputPoint = try XCTUnwrap(canvas.portPointForTesting(nodeID: dedup.id, portID: "deduplicated", direction: .output))

        canvas.testingMouseDown(at: inputPoint)
        canvas.testingMouseDragged(to: outputPoint)
        canvas.testingMouseUp(at: outputPoint)

        let connection = try XCTUnwrap(canvas.graph.allConnections.first)
        XCTAssertEqual(connection.sourceNodeId, dedup.id)
        XCTAssertEqual(connection.targetNodeId, align.id)
    }

    func testCanvasPanDeltaRespectsScrollDirectionPreferences() throws {
        let natural = WorkflowCanvasView.panDeltaForTesting(
            scrollingDeltaX: 12,
            scrollingDeltaY: 8,
            horizontalPreference: .natural,
            verticalPreference: .natural,
            isDirectionInvertedFromDevice: false
        )
        let traditional = WorkflowCanvasView.panDeltaForTesting(
            scrollingDeltaX: 12,
            scrollingDeltaY: 8,
            horizontalPreference: .traditional,
            verticalPreference: .traditional,
            isDirectionInvertedFromDevice: true
        )
        let systemNatural = WorkflowCanvasView.panDeltaForTesting(
            scrollingDeltaX: 12,
            scrollingDeltaY: 8,
            horizontalPreference: .system,
            verticalPreference: .system,
            isDirectionInvertedFromDevice: true
        )

        XCTAssertEqual(natural.x, -12, accuracy: 0.001)
        XCTAssertEqual(natural.y, -8, accuracy: 0.001)
        XCTAssertEqual(traditional.x, 12, accuracy: 0.001)
        XCTAssertEqual(traditional.y, 8, accuracy: 0.001)
        XCTAssertEqual(systemNatural.x, -12, accuracy: 0.001)
        XCTAssertEqual(systemNatural.y, -8, accuracy: 0.001)
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

    func testInspectorOffersProjectFASTQBundlesWithoutFinderChooser() throws {
        let project = try makeTemporaryDirectory().appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("sample.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        let inspector = WorkflowNodeInspectorView()
        inspector.inspect(
            node: WorkflowNode(type: .fastqBundleInput, position: .zero),
            activeProjectURL: project
        )

        XCTAssertEqual(inspector.projectFASTQBundleOptionsForTesting.map(\.projectRelativePath), ["@/Imports/sample.lungfishfastq"])
        XCTAssertNil(inspector.firstButtonForTesting(titled: "Choose..."))
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

    func testNodeViewLetsCanvasReceivePortClicksForConnectionsButHandlesCardClicks() throws {
        let nodeView = WorkflowNodeView(node: WorkflowNode(type: .fastqBundleInput, position: .zero))
        nodeView.frame = NSRect(origin: .zero, size: nodeView.intrinsicContentSize)

        let portPoint = NSPoint(x: nodeView.bounds.maxX - 6, y: 46)
        XCTAssertEqual(nodeView.portAtPoint(portPoint), "reads")
        XCTAssertNil(nodeView.hitTest(portPoint))

        let titlePoint = NSPoint(x: 24, y: 14)
        XCTAssertNil(nodeView.hitTest(titlePoint))
    }

    func testWorkflowOperationDialogBridgeAppliesFullDialogStateToNativeNodeParameters() throws {
        var node = WorkflowNode(type: .fastpTrim, position: .zero)
        let state = FASTQOperationDialogState(
            initialCategory: .trimmingFiltering,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")]
        )
        state.selectTool(.fastpTrim)
        state.qualityTrimThreshold = 27
        state.qualityTrimWindowSize = 7
        state.adapterRemovalMode = .autoDetect

        WorkflowBuilderOperationDialogBridge.apply(state: state, to: &node)

        XCTAssertEqual(node.parameters["quality"], "27")
        XCTAssertEqual(node.parameters["window"], "7")
        XCTAssertEqual(node.parameters["detectAdapter"], "true")
    }

    func testWorkflowAnalysisNodesCanChooseAnyFASTQOperationsDialogTool() throws {
        let available = WorkflowBuilderOperationDialogBridge.availableToolIDs(for: .alignment)

        XCTAssertTrue(available.contains(.minimap2))
        XCTAssertTrue(available.contains(.spades))
        XCTAssertTrue(available.contains(.kraken2))
        XCTAssertTrue(available.contains(.fastpTrim))
    }

    func testWorkflowAnalysisOperationDialogStateListsAllAllowedTools() throws {
        let state = FASTQOperationDialogState(
            initialCategory: .alignment,
            selectedInputURLs: [URL(fileURLWithPath: "/tmp/sample.lungfishfastq")],
            availableToolIDs: WorkflowBuilderOperationDialogBridge.availableToolIDs(for: .alignment)
        )

        let sidebarIDs = state.sidebarItems.map(\.id)
        XCTAssertTrue(sidebarIDs.contains(FASTQOperationToolID.minimap2.rawValue))
        XCTAssertTrue(sidebarIDs.contains(FASTQOperationToolID.spades.rawValue))
        XCTAssertTrue(sidebarIDs.contains(FASTQOperationToolID.kraken2.rawValue))
        XCTAssertTrue(sidebarIDs.contains(FASTQOperationToolID.fastpTrim.rawValue))

        state.selectTool(.kraken2)

        XCTAssertEqual(state.selectedCategory, .classification)
        XCTAssertEqual(state.selectedToolID, .kraken2)
    }

    func testWorkflowBuilderConfigureDialogOnlyExposesSelectedTool() throws {
        var node = WorkflowNode(type: .alignment, position: .zero)
        node.parameters[WorkflowBuilderOperationDialogBridge.toolIDParameter] = FASTQOperationToolID.bwaMem2.rawValue

        let available = WorkflowBuilderOperationDialogBridge.configureDialogToolIDs(for: node)

        XCTAssertEqual(available, [.bwaMem2])
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

    func firstSubview(withAccessibilityIdentifier identifier: String) -> NSView? {
        if accessibilityIdentifier() == identifier {
            return self
        }
        for subview in subviews {
            if let match = subview.firstSubview(withAccessibilityIdentifier: identifier) {
                return match
            }
        }
        return nil
    }
}

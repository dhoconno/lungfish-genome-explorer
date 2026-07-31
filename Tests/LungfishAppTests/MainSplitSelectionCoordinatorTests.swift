import XCTest
import LungfishCore
@testable import LungfishGenotypeUI
import LungfishIO
@testable import LungfishApp
import LungfishKit

@MainActor
final class MainSplitSelectionCoordinatorTests: XCTestCase {
    func testActualSidebarRestoresCommittedSelectionWhileAsyncPreflightIsCancelled() {
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let first = SidebarItem(
            title: "First",
            type: .document,
            url: URL(fileURLWithPath: "/tmp/First.txt")
        )
        let second = SidebarItem(
            title: "Second",
            type: .document,
            url: URL(fileURLWithPath: "/tmp/Second.txt")
        )
        let third = SidebarItem(
            title: "Third",
            type: .document,
            url: URL(fileURLWithPath: "/tmp/Third.txt")
        )
        sidebar.rootItems = [first, second, third]
        sidebar.reloadData()
        let delegate = SidebarSelectionPreflightSpy()
        sidebar.selectionDelegate = delegate

        sidebar.outlineView.selectRowIndexes(
            IndexSet(integer: 0),
            byExtendingSelection: false
        )
        sidebar.outlineViewSelectionDidChange(
            Notification(
                name: NSOutlineView.selectionDidChangeNotification,
                object: sidebar.outlineView
            )
        )
        XCTAssertEqual(sidebar.selectedItems().map(\.title), ["First"])
        delegate.selectionCallbacks.removeAll()
        delegate.shouldDefer = true

        sidebar.outlineView.selectRowIndexes(
            IndexSet([1, 2]),
            byExtendingSelection: false
        )
        sidebar.outlineViewSelectionDidChange(
            Notification(
                name: NSOutlineView.selectionDidChangeNotification,
                object: sidebar.outlineView
            )
        )

        XCTAssertEqual(sidebar.selectedItems().map(\.title), ["First"])
        XCTAssertTrue(delegate.selectionCallbacks.isEmpty)
        XCTAssertNotNil(delegate.pendingCommit)

        sidebar.outlineView.deselectAll(nil)
        sidebar.outlineViewSelectionDidChange(
            Notification(
                name: NSOutlineView.selectionDidChangeNotification,
                object: sidebar.outlineView
            )
        )

        XCTAssertEqual(sidebar.selectedItems().map(\.title), ["First"])
        XCTAssertTrue(delegate.selectionCallbacks.isEmpty)
    }

    func testSidebarClearContainerMultiItemAndRefreshCancelPreserveViewportAndEditor()
        async throws
    {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SidebarManualHaplotype-\(UUID().uuidString).lungfishgenotype",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )
        let controller = MainSplitViewController()
        _ = controller.view
        let selectedItem = SidebarItem(
            title: "Genotypes",
            type: .genotypeResultBundle,
            url: bundleURL
        )
        let folderA = SidebarItem(
            title: "Folder A",
            type: .folder,
            url: URL(fileURLWithPath: "/tmp/Folder-A")
        )
        let folderB = SidebarItem(
            title: "Folder B",
            type: .folder,
            url: URL(fileURLWithPath: "/tmp/Folder-B")
        )
        let document = SidebarItem(
            title: "Document",
            type: .document,
            url: URL(fileURLWithPath: "/tmp/Document.txt")
        )
        let sidebar = controller.sidebarController!
        sidebar.selectionDelegate = nil
        sidebar.rootItems = [
            selectedItem,
            folderA,
            folderB,
            document,
        ]
        sidebar.reloadData()
        sidebar.outlineView.selectRowIndexes(
            IndexSet(integer: 0),
            byExtendingSelection: false
        )
        sidebar.outlineViewSelectionDidChange(
            Notification(
                name: NSOutlineView.selectionDidChangeNotification,
                object: sidebar.outlineView
            )
        )
        sidebar.selectionDelegate = controller

        let genotypeController =
            controller.viewerController.displayGenotypeResult(
                makeGenotypeResult(bundleURL: bundleURL)
            )
        genotypeController.testingSelectMatrixColumn(
            sample: "SampleA"
        )
        genotypeController.testingUpdateManualHaplotypeLabel(
            "Unsaved"
        )
        genotypeController
            .testingSetManualHaplotypeDraftDecisionProvider {
                _ in .cancel
            }
        let originalSelection =
            genotypeController.testingCurrentSelectionMatrixTargets

        func assertPreserved(
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(
                sidebar.selectedItems().map(\.title),
                ["Genotypes"],
                file: file,
                line: line
            )
            XCTAssertTrue(
                controller.viewerController
                    .genotypeResultViewController
                    === genotypeController,
                file: file,
                line: line
            )
            XCTAssertEqual(
                genotypeController
                    .testingCurrentSelectionMatrixTargets,
                originalSelection,
                file: file,
                line: line
            )
            XCTAssertTrue(
                genotypeController
                    .testingManualHaplotypeEditorIsDirty,
                file: file,
                line: line
            )
            XCTAssertEqual(
                genotypeController
                    .testingManualHaplotypeEditorSample,
                "SampleA",
                file: file,
                line: line
            )
        }

        sidebar.outlineView.deselectAll(nil)
        sidebar.outlineViewSelectionDidChange(
            Notification(
                name: NSOutlineView.selectionDidChangeNotification,
                object: sidebar.outlineView
            )
        )
        await genotypeController
            .testingWaitForManualHaplotypeTransitions()
        assertPreserved()

        sidebar.outlineView.selectRowIndexes(
            IndexSet([1, 2]),
            byExtendingSelection: false
        )
        sidebar.outlineViewSelectionDidChange(
            Notification(
                name: NSOutlineView.selectionDidChangeNotification,
                object: sidebar.outlineView
            )
        )
        await genotypeController
            .testingWaitForManualHaplotypeTransitions()
        assertPreserved()

        sidebar.outlineView.selectRowIndexes(
            IndexSet([2, 3]),
            byExtendingSelection: false
        )
        sidebar.outlineViewSelectionDidChange(
            Notification(
                name: NSOutlineView.selectionDidChangeNotification,
                object: sidebar.outlineView
            )
        )
        await genotypeController
            .testingWaitForManualHaplotypeTransitions()
        assertPreserved()

        sidebar.handleSelectionRefresh(
            [selectedItem],
            source: "test"
        )
        await genotypeController
            .testingWaitForManualHaplotypeTransitions()
        assertPreserved()
    }

    func testGenotypeDisplayLoadsAsynchronouslyAndCancelledSelectionCannotInstallStaleResult() async {
        let controller = MainSplitViewController()
        _ = controller.view
        let staleURL = URL(fileURLWithPath: "/tmp/stale.lungfishgenotype")
        let staleResult = makeGenotypeResult(bundleURL: staleURL)
        controller.genotypeResultLoader = { _ in
            try? await Task.sleep(for: .milliseconds(100))
            return staleResult
        }
        controller.inspectorController.viewModel.selectedItem = "Current Selection"
        var mainActorHeartbeat = false
        DispatchQueue.main.async { mainActorHeartbeat = true }

        controller.testingDisplayGenotypeResultBundle(staleURL)
        _ = controller.testingBeginDisplayRequest(
            identity: ContentSelectionIdentity(
                url: URL(fileURLWithPath: "/tmp/newer.nvd"),
                kind: "nvdResult"
            )
        )
        await Task.yield()
        XCTAssertTrue(mainActorHeartbeat, "Starting genotype validation must yield the main actor")
        try? await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(controller.inspectorController.viewModel.selectedItem, "Current Selection")
        XCTAssertNil(controller.viewerController.genotypeResultViewController)
    }

    func testShowInspectorRequestIgnoresScopedNotificationFromDifferentWindow() {
        let controller = MainSplitViewController()
        _ = controller.view
        controller.setInspectorVisible(false, animated: false, source: "test.hide")

        NotificationCenter.default.post(
            name: .showInspectorRequested,
            object: nil,
            userInfo: [NotificationUserInfoKey.windowStateScope: WindowStateScope()]
        )

        XCTAssertFalse(controller.isInspectorVisible)
    }

    func testShowInspectorRequestStillAcceptsLegacyUnscopedNotification() {
        let controller = MainSplitViewController()
        _ = controller.view
        controller.setInspectorVisible(false, animated: false, source: "test.hide")

        NotificationCenter.default.post(name: .showInspectorRequested, object: nil)

        XCTAssertTrue(controller.isInspectorVisible)
    }

    func testBundleDidLoadIgnoresScopedNotificationFromDifferentWindow() {
        let controller = MainSplitViewController()
        _ = controller.view
        controller.setInspectorVisible(false, animated: false, source: "test.hide")

        NotificationCenter.default.post(
            name: .bundleDidLoad,
            object: nil,
            userInfo: [NotificationUserInfoKey.windowStateScope: WindowStateScope()]
        )

        XCTAssertFalse(controller.isInspectorVisible)
    }

    func testChromosomeInspectorRequestIgnoresScopedNotificationFromDifferentWindow() {
        let controller = MainSplitViewController()
        _ = controller.view
        controller.setInspectorVisible(false, animated: false, source: "test.hide")

        NotificationCenter.default.post(
            name: .chromosomeInspectorRequested,
            object: nil,
            userInfo: [NotificationUserInfoKey.windowStateScope: WindowStateScope()]
        )

        XCTAssertFalse(controller.isInspectorVisible)
    }

    func testStaleDelayedSelectionCommitCannotMutateInspectorAfterNewerSelectionBecomesActive() {
        let controller = MainSplitViewController()
        _ = controller.view

        let first = ContentSelectionIdentity(
            url: URL(fileURLWithPath: "/tmp/A.naomgs"),
            kind: "naoMgsResult"
        )
        let second = ContentSelectionIdentity(
            url: URL(fileURLWithPath: "/tmp/B.nvd"),
            kind: "nvdResult"
        )

        let firstToken = controller.testingBeginDisplayRequest(identity: first)
        let secondToken = controller.testingBeginDisplayRequest(identity: second)
        controller.inspectorController.viewModel.selectedItem = "Current"

        controller.testingCommitDisplayRequest(firstToken, identity: first) {
            controller.inspectorController.viewModel.selectedItem = "Stale"
        }

        XCTAssertEqual(controller.inspectorController.viewModel.selectedItem, "Current")

        controller.testingCommitDisplayRequest(secondToken, identity: second) {
            controller.inspectorController.viewModel.selectedItem = "Fresh"
        }

        XCTAssertEqual(controller.inspectorController.viewModel.selectedItem, "Fresh")
    }

    private func makeGenotypeResult(bundleURL: URL) -> ONTGenotypeResultBundleData {
        let call = ONTGenotypeCall(
            sample: "SampleA",
            genotype: "known-allele",
            passedAlignments: 8,
            passedUniqueReads: 8,
            sampleTotalReads: 8,
            sampleUniqueRetainedReads: 8,
            sampleUniqueRetainedPercent: 100,
            overallInputReads: 8,
            overallUniqueRetainedReads: 8,
            overallUniqueRetainedPercent: 100
        )
        return ONTGenotypeResultBundleData(
            bundleURL: bundleURL,
            manifest: ONTGenotypeResultBundleManifest(
                kind:
                    GenotypeResultWorkflowKind
                        .miSeqAmpliconMHCGenotype.rawValue,
                outputName: "stale",
                analysisName: "stale",
                primaryWorkbookPath: "stale.xlsx",
                longSummaryCSVPath: "calls.csv",
                sampleSummaryCSVPath: "samples.csv",
                statsJSONPath: "stats.json",
                provenancePath: "provenance.json"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: bundleURL.appendingPathComponent("stale.xlsx"),
                longSummaryCSVURL: bundleURL.appendingPathComponent("calls.csv"),
                sampleSummaryCSVURL: bundleURL.appendingPathComponent("samples.csv"),
                statsJSONURL: bundleURL.appendingPathComponent("stats.json"),
                provenanceURL: bundleURL.appendingPathComponent("provenance.json")
            ),
            stats: ONTGenotypeRunStats(),
            calls: [call],
            samples: []
        )
    }

    func testContextMenuOpenRoutesThroughExplicitDisplayDelegate() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MainSplitContextMenu-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let fastaURL = projectURL.appendingPathComponent("example.fasta")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try ">seq\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let delegate = SidebarSelectionSpy()
        sidebar.selectionDelegate = delegate

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)
        XCTAssertTrue(sidebar.selectItem(forURL: fastaURL))
        delegate.selectedItems.removeAll()

        sidebar.perform(NSSelectorFromString("contextMenuOpen:"), with: nil)

        XCTAssertEqual(
            delegate.selectedItems.compactMap { $0.url?.resolvingSymlinksInPath() },
            [fastaURL.resolvingSymlinksInPath()]
        )
    }

    func testContextMenuShowInInspectorIncludesWindowScope() throws {
        let (tempRoot, projectURL, fastaURL) = try makeSidebarProjectFixture(prefix: "MainSplitShowInspector")
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let scope = WindowStateScope()
        sidebar.windowStateScope = scope

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)
        XCTAssertTrue(sidebar.selectItem(forURL: fastaURL))

        let capture = MainSplitNotificationUserInfoCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .showInspectorRequested,
            object: sidebar,
            queue: nil
        ) { notification in
            capture.record(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        sidebar.perform(NSSelectorFromString("contextMenuShowInInspector:"), with: nil)

        XCTAssertEqual(capture.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope, scope)
    }

    func testNavigateToSidebarItemIgnoresScopedNotificationFromDifferentWindow() throws {
        let (tempRoot, projectURL, fastaURL) = try makeSidebarProjectFixture(prefix: "MainSplitNavigateScoped")
        let otherURL = projectURL.appendingPathComponent("other.fasta")
        try ">other\nTGCA\n".write(to: otherURL, atomically: true, encoding: .utf8)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        sidebar.windowStateScope = WindowStateScope()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)
        XCTAssertTrue(sidebar.selectItem(forURL: fastaURL))

        NotificationCenter.default.post(
            name: .navigateToSidebarItem,
            object: nil,
            userInfo: [
                "url": otherURL,
                NotificationUserInfoKey.windowStateScope: WindowStateScope(),
            ]
        )

        XCTAssertEqual(sidebar.selectedFileURL?.resolvingSymlinksInPath(), fastaURL.resolvingSymlinksInPath())
    }

    func testNavigateToSidebarItemStillAcceptsLegacyUnscopedNotification() throws {
        let (tempRoot, projectURL, fastaURL) = try makeSidebarProjectFixture(prefix: "MainSplitNavigateLegacy")
        let otherURL = projectURL.appendingPathComponent("other.fasta")
        try ">other\nTGCA\n".write(to: otherURL, atomically: true, encoding: .utf8)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        sidebar.windowStateScope = WindowStateScope()

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)
        XCTAssertTrue(sidebar.selectItem(forURL: fastaURL))

        NotificationCenter.default.post(
            name: .navigateToSidebarItem,
            object: nil,
            userInfo: ["url": otherURL]
        )

        XCTAssertEqual(sidebar.selectedFileURL?.resolvingSymlinksInPath(), otherURL.resolvingSymlinksInPath())
    }

    func testSidebarPreferredWidthRecommendationIncludesWindowScope() throws {
        let (tempRoot, projectURL, _) = try makeSidebarProjectFixture(prefix: "SidebarWidthScope")
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let scope = WindowStateScope()
        sidebar.windowStateScope = scope

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let capture = MainSplitNotificationUserInfoCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .sidebarPreferredWidthRecommended,
            object: sidebar,
            queue: nil
        ) { notification in
            capture.record(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        sidebar.openProject(at: projectURL)
        if capture.userInfo == nil {
            let longNameURL = projectURL.appendingPathComponent(
                "a-very-long-sidebar-label-that-forces-a-new-width-recommendation-\(UUID().uuidString).fasta"
            )
            try ">long\nACGT\n".write(to: longNameURL, atomically: true, encoding: .utf8)
            sidebar.reloadFromFilesystem()
        }

        XCTAssertEqual(capture.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope, scope)
    }

    func testSidebarReloadReportsUnchangedSelectionAsFilesystemRefresh() throws {
        let (tempRoot, projectURL, fastaURL) = try makeSidebarProjectFixture(prefix: "SidebarRefreshSelection")
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let delegate = SidebarSelectionSpy()
        sidebar.selectionDelegate = delegate

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)
        XCTAssertTrue(sidebar.selectItem(forURL: fastaURL))
        delegate.selectedItems.removeAll()
        delegate.refreshedItems.removeAll()

        sidebar.reloadFromFilesystem()

        XCTAssertEqual(
            delegate.refreshedItems.compactMap { $0.url?.resolvingSymlinksInPath() },
            [fastaURL.resolvingSymlinksInPath()]
        )
        XCTAssertTrue(delegate.selectedItems.isEmpty)
    }

    func testSidecarOnlyFASTQMetadataChangeRefreshesSelectedPayload() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarSidecarRefresh-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let fastqURL = projectURL.appendingPathComponent("reads.fastq")
        let sidecarURL = fastqURL.appendingPathExtension("lungfish-meta.json")
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try "@r1\nACGT\n+\n!!!!\n".write(to: fastqURL, atomically: true, encoding: .utf8)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let delegate = SidebarSelectionSpy()
        sidebar.selectionDelegate = delegate

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)
        XCTAssertTrue(sidebar.selectItem(forURL: fastqURL))
        delegate.selectedItems.removeAll()
        delegate.refreshedItems.removeAll()

        ProjectFilesystemRefreshCoordinator.shared.testingEmitChange(
            projectURL: projectURL,
            changedPaths: FileSystemWatcher.ChangedPaths(nonSidecar: [], all: [sidecarURL])
        )

        XCTAssertEqual(
            delegate.refreshedItems.compactMap { $0.url?.resolvingSymlinksInPath() },
            [fastqURL.resolvingSymlinksInPath()]
        )
        XCTAssertTrue(delegate.selectedItems.isEmpty)
    }

    func testBundleViewStateSidecarChangeDoesNotRefreshSelectedBundle() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarViewStateRefresh-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let bundleURL = projectURL.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        let viewStateURL = bundleURL.appendingPathComponent(BundleViewState.filename)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let delegate = SidebarSelectionSpy()
        sidebar.selectionDelegate = delegate

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)
        XCTAssertTrue(sidebar.selectItem(forURL: bundleURL))
        delegate.selectedItems.removeAll()
        delegate.refreshedItems.removeAll()

        ProjectFilesystemRefreshCoordinator.shared.testingEmitChange(
            projectURL: projectURL,
            changedPaths: FileSystemWatcher.ChangedPaths(nonSidecar: [], all: [viewStateURL])
        )

        XCTAssertTrue(delegate.refreshedItems.isEmpty)
        XCTAssertTrue(delegate.selectedItems.isEmpty)
    }

    func testBundleDirectoryMetadataChangeDoesNotRefreshSelectedBundle() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarBundleDirectoryRefresh-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let bundleURL = projectURL.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let delegate = SidebarSelectionSpy()
        sidebar.selectionDelegate = delegate

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)
        XCTAssertTrue(sidebar.selectItem(forURL: bundleURL))
        delegate.selectedItems.removeAll()
        delegate.refreshedItems.removeAll()

        ProjectFilesystemRefreshCoordinator.shared.testingEmitChange(
            projectURL: projectURL,
            changedPaths: FileSystemWatcher.ChangedPaths(nonSidecar: [bundleURL], all: [bundleURL])
        )

        XCTAssertTrue(delegate.refreshedItems.isEmpty)
        XCTAssertTrue(delegate.selectedItems.isEmpty)
    }

    func testBundleHiddenAtomicWriteDoesNotRefreshSelectedBundle() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarBundleAtomicRefresh-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let bundleURL = projectURL.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        let tempWriteURL = bundleURL.appendingPathComponent(".viewstate.json.tmp")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let delegate = SidebarSelectionSpy()
        sidebar.selectionDelegate = delegate

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)
        XCTAssertTrue(sidebar.selectItem(forURL: bundleURL))
        delegate.selectedItems.removeAll()
        delegate.refreshedItems.removeAll()

        ProjectFilesystemRefreshCoordinator.shared.testingEmitChange(
            projectURL: projectURL,
            changedPaths: FileSystemWatcher.ChangedPaths(nonSidecar: [tempWriteURL], all: [tempWriteURL])
        )

        XCTAssertTrue(delegate.refreshedItems.isEmpty)
        XCTAssertTrue(delegate.selectedItems.isEmpty)
    }

    func testFilesystemRescanDoesNotRefreshUnchangedSelectedBundle() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarBundleRescanRefresh-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let bundleURL = projectURL.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        ProjectFilesystemRefreshCoordinator.shared.testingSetFullReloadDebounce(.milliseconds(50))

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let delegate = SidebarSelectionSpy()
        sidebar.selectionDelegate = delegate

        defer {
            sidebar.closeProject()
            ProjectFilesystemRefreshCoordinator.shared.testingSetFullReloadDebounce(.milliseconds(500))
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)
        XCTAssertTrue(sidebar.selectItem(forURL: bundleURL))
        delegate.selectedItems.removeAll()
        delegate.refreshedItems.removeAll()

        ProjectFilesystemRefreshCoordinator.shared.testingEmitChange(
            projectURL: projectURL,
            changedPaths: FileSystemWatcher.ChangedPaths(nonSidecar: [], all: [])
        )

        try await Task.sleep(for: .milliseconds(120))

        XCTAssertTrue(delegate.refreshedItems.isEmpty)
        XCTAssertTrue(delegate.selectedItems.isEmpty)
    }

    func testFilesystemRootChangeDoesNotRefreshUnchangedSelectedBundle() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarBundleRootRefresh-\(UUID().uuidString)", isDirectory: true)
        let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let bundleURL = projectURL.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let delegate = SidebarSelectionSpy()
        sidebar.selectionDelegate = delegate

        defer {
            sidebar.closeProject()
            try? FileManager.default.removeItem(at: tempRoot)
        }

        sidebar.openProject(at: projectURL)
        XCTAssertTrue(sidebar.selectItem(forURL: bundleURL))
        delegate.selectedItems.removeAll()
        delegate.refreshedItems.removeAll()

        ProjectFilesystemRefreshCoordinator.shared.testingEmitChange(
            projectURL: projectURL,
            changedPaths: FileSystemWatcher.ChangedPaths(nonSidecar: [projectURL], all: [projectURL])
        )

        XCTAssertTrue(delegate.refreshedItems.isEmpty)
        XCTAssertTrue(delegate.selectedItems.isEmpty)
    }

    func testInspectorDocumentModeRequestAfterDownloadIncludesWindowScope() {
        let controller = MainSplitViewController()
        _ = controller.view

        let capture = MainSplitNotificationUserInfoCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .showInspectorRequested,
            object: nil,
            queue: nil
        ) { notification in
            capture.record(notification)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        controller.testingRequestInspectorDocumentModeAfterDownload()

        XCTAssertEqual(
            capture.userInfo?[NotificationUserInfoKey.windowStateScope] as? WindowStateScope,
            controller.testingWindowStateScope
        )
    }

    func testStaleDatabaseBuildCompletionCannotCommitAfterNewerSelectionBecomesActive() {
        let controller = MainSplitViewController()
        _ = controller.view

        let resultURL = URL(fileURLWithPath: "/tmp/kraken2-batch-stale")
        let databaseBuildRequest = controller.testingBeginDatabaseBuildRequest(
            tool: "Kraken2",
            resultURL: resultURL
        )
        _ = controller.testingBeginDisplayRequest(
            identity: ContentSelectionIdentity(
                url: URL(fileURLWithPath: "/tmp/newer.fasta"),
                kind: "sequence"
            )
        )

        var didCommit = false
        controller.testingCommitDatabaseBuildCompletion(databaseBuildRequest) {
            didCommit = true
        }

        XCTAssertFalse(didCommit)
    }
}

@MainActor
private final class SidebarSelectionSpy: SidebarSelectionDelegate {
    var selectedItems: [SidebarItem] = []
    var refreshedItems: [SidebarItem] = []

    func sidebarDidSelectItem(_ item: SidebarItem?) {
        if let item {
            selectedItems.append(item)
        }
    }

    func sidebarDidSelectItems(_ items: [SidebarItem]) {
        selectedItems.append(contentsOf: items)
    }

    func sidebarDidRefreshSelectedItems(_ items: [SidebarItem]) {
        refreshedItems.append(contentsOf: items)
    }
}

@MainActor
private final class SidebarSelectionPreflightSpy: SidebarSelectionDelegate {
    var shouldDefer = false
    var pendingCommit: (() -> Void)?
    var selectionCallbacks: [[String]] = []

    func sidebarShouldDeferSelectionTransition(
        _ transition: SidebarSelectionTransition,
        commit: @escaping @MainActor () -> Void
    ) -> Bool {
        _ = transition
        guard shouldDefer else { return false }
        pendingCommit = commit
        return true
    }

    func sidebarDidSelectItem(_ item: SidebarItem?) {
        selectionCallbacks.append(item.map { [$0.title] } ?? [])
    }

    func sidebarDidSelectItems(_ items: [SidebarItem]) {
        selectionCallbacks.append(items.map(\.title))
    }
}

private final class MainSplitNotificationUserInfoCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedUserInfo: [AnyHashable: Any]?

    var userInfo: [AnyHashable: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return capturedUserInfo
    }

    func record(_ notification: Notification) {
        lock.lock()
        capturedUserInfo = notification.userInfo
        lock.unlock()
    }
}

private func makeSidebarProjectFixture(prefix: String) throws -> (tempRoot: URL, projectURL: URL, fastaURL: URL) {
    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    let projectURL = tempRoot.appendingPathComponent("Fixture.lungfish", isDirectory: true)
    let fastaURL = projectURL.appendingPathComponent("example.fasta")
    try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    try ">seq\nACGT\n".write(to: fastaURL, atomically: true, encoding: .utf8)
    return (tempRoot, projectURL, fastaURL)
}

import XCTest
@testable import LungfishApp
import LungfishCore

@MainActor
final class OperationRoutingTests: XCTestCase {
    func testBundleCompletionDeliversOriginRouteContext() throws {
        let center = OperationCenter()
        let projectURL = URL(fileURLWithPath: "/tmp/shared.lungfish", isDirectory: true)
        let scope = WindowStateScope()
        let routeContext = OperationRouteContext(projectURL: projectURL, windowStateScope: scope)
        let bundleURL = projectURL.appendingPathComponent("Downloads/example.lungfishref", isDirectory: true)

        var deliveredURLs: [URL]?
        var deliveredContext: OperationRouteContext?
        center.onBundleReadyWithContext = { urls, context in
            deliveredURLs = urls
            deliveredContext = context
        }

        let id = center.start(
            title: "Reference",
            detail: "Downloading",
            operationType: .download,
            routeContext: routeContext
        )
        center.complete(id: id, detail: "Done", bundleURLs: [bundleURL])

        XCTAssertEqual(deliveredURLs, [bundleURL])
        XCTAssertEqual(deliveredContext, routeContext)
        XCTAssertEqual(center.items.first?.routeContext, routeContext)
    }

    func testLegacyBundleCallbackStillFiresWhenNoContextAwareCallbackIsRegistered() {
        let center = OperationCenter()
        let bundleURL = URL(fileURLWithPath: "/tmp/example.lungfishref", isDirectory: true)
        var deliveredURLs: [URL]?
        center.onBundleReady = { deliveredURLs = $0 }

        let id = center.start(title: "Reference", detail: "Downloading")
        center.complete(id: id, detail: "Done", bundleURLs: [bundleURL])

        XCTAssertEqual(deliveredURLs, [bundleURL])
    }

    func testBundleCompletionKeepsRouteContextWhenTrimReordersItems() {
        let center = OperationCenter()
        let projectURL = URL(fileURLWithPath: "/tmp/shared.lungfish", isDirectory: true)
        let firstContext = OperationRouteContext(
            projectURL: projectURL,
            windowStateScope: WindowStateScope()
        )
        let secondContext = OperationRouteContext(
            projectURL: projectURL,
            windowStateScope: WindowStateScope()
        )
        let bundleURL = projectURL.appendingPathComponent("Downloads/second.lungfishref", isDirectory: true)

        var deliveredContext: OperationRouteContext?
        center.onBundleReadyWithContext = { _, context in
            deliveredContext = context
        }

        _ = center.start(
            title: "First",
            detail: "Running",
            operationType: .download,
            routeContext: firstContext
        )
        let secondID = center.start(
            title: "Second",
            detail: "Running",
            operationType: .download,
            routeContext: secondContext
        )

        center.complete(id: secondID, detail: "Done", bundleURLs: [bundleURL])

        XCTAssertEqual(deliveredContext, secondContext)
    }

    func testDownloadImportUsesCentralReadOnlyGuardForRoutedProject() throws {
        let appDelegateURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift")
        let source = try String(contentsOf: appDelegateURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private func handleMultipleDownloadsSync"))
        let end = try XCTUnwrap(source[start.lowerBound...].range(of: "let totalCount = tempFileURLs.count"))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(
            body.contains("canWriteProjectOutputs"),
            "Downloads completing after their origin window closes must re-evaluate read-only state for the routed project URL before writing"
        )
        XCTAssertFalse(
            body.contains("targetController?.projectSession.isReadOnlyRecommended"),
            "The routed project URL, not only a possibly stale window controller, must drive download write guarding"
        )
    }

    func testCopiedBundleImportRehydratesProvenancePathsToFinalProjectLocation() throws {
        let delegate = AppDelegate()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenanceRoute-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let projectURL = temp.appendingPathComponent("Shared.lungfish", isDirectory: true)
        _ = try DocumentManager.shared.createProject(at: projectURL, name: "Shared")
        let snapshot = ProjectWindowSnapshot(
            id: UUID(),
            projectURL: projectURL,
            windowOrdinal: 1,
            windowOrder: 0,
            windowTitleSuffix: "[1]",
            frame: nil,
            isFullScreen: false,
            selectedSidebarURL: nil,
            expandedSidebarURLs: [],
            sidebarSearchText: nil,
            activeContent: nil,
            inspectorTab: nil,
            sidebarCollapsed: false,
            inspectorCollapsed: false,
            sidebarWidth: nil,
            inspectorWidth: nil,
            operationsPanelFilter: nil,
            operationsPanelVisible: false
        )
        XCTAssertTrue(try delegate.testingRestoreProjectWindows(from: ProjectWindowStateEnvelope(windows: [snapshot])))
        let controller = try XCTUnwrap(delegate.testingMainWindowControllers.first)

        let sourceBundle = temp.appendingPathComponent("external.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        let sourcePayload = sourceBundle.appendingPathComponent("payload.fa")
        try ">seq\nAAAA\n".write(to: sourcePayload, atomically: true, encoding: .utf8)
        let provenanceURL = sourceBundle.appendingPathComponent(".lungfish-provenance.json")
        let provenance: [String: Any] = [
            "bundle": sourceBundle.path,
            "outputs": [
                ["path": sourcePayload.path]
            ]
        ]
        let provenanceData = try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted])
        try provenanceData.write(to: provenanceURL)

        delegate.importReadyBundles(
            [sourceBundle],
            routeContext: OperationRouteContext(
                projectURL: projectURL,
                windowStateScope: controller.projectSession.windowStateScope
            )
        )

        let finalBundle = projectURL
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("external.lungfishref", isDirectory: true)
        let finalProvenanceURL = finalBundle.appendingPathComponent(".lungfish-provenance.json")
        let finalData = try Data(contentsOf: finalProvenanceURL)
        let finalJSON = try JSONSerialization.jsonObject(with: finalData) as? [String: Any]
        let outputs = finalJSON?["outputs"] as? [[String: Any]]

        XCTAssertEqual(finalJSON?["bundle"] as? String, finalBundle.path)
        XCTAssertEqual(outputs?.first?["path"] as? String, finalBundle.appendingPathComponent("payload.fa").path)
    }

    func testCopiedFileImportCarriesSourceAdjacentProvenanceSidecar() throws {
        let delegate = AppDelegate()
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProvenanceFileRoute-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let sourceURL = temp.appendingPathComponent("SRR123.fastq")
        let destinationURL = temp.appendingPathComponent("Project/Downloads/SRR123.fastq")
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "@r\nACGT\n+\n!!!!\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        let sourceSidecar = URL(fileURLWithPath: sourceURL.standardizedFileURL.path + ".lungfish-provenance.json")
        let provenance: [String: Any] = [
            "outputs": [
                ["path": sourceURL.standardizedFileURL.path]
            ],
            "reproducibleCommand": "lungfish-cli fetch ncbi SRR123 --save-to \(sourceURL.standardizedFileURL.path)"
        ]
        try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted])
            .write(to: sourceSidecar)

        delegate.testingRehydrateCopiedProvenance(from: sourceURL, to: destinationURL)

        let finalSidecar = URL(fileURLWithPath: destinationURL.standardizedFileURL.path + ".lungfish-provenance.json")
        let finalJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: finalSidecar)) as? [String: Any]
        let outputs = finalJSON?["outputs"] as? [[String: Any]]
        XCTAssertEqual(outputs?.first?["path"] as? String, destinationURL.standardizedFileURL.path)
        XCTAssertEqual(
            finalJSON?["reproducibleCommand"] as? String,
            "lungfish-cli fetch ncbi SRR123 --save-to \(sourceURL.standardizedFileURL.path)"
        )
    }

    func testSampleMetadataImportRoutesThroughOriginContextAndReadOnlyGuard() throws {
        let appDelegateURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift")
        let source = try String(contentsOf: appDelegateURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "@objc func importSampleMetadataToBundle"))
        let end = try XCTUnwrap(source[start.lowerBound...].range(of: "private func performVCFImport"))
        let body = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(body.contains("activeMainWindowController(sender: sender)"))
        XCTAssertTrue(body.contains("currentOperationRouteContext(for: controller)"))
        XCTAssertTrue(body.contains("canWriteProjectOutputs"))
        XCTAssertTrue(body.contains("targetMainWindowController(routeContext: routeContext)"))
        XCTAssertFalse(
            body.contains("mainWindowController?.mainSplitViewController?.viewerController"),
            "Sample metadata import must not route through the global main window in same-project multi-window sessions"
        )
    }

    func testProjectSampleMetadataImportUsesOriginWindowScope() throws {
        let projectURL = URL(fileURLWithPath: "/tmp/project.lungfish", isDirectory: true)
        let scope = WindowStateScope()

        XCTAssertEqual(
            ProjectSampleMetadataModalRouter.importRoute(
                projectURL: projectURL,
                windowStateScope: scope
            ),
            .importSheet(.init(projectURL: projectURL, windowStateScope: scope))
        )
    }

    func testAlignmentAnnotationActionUsesOriginWindow() throws {
        let appDelegateURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift")
        let source = try String(contentsOf: appDelegateURL, encoding: .utf8)
        let body = try sourceFunctionBody(
            named: "@objc func applyAlignmentAnnotationToSelection",
            endingBefore: "private func showAlert",
            in: source
        )

        XCTAssertTrue(body.contains("activeMainWindowController(sender: sender)"))
        XCTAssertTrue(body.contains("controller?.mainSplitViewController?.viewerController"))
        XCTAssertTrue(body.contains("presentingWindow: controller?.window"))
        XCTAssertFalse(
            body.contains("mainWindowController?.mainSplitViewController?.viewerController"),
            "MSA annotation actions must apply to the originating window, not the global main window"
        )

        let viewerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Viewer/ViewerViewController.swift")
        let viewerSource = try String(contentsOf: viewerURL, encoding: .utf8)
        let actionBody = try sourceFunctionBody(
            named: "private func runMSAInPlaceAnnotationAction",
            endingBefore: "func inferTreeFromMSAViaCLI",
            in: viewerSource
        )
        XCTAssertTrue(actionBody.contains("canWriteProjectOutputs(projectURL: projectURL, workflowName: title)"))
        XCTAssertTrue(actionBody.contains("routeContext: OperationRouteContext"))
    }

    func testMetagenomicsImportLaunchesCarryOriginRouteContext() throws {
        let appDelegateURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift")
        let source = try String(contentsOf: appDelegateURL, encoding: .utf8)

        let naoLaunch = try sourceFunctionBody(
            named: "@objc func launchNaoMgsImport",
            endingBefore: "@objc func launchPrimerSchemeImport",
            in: source
        )
        XCTAssertTrue(naoLaunch.contains("activeMainWindowController(sender: sender)"))
        XCTAssertTrue(naoLaunch.contains("currentOperationRouteContext(for: controller)"))
        XCTAssertTrue(naoLaunch.contains("importNaoMgsResultFromURL(resultsDir, routeContext: routeContext)"))
        XCTAssertFalse(naoLaunch.contains("mainWindowController?.window"))

        let primerLaunch = try sourceFunctionBody(
            named: "@objc func launchPrimerSchemeImport",
            endingBefore: "@objc func launchNvdImport",
            in: source
        )
        XCTAssertTrue(primerLaunch.contains("activeMainWindowController(sender: sender)"))
        XCTAssertTrue(primerLaunch.contains("canWriteProjectOutputs"))
        XCTAssertTrue(primerLaunch.contains("windowStateScope: controller.projectSession.windowStateScope"))
        XCTAssertFalse(primerLaunch.contains("mainWindowController?.mainSplitViewController"))

        let nvdLaunch = try sourceFunctionBody(
            named: "@objc func launchNvdImport",
            endingBefore: "@objc func launchCzIdImport",
            in: source
        )
        XCTAssertTrue(nvdLaunch.contains("activeMainWindowController(sender: sender)"))
        XCTAssertTrue(nvdLaunch.contains("currentOperationRouteContext(for: controller)"))
        XCTAssertTrue(nvdLaunch.contains("importNvdResultFromURL(nvdDir, routeContext: routeContext)"))
        XCTAssertFalse(nvdLaunch.contains("mainWindowController?.window"))

        let czIdLaunch = try sourceFunctionBody(
            named: "@objc func launchCzIdImport",
            endingBefore: "func importNvdResultFromURL",
            in: source
        )
        XCTAssertTrue(czIdLaunch.contains("activeMainWindowController(sender: sender)"))
        XCTAssertTrue(czIdLaunch.contains("currentOperationRouteContext(for: controller)"))
        XCTAssertTrue(czIdLaunch.contains("importCzIdResultFromURL(sourceURL, routeContext: routeContext)"))
        XCTAssertFalse(czIdLaunch.contains("mainWindowController?.mainSplitViewController"))

        let nvdImport = try sourceFunctionBody(
            named: "func importNvdResultFromURL",
            endingBefore: "/// Locates the samtools binary",
            in: source
        )
        XCTAssertTrue(nvdImport.contains("targetMainWindowController(routeContext: routeContext)"))
        XCTAssertTrue(nvdImport.contains("routeContext: routeContext"))
        XCTAssertTrue(nvdImport.contains("canWriteProjectOutputs"))
        XCTAssertFalse(nvdImport.contains("mainWindowController?.mainSplitViewController"))

        let czIdImport = try sourceFunctionBody(
            named: "func importCzIdResultFromURL",
            endingBefore: "private func runManagedMapping",
            in: source
        )
        XCTAssertTrue(czIdImport.contains("targetMainWindowController(routeContext: routeContext)"))
        XCTAssertTrue(czIdImport.contains("canWriteProjectOutputs"))
        XCTAssertFalse(czIdImport.contains("mainWindowController?.mainSplitViewController"))
    }

    func testSidebarMetadataMutationsUseWindowScopedWriteGuards() throws {
        let sidebarURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift")
        let source = try String(contentsOf: sidebarURL, encoding: .utf8)

        let sampleImport = try sourceFunctionBody(
            named: "@objc private func contextMenuImportSampleMetadata",
            endingBefore: "@objc private func contextMenuEditFolderMetadata",
            in: source
        )
        XCTAssertTrue(sampleImport.contains("canWriteSidebarProjectOutputs"))

        let folderEdit = try sourceFunctionBody(
            named: "@objc private func contextMenuEditFolderMetadata",
            endingBefore: "@objc private func contextMenuExportProjectMetadata",
            in: source
        )
        XCTAssertTrue(folderEdit.contains("canWriteSidebarProjectOutputs"))
        XCTAssertTrue(folderEdit.contains("windowStateScope: windowStateScope"))

        let projectImport = try sourceFunctionBody(
            named: "@objc private func contextMenuImportProjectMetadata",
            endingBefore: "/// Checks if a bundle URL has variant tracks",
            in: source
        )
        XCTAssertTrue(projectImport.contains("canWriteSidebarProjectOutputs"))
        XCTAssertTrue(projectImport.contains("windowStateScope: windowStateScope"))
    }

    func testSidebarFileOperationsRehydrateScientificProvenanceAfterFinalPathChanges() throws {
        let sidebarURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Sidebar/SidebarViewController.swift")
        let source = try String(contentsOf: sidebarURL, encoding: .utf8)

        let copyBody = try sourceFunctionBody(
            named: "private func copyItems(_ sourceItems: [SidebarItem], toFolderURL destFolderURL: URL, at index: Int) -> Bool",
            endingBefore: "private func uniqueDestinationURL",
            in: source
        )
        XCTAssertTrue(copyBody.contains("rehydrateScientificProvenance"))

        let renameBody = try sourceFunctionBody(
            named: "private func performRename",
            endingBefore: "@objc private func contextMenuDuplicate",
            in: source
        )
        XCTAssertTrue(renameBody.contains("rehydrateScientificProvenance"))

        let duplicateBody = try sourceFunctionBody(
            named: "@objc private func contextMenuDuplicate",
            endingBefore: "// MARK: - FASTQ Export",
            in: source
        )
        XCTAssertTrue(duplicateBody.contains("rehydrateScientificProvenance"))

        let moveBody = try sourceFunctionBody(
            named: "private func moveItems(_ sourceItems: [SidebarItem], toFolderURL destFolderURL: URL, at index: Int) -> Bool",
            endingBefore: "/// Copies an item to a new destination",
            in: source
        )
        XCTAssertTrue(moveBody.contains("rehydrateScientificProvenance"))

        let moveToFolderBody = try sourceFunctionBody(
            named: "@objc private func contextMenuMoveToFolder",
            endingBefore: "// Refresh sidebar",
            in: source
        )
        XCTAssertTrue(moveToFolderBody.contains("rehydrateScientificProvenance"))
    }

    func testAnnotationDrawerVariantAndSampleMetadataWritesUseWindowScopedWriteGuard() throws {
        let drawerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Viewer/AnnotationTableDrawerView.swift")
        let source = try String(contentsOf: drawerURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private func canWriteVariantDatabaseOutputs(workflowName: String) -> Bool"))
        XCTAssertTrue(source.contains("windowStateScope: windowStateScope"))

        let deleteBody = try sourceFunctionBody(
            named: "private func performVariantDeletion",
            endingBefore: "private func performDeleteAllVariants",
            in: source
        )
        XCTAssertTrue(deleteBody.contains("canWriteVariantDatabaseOutputs(workflowName: \"Variant deletion\")"))

        let deleteAllBody = try sourceFunctionBody(
            named: "private func performDeleteAllVariants",
            endingBefore: "/// Groups selected variant row IDs",
            in: source
        )
        XCTAssertTrue(deleteAllBody.contains("canWriteVariantDatabaseOutputs(workflowName: \"Variant deletion\")"))

        let importBody = try sourceFunctionBody(
            named: "@objc private func importMetadataAction",
            endingBefore: "// MARK: - Sample Groups",
            in: source
        )
        XCTAssertTrue(importBody.contains("canWriteVariantDatabaseOutputs(workflowName: \"Sample metadata import\")"))

        let inlineEditBody = try sourceFunctionBody(
            named: "public func controlTextDidEndEditing",
            endingBefore: "// MARK: - Sample Drag-and-Drop Reordering",
            in: source
        )
        XCTAssertTrue(inlineEditBody.contains("canWriteVariantDatabaseOutputs(workflowName: \"Sample display name edit\")"))
        XCTAssertTrue(inlineEditBody.contains("canWriteVariantDatabaseOutputs(workflowName: \"Sample metadata edit\")"))

        let deleteColumnBody = try sourceFunctionBody(
            named: "@objc private func deleteSampleMetadataFieldAction",
            endingBefore: "// MARK: - Import Metadata",
            in: source
        )
        XCTAssertGreaterThanOrEqual(
            deleteColumnBody.components(separatedBy: "canWriteVariantDatabaseOutputs(workflowName: \"Sample metadata column deletion\")").count,
            3
        )
    }

    func testCLIImportPathDoesNotOverwriteCLIWrittenProvenanceWithEmptyAppRun() throws {
        let serviceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Services/FASTQIngestionService.swift")
        let source = try String(contentsOf: serviceURL, encoding: .utf8)
        let body = try sourceFunctionBody(
            named: "nonisolated private static func _runCLIImport",
            endingBefore: "nonisolated static func cliImportCommandPreview",
            in: source
        )

        XCTAssertFalse(
            body.contains("ProvenanceRecorder.shared.beginRun"),
            "CLI import already writes full provenance; the app must not replace it with an empty GUI run"
        )
    }

    private func sourceFunctionBody(named startNeedle: String, endingBefore endNeedle: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startNeedle))
        let end = try XCTUnwrap(source[start.lowerBound...].range(of: endNeedle))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}

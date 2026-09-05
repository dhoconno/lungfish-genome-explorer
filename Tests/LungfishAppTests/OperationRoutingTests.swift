import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishTestSupport

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
        _ = appDelegateURL
        let source = combinedAppDelegateSource()
        let start = try XCTUnwrap(source.range(of: "func handleMultipleDownloadsSync"))
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

    func testCopiedBundleImportRehydratesProvenancePathsToFinalProjectLocation() async throws {
        let delegate = makeAppDelegateWithTemporaryState()
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
        let restored = try delegate.testingRestoreProjectWindows(from: ProjectWindowStateEnvelope(windows: [snapshot]))
        XCTAssertTrue(restored)
        await delegate.testingWaitForProjectRestoration()
        let controller = try XCTUnwrap(delegate.testingMainWindowControllers.first)

        let sourceBundle = temp.appendingPathComponent("external.lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceBundle, withIntermediateDirectories: true)
        let sourcePayload = sourceBundle.appendingPathComponent("payload.fa")
        try ">seq\nAAAA\n".write(to: sourcePayload, atomically: true, encoding: .utf8)
        // This route opens the imported reference in a viewer; the fixture must
        // include its manifest/index rather than a directory with only a payload.
        try "seq\t4\t5\t4\t5\n".write(to: sourceBundle.appendingPathComponent("payload.fa.fai"), atomically: true, encoding: .utf8)
        try BundleManifest(name: "external", identifier: "org.lungfish.tests.route",
            source: SourceInfo(organism: "Synthetic fixture", assembly: "fixture"),
            genome: GenomeInfo(path: "payload.fa", indexPath: "payload.fa.fai", totalLength: 4,
                chromosomes: [ChromosomeInfo(name: "seq", length: 4, offset: 5, lineBases: 4, lineWidth: 5)]))
            .save(to: sourceBundle)
        defer { controller.close() }
        let provenanceURL = sourceBundle.appendingPathComponent(".lungfish-provenance.json")
        let provenance: [String: Any] = [
            "bundle": sourceBundle.path,
            "outputs": [
                ["path": sourcePayload.path]
            ]
        ]
        let provenanceData = try JSONSerialization.data(withJSONObject: provenance, options: [.prettyPrinted])
        try provenanceData.write(to: provenanceURL)

        let writeBlocked = delegate.isProjectWriteBlocked(projectURL: projectURL,
            windowStateScope: controller.projectSession.windowStateScope)
        XCTAssertFalse(writeBlocked, "The route fixture must permit downloaded output publication")
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
        let delegate = makeAppDelegateWithTemporaryState()
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
        _ = appDelegateURL
        let source = combinedAppDelegateSource()
        let start = try XCTUnwrap(source.range(of: "@objc func importSampleMetadataToBundle"))
        let end = try XCTUnwrap(source[start.lowerBound...].range(of: "func performVCFImport"))
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

    func testWorkflowOperationsLaunchCarriesSelectedSidebarReads() throws {
        let appDelegateURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift")
        _ = appDelegateURL
        let source = combinedAppDelegateSource()
        let body = try sourceFunctionBody(
            named: "@objc func showWorkflowOperations",
            endingBefore: "@objc func showImportCenter",
            in: source
        )

        XCTAssertTrue(body.contains("activeMainWindowController(sender: sender)"))
        XCTAssertTrue(body.contains("gatherWorkflowOperationReadInputURLs(controller: $0)"))
        XCTAssertTrue(body.contains("selectedReadURLs: selectedReadURLs"))
    }

    func testAlignmentAnnotationActionUsesOriginWindow() throws {
        let appDelegateURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/App/AppDelegate.swift")
        _ = appDelegateURL
        let source = combinedAppDelegateSource()
        let body = try sourceFunctionBody(
            named: "@objc func applyAlignmentAnnotationToSelection",
            endingBefore: "func showAlert",
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
        _ = appDelegateURL
        let source = combinedAppDelegateSource()

        let naoLaunch = try sourceFunctionBody(
            named: "@objc func launchNaoMgsImport",
            endingBefore: "@objc func launchPrimerSchemeImport",
            in: source
        )
        XCTAssertTrue(naoLaunch.contains("activeMainWindowController(sender: sender)"))
        XCTAssertTrue(naoLaunch.contains("currentOperationRouteContext(for: controller)"))
        XCTAssertTrue(naoLaunch.contains("importNaoMgsResultFromURL(resultsDir, routeContext: routeContext, onDispatch:"))
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
        XCTAssertTrue(nvdLaunch.contains("importNvdResultFromURL(nvdDir, routeContext: routeContext, onDispatch:"))
        XCTAssertFalse(nvdLaunch.contains("mainWindowController?.window"))

        let czIdLaunch = try sourceFunctionBody(
            named: "@objc func launchCzIdImport",
            endingBefore: "func importNvdResultFromURL",
            in: source
        )
        XCTAssertTrue(czIdLaunch.contains("activeMainWindowController(sender: sender)"))
        XCTAssertTrue(czIdLaunch.contains("currentOperationRouteContext(for: controller)"))
        XCTAssertTrue(czIdLaunch.contains("importCzIdResultFromURL(sourceURL, routeContext: routeContext, onDispatch:"))
        XCTAssertFalse(czIdLaunch.contains("mainWindowController?.mainSplitViewController"))

        let nvdImport = try sourceFunctionBody(
            named: "func importNvdResultFromURL",
            endingBefore: "@objc func launchOrientReads",
            in: source
        )
        XCTAssertTrue(nvdImport.contains("targetMainWindowController(routeContext: routeContext)"))
        XCTAssertTrue(nvdImport.contains("routeContext: routeContext"))
        XCTAssertTrue(nvdImport.contains("canWriteProjectOutputs"))
        XCTAssertTrue(nvdImport.contains("MetagenomicsImportHelperClient.importViaCLI"))
        XCTAssertTrue(nvdImport.contains("kind: .nvd"))
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
        // SidebarViewController.swift was split into focused files; read the
        // combined source so methods that moved into an extension are still found.
        let source = combinedSidebarViewControllerSource()

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
        // SidebarViewController.swift was split into focused files; read the
        // combined source so methods that moved into an extension are still found.
        let source = combinedSidebarViewControllerSource()

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
        XCTAssertTrue(deleteBody.contains("VariantDeletionMutationService().deleteVariants"))

        let deleteAllBody = try sourceFunctionBody(
            named: "private func performDeleteAllVariants",
            endingBefore: "/// Groups selected variant row IDs",
            in: source
        )
        XCTAssertTrue(deleteAllBody.contains("canWriteVariantDatabaseOutputs(workflowName: \"Variant deletion\")"))
        XCTAssertTrue(deleteAllBody.contains("VariantDeletionMutationService().deleteAllVariants"))

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

    func testMetagenomicsHelperCancellationTerminatesSubprocessTree() throws {
        let serviceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Services/MetagenomicsImportHelperClient.swift")
        let source = try String(contentsOf: serviceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("NativeProcessCancellationHandle"))
        XCTAssertTrue(source.contains("withTaskCancellationHandler"))
        XCTAssertTrue(source.contains("requestProcessTreeTermination"))
        XCTAssertTrue(source.contains("cancellationHandle.store(process)"))
        XCTAssertTrue(source.contains("cancellationHandle.clear(process)"))
        XCTAssertTrue(source.contains("throw CancellationError()"))
    }

    func testFASTQBatchSubprocessCancellationTerminatesTreeAndDrainsStderr() throws {
        let serviceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Services/FASTQIngestionService.swift")
        let source = try String(contentsOf: serviceURL, encoding: .utf8)
        let body = try sourceFunctionBody(
            named: "nonisolated private static func runCLISubprocess",
            endingBefore: "    }\n}",
            in: source
        )

        XCTAssertTrue(body.contains("NativeProcessCancellationHandle"))
        XCTAssertTrue(body.contains("withTaskCancellationHandler"))
        XCTAssertTrue(body.contains("requestProcessTreeTermination"))
        XCTAssertTrue(body.contains("cancellationHandle.store(process)"))
        XCTAssertTrue(body.contains("cancellationHandle.clear(process)"))
        XCTAssertTrue(body.contains("stderrHandle.readabilityHandler"))
        XCTAssertTrue(body.contains("throw CancellationError()"))
    }

    func testFASTQImportSlotPreventsIdleSystemSleepWhileProcessing() throws {
        let serviceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Services/FASTQIngestionService.swift")
        let source = try String(contentsOf: serviceURL, encoding: .utf8)
        let body = try sourceFunctionBody(
            named: "nonisolated private static func withImportSlot",
            endingBefore: "    /// Runs the ingestion pipeline off the main actor.",
            in: source
        )

        XCTAssertTrue(body.contains("ProcessInfo.processInfo.beginActivity"))
        XCTAssertTrue(body.contains(".userInitiated"))
        XCTAssertTrue(body.contains(".idleSystemSleepDisabled"))
        XCTAssertTrue(body.contains("defer { ProcessInfo.processInfo.endActivity(activity) }"))
    }

    func testTwelveSBlastPreparationCancelsCLISubprocessTree() throws {
        let viewerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Viewer/ViewerViewController+TwelveS.swift")
        let source = try String(contentsOf: viewerURL, encoding: .utf8)
        let body = try sourceFunctionBody(
            named: "controller.onUnresolvedBlastRequested",
            endingBefore: "        annotationDrawerView?.isHidden",
            in: source
        )

        XCTAssertTrue(body.contains("LungfishCLIRunner.CancellationHandle()"))
        XCTAssertTrue(body.contains("LungfishCLIRunner.run(arguments: arguments, cancellation: cliCancellation)"))
        XCTAssertTrue(body.contains("catch LungfishCLIRunner.RunError.cancelled"))
        XCTAssertTrue(body.contains("cliCancellation.cancel()"))
    }

    func testAnnotationDeletionOperationsCancelCLISubprocessTree() throws {
        let viewerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishApp/Views/Viewer/ViewerViewController+AnnotationDrawer.swift")
        let source = try String(contentsOf: viewerURL, encoding: .utf8)

        let rowDeleteBody = try sourceFunctionBody(
            named: "private func runAnnotationRowDeletion",
            endingBefore: "    func annotationDrawer(",
            in: source
        )
        let trackDeleteBody = try sourceFunctionBody(
            named: "private func runAnnotationTrackDeletion",
            endingBefore: "    private func presentAnnotationTrackDeletionFailure",
            in: source
        )

        for body in [rowDeleteBody, trackDeleteBody] {
            XCTAssertTrue(body.contains("LungfishCLIRunner.CancellationHandle()"))
            XCTAssertTrue(body.contains("cancellation: cliCancellation"))
            XCTAssertTrue(body.contains("catch LungfishCLIRunner.RunError.cancelled"))
            XCTAssertTrue(body.contains("OperationCenter.shared.setCancelCallback"))
            XCTAssertTrue(body.contains("cliCancellation.cancel()"))
        }
    }

    func testFASTQOperationLaunchersRegisterOperationCenterCancelCallbacks() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let genomicsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift"),
            encoding: .utf8
        )
        let fastqImportSource = try String(
            contentsOf: root.appendingPathComponent("Sources/LungfishApp/Views/MainWindow/MainSplitViewController+FASTQImport.swift"),
            encoding: .utf8
        )

        let generalLauncher = try sourceFunctionBody(
            named: "func runFASTQOperationLaunchRequestValidated",
            endingBefore: "    func outputDirectoryWritesIntoCurrentProject",
            in: genomicsSource
        )
        let fluidigmLauncher = try sourceFunctionBody(
            named: "func performONTFluidigmSampleSplit",
            endingBefore: "    func performONTPacBioBarcodeDemux",
            in: fastqImportSource
        )
        let pacBioLauncher = try sourceFunctionBody(
            named: "func performONTPacBioBarcodeDemux",
            endingBefore: "    /// Performs the actual ONT directory import",
            in: fastqImportSource
        )

        for body in [generalLauncher, fluidigmLauncher, pacBioLauncher] {
            XCTAssertTrue(body.contains("let task = Task.detached"))
            XCTAssertTrue(body.contains("OperationCenter.shared.setCancelCallback(for: opID) { task.cancel() }"))
        }
    }

    func testSavontLaunchFansOutBeforeOperationRegistrationWithPerChildAttribution() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift"
            ),
            encoding: .utf8
        )
        let body = try sourceFunctionBody(
            named: "func runFASTQOperationLaunchRequestValidated",
            endingBefore: "    func outputDirectoryWritesIntoCurrentProject",
            in: source
        )
        let fanout = try XCTUnwrap(body.range(of: "request.independentSavontLaunchRequests"))
        let operationStart = try XCTUnwrap(body.range(of: "OperationCenter.shared.start"))

        XCTAssertLessThan(fanout.lowerBound, operationStart.lowerBound)
        // BG5 (batch-results-grouping spec §4/§6): the fan-out loop now
        // collects each recursive call's returned opID into `childOpIDs`
        // (via `.compactMap`, still ONE call per independent request, still
        // concurrent -- no `await` inside this collection step) so a
        // completion barrier further down can wait for every child's
        // terminal state before running empty-batch cleanup. The loop
        // itself is no longer literally `for independentRequest in
        // independentRequests` (still concurrent, per
        // `SavontBatchOutputLayoutTests
        // .testSavontDispatchLoopStaysConcurrentAndBarrierUsesStaticSelfFreePoll`'s
        // behavioral proof).
        XCTAssertTrue(body.contains("let childOpIDs: [UUID] = independentRequests.compactMap { independentRequest in"))
        XCTAssertTrue(body.contains("request.independentOperationInputDisplayName"))
        XCTAssertTrue(body.contains("progress: { [weak self] fraction, message in"))
        XCTAssertTrue(body.contains("OperationCenter.shared.updateWithLog("))
        XCTAssertTrue(body.contains("outputURLs: result.importedURLs"))
    }

    /// MB-2 review round 1, point 4: a pooled `.perBundle`-mode `.assemble`
    /// request with N>1 bundle URLs must fan out BEFORE any
    /// `OperationCenter.shared.start` call (matching the pre-existing
    /// `.savont` fan-out exactly), recursing into
    /// `runFASTQOperationLaunchRequestValidated` once per independent
    /// request rather than sharing a single operation/CLI-invocation loop --
    /// so one bundle's assembly failure never aborts or discards another
    /// bundle's already-completed work.
    ///
    /// MB-2 review round 2: unlike `.savont`'s fan-out (intentionally
    /// concurrent -- Savont is a cheap per-sample op), the assembly fan-out
    /// must dispatch children SEQUENTIALLY: child k+1 only starts after
    /// child k's own operation reaches a terminal state. This asserts the
    /// serialization gate (`Task { @MainActor ... await self
    /// .awaitOperationTerminal(id: opID) }`) is present and precedes the
    /// next loop iteration, while each child still goes through its own
    /// independent `runFASTQOperationLaunchRequestValidated` call (own
    /// opID, own Task.detached, own failure isolation -- unchanged from
    /// round 1).
    func testAssembleLaunchFansOutBeforeOperationRegistrationAndDispatchesChildrenSequentially() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/LungfishApp/Views/MainWindow/MainSplitViewController+GenomicsDisplay.swift"
            ),
            encoding: .utf8
        )
        let body = try sourceFunctionBody(
            named: "func runFASTQOperationLaunchRequestValidated",
            endingBefore: "    func awaitOperationTerminal",
            in: source
        )
        let savontFanout = try XCTUnwrap(body.range(of: "request.independentSavontLaunchRequests"))
        let assembleFanout = try XCTUnwrap(body.range(of: "request.independentAssembleLaunchRequests"))
        let operationStart = try XCTUnwrap(body.range(of: "OperationCenter.shared.start"))

        // Both fan-outs precede the shared single-operation path.
        XCTAssertLessThan(savontFanout.lowerBound, operationStart.lowerBound)
        XCTAssertLessThan(assembleFanout.lowerBound, operationStart.lowerBound)

        // The assemble fan-out's own block: one recursive call per bundle,
        // still gated on outputMode == .perInput (the wizard's `.perBundle`
        // picker selection), not on pairedEnd or bundle-name inference --
        // but now wrapped in exactly one `Task { @MainActor` driving a
        // sequential loop that awaits each child's terminal state before
        // the next iteration, matching the shape
        // `testManagedMappingRunsSequentiallyWithOneOperationPerBundleAndLogsPooledWarning`
        // asserts for the analogous C2/MB-1 mapping fan-out.
        let assembleFanoutBlock = try sourceFunctionBody(
            named: "request.independentAssembleLaunchRequests",
            endingBefore: "let workingDirectory: URL",
            in: String(body[assembleFanout.lowerBound...])
        )
        XCTAssertTrue(assembleFanoutBlock.contains("Task { @MainActor [weak self] in"))
        // BG4: the loop now zips each independent request with its
        // precomputed batch sample directory (spec §3) rather than
        // iterating `independentRequests` alone, but it is still exactly
        // ONE `for` loop over `independentRequests`, still sequential.
        XCTAssertTrue(assembleFanoutBlock.contains("for (independentRequest, precomputedSampleDirectory) in zip(independentRequests, precomputedSampleDirectories)"))
        // BG4 review fix: `guard let self else { break }`, NOT `{ return }`
        // -- `return` would exit the whole `Task` closure and skip the
        // post-loop empty-batch cleanup if the controller deallocates
        // mid-batch, orphaning the batch directory. `break` falls through
        // to cleanup, matching BG3's mapping fan-out driver
        // (`runManagedMapping` in `AppDelegate+ToolsMenu.swift`) exactly.
        XCTAssertTrue(assembleFanoutBlock.contains("guard let self else { break }"))
        XCTAssertFalse(assembleFanoutBlock.contains("guard let self else { return }"))
        XCTAssertTrue(assembleFanoutBlock.contains("if let opID = self.runFASTQOperationLaunchRequestValidated("))
        XCTAssertTrue(assembleFanoutBlock.contains("await self.awaitOperationTerminal(id: opID)"))
        // The await sits INSIDE the for loop's body (after the dispatch
        // call), not after the loop -- i.e. it gates each iteration, not
        // just a final join after firing all children concurrently.
        let dispatchRange = try XCTUnwrap(assembleFanoutBlock.range(of: "self.runFASTQOperationLaunchRequestValidated("))
        let awaitRange = try XCTUnwrap(assembleFanoutBlock.range(of: "await self.awaitOperationTerminal(id: opID)"))
        let loopRange = try XCTUnwrap(assembleFanoutBlock.range(of: "for (independentRequest, precomputedSampleDirectory) in zip(independentRequests, precomputedSampleDirectories)"))
        XCTAssertLessThan(loopRange.lowerBound, dispatchRange.lowerBound)
        XCTAssertLessThan(dispatchRange.lowerBound, awaitRange.lowerBound)

        // BG4 (spec §6): empty-batch cleanup runs after the sequential loop
        // completes, using the shared hoisted helper -- NOT inside the loop
        // (mid-flight), and only when a batch directory was actually
        // precomputed.
        XCTAssertTrue(assembleFanoutBlock.contains("AnalysesFolder.removeBatchDirectoryIfEffectivelyEmpty(batchDirectory)"))
        let cleanupRange = try XCTUnwrap(assembleFanoutBlock.range(of: "AnalysesFolder.removeBatchDirectoryIfEffectivelyEmpty(batchDirectory)"))
        let loopEndRange = try XCTUnwrap(assembleFanoutBlock.range(of: "}", range: awaitRange.upperBound..<assembleFanoutBlock.endIndex))
        XCTAssertLessThan(loopEndRange.lowerBound, cleanupRange.lowerBound)

        // Only ONE Task.detached call site reachable from this fan-out block
        // itself (the sequential driver's own `Task { @MainActor ... }` is
        // not a `Task.detached`; each child's OWN `Task.detached` lives
        // inside the shared single-op path further down in the function,
        // outside this block, so it fires once per child dispatch --
        // confirms the fan-out driver doesn't ALSO spawn its own detached
        // work on top of what each child already spawns).
        XCTAssertFalse(assembleFanoutBlock.contains("Task.detached"))
    }

    /// Behavioral (not source-inspection) coverage for the actual
    /// serialization primitive `awaitOperationTerminal` uses (review round
    /// 2's ordering-hook requirement): it must NOT resume while the target
    /// operation is still `.running`, and MUST resume promptly once the
    /// operation reaches a terminal state -- proven against a real,
    /// isolated `OperationCenter` instance (not source text), driving
    /// `start`/`fail` directly and observing an ordering hook that only the
    /// awaiting `Task` can append to.
    func testAwaitOperationTerminalDoesNotResumeUntilOperationReachesTerminalState() async throws {
        let controller = MainSplitViewController()
        let center = OperationCenter()
        let opID = center.start(title: "Test Assembly", detail: "Running", operationType: .assembly)

        var events: [String] = []
        let waiter = Task { @MainActor in
            await controller.awaitOperationTerminal(id: opID, center: center, pollInterval: .milliseconds(10))
            events.append("resumed")
        }

        // Give the poller several intervals to (incorrectly) resume early
        // if it were not actually checking `state.isActive`.
        try await Task.sleep(for: .milliseconds(60))
        events.append("stillRunningCheckpoint")
        XCTAssertEqual(events, ["stillRunningCheckpoint"], "must not resume while the operation is still running")

        XCTAssertTrue(center.fail(id: opID, detail: "Simulated failure"))
        await waiter.value

        XCTAssertEqual(events, ["stillRunningCheckpoint", "resumed"], "must resume once the operation reaches a terminal state")
    }

    /// The same primitive resumes for a SUCCESSFUL completion too (not only
    /// failure), and resumes for an operation that has already been trimmed
    /// out of `items` by the time it is checked (an absent item is
    /// necessarily already finished -- see the doc comment on
    /// `awaitOperationTerminal`).
    func testAwaitOperationTerminalResumesOnCompletionAndOnAlreadyAbsentItem() async throws {
        let controller = MainSplitViewController()
        let center = OperationCenter()

        let completingOpID = center.start(title: "Test Assembly A", detail: "Running", operationType: .assembly)
        let completionWaiter = Task { @MainActor in
            await controller.awaitOperationTerminal(id: completingOpID, center: center, pollInterval: .milliseconds(10))
        }
        XCTAssertTrue(center.complete(id: completingOpID, detail: "Done"))
        await completionWaiter.value // Must not hang.

        let neverRegisteredID = UUID()
        let absentWaiter = Task { @MainActor in
            await controller.awaitOperationTerminal(id: neverRegisteredID, center: center, pollInterval: .milliseconds(10))
        }
        await absentWaiter.value // Must not hang.
    }

    /// End-to-end ordering proof for the actual `.assemble` fan-out gate,
    /// isolated from the real `runFASTQOperationLaunchRequestValidated`
    /// dispatch machinery (which needs a fully wired window/project/CLI
    /// environment): drives THREE simulated "children" through the same
    /// `awaitOperationTerminal`-gated loop shape the production fan-out
    /// uses, and asserts (a) each child only starts after the previous
    /// child reached a terminal state (sequential, not concurrent
    /// dispatch), and (b) a failing middle child does not prevent the third
    /// child from starting and completing (failure isolation preserved).
    func testSequentialFanoutGateOrdersChildrenWhileIsolatingAMiddleFailure() async throws {
        let controller = MainSplitViewController()
        let center = OperationCenter()
        var startedOrder: [String] = []
        var finishedOrder: [String] = []

        let bundleNames = ["SampleA", "SampleB", "SampleC"]
        for (index, name) in bundleNames.enumerated() {
            startedOrder.append(name)
            let opID = center.start(title: "Assembly: \(name)", detail: "Running", operationType: .assembly)

            // Simulate each child's own independently-running pipeline: the
            // middle bundle (index 1) fails; the others complete
            // successfully. Dispatched as its own concurrently-scheduled
            // `Task` (mirroring the production single-op path's own
            // `Task.detached` body being independent of the fan-out loop),
            // so this reproduces the same "child runs independently, gate
            // only controls the NEXT dispatch" shape without crossing an
            // actual background-executor boundary (unnecessary here and
            // would require `@Sendable`-safe capture of the test's local
            // ordering arrays).
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(5))
                if index == 1 {
                    _ = center.fail(id: opID, detail: "Simulated failure for \(name)")
                } else {
                    _ = center.complete(id: opID, detail: "Done")
                }
                finishedOrder.append(name)
            }

            // The gate: do not proceed to the next bundle in this loop
            // until the just-started one reaches a terminal state.
            await controller.awaitOperationTerminal(id: opID, center: center, pollInterval: .milliseconds(5))
        }

        XCTAssertEqual(startedOrder, bundleNames, "children must be dispatched in order")
        XCTAssertEqual(finishedOrder, bundleNames, "each child must finish before the next one starts")
        XCTAssertEqual(center.items.first { $0.title.hasSuffix("SampleB") }?.state, .failed)
        XCTAssertEqual(center.items.first { $0.title.hasSuffix("SampleA") }?.state, .completed)
        XCTAssertEqual(center.items.first { $0.title.hasSuffix("SampleC") }?.state, .completed)
    }

    func testManagedMappingRunsSequentiallyWithOneOperationPerBundleAndLogsPooledWarning() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift"
            ),
            encoding: .utf8
        )
        let fanout = try sourceFunctionBody(
            named: "private func runManagedMapping(\n        plan: MappingRunPlan",
            endingBefore: "    private func runSingleManagedMappingAwaitingCompletion",
            in: source
        )
        // F5: one `Task.detached` driving a sequential `for` loop over
        // `requests`, awaiting each bundle's mapping to completion before
        // starting the next -- NOT N concurrent Task.detached mappers.
        XCTAssertTrue(fanout.contains("let task = Task.detached"))
        XCTAssertTrue(fanout.contains("for request in requests"))
        XCTAssertTrue(fanout.contains("await self.runSingleManagedMappingAwaitingCompletion("))
        XCTAssertTrue(fanout.contains("warning: plan.warning"))
        // Only one Task.detached CALL SITE (`let task = Task.detached`) in
        // the fan-out function -- per-bundle work is awaited inline inside
        // that one sequential loop, never spawned as its own detached task
        // per bundle. (Doc comments elsewhere in the function mention
        // "Task.detached" in prose, so this counts call sites specifically.)
        let detachedCallSites = fanout.components(separatedBy: "let task = Task.detached").count - 1
        XCTAssertEqual(detachedCallSites, 1, "Expected exactly one `let task = Task.detached` (sequential driver), found \(detachedCallSites)")

        let single = try sourceFunctionBody(
            named: "private func runSingleManagedMappingAwaitingCompletion",
            endingBefore: "    private func runMAFFTAlignment",
            in: source
        )
        let opStart = try XCTUnwrap(single.range(of: "OperationCenter.shared.start"))
        let warningLog = try XCTUnwrap(single.range(of: "OperationCenter.shared.log(id: opID, level: .warning, message: warning)"))
        XCTAssertLessThan(opStart.lowerBound, warningLog.lowerBound)
        XCTAssertTrue(single.contains("if let warning {"))
        // F2: pairedEnd must be recomputed from the resolved file list,
        // never taken from the pre-resolve request as-is.
        XCTAssertTrue(single.contains("Self.resolvedPairedEnd(for: resolvedFiles)"))
        XCTAssertTrue(single.contains("request.withInputFASTQURLs(resolvedFiles, pairedEnd: resolvedPairedEnd)"))
    }

    /// Regression test for a round-2 fix: the F2 pairedEnd-resolution change
    /// added `resolvedRequest` (derived from the actually-resolved input
    /// files) but the analysis-manifest recording code kept reading from
    /// the pre-resolve `request`, whose `pairedEnd` is always the wizard's
    /// `false` placeholder (see MappingWizardSheet.buildRunPlan). That made
    /// every persisted manifest entry claim `isPairedEnd: false` regardless
    /// of the actual run. The fix must:
    ///  1. Still build `capturedRequest` (used by `findSourceBundle`) from
    ///     the ORIGINAL `request`, since `resolveInputFiles` can materialize
    ///     a virtual bundle's reads into a scratch temp directory that has
    ///     no enclosing `.lungfishfastq` bundle of its own.
    ///  2. Build the manifest `parameters` field from `resolvedRequest`
    ///     (via `summaryParameters()`), so `isPairedEnd` reflects the
    ///     actually-resolved value used by the pipeline run.
    func testManagedMappingManifestRecordsResolvedPairedEndNotPlaceholder() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/LungfishApp/App/AppDelegate+ToolsMenu.swift"
            ),
            encoding: .utf8
        )
        let single = try sourceFunctionBody(
            named: "private func runSingleManagedMappingAwaitingCompletion",
            endingBefore: "    private func runMAFFTAlignment",
            in: source
        )

        // findSourceBundle must still walk up from the ORIGINAL request's
        // input URLs, not the resolved (possibly materialized-to-temp-dir)
        // ones.
        XCTAssertTrue(
            single.contains("Self.findSourceBundle(for: capturedRequest.inputFASTQURLs)"),
            "findSourceBundle must resolve from capturedRequest (built from the original request), " +
            "not resolvedRequest, since resolved files may live in a scratch temp directory outside any bundle"
        )
        let capturedAssign = try XCTUnwrap(single.range(of: "let capturedRequest = request\n"))
        XCTAssertFalse(
            single[capturedAssign.upperBound...].range(of: "let capturedRequest = resolvedRequest") != nil,
            "capturedRequest must be derived from the original request, not resolvedRequest"
        )

        // The manifest's persisted parameters (including isPairedEnd) must
        // come from resolvedRequest.summaryParameters(), which carries the
        // pairedEnd value actually used by the pipeline run -- not from
        // capturedRequest/request, whose pairedEnd is always the wizard's
        // pre-resolve `false` placeholder.
        XCTAssertTrue(
            single.contains("parameters: resolvedRequest.summaryParameters(),"),
            "AnalysisManifestEntry.parameters must be built from resolvedRequest.summaryParameters() " +
            "so the persisted manifest records the true isPairedEnd, not the wizard's placeholder"
        )
        XCTAssertFalse(
            single.contains("parameters: capturedRequest.summaryParameters(),"),
            "AnalysisManifestEntry.parameters must NOT be built from capturedRequest.summaryParameters() " +
            "(that request's pairedEnd is always the pre-resolve wizard placeholder)"
        )
    }

    private func sourceFunctionBody(named startNeedle: String, endingBefore endNeedle: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startNeedle))
        let end = try XCTUnwrap(source[start.lowerBound...].range(of: endNeedle))
        return String(source[start.lowerBound..<end.lowerBound])
    }
}

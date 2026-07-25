import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class MappingViewportRoutingTests: XCTestCase {
    private final class IdleCancellation: GenotypeCurrentWorkbookSyncCoordinator.IdleCancellation {
        func cancel() {}
    }

    private final class WeakReference<Object: AnyObject> {
        weak var value: Object?

        init(_ value: Object?) {
            self.value = value
        }
    }

    private final class MatrixRetryScheduler: GenotypeMatrixWorkbookUpdateScheduling {
        private final class Cancellation: GenotypeMatrixWorkbookUpdateCancellation {
            func cancel() {}
        }

        private var actions: [@MainActor () -> Void] = []

        func schedule(
            _ action: @escaping @MainActor () -> Void
        ) -> GenotypeMatrixWorkbookUpdateCancellation {
            actions.append(action)
            return Cancellation()
        }

        func fire() {
            let pending = actions
            actions.removeAll()
            pending.forEach { $0() }
        }
    }

    func testViewerDisplaysLegacyMappingResultInMappingMode() throws {
        let resultDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-legacy-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Legacy Mapping Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
            ]
        )
        let result = MappingRoutingFixture.makeMappingResult(
            resultDirectory: resultDirectory,
            viewerBundleURL: bundleURL
        )
        let vc = ViewerViewController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)

        vc.displayMappingResult(result, resultDirectoryURL: resultDirectory)

        let controller = try XCTUnwrap(vc.mappingResultController)
        XCTAssertEqual(vc.contentMode, .mapping)
        XCTAssertEqual(controller.currentInput?.mappingResultDirectoryURL, resultDirectory.standardizedFileURL)
        XCTAssertNil(vc.referenceBundleViewportController)

        vc.hideMappingView()

        XCTAssertNil(vc.mappingResultController)
    }

    func testReferenceBundlesRouteThroughHarmonizedReferenceViewport() throws {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Reference Viewport Route",
            chromosomes: [
                .init(name: "chr1", length: 100),
                .init(name: "chr2", length: 120),
            ]
        )
        let vc = ViewerViewController()
        _ = vc.view

        try vc.displayBundle(at: bundleURL, mode: .browse)

        let viewportController = try XCTUnwrap(vc.referenceBundleViewportController)
        XCTAssertEqual(viewportController.currentInput?.kind, .directBundle)
        XCTAssertEqual(viewportController.currentInput?.renderedBundleURL, bundleURL.standardizedFileURL)
        XCTAssertNil(vc.referenceFrame)
        XCTAssertNil(vc.chromosomeNavigatorView)
    }

    func testReferenceBundleRouteClearsInspectorBeforeManifestLoadAndWiresDirectInspectorState() throws {
        let mainWindowSource = combinedMainSplitViewControllerSource()
        let routeStart = try XCTUnwrap(
            mainWindowSource.range(of: "func displayReferenceBundleViewportFromSidebar")
        )
        let routeEnd = try XCTUnwrap(
            mainWindowSource.range(of: "func displayAssemblyAnalysisFromSidebar")
        )
        let routeSource = String(mainWindowSource[routeStart.lowerBound..<routeEnd.lowerBound])

        let clearRange = try XCTUnwrap(routeSource.range(of: "self.inspectorController.clearSelection()"))
        let manifestRange = try XCTUnwrap(routeSource.range(of: "let manifest = try BundleManifest.load(from: url)"))

        XCTAssertLessThan(clearRange.lowerBound, manifestRange.lowerBound)
        XCTAssertTrue(routeSource.contains("wireDirectReferenceViewportInspectorUpdates()"))
        XCTAssertTrue(routeSource.contains("updateReferenceBundleTrackSections("))
        XCTAssertTrue(routeSource.contains("notifyEmbeddedReferenceBundleLoadedIfAvailable()"))
    }

    func testExternalOpenReferenceBundleUsesValidatedDisplayPathAndInspectorTarget() throws {
        let appDelegateSource = try loadSource(at: "Sources/LungfishApp/App/AppDelegate.swift")
        let routeStart = try XCTUnwrap(appDelegateSource.range(of: "case .lungfishReferenceBundle:"))
        let routeEnd = try XCTUnwrap(appDelegateSource.range(of: "case .lungfishMultipleSequenceAlignmentBundle:"))
        let routeSource = String(appDelegateSource[routeStart.lowerBound..<routeEnd.lowerBound])

        XCTAssertTrue(routeSource.contains("displayReferenceBundleFromExternalOpen(at: url)"))
        XCTAssertFalse(routeSource.contains("BundleManifest.load(from: url)"))
        XCTAssertFalse(routeSource.contains("ViewerDisplayRouteFactory.directReferenceBundle"))

        let mainWindowSource = combinedMainSplitViewControllerSource()
        XCTAssertTrue(mainWindowSource.contains("func displayReferenceBundleFromExternalOpen(at url: URL) throws"))
        XCTAssertTrue(mainWindowSource.contains("try viewerController.displayBundle(at: url)"))
        XCTAssertTrue(mainWindowSource.contains("sidebarType: .referenceBundle"))
        XCTAssertTrue(mainWindowSource.contains("wireDirectReferenceViewportInspectorUpdates()"))
    }

    func testONTGenotypingRawBAMURLsResolveToPreparedViewerBundles() throws {
        let outputDirectory = URL(fileURLWithPath: "/tmp/ONT genotyping results", isDirectory: true)

        XCTAssertEqual(
            MainSplitViewController.ontGenotypingViewerBundleURL(
                forRawBAM: outputDirectory.appendingPathComponent("barcode08-mhc.md.sorted.bam")
            ),
            outputDirectory.appendingPathComponent("barcode08-mhc.mapped.lungfishref", isDirectory: true)
        )
        XCTAssertEqual(
            MainSplitViewController.ontGenotypingViewerBundleURL(
                forRawBAM: outputDirectory.appendingPathComponent("barcode08-mhc.retained.demuxed.bam")
            ),
            outputDirectory.appendingPathComponent("barcode08-mhc.retained-demux.lungfishref", isDirectory: true)
        )
        XCTAssertNil(MainSplitViewController.ontGenotypingViewerBundleURL(
            forRawBAM: outputDirectory.appendingPathComponent("unrelated.bam")
        ))
    }

    func testGenotypeResultBundleResolvesPrimaryWorkbook() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappingViewportRoutingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode08-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let workbookURL = bundleURL.appendingPathComponent("barcode08-mhc.xlsx")
        try Data("workbook".utf8).write(to: workbookURL)
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "barcode08-mhc",
            analysisName: "barcode08-mhc",
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: "barcode08-mhc.retained-demux-genotypes.csv",
            sampleSummaryCSVPath: "barcode08-mhc.retained-demux-samples.csv",
            statsJSONPath: "barcode08-mhc.retained-demux-stats.json",
            provenancePath: "retained-demux-genotyping-provenance.json"
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        XCTAssertEqual(
            MainSplitViewController.genotypeResultWorkbookURL(forBundle: bundleURL),
            workbookURL.standardizedFileURL
        )
    }

    func testGenotypeResultBundleResolvesEditableCurrentWorkbookWhenPresent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MappingViewportRoutingCurrentWorkbook-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("barcode08-mhc.lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let originalWorkbookURL = bundleURL.appendingPathComponent("barcode08-mhc.xlsx")
        let currentWorkbookURL = bundleURL
            .appendingPathComponent("artifacts/workbooks/current.xlsx")
        try FileManager.default.createDirectory(
            at: currentWorkbookURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("original".utf8).write(to: originalWorkbookURL)
        try Data("editable".utf8).write(to: currentWorkbookURL)
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "barcode08-mhc",
            analysisName: "barcode08-mhc",
            primaryWorkbookPath: originalWorkbookURL.lastPathComponent,
            currentWorkbookPath: "artifacts/workbooks/current.xlsx",
            longSummaryCSVPath: "barcode08-mhc.retained-demux-genotypes.csv",
            sampleSummaryCSVPath: "barcode08-mhc.retained-demux-samples.csv",
            statsJSONPath: "barcode08-mhc.retained-demux-stats.json",
            provenancePath: "retained-demux-genotyping-provenance.json"
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)

        XCTAssertEqual(
            MainSplitViewController.genotypeResultWorkbookURL(forBundle: bundleURL),
            currentWorkbookURL.standardizedFileURL
        )
    }

    func testGenotypeResultWithoutHaplotypingDisplaysPrimaryWorkbookPreview() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeNoHapPreview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "barcode08-mhc-newref",
            haplotypeAnalysisPath: nil,
            includeGenotypeCalls: false
        )
        let workbookURL = try XCTUnwrap(MainSplitViewController.genotypeResultWorkbookURL(forBundle: bundleURL))
        let controller = MainSplitViewController()
        _ = controller.view

        await controller.testingDisplayGenotypeResultBundleAndWait(bundleURL)

        XCTAssertEqual(
            controller.viewerController.testQuickLookURL?.standardizedFileURL,
            workbookURL.standardizedFileURL
        )
        XCTAssertNil(controller.viewerController.genotypeResultViewController)
    }

    func testGenotypeWorkbookPreviewRemovesPreviousNativeGenotypeViewport() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeNoHapPreviewAfterNative-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "barcode08-mhc-newref",
            haplotypeAnalysisPath: nil,
            includeGenotypeCalls: false
        )
        let controller = MainSplitViewController()
        _ = controller.view
        _ = controller.viewerController.displayGenotypeResult(makeNativeHaplotypedResult())
        XCTAssertNotNil(controller.viewerController.genotypeResultViewController)

        await controller.testingDisplayGenotypeResultBundleAndWait(bundleURL)

        XCTAssertNil(controller.viewerController.genotypeResultViewController)
        XCTAssertEqual(
            controller.viewerController.testQuickLookURL?.lastPathComponent,
            "barcode08-mhc-newref.xlsx"
        )
    }

    func testGenotypeResultWithoutHaplotypeAnalysisDisplaysNativeRawMatrix() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeNoHapCallsPreview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "barcode08-mhc-newref",
            haplotypeAnalysisPath: nil,
            includeGenotypeCalls: true
        )
        let currentWorkbookURL = bundleURL.appendingPathComponent("artifacts/workbooks/current.xlsx")
        try FileManager.default.createDirectory(
            at: currentWorkbookURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("editable".utf8).write(to: currentWorkbookURL)
        var manifest = try ONTGenotypeResultBundle.loadManifest(from: bundleURL)
        manifest = ONTGenotypeResultBundleManifest(
            outputName: manifest.outputName,
            analysisName: manifest.analysisName,
            primaryWorkbookPath: manifest.primaryWorkbookPath,
            currentWorkbookPath: "artifacts/workbooks/current.xlsx",
            workbookRevisions: manifest.workbookRevisions,
            longSummaryCSVPath: manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: manifest.sampleSummaryCSVPath,
            statsJSONPath: manifest.statsJSONPath,
            provenancePath: manifest.provenancePath,
            haplotypeAnalysisPath: manifest.haplotypeAnalysisPath,
            haplotypeDefinitionSetID: manifest.haplotypeDefinitionSetID,
            haplotypeAssayID: manifest.haplotypeAssayID,
            presetID: manifest.presetID,
            presetVersion: manifest.presetVersion,
            createdAt: manifest.createdAt
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        let controller = MainSplitViewController()
        _ = controller.view

        await controller.testingDisplayGenotypeResultBundleAndWait(bundleURL)

        XCTAssertNil(controller.viewerController.testQuickLookURL)
        let resultController = try XCTUnwrap(controller.viewerController.genotypeResultViewController)
        XCTAssertEqual(resultController.testingSummaryViewMode, .matrix)
        XCTAssertFalse(resultController.testingComparisonMatrixIsHidden)
        XCTAssertEqual(
            controller.inspectorController.viewModel.genotypeResultDisplaySectionViewModel.displayState.summaryViewMode,
            .matrix
        )
        XCTAssertEqual(
            controller.inspectorController.viewModel.documentSectionViewModel.genotypeResultDocument?.summaryViewMode,
            .matrix
        )
    }

    func testGenotypeMatrixReviewProductionBridgeSharesCapabilityAndRoutesSemanticCommands() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeReviewBridge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "review-bridge",
            haplotypeAnalysisPath: nil
        )
        let splitController = MainSplitViewController()
        _ = splitController.view

        await splitController.testingDisplayGenotypeResultBundleAndWait(bundleURL)

        let resultController = try XCTUnwrap(
            splitController.viewerController.genotypeResultViewController
        )
        let viewModel = splitController.inspectorController
            .genotypeResultDisplaySectionViewModel
        resultController.testingSelectMatrixCell(
            genotype: "01_Mafa_A1_063g",
            sample: "DW472"
        )
        let targets = resultController.testingCurrentSelectionMatrixTargets
        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(
            viewModel.matrixReviewCapability,
            resultController.testingMatrixReviewCapability
        )
        XCTAssertEqual(viewModel.matrixReviewCapability.falsePositive, .enabled)

        try XCTUnwrap(viewModel.onMatrixReviewRequested)(
            .init(targets: targets, intent: .set(.falsePositive))
        )
        try XCTUnwrap(viewModel.onMatrixCommentRequested)(
            .init(targets: targets, intent: .upsert(body: "Production bridge"))
        )

        let sidecar = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(
            forBundleAt: bundleURL
        )
        XCTAssertEqual(sidecar.matrixReviews.map(\.target), targets)
        XCTAssertEqual(sidecar.resolvedMatrixComments[targets[0]]?.body, "Production bridge")

        splitController.inspectorController.clearSelection()
        XCTAssertNil(viewModel.onMatrixReviewRequested)
        XCTAssertNil(viewModel.onMatrixCommentRequested)
        splitController.viewerController.hideGenotypeResultView()
        XCTAssertNil(resultController.onMatrixReviewCapabilityChanged)
    }

    func testGenotypeResultLoadRegistersCurrentWorkbookSnapshotWithWindowCoordinator() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeWorkbookRegister-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "register-current-workbook",
            haplotypeAnalysisPath: nil
        )
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in nil },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        let splitController = MainSplitViewController()
        splitController.genotypeCurrentWorkbookSyncCoordinator = coordinator
        _ = splitController.view

        await splitController.testingDisplayGenotypeResultBundleAndWait(bundleURL)

        let registeredAsDirty = await eventually {
            coordinator.phase(for: bundleURL) == .dirty
        }
        XCTAssertTrue(registeredAsDirty)
        let resultController = try XCTUnwrap(
            splitController.viewerController.genotypeResultViewController
        )
        XCTAssertEqual(
            resultController.testingCurrentWorkbookUpdateStatus,
            "Pending edits — current.xlsx does not include the latest LGE review state."
        )
        XCTAssertEqual(
            splitController.inspectorController.viewModel.documentSectionViewModel
                .genotypeResultDocument?.currentWorkbookUpdate?.statusText,
            "Pending edits — current.xlsx does not include the latest LGE review state."
        )
    }

    func testUpdateAndViewRoutesThroughWindowCoordinatorAndOpensSynchronizedWorkbook() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeWorkbookUpdateAndView-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "update-and-view-current-workbook",
            haplotypeAnalysisPath: nil
        )
        let currentWorkbookURL = bundleURL.appendingPathComponent("current.xlsx")
        var routedRequests: [GenotypeCurrentWorkbookSyncCoordinator.Request] = []
        var routedIntents: [GenotypeCurrentWorkbookSyncIntent] = []
        var openedURLs: [URL] = []
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in nil },
            updateRunner: { request, intent in
                routedRequests.append(request)
                routedIntents.append(intent)
                return currentWorkbookURL
            },
            workbookOpener: { openedURLs.append($0) },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        let splitController = MainSplitViewController()
        splitController.genotypeCurrentWorkbookSyncCoordinator = coordinator
        _ = splitController.view
        await splitController.testingDisplayGenotypeResultBundleAndWait(bundleURL)
        let resultController = try XCTUnwrap(
            splitController.viewerController.genotypeResultViewController
        )
        let registeredAsDirty = await eventually {
            coordinator.phase(for: bundleURL) == .dirty
        }
        XCTAssertTrue(registeredAsDirty)

        resultController.testingRequestCurrentWorkbookUpdateAndView()

        let openedSynchronizedWorkbook = await eventually {
            openedURLs == [currentWorkbookURL]
        }
        XCTAssertTrue(openedSynchronizedWorkbook)
        XCTAssertEqual(routedIntents, [.updateAndView])
        XCTAssertEqual(routedRequests.first?.bundleURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(
            routedRequests.first?.annotationSidecarURL,
            ONTGenotypeResultBundleData.annotationSidecarURL(
                forBundleAt: bundleURL
            ).standardizedFileURL
        )
        XCTAssertTrue(routedRequests.first?.annotationOnly == true)
        XCTAssertEqual(coordinator.phase(for: bundleURL), .current)
    }

    func testUpdateAndViewOpensCleanCurrentWorkbookWithoutRunningUpdate() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeWorkbookCleanOpen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "clean-current-workbook",
            haplotypeAnalysisPath: nil
        )
        let loadedResult = try await ONTGenotypeResultBundle.loadResultAsync(
            from: bundleURL
        )
        let snapshotProbe = GenotypeResultViewController()
        _ = snapshotProbe.view
        var probeRequest: GenotypeCurrentWorkbookUIRequest?
        snapshotProbe.onCurrentWorkbookSyncRequested = { probeRequest = $0 }
        snapshotProbe.configure(result: loadedResult)
        snapshotProbe.requestCurrentWorkbookRegistration()
        let snapshot = try XCTUnwrap(probeRequest?.snapshot)
        let fingerprint = try GenotypeCurrentWorkbookInputFingerprint.make(
            calls: snapshot.calls,
            includedLoci: snapshot.includedLoci,
            annotationSidecar: snapshot.annotationSidecar,
            candidateArtifacts: snapshot.candidateArtifacts
        )
        let currentWorkbookURL = bundleURL.appendingPathComponent("current.xlsx")
        var fingerprintLoadCount = 0
        var updateCount = 0
        var openedURLs: [URL] = []
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in
                fingerprintLoadCount += 1
                return fingerprint
            },
            currentWorkbookResolver: { _ in currentWorkbookURL },
            updateRunner: { _, _ in
                updateCount += 1
                return currentWorkbookURL
            },
            workbookOpener: { openedURLs.append($0) },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        let splitController = MainSplitViewController()
        splitController.genotypeCurrentWorkbookSyncCoordinator = coordinator
        _ = splitController.view
        await splitController.testingDisplayGenotypeResultBundleAndWait(bundleURL)
        let loadedRecordedFingerprint = await eventually {
            fingerprintLoadCount == 1
        }
        XCTAssertTrue(loadedRecordedFingerprint)
        let resultController = try XCTUnwrap(
            splitController.viewerController.genotypeResultViewController
        )

        var currentRequest: GenotypeCurrentWorkbookUIRequest?
        resultController.onCurrentWorkbookSyncRequested = { currentRequest = $0 }
        resultController.requestCurrentWorkbookRegistration()
        splitController.routeGenotypeCurrentWorkbookRequest(.init(
            snapshot: readOnlySnapshot(try XCTUnwrap(currentRequest?.snapshot)),
            action: .synchronize(.updateAndView)
        ))

        let openedCurrentWorkbook = await eventually {
            openedURLs == [currentWorkbookURL]
        }
        XCTAssertTrue(openedCurrentWorkbook)
        XCTAssertEqual(updateCount, 0)
    }

    func testDirtyReadOnlyUpdateAndViewDoesNotRunOrOpenWorkbook() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeWorkbookReadOnlyDirty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "read-only-dirty-current-workbook",
            haplotypeAnalysisPath: nil
        )
        var updateCount = 0
        var openedURLs: [URL] = []
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in nil },
            updateRunner: { request, _ in
                updateCount += 1
                return request.bundleURL.appendingPathComponent("current.xlsx")
            },
            workbookOpener: { openedURLs.append($0) },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        let splitController = MainSplitViewController()
        splitController.genotypeCurrentWorkbookSyncCoordinator = coordinator
        _ = splitController.view
        await splitController.testingDisplayGenotypeResultBundleAndWait(bundleURL)
        let registeredAsDirty = await eventually {
            coordinator.phase(for: bundleURL) == .dirty
        }
        XCTAssertTrue(registeredAsDirty)
        let resultController = try XCTUnwrap(
            splitController.viewerController.genotypeResultViewController
        )
        var currentRequest: GenotypeCurrentWorkbookUIRequest?
        resultController.onCurrentWorkbookSyncRequested = { currentRequest = $0 }
        resultController.requestCurrentWorkbookRegistration()

        splitController.routeGenotypeCurrentWorkbookRequest(.init(
            snapshot: readOnlySnapshot(try XCTUnwrap(currentRequest?.snapshot)),
            action: .synchronize(.updateAndView)
        ))

        let routingFinished = await eventually {
            splitController.pendingGenotypeCurrentWorkbookRoutes.isEmpty
        }
        XCTAssertTrue(routingFinished)
        XCTAssertEqual(updateCount, 0)
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testHidingDirtyGenotypeBundleSynchronizesWithBundleSwitchIntentWithoutOpening() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeWorkbookBundleSwitch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "bundle-switch-current-workbook",
            haplotypeAnalysisPath: nil
        )
        var routedIntents: [GenotypeCurrentWorkbookSyncIntent] = []
        var openedURLs: [URL] = []
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in nil },
            updateRunner: { request, intent in
                routedIntents.append(intent)
                return request.bundleURL.appendingPathComponent("current.xlsx")
            },
            workbookOpener: { openedURLs.append($0) },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        let splitController = MainSplitViewController()
        splitController.genotypeCurrentWorkbookSyncCoordinator = coordinator
        _ = splitController.view
        await splitController.testingDisplayGenotypeResultBundleAndWait(bundleURL)
        let registeredAsDirty = await eventually {
            coordinator.phase(for: bundleURL) == .dirty
        }
        XCTAssertTrue(registeredAsDirty)

        splitController.viewerController.hideGenotypeResultView()

        let synchronizedOnSwitch = await eventually {
            routedIntents == [.bundleSwitch]
        }
        XCTAssertTrue(synchronizedOnSwitch)
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testHidingViewportRetainsDeferredAnnotationUntilPublicationLockClears() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeDeferredMutationLifetime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "deferred-mutation-lifetime",
            haplotypeAnalysisPath: nil
        )
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in nil },
            updateRunner: { request, _ in
                request.bundleURL.appendingPathComponent("current.xlsx")
            },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        let splitController = MainSplitViewController()
        splitController.genotypeCurrentWorkbookSyncCoordinator = coordinator
        _ = splitController.view
        await splitController.testingDisplayGenotypeResultBundleAndWait(bundleURL)
        var resultController = splitController.viewerController.genotypeResultViewController
        let scheduler = MatrixRetryScheduler()
        resultController?.matrixAnnotationRetryScheduler = scheduler
        let publicationLock = try ONTGenotypeBundlePublicationLock.acquire(for: bundleURL)
        resultController?.editMatrixComment(.init(
            targets: [.column(sample: "DW472")],
            intent: .upsert(body: "survive bundle switch")
        ))
        XCTAssertEqual(
            resultController?.testingDeferredMatrixAnnotationMutationCount,
            1
        )
        let weakResultController = WeakReference(resultController)

        splitController.viewerController.hideGenotypeResultView()
        resultController = nil

        XCTAssertNotNil(weakResultController.value)
        publicationLock.release()
        scheduler.fire()
        let persisted = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(
            forBundleAt: bundleURL
        )
        XCTAssertEqual(
            persisted.matrixComments.first?.body,
            "survive bundle switch"
        )
        let releasedAfterDrain = await eventually {
            weakResultController.value == nil
        }
        XCTAssertTrue(releasedAfterDrain)
    }

    func testOldBundlePhaseCannotRepaintActiveGenotypeInspector() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeWorkbookOldPhase-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstBundle = try makeGenotypeResultBundle(
            root: root,
            name: "first-bundle",
            haplotypeAnalysisPath: nil
        )
        let secondBundle = try makeGenotypeResultBundle(
            root: root,
            name: "second-bundle",
            haplotypeAnalysisPath: nil
        )
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in nil },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        let splitController = MainSplitViewController()
        splitController.genotypeCurrentWorkbookSyncCoordinator = coordinator
        _ = splitController.view
        await splitController.testingDisplayGenotypeResultBundleAndWait(firstBundle)
        await splitController.testingDisplayGenotypeResultBundleAndWait(secondBundle)
        let secondBecameActive = await eventually {
            splitController.inspectorController.viewModel.documentSectionViewModel
                .genotypeResultDocument?.bundleURL?.standardizedFileURL
                == secondBundle.standardizedFileURL
        }
        XCTAssertTrue(secondBecameActive)
        let activeStatus = splitController.inspectorController.viewModel
            .documentSectionViewModel.genotypeResultDocument?
            .currentWorkbookUpdate?.statusText

        splitController.applyGenotypeCurrentWorkbookSyncPhase(
            .failed("stale first-bundle completion"),
            bundleURL: firstBundle
        )

        XCTAssertEqual(
            splitController.inspectorController.viewModel.documentSectionViewModel
                .genotypeResultDocument?.bundleURL?.standardizedFileURL,
            secondBundle.standardizedFileURL
        )
        XCTAssertEqual(
            splitController.inspectorController.viewModel.documentSectionViewModel
                .genotypeResultDocument?.currentWorkbookUpdate?.statusText,
            activeStatus
        )
    }

    func testAIHaplotypingGUIUsesReplayableCLICommandPreviewAndSanitizedFailureDetail() throws {
        let source = try loadSource(at: "Sources/LungfishApp/Services/GenotypeAIHaplotypingExecutionService.swift")

        XCTAssertTrue(source.contains("CLICommandIdentity.executableName"))
        XCTAssertTrue(source.contains("mode.commandLineArgument"))
        XCTAssertTrue(source.contains("AIHaplotypingExecutionDefaults.maxObservationsPerChunk"))
        XCTAssertTrue(source.contains("AIHaplotypingExecutionDefaults.maxOutputTokens"))
        XCTAssertTrue(source.contains("AIHaplotypingExecutionDefaults.temperature"))
        XCTAssertTrue(source.contains("AIHaplotypingExecutionDefaults.maxProviderRetries"))
        XCTAssertTrue(source.contains("AIHaplotypingExecutionDefaults.compactKnowledgePack"))
        XCTAssertTrue(source.contains("static let maxObservationsPerChunk = 10_000"))
        XCTAssertTrue(source.contains("static let openAIModel = MCMHaplotypingPreset.mcmMHCmiseq.aiOpenAIModel"))
        XCTAssertTrue(source.contains("static let reasoningEffort = MCMHaplotypingPreset.mcmMHCmiseq.aiReasoningEffort"))
        XCTAssertTrue(source.contains("\"--reasoning-effort\""))
        XCTAssertTrue(source.contains("AIProviderIdentifier(rawValue: settings.preferredAIProvider) ?? .openAI"))
        XCTAssertTrue(source.contains("[AIProviderIdentifier.openAI, .anthropic]"))
        XCTAssertTrue(source.contains("\"--compact-knowledge-pack\""))
        XCTAssertFalse(source.contains("\"--credential-source\""))
        XCTAssertFalse(source.contains("String(describing: error)"))
        XCTAssertTrue(source.contains("AIHaplotypingRunFailure"))
        XCTAssertTrue(source.contains("sanitizedErrorCategory"))
    }

    func testMainActorGenotypeBundleConsumersDoNotUseSynchronousResultLoader() throws {
        let serviceSource = try loadSource(
            at: "Sources/LungfishApp/Services/GenotypeAIHaplotypingExecutionService.swift"
        )
        XCTAssertTrue(serviceSource.contains("try await ONTGenotypeResultBundle.loadResultAsync(from: bundle)"))
        XCTAssertFalse(serviceSource.contains("ONTGenotypeResultBundle.loadResult(from: bundle)"))

        let inspectorSource = try loadSource(
            at: "Sources/LungfishApp/Views/Inspector/InspectorViewController+PublicAPI.swift"
        )
        let sidecarUpdate = try XCTUnwrap(
            inspectorSource.range(of: "func updateGenotypeAnnotationSidecar")
        )
        let sidecarUpdateTail = String(inspectorSource[sidecarUpdate.lowerBound...])
        let nextMethod = try XCTUnwrap(sidecarUpdateTail.range(of: "private func genotypeSummaryRows"))
        let sidecarUpdateBody = String(sidecarUpdateTail[..<nextMethod.lowerBound])
        XCTAssertFalse(sidecarUpdateBody.contains("ONTGenotypeResultBundle.loadResult"))

        let viewportSource = try loadSource(
            at: "Sources/LungfishGenotypeUI/GenotypeResultViewController.swift"
        )
        XCTAssertTrue(viewportSource.contains("ONTGenotypeResultBundle.loadResultAsync(from: bundleURL)"))
        XCTAssertFalse(viewportSource.contains("ONTGenotypeResultBundle.loadResult(from:"))
    }

    func testExternalOpenReferenceBundleWiresInspectorCallbacksAndProvenanceTarget() throws {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "External Open Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
            ]
        )
        let controller = MainSplitViewController()
        _ = controller.view

        try controller.displayReferenceBundleFromExternalOpen(at: bundleURL)

        let viewportController = try XCTUnwrap(controller.viewerController.referenceBundleViewportController)
        XCTAssertEqual(viewportController.currentInput?.kind, .directBundle)
        XCTAssertNotNil(viewportController.onEmbeddedReferenceBundleLoaded)
        XCTAssertNotNil(viewportController.onSequenceSelectionStateChanged)
        XCTAssertEqual(
            controller.inspectorController.viewModel.provenanceSectionViewModel.currentItem?.url,
            bundleURL
        )
        XCTAssertEqual(
            controller.inspectorController.viewModel.provenanceSectionViewModel.currentItem?.sidebarType,
            .referenceBundle
        )
    }

    func testExternalOpenReferenceBundleRejectsInvalidManifestBeforeInstallingViewport() throws {
        let bundleURL = try MappingRoutingFixture.makeInvalidReferenceBundle(name: "Invalid External Open")
        let controller = MainSplitViewController()
        _ = controller.view

        XCTAssertThrowsError(try controller.displayReferenceBundleFromExternalOpen(at: bundleURL))
        XCTAssertNil(controller.viewerController.referenceBundleViewportController)
        XCTAssertNil(controller.inspectorController.viewModel.provenanceSectionViewModel.currentItem)
    }

    func testExternalOpenMHCReferenceBundleRoutesThroughDedicatedDisplayPath() throws {
        let appDelegateSource = try loadSource(at: "Sources/LungfishApp/App/AppDelegate.swift")
        let routeStart = try XCTUnwrap(appDelegateSource.range(of: "case .lungfishMHCReferenceBundle:"))
        let routeEnd = try XCTUnwrap(
            appDelegateSource.range(of: "default:", range: routeStart.upperBound..<appDelegateSource.endIndex)
        )
        let routeSource = String(appDelegateSource[routeStart.lowerBound..<routeEnd.lowerBound])

        XCTAssertTrue(routeSource.contains("displayMHCReferenceBundleFromExternalOpen(at: url)"))
        XCTAssertFalse(routeSource.contains("MHCAmpliconReferenceBundle.loadManifest(from: url)"))

        let mainWindowSource = combinedMainSplitViewControllerSource()
        XCTAssertTrue(mainWindowSource.contains("func displayMHCReferenceBundleFromExternalOpen(at url: URL)"))
        XCTAssertTrue(mainWindowSource.contains("inspectorController.updateMHCReferenceBundleDocument(url)"))
        XCTAssertTrue(mainWindowSource.contains("displayMHCReferenceBundle(model)"))
    }

    func testExternalOpenMHCReferenceBundlePopulatesInspectorAndProvenanceTarget() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MHCExternalOpen-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = tempRoot.appendingPathComponent("MCM.lungfishmhcref", isDirectory: true)
        try MHCReferenceBundleSidebarTests.writeMHCReferenceBundle(at: bundleURL, name: "MCM")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let controller = MainSplitViewController()
        _ = controller.view

        controller.displayMHCReferenceBundleFromExternalOpen(at: bundleURL)

        let state = try XCTUnwrap(
            controller.inspectorController.viewModel.documentSectionViewModel.mhcReferenceBundleDocument
        )
        XCTAssertEqual(state.name, "MCM MHC")
        XCTAssertEqual(state.bundleURL?.standardizedFileURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(
            controller.inspectorController.viewModel.provenanceSectionViewModel.currentItem?.url,
            bundleURL
        )
        XCTAssertEqual(
            controller.inspectorController.viewModel.provenanceSectionViewModel.currentItem?.sidebarType,
            .mhcReferenceBundle
        )
        XCTAssertNotNil(controller.viewerController.mhcReferenceBundleViewController)
    }

    func testReferenceBundleSidebarRouteHasNoDeadForceReloadParameter() throws {
        let mainWindowSource = combinedMainSplitViewControllerSource()

        XCTAssertFalse(mainWindowSource.contains("forceReload"))
    }

    func testMappingAnalysisRouteDisplaysReferenceViewportWithMappingResultInput() throws {
        let mainWindowSource = combinedMainSplitViewControllerSource()
        let routeStart = try XCTUnwrap(
            mainWindowSource.range(of: "func displayMappingAnalysisFromSidebar")
        )
        let routeEnd = try XCTUnwrap(
            mainWindowSource.range(of: "/// Routes a classifier result directory through the DB router.")
        )
        let routeSource = String(mainWindowSource[routeStart.lowerBound..<routeEnd.lowerBound])

        XCTAssertTrue(routeSource.contains("ViewerDisplayRouteFactory.mappingResult("))
        XCTAssertTrue(routeSource.contains("resultDirectoryURL: url"))
        XCTAssertTrue(routeSource.contains("provenance: provenance"))
        XCTAssertTrue(routeSource.contains("try viewerController.display(route)"))
        XCTAssertFalse(routeSource.contains("viewerController.displayMappingResult(result, resultDirectoryURL: url)"))
    }

    func testDirectReferenceBundleRouteFactoryProducesReferenceViewportRoute() throws {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Route Factory Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
            ]
        )
        let manifest = try BundleManifest.load(from: bundleURL)

        let route = ViewerDisplayRouteFactory.directReferenceBundle(
            bundleURL: bundleURL,
            manifest: manifest
        )

        guard case .referenceBundle(let input) = route else {
            return XCTFail("Expected reference bundle route")
        }
        XCTAssertEqual(input.kind, .directBundle)
        XCTAssertEqual(input.renderedBundleURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(input.manifest, manifest)
    }

    func testReferenceBundleDisplayRouteFactoryUsesReferenceViewportForBrowseMode() throws {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Browse Display Route Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
            ]
        )
        let manifest = try BundleManifest.load(from: bundleURL)

        let displayRoute = ViewerDisplayRouteFactory.referenceBundleDisplayRoute(
            bundleURL: bundleURL,
            manifest: manifest,
            mode: .browse
        )

        guard case .referenceViewport(let route) = displayRoute,
              case .referenceBundle(let input) = route else {
            return XCTFail("Expected browse mode to route through the reference viewport")
        }
        XCTAssertEqual(input.kind, .directBundle)
        XCTAssertEqual(input.renderedBundleURL, bundleURL.standardizedFileURL)
        XCTAssertEqual(input.manifest, manifest)
    }

    func testReferenceBundleDisplayRouteFactoryPreservesSequenceModeIntent() throws {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Sequence Display Route Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
            ]
        )
        let manifest = try BundleManifest.load(from: bundleURL)

        let displayRoute = ViewerDisplayRouteFactory.referenceBundleDisplayRoute(
            bundleURL: bundleURL,
            manifest: manifest,
            mode: .sequence(name: "chr1", restoreViewState: false)
        )

        XCTAssertEqual(displayRoute, .sequence(name: "chr1", restoreViewState: false))
    }

    func testMappingResultRouteFactoryPreservesResultDirectoryAndProvenance() throws {
        let resultDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-route-factory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Route Factory Mapping Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
            ]
        )
        let result = MappingRoutingFixture.makeMappingResult(
            resultDirectory: resultDirectory,
            viewerBundleURL: bundleURL
        )

        let route = ViewerDisplayRouteFactory.mappingResult(
            result,
            resultDirectoryURL: resultDirectory,
            provenance: nil
        )

        guard case .referenceBundle(let input) = route else {
            return XCTFail("Expected reference bundle route")
        }
        XCTAssertEqual(input.kind, .mappingResult)
        XCTAssertEqual(input.mappingResult, result)
        XCTAssertEqual(input.mappingResultDirectoryURL, resultDirectory.standardizedFileURL)
        XCTAssertNil(input.mappingProvenance)
    }

    func testViewerDisplaysDirectBundleViewportWithDirectInput() throws {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Route Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
            ]
        )
        let manifest = try BundleManifest.load(from: bundleURL)
        let vc = ViewerViewController()
        _ = vc.view

        try vc.display(ViewerDisplayRouteFactory.directReferenceBundle(
            bundleURL: bundleURL,
            manifest: manifest
        ))

        let controller = try XCTUnwrap(vc.referenceBundleViewportController)
        XCTAssertEqual(controller.currentInput?.kind, .directBundle)
        XCTAssertEqual(controller.currentInput?.renderedBundleURL, bundleURL.standardizedFileURL)
    }

    func testViewerExposesReferenceViewportMappingInputAsActiveMappingViewport() throws {
        let resultDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Route Mapping Reference",
            chromosomes: [
                .init(name: "chr1", length: 100),
            ]
        )
        let result = MappingRoutingFixture.makeMappingResult(
            resultDirectory: resultDirectory,
            viewerBundleURL: bundleURL
        )
        let vc = ViewerViewController()
        _ = vc.view

        try vc.display(ViewerDisplayRouteFactory.mappingResult(
            result,
            resultDirectoryURL: resultDirectory,
            provenance: nil
        ))

        XCTAssertEqual(vc.activeMappingViewportController?.currentInput?.kind, .mappingResult)
        XCTAssertEqual(
            vc.activeMappingViewportController?.testFilteredAlignmentServiceTarget,
            .mappingResult(resultDirectory.standardizedFileURL)
        )
    }

    func testBundleBackNavigationButtonUsesStableAccessibilityIdentifier() throws {
        let viewerSource = try loadSource(at: "Sources/LungfishApp/Views/Viewer/ViewerViewController.swift")

        XCTAssertTrue(viewerSource.contains("viewer-back-navigation-button"))
    }

    private func makeNativeHaplotypedResult() -> ONTGenotypeResultBundleData {
        ONTGenotypeResultBundleData(
            bundleURL: URL(fileURLWithPath: "/tmp/native.lungfishgenotype"),
            manifest: ONTGenotypeResultBundleManifest(
                outputName: "native",
                analysisName: "native",
                primaryWorkbookPath: "native.xlsx",
                longSummaryCSVPath: "native.retained-demux-genotypes.csv",
                sampleSummaryCSVPath: "native.retained-demux-samples.csv",
                statsJSONPath: "native.retained-demux-stats.json",
                provenancePath: "retained-demux-genotyping-provenance.json",
                haplotypeAnalysisPath: "native-haplotype-analysis.json",
                haplotypeDefinitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
            ),
            artifacts: ONTGenotypeResultArtifacts(
                workbookURL: URL(fileURLWithPath: "/tmp/native.xlsx"),
                longSummaryCSVURL: URL(fileURLWithPath: "/tmp/native.retained-demux-genotypes.csv"),
                sampleSummaryCSVURL: URL(fileURLWithPath: "/tmp/native.retained-demux-samples.csv"),
                statsJSONURL: URL(fileURLWithPath: "/tmp/native.retained-demux-stats.json"),
                provenanceURL: URL(fileURLWithPath: "/tmp/retained-demux-genotyping-provenance.json")
            ),
            stats: ONTGenotypeRunStats(totalInputReads: 1, retainedUniqueReads: 1),
            calls: [],
            samples: [],
            haplotypeAnalysis: GenotypeHaplotypeAnalysis(
                assayID: "MHC-exon2-miSeq",
                definitionSetID: "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
                definitionSetName: "Mauritian cynomolgus macaques",
                speciesName: "Mauritian cynomolgus macaques",
                samples: []
            )
        )
    }

    private func eventually(
        timeout: TimeInterval = 2,
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private func readOnlySnapshot(
        _ snapshot: GenotypeCurrentWorkbookUISnapshot
    ) -> GenotypeCurrentWorkbookUISnapshot {
        GenotypeCurrentWorkbookUISnapshot(
            bundleURL: snapshot.bundleURL,
            calls: snapshot.calls,
            includedLoci: snapshot.includedLoci,
            annotationSidecar: snapshot.annotationSidecar,
            annotationSidecarURL: snapshot.annotationSidecarURL,
            candidateArtifacts: snapshot.candidateArtifacts,
            annotationOnly: snapshot.annotationOnly,
            isReadOnly: true
        )
    }

    private func makeGenotypeResultBundle(
        root: URL,
        name: String,
        haplotypeAnalysisPath: String?,
        includeGenotypeCalls: Bool = true
    ) throws -> URL {
        let bundleURL = root.appendingPathComponent("\(name).lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let workbookURL = bundleURL.appendingPathComponent("\(name).xlsx")
        let genotypeCSV = bundleURL.appendingPathComponent("\(name).retained-demux-genotypes.csv")
        let samplesCSV = bundleURL.appendingPathComponent("\(name).retained-demux-samples.csv")
        let statsJSON = bundleURL.appendingPathComponent("\(name).retained-demux-stats.json")
        let provenanceJSON = bundleURL.appendingPathComponent("retained-demux-genotyping-provenance.json")

        try Data("workbook".utf8).write(to: workbookURL)
        if includeGenotypeCalls {
            try """
            sample,genotype,passed_alignments,passed_unique_reads
            DW472,01_Mafa_A1_063g,10,8

            """.write(to: genotypeCSV, atomically: true, encoding: .utf8)
            try """
            sample,passed_alignments,passed_unique_reads
            DW472,10,8

            """.write(to: samplesCSV, atomically: true, encoding: .utf8)
        } else {
            try "sample,genotype,passed_alignments,passed_unique_reads\n"
                .write(to: genotypeCSV, atomically: true, encoding: .utf8)
            try "sample,passed_alignments,passed_unique_reads\n"
                .write(to: samplesCSV, atomically: true, encoding: .utf8)
        }
        try #"{"totalInputReads":10,"retainedUniqueReads":8}"#
            .write(to: statsJSON, atomically: true, encoding: .utf8)
        try #"{"workflow":"test"}"#
            .write(to: provenanceJSON, atomically: true, encoding: .utf8)

        let manifest = ONTGenotypeResultBundleManifest(
            outputName: name,
            analysisName: name,
            primaryWorkbookPath: workbookURL.lastPathComponent,
            longSummaryCSVPath: genotypeCSV.lastPathComponent,
            sampleSummaryCSVPath: samplesCSV.lastPathComponent,
            statsJSONPath: statsJSON.lastPathComponent,
            provenancePath: provenanceJSON.lastPathComponent,
            haplotypeAnalysisPath: haplotypeAnalysisPath,
            haplotypeDefinitionSetID: haplotypeAnalysisPath == nil
                ? nil
                : "MHC-exon2-miSeq.mauritian-cynomolgus-macaques"
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundleURL)
        return bundleURL
    }

    private func loadSource(at relativePath: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}

private enum MappingRoutingFixture {
    struct Chromosome {
        let name: String
        let length: Int
    }

    static func makeReferenceBundle(
        name: String,
        chromosomes: [Chromosome]
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-routing-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        let genomeURL = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeURL, withIntermediateDirectories: true)

        let fasta = chromosomes.map { ">\($0.name)\n\(String(repeating: "A", count: $0.length))\n" }.joined()
        let fastaURL = genomeURL.appendingPathComponent("sequence.fa")
        try fasta.write(to: fastaURL, atomically: true, encoding: .utf8)

        var offset = Int64(0)
        let chromInfos = chromosomes.map { chrom in
            let info = ChromosomeInfo(
                name: chrom.name,
                length: Int64(chrom.length),
                offset: offset,
                lineBases: chrom.length,
                lineWidth: chrom.length + 1
            )
            offset += Int64(">\(chrom.name)\n".utf8.count + chrom.length + 1)
            return info
        }

        let index = zip(chromosomes, chromInfos).map { chrom, info in
            "\(chrom.name)\t\(chrom.length)\t\(info.offset)\t\(chrom.length)\t\(chrom.length + 1)\n"
        }.joined()
        try index.write(to: genomeURL.appendingPathComponent("sequence.fa.fai"), atomically: true, encoding: .utf8)

        let manifest = BundleManifest(
            name: name,
            identifier: "org.lungfish.tests.\(UUID().uuidString)",
            source: SourceInfo(organism: "Test organism", assembly: name),
            genome: GenomeInfo(
                path: "genome/sequence.fa",
                indexPath: "genome/sequence.fa.fai",
                totalLength: Int64(chromosomes.reduce(0) { $0 + $1.length }),
                chromosomes: chromInfos
            ),
            annotations: [],
            variants: [],
            tracks: [],
            alignments: [],
            browserSummary: BundleBrowserSummary(
                schemaVersion: 1,
                aggregate: .init(
                    annotationTrackCount: 0,
                    variantTrackCount: 0,
                    alignmentTrackCount: 0,
                    totalMappedReads: nil
                ),
                sequences: chromosomes.map {
                    BundleBrowserSequenceSummary(
                        name: $0.name,
                        displayDescription: nil,
                        length: Int64($0.length),
                        aliases: [],
                        isPrimary: true,
                        isMitochondrial: false,
                        metrics: nil
                    )
                }
            )
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    static func makeInvalidReferenceBundle(name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-routing-invalid-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("\(name).lungfishref", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let manifest = BundleManifest(
            name: "",
            identifier: "",
            source: SourceInfo(organism: "Test organism", assembly: name),
            genome: nil,
            annotations: [],
            variants: [],
            tracks: [],
            alignments: []
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    static func makeMappingResult(
        resultDirectory: URL,
        viewerBundleURL: URL
    ) -> MappingResult {
        MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: viewerBundleURL,
            bamURL: resultDirectory.appendingPathComponent("sample.sorted.bam"),
            baiURL: resultDirectory.appendingPathComponent("sample.sorted.bam.bai"),
            totalReads: 10,
            mappedReads: 9,
            unmappedReads: 1,
            wallClockSeconds: 1.0,
            contigs: []
        )
    }
}

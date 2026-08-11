import CryptoKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishKit

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

    @MainActor
    private final class FingerprintLoadGate {
        private var continuation:
            CheckedContinuation<GenotypeCurrentWorkbookInputFingerprint?, Never>?
        private(set) var loadCount = 0

        func load() async -> GenotypeCurrentWorkbookInputFingerprint? {
            loadCount += 1
            return await withCheckedContinuation { continuation = $0 }
        }

        func resume(with fingerprint: GenotypeCurrentWorkbookInputFingerprint?) {
            continuation?.resume(returning: fingerprint)
            continuation = nil
        }
    }

    @MainActor
    private final class WorkbookUpdateGate {
        private var continuation: CheckedContinuation<URL, Error>?
        private(set) var requests:
            [(GenotypeCurrentWorkbookSyncCoordinator.Request, GenotypeCurrentWorkbookSyncIntent)] = []

        func run(
            request: GenotypeCurrentWorkbookSyncCoordinator.Request,
            intent: GenotypeCurrentWorkbookSyncIntent
        ) async throws -> URL {
            requests.append((request, intent))
            return try await withCheckedThrowingContinuation {
                continuation = $0
            }
        }

        func succeed(with workbookURL: URL) {
            continuation?.resume(returning: workbookURL)
            continuation = nil
        }
    }

    @MainActor
    private final class WorkbookResultReloadGate {
        private(set) var loadCount = 0
        private var continuations:
            [Int: CheckedContinuation<ONTGenotypeResultBundleData, Error>] = [:]

        func load() async throws -> ONTGenotypeResultBundleData {
            let index = loadCount
            loadCount += 1
            return try await withCheckedThrowingContinuation {
                continuations[index] = $0
            }
        }

        func succeed(
            at index: Int,
            with result: ONTGenotypeResultBundleData
        ) {
            continuations.removeValue(forKey: index)?.resume(returning: result)
        }
    }

    private actor ManualHaplotypeConfigurationGate {
        private var continuation:
            CheckedContinuation<GenotypeManualHaplotypeDraftDecision, Never>?
        private var decisionCount = 0

        func decide() async -> GenotypeManualHaplotypeDraftDecision {
            decisionCount += 1
            guard decisionCount == 1 else {
                return .cancel
            }
            return await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func waitUntilPending() async -> Bool {
            for _ in 0..<1_000 {
                if continuation != nil {
                    return true
                }
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            return false
        }

        func resume(with decision: GenotypeManualHaplotypeDraftDecision) {
            continuation?.resume(returning: decision)
            continuation = nil
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

    func testDirectReferenceBAMRouteInstallsOneContextAndPublishesGenericImportsToListAndReopen() throws {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Direct BAM Metadata",
            chromosomes: [.init(name: "chr1", length: 100)]
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        try MappingRoutingFixture.addSingleSampleAlignment(to: bundleURL, sampleID: "S1")

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayReferenceBundleViewportFromSidebar(at: bundleURL)
        let firstContext = try MappingRoutingFixture.waitForBAMMetadataContext(on: split)
        let viewport = try XCTUnwrap(split.viewerController.referenceBundleViewportController)

        XCTAssertTrue(
            split.inspectorController.viewModel.documentSectionViewModel.sampleMetadataPresentationContext === firstContext
        )
        XCTAssertEqual(firstContext.identityIndex.canonicalSampleIDs, ["S1"])

        let importURL = bundleURL.deletingLastPathComponent().appendingPathComponent("samples.tsv")
        try "Sample\tCohort\nS1\tcase\n".write(to: importURL, atomically: true, encoding: .utf8)
        try split.inspectorController.testingImportMetadata(from: importURL)
        XCTAssertEqual(firstContext.sampleMetadataStore?.records["S1"]?["Cohort"], "case")

        let table = try XCTUnwrap(viewport.testSequenceTableView.tableView)
        let headerMenu = try XCTUnwrap(table.headerView?.menu)
        let cohortItem = try XCTUnwrap(headerMenu.items.firstIndex {
            ($0.representedObject as? String) == "Cohort"
        })
        headerMenu.performActionForItem(at: cohortItem)
        XCTAssertTrue(viewport.testRecordTableColumnIdentifiers.contains("metadata_Cohort"))
        let cohortColumn = table.column(withIdentifier: .init("metadata_Cohort"))
        XCTAssertGreaterThanOrEqual(cohortColumn, 0)
        let cell = table.view(atColumn: cohortColumn, row: 0, makeIfNecessary: true) as? NSTableCellView
        XCTAssertEqual(cell?.textField?.stringValue, "case")

        let reopened = MainSplitViewController()
        reopened.loadViewIfNeeded()
        reopened.displayReferenceBundleViewportFromSidebar(at: bundleURL)
        let reopenedContext = try MappingRoutingFixture.waitForBAMMetadataContext(on: reopened)
        XCTAssertEqual(reopenedContext.sampleMetadataStore?.records["S1"]?["Cohort"], "case")

        let replacementURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Replacement BAM Metadata",
            chromosomes: [.init(name: "chr2", length: 100)]
        )
        defer { try? FileManager.default.removeItem(at: replacementURL.deletingLastPathComponent()) }
        try MappingRoutingFixture.addSingleSampleAlignment(to: replacementURL, sampleID: "S2")
        split.displayReferenceBundleViewportFromSidebar(at: replacementURL)
        let replacementContext = try MappingRoutingFixture.waitForBAMMetadataContext(on: split, excluding: firstContext)
        let replacementViewport = try XCTUnwrap(split.viewerController.referenceBundleViewportController)
        XCTAssertFalse(replacementContext === firstContext)
        XCTAssertEqual(replacementContext.identityIndex.canonicalSampleIDs, ["S2"])
        firstContext.updateSampleMetadataStore(try SampleMetadataStore(
            csvData: Data("Sample\tCohort\nS1\tstale\n".utf8), knownSampleIds: ["S1"]
        ))
        XCTAssertNil(replacementViewport.testSequenceTableView.metadataColumns.store)
    }

    func testDirectReferenceBAMRouteExpandsTwoTracksIntoTruthfulSampleRowsAndSelection() throws {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Direct Multi BAM Metadata",
            chromosomes: [.init(name: "chr1", length: 100), .init(name: "chr2", length: 100)]
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        try MappingRoutingFixture.addSingleSampleAlignment(
            to: bundleURL, sampleID: "S1", trackID: "reads-s1"
        )
        try MappingRoutingFixture.addSingleSampleAlignment(
            to: bundleURL, sampleID: "S2", trackID: "reads-s2"
        )

        let split = MainSplitViewController()
        split.loadViewIfNeeded()
        split.displayReferenceBundleViewportFromSidebar(at: bundleURL)
        let context = try MappingRoutingFixture.waitForBAMMetadataContext(on: split)
        let viewport = try XCTUnwrap(split.viewerController.referenceBundleViewportController)

        XCTAssertEqual(context.identityIndex.canonicalSampleIDs, ["S1", "S2"])
        XCTAssertEqual(viewport.testDisplayedSequenceNames.count, 4)
        XCTAssertEqual(Set(viewport.testDisplayedSequenceSampleIDs.compactMap { $0 }), Set(["S1", "S2"]))
        XCTAssertTrue(viewport.testRecordTableColumnIdentifiers.contains("sample"))

        viewport.testSelectSequence(sampleID: "S2", named: "chr1")
        XCTAssertEqual(viewport.testVisibleAlignmentTrackID, "reads-s2")
        XCTAssertEqual(viewport.testSelectedReadGroups, Set(["S2-rg"]))
    }

    func testDirectSequenceNoRGFallbackClearsPreviousReadGroupFilter() throws {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Direct RG Clear",
            chromosomes: [.init(name: "chr1", length: 100)]
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        try MappingRoutingFixture.addSingleSampleAlignment(
            to: bundleURL, sampleID: "RG", trackID: "rg-track"
        )
        try MappingRoutingFixture.addSingleSampleAlignment(
            to: bundleURL, sampleID: "NoRG", trackID: "no-rg-track", includeReadGroup: false
        )

        let split = MainSplitViewController(); split.loadViewIfNeeded()
        split.displayReferenceBundleViewportFromSidebar(at: bundleURL)
        _ = try MappingRoutingFixture.waitForBAMMetadataContext(on: split)
        let viewport = try XCTUnwrap(split.viewerController.referenceBundleViewportController)

        viewport.testSelectSequence(sampleID: "RG", named: "chr1")
        XCTAssertEqual(viewport.testSelectedReadGroups, Set(["RG-rg"]))
        viewport.testSelectSequence(sampleID: "NoRG", named: "chr1")
        XCTAssertEqual(viewport.testVisibleAlignmentTrackID, "no-rg-track")
        XCTAssertEqual(viewport.testSelectedReadGroups, [])
    }

    func testBAMInstallerMergesCaseWhitespaceEquivalentTracksAndExplicitAliases() throws {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Canonical BAM Merge",
            chromosomes: [.init(name: "chr1", length: 100)]
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        try MappingRoutingFixture.addSingleSampleAlignment(to: bundleURL, sampleID: " S1 ", trackID: "track-a")
        try MappingRoutingFixture.addSingleSampleAlignment(to: bundleURL, sampleID: "s1", trackID: "track-b")

        let split = MainSplitViewController(); split.loadViewIfNeeded()
        let manifest = try BundleManifest.load(from: bundleURL)
        try split.viewerController.display(ViewerDisplayRouteFactory.directReferenceBundle(
            bundleURL: bundleURL, manifest: manifest
        ))
        split.installBAMMetadataPresentation(
            resultURL: bundleURL,
            bundleURL: bundleURL,
            workflowName: "Reference Bundle",
            persistedSampleAliases: ["S1": ["subject-1"]]
        )

        let index = try XCTUnwrap(split.bamMetadataPresentationContext?.identityIndex)
        XCTAssertEqual(index.canonicalSampleIDs, Set(["S1"]))
        XCTAssertEqual(index.alignmentTrackIDs(forCanonicalSampleID: "s1"), Set(["track-a", "track-b"]))
        XCTAssertEqual(index.readGroupIDs(forCanonicalSampleID: "S1"), Set([" S1 -rg", "s1-rg"]))
        XCTAssertEqual(index.canonicalSampleID(forMetadataIdentifier: "subject-1"), "S1")
    }

    func testSidebarMappingRoutePassesViewerManifestAndBuildsInitialSampleRows() throws {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Sidebar Initial BAM Rows",
            chromosomes: [.init(name: "chr1", length: 100)]
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        try MappingRoutingFixture.addSingleSampleAlignment(
            to: bundleURL, sampleID: "S1", includeReadGroup: false, includeChromosomeStats: true
        )
        let statsDatabase = try AlignmentMetadataDatabase(
            url: bundleURL.appendingPathComponent("alignments/reads-track.metadata.sqlite")
        )
        XCTAssertEqual(statsDatabase.chromosomeStats().first?.mappedReads, 1)
        XCTAssertEqual(try BundleManifest.load(from: bundleURL).alignments.map(\.id), ["reads-track"])
        let resultURL = bundleURL.deletingLastPathComponent().appendingPathComponent("mapping-result", isDirectory: true)
        try FileManager.default.createDirectory(at: resultURL, withIntermediateDirectories: true)
        let result = MappingRoutingFixture.makeMappingResult(
            resultDirectory: resultURL, viewerBundleURL: bundleURL
        )
        try result.save(to: resultURL)

        let split = MainSplitViewController(); split.loadViewIfNeeded()
        split.displayMappingAnalysisFromSidebar(at: resultURL)
        let viewport = try MappingRoutingFixture.waitForInitialSampleRows(on: split)
        XCTAssertEqual(viewport.currentInput?.viewerBundleManifest?.identifier, (try BundleManifest.load(from: bundleURL)).identifier)
        XCTAssertEqual(viewport.testContigTableView.displayedRows.map(\.sampleID), ["S1"])
    }

    func testSidebarMappingRouteUsesPersistedManifestSampleNameAliasForImportedMetadata() throws {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Sidebar Manifest Alias",
            chromosomes: [.init(name: "chr1", length: 100)]
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        try MappingRoutingFixture.addSingleSampleAlignment(
            to: bundleURL,
            sampleID: "S1",
            includeReadGroup: true,
            includeChromosomeStats: true,
            manifestSampleNames: ["subject-1"]
        )
        let resultURL = bundleURL.deletingLastPathComponent().appendingPathComponent(
            "mapping-result", isDirectory: true
        )
        try FileManager.default.createDirectory(at: resultURL, withIntermediateDirectories: true)
        let result = MappingRoutingFixture.makeMappingResult(
            resultDirectory: resultURL, viewerBundleURL: bundleURL
        )
        try result.save(to: resultURL)
        let metadataURL = resultURL.appendingPathComponent("metadata/sample_metadata.tsv")
        try FileManager.default.createDirectory(
            at: metadataURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("Sample\tCohort\nsubject-1\tcase\n".utf8).write(to: metadataURL)

        let split = MainSplitViewController(); split.loadViewIfNeeded()
        split.displayMappingAnalysisFromSidebar(at: resultURL)
        let context = try MappingRoutingFixture.waitForBAMMetadataContext(on: split)

        XCTAssertEqual(context.identityIndex.canonicalSampleID(forMetadataIdentifier: "subject-1"), "S1")
        XCTAssertEqual(context.sampleMetadataStore?.records["S1"]?["Cohort"], "case")
        XCTAssertTrue(context.sampleMetadataStore?.unmatchedRecords.isEmpty ?? false)
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

    func testCandidateOnlyGenotypeResultDisplaysNativeRawMatrix() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeCandidateOnlyRoute-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "candidate-only",
            haplotypeAnalysisPath: nil,
            includeGenotypeCalls: false,
            genotypeOnlyWorkflowKind: .fullLengthONTMHCGenotype,
            includeReviewableRowCatalog: true
        )
        let controller = MainSplitViewController()
        _ = controller.view

        await controller.testingDisplayGenotypeResultBundleAndWait(bundleURL)

        XCTAssertNil(controller.viewerController.testQuickLookURL)
        let resultController = try XCTUnwrap(
            controller.viewerController.genotypeResultViewController
        )
        XCTAssertEqual(resultController.testingSummaryViewMode, .matrix)
        XCTAssertFalse(resultController.testingComparisonMatrixIsHidden)
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

    func testGenotypeMatrixVisibilityBridgePublishesInitialCapabilityAndRoutesViewCommand()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeVisibilityBridge-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "visibility-bridge",
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
        XCTAssertEqual(
            viewModel.matrixVisibilityCapability,
            resultController.testingMatrixVisibilityCapability
        )
        XCTAssertEqual(viewModel.matrixVisibilityScopeSummary, "Scope: Entire matrix")
        XCTAssertEqual(
            viewModel.matrixVisibilityStatus,
            "No manual visibility restrictions."
        )

        resultController.testingSetQuickFilterSearchText("does-not-match")
        XCTAssertTrue(resultController.testingVisibleMatrixGenotypes.isEmpty)
        XCTAssertEqual(
            viewModel.matrixVisibilityStatus,
            "No manual visibility restrictions."
        )
        resultController.testingSetQuickFilterSearchText("")

        resultController.testingSelectMatrixRows(
            genotypes: ["01_Mafa_A1_063g"],
            sample: nil
        )
        XCTAssertEqual(
            viewModel.matrixVisibilityScopeSummary,
            "Selected: 1 allele row"
        )
        viewModel.showOnlySelectedMatrixRows()
        XCTAssertEqual(
            resultController.testingVisibleMatrixGenotypes,
            ["01_Mafa_A1_063g"]
        )
        XCTAssertEqual(
            viewModel.matrixVisibilityStatus,
            "Manual allele-row visibility is active."
        )
        viewModel.resetMatrixVisibility()
        resultController.testingSelectMatrixRows(
            genotypes: ["01_Mafa_A1_063g"],
            sample: nil
        )
        viewModel.hideSelectedMatrixRows()

        XCTAssertTrue(resultController.testingVisibleMatrixGenotypes.isEmpty)
        XCTAssertTrue(viewModel.canResetMatrixVisibility)
    }

    func testStaleGenotypeVisibilityCommandCannotAffectReplacementBundle()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeVisibilitySwitch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstBundle = try makeGenotypeResultBundle(
            root: root,
            name: "visibility-first",
            haplotypeAnalysisPath: nil
        )
        let secondBundle = try makeGenotypeResultBundle(
            root: root,
            name: "visibility-second",
            haplotypeAnalysisPath: nil
        )
        let splitController = MainSplitViewController()
        _ = splitController.view
        await splitController.testingDisplayGenotypeResultBundleAndWait(firstBundle)
        let firstController = try XCTUnwrap(
            splitController.viewerController.genotypeResultViewController
        )
        firstController.testingSelectMatrixRows(
            genotypes: ["01_Mafa_A1_063g"],
            sample: nil
        )
        let firstView = firstController.view
        XCTAssertEqual(
            splitController.viewerController.children
                .compactMap { $0 as? GenotypeResultViewController }
                .count,
            1
        )
        let staleCommand = splitController.inspectorController
            .genotypeResultDisplaySectionViewModel
            .onMatrixVisibilityCommandRequested

        await splitController.testingDisplayGenotypeResultBundleAndWait(secondBundle)
        let secondController = try XCTUnwrap(
            splitController.viewerController.genotypeResultViewController
        )
        staleCommand?(.hideSelectedRows)

        XCTAssertEqual(
            firstController.testingVisibleMatrixGenotypes,
            ["01_Mafa_A1_063g"]
        )
        XCTAssertEqual(
            secondController.testingVisibleMatrixGenotypes,
            ["01_Mafa_A1_063g"]
        )
        XCTAssertNil(firstView.superview)
        XCTAssertTrue(secondController.view.superview === splitController.viewerController.view)
        XCTAssertEqual(
            splitController.viewerController.children
                .compactMap { $0 as? GenotypeResultViewController }
                .count,
            1
        )
        XCTAssertNil(firstController.onMatrixVisibilityCapabilityChanged)
        XCTAssertEqual(
            splitController.inspectorController
                .genotypeResultDisplaySectionViewModel
                .matrixVisibilityScopeSummary,
            "Scope: Entire matrix"
        )
    }

    func testGenotypeVisibilityCommandsAreIsolatedAcrossTwoWindows()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeVisibilityWindows-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstBundle = try makeGenotypeResultBundle(
            root: root,
            name: "visibility-window-one",
            haplotypeAnalysisPath: nil
        )
        let secondBundle = try makeGenotypeResultBundle(
            root: root,
            name: "visibility-window-two",
            haplotypeAnalysisPath: nil
        )
        let first = MainSplitViewController()
        let second = MainSplitViewController()
        _ = first.view
        _ = second.view
        await first.testingDisplayGenotypeResultBundleAndWait(firstBundle)
        await second.testingDisplayGenotypeResultBundleAndWait(secondBundle)
        let firstResult = try XCTUnwrap(
            first.viewerController.genotypeResultViewController
        )
        let secondResult = try XCTUnwrap(
            second.viewerController.genotypeResultViewController
        )
        firstResult.testingSelectMatrixRows(
            genotypes: ["01_Mafa_A1_063g"],
            sample: nil
        )
        secondResult.testingSelectMatrixRows(
            genotypes: ["01_Mafa_A1_063g"],
            sample: nil
        )

        first.inspectorController.genotypeResultDisplaySectionViewModel
            .hideSelectedMatrixRows()

        XCTAssertTrue(firstResult.testingVisibleMatrixGenotypes.isEmpty)
        XCTAssertEqual(
            secondResult.testingVisibleMatrixGenotypes,
            ["01_Mafa_A1_063g"]
        )
        XCTAssertTrue(
            first.inspectorController.genotypeResultDisplaySectionViewModel
                .canResetMatrixVisibility
        )
        XCTAssertFalse(
            second.inspectorController.genotypeResultDisplaySectionViewModel
                .canResetMatrixVisibility
        )
    }

    func testInspectorVisibilityCommandsDoNotMutateBundleOrWorkbookDirtyFlags()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeVisibilityArtifacts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "visibility-artifacts",
            haplotypeAnalysisPath: nil
        )
        let splitController = MainSplitViewController()
        _ = splitController.view
        await splitController.testingDisplayGenotypeResultBundleAndWait(bundleURL)
        let resultController = try XCTUnwrap(
            splitController.viewerController.genotypeResultViewController
        )
        let beforeFiles = try recursiveFileBytes(in: bundleURL)
        let beforeNeedsRefresh = resultController.testingCurrentWorkbookNeedsRefresh
        let beforeRequiresFullUpdate =
            resultController.testingCurrentWorkbookRequiresFullUpdate
        let viewModel = splitController.inspectorController
            .genotypeResultDisplaySectionViewModel

        resultController.testingSelectMatrixRows(
            genotypes: ["01_Mafa_A1_063g"],
            sample: nil
        )
        viewModel.showOnlySelectedMatrixRows()
        viewModel.resetMatrixVisibility()
        resultController.testingSelectMatrixColumns(samples: ["DW472"])
        viewModel.hideSelectedMatrixColumns()
        viewModel.resetMatrixVisibility()

        XCTAssertEqual(try recursiveFileBytes(in: bundleURL), beforeFiles)
        XCTAssertEqual(
            resultController.testingCurrentWorkbookNeedsRefresh,
            beforeNeedsRefresh
        )
        XCTAssertEqual(
            resultController.testingCurrentWorkbookRequiresFullUpdate,
            beforeRequiresFullUpdate
        )
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

    func testMainSplitDefaultsToApplicationSharedWorkbookCoordinator() {
        let first = MainSplitViewController()
        let second = MainSplitViewController()

        XCTAssertTrue(
            first.genotypeCurrentWorkbookSyncCoordinator
                === second.genotypeCurrentWorkbookSyncCoordinator
        )
    }

    func testTwoWindowsShareOneSameBundleWorkbookUpdateAndOpen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeWorkbookTwoWindows-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "two-window-single-flight",
            haplotypeAnalysisPath: nil
        )
        let workbookURL = bundleURL.appendingPathComponent("current.xlsx")
        let updateGate = WorkbookUpdateGate()
        var openedURLs: [URL] = []
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in nil },
            updateRunner: { request, intent in
                try await updateGate.run(request: request, intent: intent)
            },
            workbookOpener: { openedURLs.append($0) },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        let first = MainSplitViewController()
        let second = MainSplitViewController()
        first.genotypeCurrentWorkbookSyncCoordinator = coordinator
        second.genotypeCurrentWorkbookSyncCoordinator = coordinator
        _ = first.view
        _ = second.view
        await first.testingDisplayGenotypeResultBundleAndWait(bundleURL)
        await second.testingDisplayGenotypeResultBundleAndWait(bundleURL)
        let bothRegistered = await eventually {
            coordinator.phase(for: bundleURL) == .dirty
        }
        XCTAssertTrue(bothRegistered)

        first.viewerController.genotypeResultViewController?
            .testingRequestCurrentWorkbookUpdateAndView()
        second.viewerController.genotypeResultViewController?
            .testingRequestCurrentWorkbookUpdateAndView()

        let updateStarted = await eventually { updateGate.requests.count == 1 }
        XCTAssertTrue(updateStarted)
        updateGate.succeed(with: workbookURL)
        let openedOnce = await eventually {
            openedURLs == [workbookURL.standardizedFileURL]
        }
        XCTAssertTrue(openedOnce)
        XCTAssertEqual(updateGate.requests.count, 1)
    }

    func testProjectSessionWriteDenialCannotRunOrOpenDirtyWorkbook() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeWorkbookProjectDenied-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "project-session-denied",
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
        splitController.genotypeCurrentWorkbookProjectWriteAuthorizationProvider = {
            false
        }
        _ = splitController.view
        await splitController.testingDisplayGenotypeResultBundleAndWait(bundleURL)
        let registeredDirty = await eventually {
            coordinator.phase(for: bundleURL) == .dirty
        }
        XCTAssertTrue(registeredDirty)

        splitController.viewerController.genotypeResultViewController?
            .testingRequestCurrentWorkbookUpdateAndView()
        let routingFinished = await eventually {
            splitController.pendingGenotypeCurrentWorkbookRoutes.isEmpty
        }
        XCTAssertTrue(routingFinished)
        XCTAssertEqual(updateCount, 0)
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testRegisteredWorkbookRequestRevalidatesCurrentWindowAuthorization()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GenotypeWorkbookFreshWindowAuthorization-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "fresh-window-authorization",
            haplotypeAnalysisPath: nil
        )
        var allowsWrites = true
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in nil },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        let splitController = MainSplitViewController()
        splitController.genotypeCurrentWorkbookSyncCoordinator = coordinator
        splitController.genotypeCurrentWorkbookProjectWriteAuthorizationProvider = {
            allowsWrites
        }
        _ = splitController.view

        await splitController.testingDisplayGenotypeResultBundleAndWait(bundleURL)
        let registered = await eventually {
            coordinator.testingLatestRequestIsUpdateAuthorized(
                for: bundleURL
            ) == true
        }
        XCTAssertTrue(registered)

        allowsWrites = false

        XCTAssertEqual(
            coordinator.testingLatestRequestIsUpdateAuthorized(for: bundleURL),
            false
        )
    }

    func testRegisteredWorkbookAuthorizationDoesNotRetainWindowController()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GenotypeWorkbookWeakWindowAuthorization-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "weak-window-authorization",
            haplotypeAnalysisPath: nil
        )
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in nil },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        var splitController: MainSplitViewController? = MainSplitViewController()
        splitController?.genotypeCurrentWorkbookSyncCoordinator = coordinator
        _ = splitController?.view
        await splitController?.testingDisplayGenotypeResultBundleAndWait(bundleURL)
        let registered = await eventually {
            coordinator.testingLatestRequestIsUpdateAuthorized(
                for: bundleURL
            ) == true
        }
        XCTAssertTrue(registered)
        let weakController = WeakReference(splitController)

        splitController = nil
        let released = await eventually { weakController.value == nil }

        XCTAssertTrue(released)
        XCTAssertEqual(
            coordinator.testingLatestRequestIsUpdateAuthorized(for: bundleURL),
            false
        )
    }

    func testUnauthorizedSynchronizeCleansContextWithoutPhaseTransition()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GenotypeWorkbookUnauthorizedContextCleanup-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "unauthorized-context-cleanup",
            haplotypeAnalysisPath: nil
        )
        var allowsWrites = true
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in nil },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        let splitController = MainSplitViewController()
        splitController.genotypeCurrentWorkbookSyncCoordinator = coordinator
        splitController.genotypeCurrentWorkbookProjectWriteAuthorizationProvider = {
            allowsWrites
        }
        _ = splitController.view
        await splitController.testingDisplayGenotypeResultBundleAndWait(bundleURL)
        let registeredDirty = await eventually {
            coordinator.phase(for: bundleURL) == .dirty
                && splitController
                    .testingGenotypeCurrentWorkbookRetentionDiagnostics
                    .completionContextCount == 1
        }
        XCTAssertTrue(registeredDirty)

        allowsWrites = false
        splitController.viewerController.genotypeResultViewController?
            .testingRequestCurrentWorkbookUpdateAndView()

        let released = await eventually {
            splitController.pendingGenotypeCurrentWorkbookRoutes.isEmpty
                && splitController
                    .testingGenotypeCurrentWorkbookRetentionDiagnostics
                    .completionContextCount == 0
        }
        XCTAssertTrue(released)
        XCTAssertEqual(coordinator.phase(for: bundleURL), .dirty)
    }

    func testOlderUnauthorizedCatchPreservesNewerCompletionContext()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GenotypeWorkbookGenerationScopedCleanup-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceBundle = try makeGenotypeResultBundle(
            root: root,
            name: "generation-scoped-source",
            haplotypeAnalysisPath: nil
        )
        let loadedResult = try await ONTGenotypeResultBundle.loadResultAsync(
            from: sourceBundle
        )
        let snapshotProbe = GenotypeResultViewController()
        _ = snapshotProbe.view
        var probeRequest: GenotypeCurrentWorkbookUIRequest?
        snapshotProbe.onCurrentWorkbookSyncRequested = {
            probeRequest = $0
        }
        snapshotProbe.configure(result: loadedResult)
        snapshotProbe.requestCurrentWorkbookRegistration()
        let sourceSnapshot = try XCTUnwrap(probeRequest?.snapshot)
        let routedBundle = root.appendingPathComponent(
            "generation-scoped-route.lungfishgenotype",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: routedBundle,
            withIntermediateDirectories: true
        )
        let deniedSnapshot = GenotypeCurrentWorkbookUISnapshot(
            bundleURL: routedBundle,
            calls: sourceSnapshot.calls,
            includedLoci: sourceSnapshot.includedLoci,
            annotationSidecar: sourceSnapshot.annotationSidecar,
            annotationSidecarData: sourceSnapshot.annotationSidecarData,
            annotationSidecarURL: sourceSnapshot.annotationSidecarURL,
            candidateArtifacts: sourceSnapshot.candidateArtifacts,
            annotationOnly: sourceSnapshot.annotationOnly,
            isReadOnly: true
        )
        let newerSnapshot = GenotypeCurrentWorkbookUISnapshot(
            bundleURL: routedBundle,
            calls: sourceSnapshot.calls,
            includedLoci: sourceSnapshot.includedLoci,
            annotationSidecar: sourceSnapshot.annotationSidecar,
            annotationSidecarData: sourceSnapshot.annotationSidecarData,
            annotationSidecarURL: sourceSnapshot.annotationSidecarURL,
            candidateArtifacts: sourceSnapshot.candidateArtifacts,
            annotationOnly: sourceSnapshot.annotationOnly,
            isReadOnly: false
        )
        let fingerprintGate = FingerprintLoadGate()
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in await fingerprintGate.load() },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        let splitController = MainSplitViewController()
        splitController.genotypeCurrentWorkbookSyncCoordinator = coordinator
        _ = splitController.view

        splitController.routeGenotypeCurrentWorkbookRequest(.init(
            snapshot: deniedSnapshot,
            action: .synchronize(.updateAndView)
        ))
        let olderReachedCoordinator = await eventually {
            fingerprintGate.loadCount == 1
        }
        XCTAssertTrue(olderReachedCoordinator)
        splitController.routeGenotypeCurrentWorkbookRequest(.init(
            snapshot: newerSnapshot,
            action: .register
        ))
        let newerContextInstalled = await eventually {
            splitController.pendingGenotypeCurrentWorkbookRoutes.isEmpty
                && splitController
                    .testingGenotypeCurrentWorkbookRetentionDiagnostics
                    .completionContextCount == 1
        }
        XCTAssertTrue(newerContextInstalled)

        fingerprintGate.resume(with: nil)

        let settled = await eventually {
            coordinator.phase(for: routedBundle) == .dirty
                && splitController.pendingGenotypeCurrentWorkbookRoutes.isEmpty
        }
        XCTAssertTrue(settled)
        let diagnostics =
            splitController.testingGenotypeCurrentWorkbookRetentionDiagnostics
        XCTAssertEqual(diagnostics.completionContextCount, 1)
        XCTAssertEqual(diagnostics.inactiveCompletionContextCount, 1)
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

    func testSuccessfulFullWorkbookPublicationReloadsResultAndClearsFullUpdateRequirement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeWorkbookCompletionReload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "completion-reload",
            haplotypeAnalysisPath: nil
        )
        let updatedResult = try await ONTGenotypeResultBundle.loadResultAsync(
            from: bundleURL
        )
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in nil },
            updateRunner: { request, _ in
                request.bundleURL.appendingPathComponent("current.xlsx")
            },
            workbookOpener: { _ in },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        let splitController = MainSplitViewController()
        splitController.genotypeCurrentWorkbookSyncCoordinator = coordinator
        _ = splitController.view
        await splitController.testingDisplayGenotypeResultBundleAndWait(bundleURL)
        let resultController = try XCTUnwrap(
            splitController.viewerController.genotypeResultViewController
        )
        var capturedRequest: GenotypeCurrentWorkbookUIRequest?
        resultController.onCurrentWorkbookSyncRequested = { capturedRequest = $0 }
        resultController.requestCurrentWorkbookRegistration()
        let snapshot = try XCTUnwrap(capturedRequest?.snapshot)
        resultController.testingSelectMatrixRows(
            genotypes: ["01_Mafa_A1_063g"],
            sample: nil
        )
        splitController.inspectorController.genotypeResultDisplaySectionViewModel
            .hideSelectedMatrixRows()
        XCTAssertTrue(resultController.testingVisibleMatrixGenotypes.isEmpty)
        XCTAssertTrue(
            splitController.inspectorController.genotypeResultDisplaySectionViewModel
                .canResetMatrixVisibility
        )
        resultController.testingRequireFullCurrentWorkbookUpdate()
        splitController.genotypeResultLoader = { _ in
            return updatedResult
        }
        let fullSnapshot = GenotypeCurrentWorkbookUISnapshot(
            bundleURL: snapshot.bundleURL,
            calls: snapshot.calls,
            includedLoci: snapshot.includedLoci,
            annotationSidecar: snapshot.annotationSidecar,
            annotationSidecarData: snapshot.annotationSidecarData,
            annotationSidecarURL: snapshot.annotationSidecarURL,
            candidateArtifacts: snapshot.candidateArtifacts,
            annotationOnly: false,
            isReadOnly: snapshot.isReadOnly
        )

        splitController.routeGenotypeCurrentWorkbookRequest(.init(
            snapshot: fullSnapshot,
            action: .synchronize(.updateAndView)
        ))

        let completionApplied = await eventually {
            !resultController.testingCurrentWorkbookRequiresFullUpdate
                && !resultController.testingCurrentWorkbookNeedsRefresh
        }
        XCTAssertTrue(completionApplied)
        XCTAssertTrue(resultController.testingVisibleMatrixGenotypes.isEmpty)
        XCTAssertTrue(
            splitController.inspectorController.genotypeResultDisplaySectionViewModel
                .canResetMatrixVisibility
        )
        XCTAssertEqual(
            splitController.inspectorController.genotypeResultDisplaySectionViewModel
                .matrixVisibilityCapability,
            resultController.testingMatrixVisibilityCapability
        )
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
        let cleanPhaseApplied = await eventually {
            resultController.testingCurrentWorkbookUpdateStatus
                == "Current — current.xlsx represents the latest LGE review state."
                && resultController.testingCurrentWorkbookUpdateButtonEnabled
        }
        XCTAssertTrue(cleanPhaseApplied)

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

    func testHidingWhileInitialRegistrationIsPendingStillRoutesBundleSwitch() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeWorkbookPendingSwitch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "pending-registration-switch",
            haplotypeAnalysisPath: nil
        )
        let fingerprintGate = FingerprintLoadGate()
        var routedIntents: [GenotypeCurrentWorkbookSyncIntent] = []
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in await fingerprintGate.load() },
            updateRunner: { request, intent in
                routedIntents.append(intent)
                return request.bundleURL.appendingPathComponent("current.xlsx")
            },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        let splitController = MainSplitViewController()
        splitController.genotypeCurrentWorkbookSyncCoordinator = coordinator
        _ = splitController.view
        await splitController.testingDisplayGenotypeResultBundleAndWait(bundleURL)
        let registrationStarted = await eventually {
            fingerprintGate.loadCount == 1
        }
        XCTAssertTrue(registrationStarted)

        splitController.viewerController.hideGenotypeResultView()
        fingerprintGate.resume(with: nil)

        let synchronizedOnSwitch = await eventually {
            routedIntents == [.bundleSwitch]
        }
        XCTAssertTrue(synchronizedOnSwitch)
    }

    func testReadOnlyFastClickDuringPendingRegistrationCannotRunOrOpen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenotypeWorkbookPendingReadOnly-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "pending-read-only-fast-click",
            haplotypeAnalysisPath: nil
        )
        let fingerprintGate = FingerprintLoadGate()
        var updateCount = 0
        var openedURLs: [URL] = []
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in await fingerprintGate.load() },
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
        let registrationStarted = await eventually {
            fingerprintGate.loadCount == 1
        }
        XCTAssertTrue(registrationStarted)
        let resultController = try XCTUnwrap(
            splitController.viewerController.genotypeResultViewController
        )
        var capturedRequest: GenotypeCurrentWorkbookUIRequest?
        resultController.onCurrentWorkbookSyncRequested = { capturedRequest = $0 }
        resultController.requestCurrentWorkbookRegistration()
        splitController.routeGenotypeCurrentWorkbookRequest(.init(
            snapshot: readOnlySnapshot(try XCTUnwrap(capturedRequest?.snapshot)),
            action: .synchronize(.updateAndView)
        ))

        fingerprintGate.resume(with: nil)
        let routingFinished = await eventually {
            splitController.pendingGenotypeCurrentWorkbookRoutes.isEmpty
        }
        XCTAssertTrue(routingFinished)
        XCTAssertEqual(updateCount, 0)
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
        let secondBundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "deferred-mutation-active-bundle",
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

        await splitController.testingDisplayGenotypeResultBundleAndWait(
            secondBundleURL
        )
        resultController = nil

        XCTAssertNotNil(weakResultController.value)
        XCTAssertEqual(
            splitController.inspectorController.viewModel.documentSectionViewModel
                .genotypeResultDocument?.bundleURL?.standardizedFileURL,
            secondBundleURL.standardizedFileURL
        )
        XCTAssertNil(weakResultController.value?.onSelectionStateChanged)
        XCTAssertNil(weakResultController.value?.onDisplaySummaryChanged)
        XCTAssertNil(weakResultController.value?.onDisplayStateChanged)
        XCTAssertNil(weakResultController.value?.onAnnotationSidecarChanged)
        XCTAssertNil(weakResultController.value?.onMatrixReviewCapabilityChanged)
        XCTAssertNil(weakResultController.value?.onMatrixAnnotationCommandError)
        XCTAssertNil(
            weakResultController.value?.onCandidatePersistenceWarningChanged
        )
        XCTAssertNil(weakResultController.value?.onAIHaplotypingRequested)
        XCTAssertNotNil(weakResultController.value?.onCurrentWorkbookSyncRequested)
        XCTAssertNotNil(
            weakResultController.value?
                .onDeferredMatrixAnnotationMutationsDrained
        )
        publicationLock.release()
        scheduler.fire()
        let persisted = try ONTGenotypeResultBundleData.loadOrCreateAnnotationSidecar(
            forBundleAt: bundleURL
        )
        XCTAssertEqual(
            persisted.matrixComments.first?.body,
            "survive bundle switch"
        )
        XCTAssertEqual(
            splitController.inspectorController.viewModel.documentSectionViewModel
                .genotypeResultDocument?.bundleURL?.standardizedFileURL,
            secondBundleURL.standardizedFileURL
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

    func testManyInactiveWorkbookPublicationsReleaseFullSnapshotsAndTasks()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GenotypeWorkbookRetentionStress-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let activeBundle = try makeGenotypeResultBundle(
            root: root,
            name: "retention-active",
            haplotypeAnalysisPath: nil
        )
        var updateCount = 0
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in nil },
            updateRunner: { request, _ in
                updateCount += 1
                return request.bundleURL.appendingPathComponent("current.xlsx")
            },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        let splitController = MainSplitViewController()
        splitController.genotypeCurrentWorkbookSyncCoordinator = coordinator
        _ = splitController.view
        await splitController.testingDisplayGenotypeResultBundleAndWait(
            activeBundle
        )
        let resultController = try XCTUnwrap(
            splitController.viewerController.genotypeResultViewController
        )
        var capturedRequest: GenotypeCurrentWorkbookUIRequest?
        resultController.onCurrentWorkbookSyncRequested = {
            capturedRequest = $0
        }
        resultController.requestCurrentWorkbookRegistration()
        let activeSnapshot = try XCTUnwrap(capturedRequest?.snapshot)
        let inactiveBundles = (0..<24).map {
            root.appendingPathComponent(
                "inactive-\($0).lungfishgenotype",
                isDirectory: true
            )
        }

        for bundleURL in inactiveBundles {
            try FileManager.default.createDirectory(
                at: bundleURL,
                withIntermediateDirectories: true
            )
            let snapshot = GenotypeCurrentWorkbookUISnapshot(
                bundleURL: bundleURL,
                calls: activeSnapshot.calls,
                includedLoci: activeSnapshot.includedLoci,
                annotationSidecar: activeSnapshot.annotationSidecar,
                annotationSidecarData: activeSnapshot.annotationSidecarData,
                annotationSidecarURL: activeSnapshot.annotationSidecarURL,
                candidateArtifacts: activeSnapshot.candidateArtifacts,
                annotationOnly: activeSnapshot.annotationOnly,
                isReadOnly: false
            )
            splitController.routeGenotypeCurrentWorkbookRequest(.init(
                snapshot: snapshot,
                action: .synchronize(.bundleSwitch)
            ))
        }

        let allTerminal = await eventually(timeout: 5) {
            updateCount == inactiveBundles.count
                && inactiveBundles.allSatisfy {
                coordinator.phase(for: $0) == .current
            }
                && splitController.pendingGenotypeCurrentWorkbookRoutes.isEmpty
        }
        XCTAssertTrue(allTerminal)
        let diagnostics =
            splitController.testingGenotypeCurrentWorkbookRetentionDiagnostics
        XCTAssertEqual(diagnostics.pendingFullSnapshotCount, 0)
        XCTAssertEqual(diagnostics.inactiveCompletionContextCount, 0)
        XCTAssertEqual(diagnostics.reloadTaskCount, 0)
        XCTAssertEqual(diagnostics.retainedDetachedControllerCount, 0)
        XCTAssertLessThanOrEqual(diagnostics.completionContextCount, 1)
    }

    func testCancelledReloadCannotReleaseSameGenerationReplacementInputs()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GenotypeWorkbookReloadReplacement-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = try makeGenotypeResultBundle(
            root: root,
            name: "reload-replacement",
            haplotypeAnalysisPath: nil
        )
        let updatedResult = try await ONTGenotypeResultBundle.loadResultAsync(
            from: bundleURL
        )
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in nil },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        let splitController = MainSplitViewController()
        splitController.genotypeCurrentWorkbookSyncCoordinator = coordinator
        _ = splitController.view
        await splitController.testingDisplayGenotypeResultBundleAndWait(bundleURL)
        let registered = await eventually {
            splitController
                .testingGenotypeCurrentWorkbookRetentionDiagnostics
                .completionContextCount == 1
        }
        XCTAssertTrue(registered)
        let reloadGate = WorkbookResultReloadGate()
        splitController.genotypeResultLoader = { _ in
            try await reloadGate.load()
        }

        splitController.applyGenotypeCurrentWorkbookSyncPhase(
            .current,
            bundleURL: bundleURL
        )
        let firstStarted = await eventually { reloadGate.loadCount == 1 }
        XCTAssertTrue(firstStarted)
        splitController.applyGenotypeCurrentWorkbookSyncPhase(
            .current,
            bundleURL: bundleURL
        )
        let replacementStarted = await eventually { reloadGate.loadCount == 2 }
        XCTAssertTrue(replacementStarted)

        reloadGate.succeed(at: 0, with: updatedResult)
        await Task.yield()

        var diagnostics =
            splitController.testingGenotypeCurrentWorkbookRetentionDiagnostics
        XCTAssertEqual(diagnostics.completionContextCount, 1)
        XCTAssertEqual(diagnostics.reloadTaskCount, 1)

        reloadGate.succeed(at: 1, with: updatedResult)
        let replacementFinished = await eventually {
            splitController
                .testingGenotypeCurrentWorkbookRetentionDiagnostics
                .reloadTaskCount == 0
        }
        XCTAssertTrue(replacementFinished)
        diagnostics =
            splitController.testingGenotypeCurrentWorkbookRetentionDiagnostics
        XCTAssertEqual(diagnostics.completionContextCount, 0)
    }

    func testCompletedWorkbookReloadCannotApplyAfterReplacementConfigurationIsQueued()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GenotypeWorkbookQueuedConfiguration-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let firstBundle = try makeGenotypeResultBundle(
            root: root,
            name: "host-authority-first",
            haplotypeAnalysisPath: nil,
            genotypeOnlyWorkflowKind: .fullLengthONTMHCGenotype
        )
        let secondBundle = try makeGenotypeResultBundle(
            root: root,
            name: "host-authority-second",
            haplotypeAnalysisPath: nil,
            genotypeOnlyWorkflowKind: .fullLengthONTMHCGenotype
        )
        let secondResult = try await ONTGenotypeResultBundle.loadResultAsync(
            from: secondBundle
        )
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in nil },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        let splitController = MainSplitViewController()
        splitController.genotypeCurrentWorkbookSyncCoordinator = coordinator
        _ = splitController.view
        await splitController.testingDisplayGenotypeResultBundleAndWait(
            firstBundle
        )
        let registered = await eventually {
            splitController
                .testingGenotypeCurrentWorkbookRetentionDiagnostics
                .completionContextCount == 1
        }
        XCTAssertTrue(registered)
        let resultController = try XCTUnwrap(
            splitController.viewerController.genotypeResultViewController
        )
        resultController.testingSelectMatrixColumn(sample: "DW472")
        resultController.testingUpdateManualHaplotypeLabel("H1")
        XCTAssertTrue(resultController.testingManualHaplotypeEditorIsDirty)

        let reloadGate = WorkbookResultReloadGate()
        splitController.genotypeResultLoader = { _ in
            try await reloadGate.load()
        }
        splitController.applyGenotypeCurrentWorkbookSyncPhase(
            .current,
            bundleURL: firstBundle
        )
        let reloadStarted = await eventually { reloadGate.loadCount == 1 }
        XCTAssertTrue(reloadStarted)

        let configurationGate = ManualHaplotypeConfigurationGate()
        resultController.testingSetManualHaplotypeDraftDecisionProvider { _ in
            await configurationGate.decide()
        }
        resultController.configure(result: secondResult)
        let configurationIsPending =
            await configurationGate.waitUntilPending()
        XCTAssertTrue(configurationIsPending)
        guard configurationIsPending else {
            return
        }
        XCTAssertEqual(
            resultController.testingPendingManualHaplotypeMutationCount,
            1
        )

        let updatedStatsURL = firstBundle.appendingPathComponent(
            "host-authority-first.retained-demux-stats.json"
        )
        try #"{"totalInputReads":999,"retainedUniqueReads":8}"#
            .write(
                to: updatedStatsURL,
                atomically: true,
                encoding: .utf8
            )
        let updatedFirstResult =
            try await ONTGenotypeResultBundle.loadResultAsync(from: firstBundle)
        reloadGate.succeed(at: 0, with: updatedFirstResult)
        let reloadFinished = await eventually {
            splitController
                .testingGenotypeCurrentWorkbookRetentionDiagnostics
                .reloadTaskCount == 0
        }
        XCTAssertTrue(reloadFinished)

        XCTAssertEqual(resultController.testingResultTotalInputReads, 10)

        await configurationGate.resume(with: .discard)
        await resultController.testingWaitForManualHaplotypeTransitions()
        XCTAssertEqual(
            resultController.testingResultBundleURL,
            secondBundle.standardizedFileURL,
            "The old host reload must not replace the already-queued bundle configuration."
        )
    }

    func testQueuedReplacementConfigurationRejectsOlderWorkbookReloadBeforeItStarts()
        async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "GenotypeWorkbookDesiredConfiguration-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let firstBundle = try makeGenotypeResultBundle(
            root: root,
            name: "desired-authority-first",
            haplotypeAnalysisPath: nil,
            genotypeOnlyWorkflowKind: .fullLengthONTMHCGenotype
        )
        let secondBundle = try makeGenotypeResultBundle(
            root: root,
            name: "desired-authority-second",
            haplotypeAnalysisPath: nil,
            genotypeOnlyWorkflowKind: .fullLengthONTMHCGenotype
        )
        let firstResult = try await ONTGenotypeResultBundle.loadResultAsync(
            from: firstBundle
        )
        let secondResult = try await ONTGenotypeResultBundle.loadResultAsync(
            from: secondBundle
        )
        let coordinator = GenotypeCurrentWorkbookSyncCoordinator(
            recordedFingerprintLoader: { _ in nil },
            idleScheduler: { _, _ in IdleCancellation() }
        )
        let splitController = MainSplitViewController()
        splitController.genotypeCurrentWorkbookSyncCoordinator = coordinator
        _ = splitController.view
        await splitController.testingDisplayGenotypeResultBundleAndWait(
            firstBundle
        )
        let registered = await eventually {
            splitController
                .testingGenotypeCurrentWorkbookRetentionDiagnostics
                .completionContextCount == 1
        }
        XCTAssertTrue(registered)
        let resultController = try XCTUnwrap(
            splitController.viewerController.genotypeResultViewController
        )
        resultController.testingSelectMatrixColumn(sample: "DW472")
        resultController.testingUpdateManualHaplotypeLabel("H1")
        XCTAssertTrue(resultController.testingManualHaplotypeEditorIsDirty)

        let configurationGate = ManualHaplotypeConfigurationGate()
        resultController.testingSetManualHaplotypeDraftDecisionProvider { _ in
            await configurationGate.decide()
        }
        resultController.configure(result: secondResult)
        let configurationIsPending =
            await configurationGate.waitUntilPending()
        XCTAssertTrue(configurationIsPending)
        guard configurationIsPending else {
            return
        }

        let reloadGate = WorkbookResultReloadGate()
        splitController.genotypeResultLoader = { _ in
            try await reloadGate.load()
        }
        splitController.applyGenotypeCurrentWorkbookSyncPhase(
            .current,
            bundleURL: firstBundle
        )
        let staleReloadStarted = await eventually {
            reloadGate.loadCount == 1
        }
        XCTAssertFalse(
            staleReloadStarted,
            "Requesting bundle B must immediately revoke host reload authority for displayed bundle A."
        )

        if staleReloadStarted {
            reloadGate.succeed(at: 0, with: firstResult)
            _ = await eventually {
                splitController
                    .testingGenotypeCurrentWorkbookRetentionDiagnostics
                    .reloadTaskCount == 0
            }
        }
        await configurationGate.resume(with: .discard)
        await resultController.testingWaitForManualHaplotypeTransitions()
        XCTAssertEqual(
            resultController.testingResultBundleURL,
            secondBundle.standardizedFileURL,
            "The older host reload must not replace the already-queued bundle configuration."
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
            annotationSidecarData: snapshot.annotationSidecarData,
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
        includeGenotypeCalls: Bool = true,
        genotypeOnlyWorkflowKind: GenotypeResultWorkflowKind? = nil,
        includeReviewableRowCatalog: Bool = false
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

        let reviewableRowCatalog: ONTMHCArtifactReference?
        if includeReviewableRowCatalog {
            let catalog = GenotypeReviewableRowCatalog(
                schemaID: GenotypeReviewableRowCatalog.schemaID,
                schemaVersion: GenotypeReviewableRowCatalog.schemaVersion,
                samples: ["DW472"],
                rows: [
                    .init(
                        kind: .candidate,
                        callID: "candidate:MHC-E:candidate-1",
                        displayName: "Mafa-E*02:04:01:01_10nt_nov",
                        locus: "MHC-E",
                        stableID: "candidate-1",
                        section: "candidate",
                        sortKey: "MHC-E|Mafa-E*02:04:01:01_10nt_nov",
                        supportBySample: ["DW472": 17]
                    ),
                ]
            )
            let catalogData = try catalog.encoded()
            let catalogPath = "artifacts/projections/genotype-reviewable-rows.json"
            let catalogURL = bundleURL.appendingPathComponent(catalogPath)
            try FileManager.default.createDirectory(
                at: catalogURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try catalogData.write(to: catalogURL)
            reviewableRowCatalog = ONTMHCArtifactReference(
                path: catalogPath,
                sha256: SHA256.hash(data: catalogData)
                    .map { String(format: "%02x", $0) }
                    .joined(),
                sizeBytes: Int64(catalogData.count)
            )
        } else {
            reviewableRowCatalog = nil
        }

        let manifest = ONTGenotypeResultBundleManifest(
            kind: genotypeOnlyWorkflowKind?.rawValue
                ?? "ont-barcode-genotype",
            workflowKind: genotypeOnlyWorkflowKind,
            workflowMode: genotypeOnlyWorkflowKind == nil
                ? nil
                : .genotypeOnly,
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
                : "MHC-exon2-miSeq.mauritian-cynomolgus-macaques",
            reviewableRowCatalog: reviewableRowCatalog
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

    private func recursiveFileBytes(in root: URL) throws -> [String: Data] {
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys
        ) else {
            return [:]
        }
        var result: [String: Data] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: Set(resourceKeys)).isRegularFile == true
            else {
                continue
            }
            let relativePath = String(
                url.standardizedFileURL.path.dropFirst(
                    root.standardizedFileURL.path.count + 1
                )
            )
            result[relativePath] = try Data(contentsOf: url)
        }
        return result
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

    static func addSingleSampleAlignment(
        to bundleURL: URL,
        sampleID: String,
        trackID: String = "reads-track",
        includeReadGroup: Bool = true,
        includeChromosomeStats: Bool = false,
        manifestSampleNames: [String]? = nil
    ) throws {
        let alignmentsURL = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: alignmentsURL, withIntermediateDirectories: true)
        try Data().write(to: alignmentsURL.appendingPathComponent("\(trackID).bam"))
        try Data().write(to: alignmentsURL.appendingPathComponent("\(trackID).bam.bai"))
        let metadataPath = "alignments/\(trackID).metadata.sqlite"
        let database = try AlignmentMetadataDatabase.create(
            at: bundleURL.appendingPathComponent(metadataPath)
        )
        if includeReadGroup {
            database.addReadGroup(id: "\(sampleID)-rg", sample: sampleID)
        }
        if includeChromosomeStats {
            database.addChromosomeStats(chromosome: "chr1", length: 100, mapped: 1, unmapped: 0)
        }

        let manifest = try BundleManifest.load(from: bundleURL)
        let alignment = AlignmentTrackInfo(
                id: trackID,
                name: "Reads",
                sourcePath: "alignments/\(trackID).bam",
                indexPath: "alignments/\(trackID).bam.bai",
                metadataDBPath: metadataPath,
                mappedReadCount: 1,
                unmappedReadCount: 0,
                sampleNames: manifestSampleNames ?? (includeReadGroup ? [] : [sampleID])
        )
        let updatedManifest = BundleManifest(
            formatVersion: manifest.formatVersion,
            name: manifest.name,
            identifier: manifest.identifier,
            description: manifest.description,
            originBundlePath: manifest.originBundlePath,
            createdDate: manifest.createdDate,
            modifiedDate: Date(),
            source: manifest.source,
            genome: manifest.genome,
            annotations: manifest.annotations,
            variants: manifest.variants,
            tracks: manifest.tracks,
            alignments: manifest.alignments + [alignment],
            metadata: manifest.metadata,
            browserSummary: manifest.browserSummary,
            warnings: manifest.warnings,
            recordStore: manifest.recordStore
        )
        try updatedManifest.save(to: bundleURL)
    }

    @MainActor
    static func waitForBAMMetadataContext(
        on split: MainSplitViewController,
        excluding previous: SampleMetadataPresentationContext? = nil
    ) throws -> SampleMetadataPresentationContext {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let context = split.bamMetadataPresentationContext,
               context !== previous {
                return context
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        throw NSError(domain: "MappingRoutingFixture", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Timed out installing the BAM metadata context"
        ])
    }

    @MainActor
    static func waitForInitialSampleRows(
        on split: MainSplitViewController
    ) throws -> ReferenceBundleViewportController {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let viewport = split.viewerController.referenceBundleViewportController,
               viewport.testContigTableView.displayedRows.contains(where: { $0.sampleID == "S1" }) {
                return viewport
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        let input = split.viewerController.referenceBundleViewportController?.currentInput
        let rows = split.viewerController.referenceBundleViewportController?
            .testContigTableView.displayedRows
            .map { "\($0.sampleID ?? "nil"):\($0.contigName)" }
        let visibleTrack = split.viewerController.referenceBundleViewportController?.testVisibleAlignmentTrackID
        throw NSError(domain: "MappingRoutingFixture", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Timed out waiting for initial sample × contig rows; rendered=\(input?.renderedBundleURL?.path ?? "nil") manifest=\(input?.viewerBundleManifest?.name ?? "nil") tracks=\(input?.viewerBundleManifest?.alignments.map(\.id) ?? []) track=\(visibleTrack ?? "nil") rows=\(rows ?? [])"
        ])
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

import CryptoKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishGenotypeUI
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishKit
import LungfishTestSupport

@MainActor
final class MappingViewportRoutingTests: XCTestCase {
    /// Every request owns a continuation and a deadline. A second request can
    /// never replace the first waiter (including removal-triggered sync).
    @MainActor private final class ExcelAwaitGate {
        private var pending: [Int: CheckedContinuation<Void, Error>] = [:]
        private(set) var count = 0
        func wait() async throws {
            let id = count
            count += 1
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self.pending.removeValue(forKey: id)?.resume(throwing: NSError(domain: "Excel test gate timed out", code: id))
                }
            }
        }
        func release(_ id: Int = 0) { pending.removeValue(forKey: id)?.resume() }
    }

    private func makeOneWayExcelFixture(root: URL) async throws -> (MainSplitViewController, GenotypeResultViewController) {
        let bundle = try makeGenotypeResultBundle(root: root, name: "one-way", haplotypeAnalysisPath: nil)
        let split = MainSplitViewController()
        _ = split.view
        await split.testingDisplayGenotypeResultBundleAndWait(bundle)
        return (split, try XCTUnwrap(split.viewerController.genotypeResultViewController))
    }

    private final class WeakReference<Object: AnyObject> {
        weak var value: Object?

        init(_ value: Object?) {
            self.value = value
        }
    }

    private final class MatrixRetryScheduler: GenotypeMatrixAnnotationRetryScheduling {
        private final class Cancellation: GenotypeMatrixAnnotationRetryCancellation {
            func cancel() {}
        }

        private var actions: [@MainActor () -> Void] = []

        func schedule(
            _ action: @escaping @MainActor () -> Void
        ) -> GenotypeMatrixAnnotationRetryCancellation {
            actions.append(action)
            return Cancellation()
        }

        func fire() {
            let pending = actions
            actions.removeAll()
            pending.forEach { $0() }
        }
    }


    func testInspectorExcelExportRejectsStaleControllerAndDelayedPanelAfterViewerSwitch() async throws {
        let root = try TestTempDirectory.make(prefix: "ExcelInspectorOrigin")
        defer { TestTempDirectory.cleanup(root) }
        let (split, controller) = try await makeOneWayExcelFixture(root: root)
        let action = try XCTUnwrap(controller.onExcelExportRequested)
        var save: ((URL?) -> Void)?
        var panels = 0
        var exports = 0
        controller.excelSavePanelPresenter = { _, _, completion in panels += 1; save = completion }
        controller.viewportExportRunner = { _, _, _ in exports += 1 }
        action()
        XCTAssertEqual(panels, 1)
        split.viewerController.hideGenotypeResultView()
        action()
        try XCTUnwrap(save)(root.appendingPathComponent("stale.xlsx"))
        await Task.yield()
        XCTAssertEqual(panels, 1)
        XCTAssertEqual(exports, 0)
        XCTAssertNil(split.inspectorController.genotypeExcelExportSession.presentation)
    }

    func testInspectorExcelAsyncCompletionCannotRestoreLastSuccessAfterContextReset() async throws {
        for fails in [false, true] {
            let root = try TestTempDirectory.make(prefix: "ExcelInspectorCompletion")
            defer { TestTempDirectory.cleanup(root) }
            let (split, controller) = try await makeOneWayExcelFixture(root: root)
            let prior = root.appendingPathComponent("prior.xlsx")
            split.inspectorController.recordGenotypeExcelExport(.succeeded(prior))
            XCTAssertEqual(split.inspectorController.genotypeExcelExportSession.presentation?.url, prior)
            let gate = ExcelAwaitGate()
            let lateEvent = expectation(description: "No stale export completion event")
            lateEvent.isInverted = true
            let routedEvent = controller.onExcelExportEvent
            controller.onExcelExportEvent = { event in
                if case .started = event {} else { lateEvent.fulfill() }
                routedEvent?(event)
            }
            controller.excelSavePanelPresenter = { _, _, completion in completion(root.appendingPathComponent("late.xlsx")) }
            controller.viewportExportRunner = { _, _, _ in
                try await gate.wait()
                if fails { throw NSError(domain: "Delayed export failed", code: 1) }
            }
            controller.onExcelExportRequested?()
            let started = await eventually { gate.count == 1 }
            XCTAssertTrue(started)
            split.viewerController.hideGenotypeResultView()
            split.inspectorController.clearSelection()
            XCTAssertNil(split.inspectorController.genotypeExcelExportSession.presentation)
            gate.release()
            await fulfillment(of: [lateEvent], timeout: 0.15)
            XCTAssertNil(split.inspectorController.genotypeExcelExportSession.presentation)
            XCTAssertNil(split.inspectorController.genotypeExcelExportSession.statusText)
        }
    }

    func testInspectorExcelExportRemainsAvailableWithoutProjectWriteOwnership() async throws {
        let root = try TestTempDirectory.make(prefix: "ExcelReadableSource")
        defer { TestTempDirectory.cleanup(root) }
        let (split, controller) = try await makeOneWayExcelFixture(root: root)
        var presented = 0
        controller.excelSavePanelPresenter = { panel, _, completion in
            presented += 1
            XCTAssertEqual(panel.prompt, "Export")
            XCTAssertTrue((panel.accessoryView as? NSTextField)?.stringValue.contains("Filtering does not remove data from the All worksheet.") == true)
            completion(nil)
        }
        controller.onExcelExportRequested?()
        XCTAssertEqual(presented, 1)
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

    func testLegacyMappingSelectionInstallsAlignmentActionContext() throws {
        let resultDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping-action-context-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: resultDirectory) }
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Legacy Mapping Actions",
            chromosomes: [.init(name: "chr1", length: 100)]
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        let bamURL = resultDirectory.appendingPathComponent("sample.sorted.bam")
        let indexURL = resultDirectory.appendingPathComponent("sample.sorted.bam.bai")
        try Data("bam-evidence".utf8).write(to: bamURL)
        try Data("index-evidence".utf8).write(to: indexURL)
        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            viewerBundleURL: bundleURL,
            bamURL: bamURL,
            baiURL: indexURL,
            totalReads: 10,
            mappedReads: 9,
            unmappedReads: 1,
            wallClockSeconds: 1,
            contigs: [.init(
                sampleID: "S1",
                readGroupIDs: ["S1-rg"],
                contigName: "chr1",
                contigLength: 100,
                mappedReads: 9,
                mappedReadPercent: 90,
                meanDepth: 1,
                coverageBreadth: 50,
                medianMAPQ: 40,
                meanIdentity: 99
            )]
        )
        let viewport = ReferenceBundleViewportController()
        _ = viewport.view

        viewport.configureForTesting(result: result, resultDirectoryURL: resultDirectory)
        viewport.testSelectContig(sampleID: "S1", alignmentTrackID: nil, named: "chr1")

        let context = try MappingRoutingFixture.waitForAlignmentActionContext(on: viewport)
        XCTAssertEqual(context.identity.workflow, "mapping")
        XCTAssertEqual(context.identity.sampleID, "S1")
        XCTAssertEqual(context.alignmentURL, bamURL.standardizedFileURL)
        XCTAssertEqual(context.indexURL, indexURL.standardizedFileURL)
        XCTAssertEqual(context.contig, "chr1")
        XCTAssertEqual(context.filters.readGroups, ["S1-rg"])
        XCTAssertEqual(context.outputCapability, .projectDerivedRoot(resultDirectory.standardizedFileURL))
        XCTAssertEqual(context.sourceReads, .bamFallback)

        viewport.applyEmbeddedReadDisplaySettings([
            NotificationUserInfoKey.minMapQ: 23,
            NotificationUserInfoKey.consensusMinMapQ: 29,
        ])
        let updatedContext = try MappingRoutingFixture.waitForAlignmentActionContext(
            on: viewport,
            where: { $0.filters.minimumMapQ == 29 }
        )
        XCTAssertEqual(updatedContext.identity, context.identity)
        XCTAssertEqual(updatedContext.filters.minimumMapQ, 29)
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
        let actionContext = try MappingRoutingFixture.waitForAlignmentActionContext(on: viewport)
        XCTAssertEqual(actionContext.identity.workflow, "reference-bundle")
        XCTAssertEqual(actionContext.identity.sampleID, "S2")
        XCTAssertEqual(actionContext.identity.evidenceID, "reads-s2:chr1")
        XCTAssertEqual(actionContext.alignmentURL, bundleURL.appendingPathComponent("alignments/reads-s2.bam"))
        XCTAssertEqual(actionContext.indexURL, bundleURL.appendingPathComponent("alignments/reads-s2.bam.bai"))
        XCTAssertEqual(actionContext.contig, "chr1")
        XCTAssertEqual(actionContext.filters.readGroups, Set(["S2-rg"]))
        XCTAssertEqual(actionContext.outputCapability, .userSelectedDestination)
        XCTAssertEqual(actionContext.sourceReads, .bamFallback)

        viewport.applyEmbeddedReadDisplaySettings([
            NotificationUserInfoKey.visibleAlignmentTrackID: "reads-s2",
            NotificationUserInfoKey.selectedReadGroups: Set(["S2-rg"]),
            NotificationUserInfoKey.minMapQ: 37,
            NotificationUserInfoKey.consensusMinMapQ: 41,
        ])
        let updatedContext = try MappingRoutingFixture.waitForAlignmentActionContext(
            on: viewport,
            where: { $0.filters.minimumMapQ == 41 }
        )
        XCTAssertEqual(updatedContext.identity, actionContext.identity)
        XCTAssertEqual(updatedContext.filters.minimumMapQ, 41)
    }

    func testDirectReferenceBAMRouteKeepsUnresolvedTrackRowsAlongsideResolvedTracks() throws {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Direct Resolved and Unresolved BAM Metadata",
            chromosomes: [.init(name: "chr1", length: 100)]
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        try MappingRoutingFixture.addSingleSampleAlignment(
            to: bundleURL, sampleID: "S1", trackID: "reads-s1"
        )
        try MappingRoutingFixture.addUnresolvedAlignment(
            to: bundleURL, trackID: "reads-unresolved"
        )

        let split = MainSplitViewController(); split.loadViewIfNeeded()
        split.displayReferenceBundleViewportFromSidebar(at: bundleURL)
        _ = try MappingRoutingFixture.waitForBAMMetadataContext(on: split)
        let viewport = try XCTUnwrap(split.viewerController.referenceBundleViewportController)

        XCTAssertEqual(viewport.testDisplayedSequenceNames, ["chr1", "chr1"])
        XCTAssertEqual(viewport.testDisplayedSequenceSampleIDs, ["S1", nil])

        viewport.testSelectSequence(sampleID: nil, alignmentTrackID: "reads-unresolved", named: "chr1")
        XCTAssertEqual(viewport.testVisibleAlignmentTrackID, "reads-unresolved")
        XCTAssertEqual(viewport.testSelectedReadGroups, [])
    }

    func testDirectReferenceBAMRouteKeepsUnmatchedReadGroupsBesideResolvedSampleInSameTrack() throws {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Direct Mixed BAM Metadata",
            chromosomes: [.init(name: "chr1", length: 100)]
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        try MappingRoutingFixture.addSingleSampleAlignment(
            to: bundleURL, sampleID: "S1", trackID: "mixed-track"
        )
        do {
            let database = try AlignmentMetadataDatabase.openForUpdate(
                at: bundleURL.appendingPathComponent("alignments/mixed-track.metadata.sqlite")
            )
            database.addReadGroup(id: "unmatched-rg", sample: nil)
            XCTAssertEqual(Set(database.readGroups().map(\.id)), Set(["S1-rg", "unmatched-rg"]))
        }

        let split = MainSplitViewController(); split.loadViewIfNeeded()
        split.displayReferenceBundleViewportFromSidebar(at: bundleURL)
        _ = try MappingRoutingFixture.waitForBAMMetadataContext(on: split)
        let viewport = try XCTUnwrap(split.viewerController.referenceBundleViewportController)

        XCTAssertEqual(viewport.testDisplayedSequenceNames, ["chr1", "chr1"])
        XCTAssertEqual(viewport.testDisplayedSequenceSampleIDs, ["S1", nil])

        viewport.testSelectSequence(sampleID: nil, alignmentTrackID: "mixed-track", named: "chr1")
        XCTAssertEqual(viewport.testVisibleAlignmentTrackID, "mixed-track")
        XCTAssertEqual(viewport.testSelectedReadGroups, Set(["unmatched-rg"]))
    }

    func testMetadataContextAllowsSameReadGroupIDInIndependentTracks() throws {
        let bundleURL = try MappingRoutingFixture.makeReferenceBundle(
            name: "Track Scoped RG Identity",
            chromosomes: [.init(name: "chr1", length: 100)]
        )
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }
        try MappingRoutingFixture.addSingleSampleAlignment(
            to: bundleURL, sampleID: "S1", trackID: "track-a", readGroupID: "RG1"
        )
        try MappingRoutingFixture.addSingleSampleAlignment(
            to: bundleURL, sampleID: "S2", trackID: "track-b", readGroupID: "RG1"
        )

        let split = MainSplitViewController(); split.loadViewIfNeeded()
        split.displayReferenceBundleViewportFromSidebar(at: bundleURL)
        let context = try MappingRoutingFixture.waitForBAMMetadataContext(on: split)

        XCTAssertEqual(context.identityIndex.canonicalSampleIDs, Set(["S1", "S2"]))
        XCTAssertEqual(
            context.identityIndex.canonicalSampleID(forReadGroupID: "RG1", alignmentTrackID: "track-a"),
            "S1"
        )
        XCTAssertEqual(
            context.identityIndex.canonicalSampleID(forReadGroupID: "RG1", alignmentTrackID: "track-b"),
            "S2"
        )
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

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // displayReferenceBundleViewportFromSidebar(at:) is a real, directly-callable
        // method already exercised behaviorally many times elsewhere in this file (e.g.
        // testDirectReferenceBAMRouteInstallsOneContextAndPublishesGenericImportsToListAndReopen),
        // and the effects named here (wireDirectReferenceViewportInspectorUpdates,
        // updateReferenceBundleTrackSections, notifyEmbeddedReferenceBundleLoadedIfAvailable)
        // are all covered by those tests' downstream assertions on inspectorController /
        // viewport state. What is NOT independently observable at runtime is the specific
        // internal *ordering* this test checks (clearSelection() called strictly before
        // BundleManifest.load(from:)) -- there is no timing/ordering seam for that without
        // adding instrumentation to the production method.
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

        // Finder/open dispatch shares the sidebar display route so both entrypoints
        // receive the same selection-token and Inspector publication guards.
        XCTAssertTrue(routeSource.contains("displayReferenceBundleViewportFromSidebar(at: url)"))
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
        let splitController = MainSplitViewController()
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

    func testAIHaplotypingGUIUsesReplayableCLICommandPreviewAndSanitizedFailureDetail() throws {
        let source = try loadSource(at: "Sources/LungfishApp/Services/GenotypeAIHaplotypingExecutionService.swift")

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // GenotypeAIHaplotypingExecutionService.commandPreview(...) and failureDetail(...)
        // are private with no testing-prefixed wrapper. The built argv IS logged through
        // operationCenter.log(...) -- a real, already-tested seam elsewhere in this
        // suite -- but reaching that log line requires running the full AI haplotyping
        // path (a real or mocked AIHaplotypingRunner + provider + network credentials),
        // which is a materially larger integration than a unit test should take on here;
        // no such fixture exists in this suite today.
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
        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // This is a deliberate concurrency-hygiene scan: confirms MainActor-isolated
        // genotype-bundle consumers call the async loader (loadResultAsync) rather than
        // the synchronous one (loadResult), which would block the main actor. There is
        // no runtime-observable difference between the two call sites other than which
        // symbol name was written, so this is a source check by design, not a behavior
        // check with an achievable seam.
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
        // The removed current-workbook updater was the viewport\'s only loader.
        // Capture now consumes its in-memory result; async loading remains at the service boundary.
        XCTAssertFalse(viewportSource.contains("ONTGenotypeResultBundle.loadResultAsync("))
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

        // External open now delegates to the same generation-guarded route used
        // by sidebar selection, preserving its viewport/Inspector pairing.
        XCTAssertTrue(routeSource.contains("displayMHCReferenceBundleFromSidebar(at: url)"))
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
        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // Dead-code absence check (a removed dead parameter name); no runtime instance
        // to test against by definition.
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

        // source-text: no runtime seam — see docs/reports/2026-08-21-test-suite-review.md §3
        // displayMappingAnalysisFromSidebar(at:) is a real, directly-callable method
        // already exercised behaviorally elsewhere in this file (e.g.
        // testSidebarMappingRoutePassesViewerManifestAndBuildsInitialSampleRows), but that
        // test observes the resulting viewport/manifest state, not which specific
        // internal factory/display call (ViewerDisplayRouteFactory.mappingResult vs. the
        // legacy displayMappingResult(...)) produced it -- that specific routing-call
        // distinction has no separate runtime seam.
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
        // Converted from source-text grep to a behavioral assertion: showing the real
        // back-navigation button on a real ViewerViewController produces a real NSButton
        // carrying the stable accessibility identifier, read back through the existing
        // #if DEBUG test accessor (testBundleBackNavigationAccessibilityIdentifier).
        let vc = ViewerViewController()
        _ = vc.view

        vc.showBundleBackNavigationButton(title: "Back") {}

        XCTAssertEqual(
            vc.testBundleBackNavigationAccessibilityIdentifier,
            "viewer-back-navigation-button"
        )
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
        manifestSampleNames: [String]? = nil,
        readGroupID: String? = nil
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
            database.addReadGroup(id: readGroupID ?? "\(sampleID)-rg", sample: sampleID)
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

    static func addUnresolvedAlignment(
        to bundleURL: URL,
        trackID: String
    ) throws {
        let alignmentsURL = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        try FileManager.default.createDirectory(at: alignmentsURL, withIntermediateDirectories: true)
        try Data().write(to: alignmentsURL.appendingPathComponent("\(trackID).bam"))
        try Data().write(to: alignmentsURL.appendingPathComponent("\(trackID).bam.bai"))
        let metadataPath = "alignments/\(trackID).metadata.sqlite"
        let database = try AlignmentMetadataDatabase.create(
            at: bundleURL.appendingPathComponent(metadataPath)
        )
        database.addReadGroup(id: "unresolved-rg", sample: nil)

        let manifest = try BundleManifest.load(from: bundleURL)
        let alignment = AlignmentTrackInfo(
            id: trackID,
            name: "Unresolved reads",
            sourcePath: "alignments/\(trackID).bam",
            indexPath: "alignments/\(trackID).bam.bai",
            metadataDBPath: metadataPath,
            mappedReadCount: 1,
            unmappedReadCount: 0
        )
        try BundleManifest(
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
        ).save(to: bundleURL)
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

    @MainActor
    static func waitForAlignmentActionContext(
        on viewport: ReferenceBundleViewportController,
        where predicate: (AlignmentActionContext) -> Bool = { _ in true }
    ) throws -> AlignmentActionContext {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let context = viewport.testAlignmentActionContext, predicate(context) {
                return context
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        throw NSError(domain: "MappingRoutingFixture", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Timed out installing the alignment action context"
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

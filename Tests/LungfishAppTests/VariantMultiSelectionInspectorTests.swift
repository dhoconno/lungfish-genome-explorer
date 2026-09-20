import AppKit
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class VariantMultiSelectionInspectorTests: XCTestCase {
    func testModelSummarizesSelectedRowsAndUniqueVariantsWithoutAggregatingGenotypes() {
        let first = makeResult(trackID: "track-a", rowID: 7, chromosome: "chr1", type: "SNP")
        let sameNumericIDOtherTrack = makeResult(trackID: "track-b", rowID: 7, chromosome: "chr2", type: "DEL")
        let entries = [
            VariantSelectionEntry(result: first, fields: fields("A"), sampleName: "sample-1"),
            VariantSelectionEntry(result: first, fields: fields("B"), sampleName: "sample-2"),
            VariantSelectionEntry(result: sameNumericIDOtherTrack, fields: fields("C")),
        ]
        let model = VariantSectionViewModel()

        model.select(entries: entries)

        XCTAssertNil(model.selectedVariant)
        XCTAssertEqual(model.selectionEntries.count, 3)
        XCTAssertEqual(model.uniqueVariantCount, 2)
        XCTAssertEqual(model.trackBreakdown, ["track-a": 2, "track-b": 1])
        XCTAssertEqual(model.chromosomeBreakdown, ["chr1": 2, "chr2": 1])
        XCTAssertEqual(model.typeBreakdown, ["DEL": 1, "SNP": 2])
        XCTAssertEqual(model.selectionEntries.compactMap(\.sampleName), ["sample-1", "sample-2"])
        XCTAssertEqual(model.selectionEntries[1].fields, fields("B"))
        XCTAssertFalse(model.hasGenotypes)
        XCTAssertEqual(model.totalSamples, 0)
    }

    func testSwitchingMultiToSingleRestoresSingleDetailAndSingleToMultiClearsStaleState() {
        let first = makeResult(trackID: "track-a", rowID: 1)
        let second = makeResult(trackID: "track-a", rowID: 2)
        let model = VariantSectionViewModel()

        model.select(entries: [
            VariantSelectionEntry(result: first, fields: fields("A")),
            VariantSelectionEntry(result: second, fields: fields("B")),
        ])
        model.select(variant: first, tableFields: fields("single"))

        XCTAssertTrue(model.selectionEntries.isEmpty)
        XCTAssertEqual(model.selectedVariant?.variantRowId, 1)
        XCTAssertEqual(model.tableFields, fields("single"))

        model.select(entries: [VariantSelectionEntry(result: second, fields: fields("multi"))])
        XCTAssertNil(model.selectedVariant)
        XCTAssertEqual(model.selectionEntries.map(\.result.variantRowId), [Int64?(2)])
        XCTAssertTrue(model.tableFields.isEmpty)
        XCTAssertTrue(model.infoFields.isEmpty)
    }

    func testInFlightSingleDatabaseLoadCannotOverwriteMultiSelection() async throws {
        let model = VariantSectionViewModel()
        model.variantDatabasesByTrackId["track-a"] = try makeDatabase()
        let first = makeResult(trackID: "track-a", rowID: 1)
        let second = makeResult(trackID: "track-a", rowID: 2)

        model.select(variant: first)
        model.select(entries: [VariantSelectionEntry(result: second, fields: fields("multi"))])
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(model.selectedVariant)
        XCTAssertEqual(model.selectionEntries.map(\.result.variantRowId), [Int64?(2)])
        XCTAssertFalse(model.hasGenotypes)
        XCTAssertEqual(model.totalSamples, 0)
        XCTAssertTrue(model.infoFields.isEmpty)
    }

    func testGenotypeSelectionEntriesPreserveSamplesAndParentTrackIdentity() {
        let drawer = AnnotationTableDrawerView(frame: NSRect(x: 0, y: 0, width: 800, height: 240))
        drawer.activeTab = .variants
        drawer.activeVariantSubtab = .genotypes
        let variant = makeResult(trackID: "track-a", rowID: 42)
        drawer.displayedAnnotations = [variant]
        drawer.displayedGenotypes = [
            makeGenotype(sample: "sample-1", trackID: "track-a", rowID: 42),
            makeGenotype(sample: "sample-2", trackID: "track-a", rowID: 42),
        ]
        drawer.tableView.reloadData()
        drawer.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)

        let entries = drawer.variantSelectionEntriesForSelectedRows()

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.sampleName), ["sample-1", "sample-2"])
        XCTAssertEqual(Set(entries.map(\.stableVariantIdentity)).count, 1)
        XCTAssertTrue(entries.allSatisfy { $0.result.trackId == "track-a" && $0.result.variantRowId == 42 })
        XCTAssertEqual(entries[0].fields.first(where: { $0.key == "genotype" })?.value, "0/1")
    }

    func testDrawerPublishesMultiAndEmptySelectionWithoutNavigation() {
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.activeTab = .variants
        drawer.activeVariantSubtab = .calls
        drawer.displayedAnnotations = [
            makeResult(trackID: "track-a", rowID: 1),
            makeResult(trackID: "track-b", rowID: 1),
        ]
        let capture = VariantSelectionDelegateCapture()
        drawer.delegate = capture

        drawer.tableView.reloadData()
        drawer.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        XCTAssertEqual(capture.entries.count, 2)
        XCTAssertEqual(capture.singleHighlights, 0)

        drawer.tableView.deselectAll(nil)
        XCTAssertTrue(capture.entries.isEmpty)
        XCTAssertEqual(capture.multiCallbacks, 2)
        XCTAssertEqual(capture.singleHighlights, 0)
    }

    func testFilteredAwayCallsSelectionPublishesEmptySelection() {
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.activeTab = .variants
        drawer.activeVariantSubtab = .calls
        let first = makeResult(trackID: "track-a", rowID: 1)
        let second = makeResult(trackID: "track-b", rowID: 2)
        drawer.baseDisplayedVariantAnnotations = [first, second]
        drawer.displayedAnnotations = [first, second]
        drawer.tableView.reloadData()
        drawer.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let capture = VariantSelectionDelegateCapture()
        drawer.delegate = capture
        drawer.hiddenVariantTrackIDs = ["track-a"]

        drawer.applyVariantColumnFiltersFromBase()

        XCTAssertTrue(drawer.tableView.selectedRowIndexes.isEmpty)
        XCTAssertEqual(capture.multiCallbacks, 1)
        XCTAssertTrue(capture.entries.isEmpty)
    }

    func testFilteredAwayGenotypeSelectionDoesNotRetargetSameRowIndex() {
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.activeTab = .variants
        drawer.activeVariantSubtab = .genotypes
        let variant = makeResult(trackID: "track-a", rowID: 42)
        drawer.displayedAnnotations = [variant]
        let first = makeGenotype(sample: "sample-1", trackID: "track-a", rowID: 42)
        let second = makeGenotype(sample: "sample-2", trackID: "track-a", rowID: 42)
        drawer.displayedGenotypes = [first, second]
        drawer.baseDisplayedGenotypes = [second]
        drawer.tableView.reloadData()
        drawer.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let capture = VariantSelectionDelegateCapture()
        drawer.delegate = capture

        drawer.applyGenotypeColumnFiltersFromBase()

        XCTAssertTrue(drawer.tableView.selectedRowIndexes.isEmpty)
        XCTAssertEqual(capture.multiCallbacks, 1)
        XCTAssertTrue(capture.entries.isEmpty)
    }

    func testGenotypeSortPreservesSelectedSampleIdentitiesAndPublishesOnce() {
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.activeTab = .variants
        drawer.activeVariantSubtab = .genotypes
        let variant = makeResult(trackID: "track-a", rowID: 42)
        drawer.displayedAnnotations = [variant]
        drawer.displayedGenotypes = [
            makeGenotype(sample: "sample-a", trackID: "track-a", rowID: 42),
            makeGenotype(sample: "sample-b", trackID: "track-a", rowID: 42),
            makeGenotype(sample: "sample-c", trackID: "track-a", rowID: 42),
        ]
        drawer.tableView.reloadData()
        drawer.tableView.selectRowIndexes(IndexSet([0, 2]), byExtendingSelection: false)
        let capture = VariantSelectionDelegateCapture()
        drawer.delegate = capture
        drawer.tableView.sortDescriptors = [NSSortDescriptor(key: "sample", ascending: false)]
        capture.reset()

        drawer.tableView(drawer.tableView, sortDescriptorsDidChange: [])

        XCTAssertEqual(Set(drawer.variantSelectionEntriesForSelectedRows().compactMap(\.sampleName)), ["sample-a", "sample-c"])
        XCTAssertEqual(capture.multiCallbacks, 1)
        XCTAssertEqual(Set(capture.entries.compactMap(\.sampleName)), ["sample-a", "sample-c"])
        XCTAssertEqual(capture.singleHighlights, 0)
    }

    func testPendingGenotypeFetchCannotRepopulateAfterEmptySelectionOrCallsSwitch() async throws {
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.activeTab = .variants
        drawer.activeVariantSubtab = .genotypes
        drawer.displayedAnnotations = [makeResult(trackID: "track-a", rowID: 42)]
        drawer.displayedGenotypes = [makeGenotype(sample: "old", trackID: "track-a", rowID: 42)]
        drawer.baseDisplayedGenotypes = drawer.displayedGenotypes
        let gate = GenotypeFetchGate()
        drawer.debugGenotypeFetchBeforeApply = { gate.blockBeforeApply() }

        drawer.buildGenotypeRows()
        XCTAssertEqual(gate.waitUntilBlocked(), .success)

        drawer.displayedAnnotations = []
        drawer.debugGenotypeFetchBeforeApply = nil
        drawer.buildGenotypeRows()
        drawer.variantSubtabControl.selectedSegment = AnnotationTableDrawerView.VariantSubtab.calls.rawValue
        drawer.variantSubtabChanged(drawer.variantSubtabControl)
        gate.release()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(drawer.displayedGenotypes.isEmpty)
        XCTAssertTrue(drawer.baseDisplayedGenotypes.isEmpty)
        XCTAssertEqual(drawer.activeVariantSubtab, .calls)
    }

    func testShowInInspectorUsesWholeMultiSelectionWhenContextRowIsSelected() {
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.activeTab = .variants
        drawer.activeVariantSubtab = .calls
        let first = makeResult(trackID: "track-a", rowID: 1)
        let second = makeResult(trackID: "track-b", rowID: 1)
        drawer.displayedAnnotations = [first, second]
        drawer.tableView.reloadData()
        drawer.tableView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        let capture = VariantSelectionNotificationCapture()
        let observer = NotificationCenter.default.addObserver(
            forName: .variantSelectionChanged, object: drawer, queue: nil
        ) { capture.record($0) }
        defer { NotificationCenter.default.removeObserver(observer) }
        let item = NSMenuItem()
        item.representedObject = second

        drawer.showInInspectorAction(item)

        XCTAssertEqual(capture.entries.count, 2)
        XCTAssertEqual(capture.entries.map(\.result.trackId), ["track-a", "track-b"])
    }

    func testControllerBridgeDoesNotNavigateForMultipleVariants() {
        let controller = ViewerViewController()
        controller.loadView()
        controller.referenceFrame = ReferenceFrame(
            chromosome: "chr1", start: 100, end: 200, pixelWidth: 600, sequenceLength: 1_000
        )
        let entries = [
            VariantSelectionEntry(result: makeResult(trackID: "track-a", rowID: 1), fields: fields("A")),
            VariantSelectionEntry(result: makeResult(trackID: "track-b", rowID: 1), fields: fields("B")),
        ]

        controller.annotationDrawer(
            AnnotationTableDrawerView(frame: .zero),
            didHighlightVariants: entries
        )

        XCTAssertEqual(controller.referenceFrame?.chromosome, "chr1")
        XCTAssertEqual(controller.referenceFrame?.start, 100)
        XCTAssertEqual(controller.referenceFrame?.end, 200)
        XCTAssertNil(controller.viewerView.selectedAnnotation)
    }

    func testInspectorRejectsForeignWindowArrayEventAndClearsAnnotationForAcceptedSelection() {
        let inspector = InspectorViewController()
        _ = inspector.view
        let scope = WindowStateScope()
        inspector.testingWindowStateScope = scope
        let annotation = SequenceAnnotation(type: .gene, name: "old", chromosome: "chr1", intervals: [.init(start: 1, end: 2)])
        inspector.viewModel.selectedAnnotation = annotation
        inspector.selectionSectionViewModel.select(annotation: annotation)
        let entries = [VariantSelectionEntry(result: makeResult(trackID: "track-a", rowID: 1), fields: fields("A"))]

        inspector.handleVariantSelectionChanged(Notification(
            name: .variantSelectionChanged,
            object: nil,
            userInfo: [
                NotificationUserInfoKey.windowStateScope: WindowStateScope(),
                NotificationUserInfoKey.variantSelectionEntries: entries,
            ]
        ))
        XCTAssertTrue(inspector.variantSectionViewModel.selectionEntries.isEmpty)
        XCTAssertNotNil(inspector.viewModel.selectedAnnotation)

        inspector.handleVariantSelectionChanged(Notification(
            name: .variantSelectionChanged,
            object: nil,
            userInfo: [
                NotificationUserInfoKey.windowStateScope: scope,
                NotificationUserInfoKey.variantSelectionEntries: entries,
            ]
        ))
        XCTAssertEqual(inspector.variantSectionViewModel.selectionEntries.count, 1)
        XCTAssertNil(inspector.viewModel.selectedAnnotation)
        XCTAssertNil(inspector.selectionSectionViewModel.selectedAnnotation)
        XCTAssertEqual(inspector.viewModel.selectedTab, .selectedItem)

        inspector.viewModel.selectedTab = .view
        inspector.handleVariantSelectionChanged(Notification(
            name: .variantSelectionChanged,
            object: nil,
            userInfo: [
                NotificationUserInfoKey.windowStateScope: scope,
                NotificationUserInfoKey.variantSelectionEntries: [VariantSelectionEntry](),
            ]
        ))
        XCTAssertTrue(inspector.variantSectionViewModel.selectionEntries.isEmpty)
        XCTAssertEqual(inspector.viewModel.selectedTab, .view)
    }

    private func makeResult(
        trackID: String,
        rowID: Int64,
        chromosome: String = "chr1",
        type: String = "SNP"
    ) -> AnnotationSearchIndex.SearchResult {
        AnnotationSearchIndex.SearchResult(
            name: "variant-\(trackID)-\(rowID)", chromosome: chromosome, start: Int(rowID),
            end: Int(rowID) + 1, trackId: trackID, trackName: trackID,
            type: type, strand: ".", ref: "A", alt: "G", quality: 30,
            filter: "PASS", sampleCount: 2, variantRowId: rowID,
            infoDict: ["DP": "20"], sourceFile: "calls.vcf"
        )
    }

    private func fields(_ value: String) -> [VariantInspectorField] {
        [VariantInspectorField(key: "depth", label: "Depth", value: value)]
    }

    private func makeGenotype(sample: String, trackID: String, rowID: Int64) -> AnnotationTableDrawerView.GenotypeDisplayRow {
        .init(
            sampleName: sample, variantRowId: rowID, variantID: "v\(rowID)", chromosome: "chr1",
            position: Int(rowID), ref: "A", alt: "G", genotype: "0/1", zygosity: "Het",
            alleleDepths: "10,10", depth: 20, genotypeQuality: 60, alleleBalance: 0.5,
            infoDict: ["DP": "20"], trackId: trackID, trackName: trackID
        )
    }

    private func makeDatabase() throws -> VariantDatabase {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("variant-multi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let vcfURL = directory.appendingPathComponent("calls.vcf")
        try """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS1\tS2
        chr1\t2\tv1\tA\tG\t30\tPASS\tDP=20\tGT:DP\t0/1:10\t1/1:10
        chr1\t3\tv2\tA\tT\t30\tPASS\tDP=18\tGT:DP\t0/1:9\t0/0:9
        """.write(to: vcfURL, atomically: true, encoding: .utf8)
        let databaseURL = directory.appendingPathComponent("calls.sqlite")
        _ = try VariantDatabase.createFromVCF(
            vcfURL: vcfURL, outputURL: databaseURL, parseGenotypes: true
        )
        return try VariantDatabase(url: databaseURL)
    }
}

@MainActor
private final class VariantSelectionDelegateCapture: AnnotationTableDrawerDelegate {
    var entries: [VariantSelectionEntry] = []
    var multiCallbacks = 0
    var singleHighlights = 0

    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didSelectAnnotation result: AnnotationSearchIndex.SearchResult) {}
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didHighlightVariant result: AnnotationSearchIndex.SearchResult) {
        singleHighlights += 1
    }
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didHighlightVariants entries: [VariantSelectionEntry]) {
        self.entries = entries
        multiCallbacks += 1
    }
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didDeleteVariants count: Int) {}
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didResolveGeneRegions regions: [GeneRegion]) {}
    func annotationDrawer(_ drawer: AnnotationTableDrawerView, didUpdateVisibleVariantRenderKeys keys: Set<String>?) {}
    func annotationDrawerDidDragDivider(_ drawer: AnnotationTableDrawerView, deltaY: CGFloat) {}
    func annotationDrawerDidFinishDraggingDivider(_ drawer: AnnotationTableDrawerView) {}

    func reset() {
        entries = []
        multiCallbacks = 0
        singleHighlights = 0
    }
}

private final class GenotypeFetchGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)

    func blockBeforeApply() {
        entered.signal()
        proceed.wait()
    }

    func waitUntilBlocked() -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + 2)
    }

    func release() {
        proceed.signal()
    }
}

private final class VariantSelectionNotificationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEntries: [VariantSelectionEntry] = []

    var entries: [VariantSelectionEntry] {
        lock.lock()
        defer { lock.unlock() }
        return storedEntries
    }

    func record(_ notification: Notification) {
        lock.lock()
        storedEntries = notification.userInfo?[NotificationUserInfoKey.variantSelectionEntries]
            as? [VariantSelectionEntry] ?? []
        lock.unlock()
    }
}

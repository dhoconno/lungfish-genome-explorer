import XCTest
@testable import LungfishApp
@testable import LungfishIO
import ObjectiveC.runtime

private final class SplitViewPositionSpy: NSSplitView {
    static var setPositionCallCount = 0

    override func setPosition(_ position: CGFloat, ofDividerAt dividerIndex: Int) {
        Self.setPositionCallCount += 1
        super.setPosition(position, ofDividerAt: dividerIndex)
    }
}

@MainActor
final class MetagenomicsLayoutModeTests: XCTestCase {
    private func makeEsVirituDetection() -> ViralDetection {
        ViralDetection(
            sampleId: "sample-1",
            name: "Example virus",
            description: "Example virus contig",
            length: 1_000,
            segment: nil,
            accession: "NC_000001",
            assembly: "GCF_000001",
            assemblyLength: 1_000,
            kingdom: "Viruses",
            phylum: nil,
            tclass: nil,
            order: nil,
            family: "ExampleFamily",
            genus: "ExampleGenus",
            species: "Example species",
            subspecies: nil,
            rpkmf: 10.0,
            readCount: 100,
            coveredBases: 900,
            meanCoverage: 12.5,
            avgReadIdentity: 0.98,
            pi: 0.01,
            filteredReadsInSample: 100_000
        )
    }

    private func makeEsVirituAssembly() -> ViralAssembly {
        let detection = makeEsVirituDetection()
        return ViralAssembly(
            assembly: detection.assembly,
            assemblyLength: detection.assemblyLength,
            name: detection.name,
            family: detection.family,
            genus: detection.genus,
            species: detection.species,
            totalReads: detection.readCount,
            rpkmf: detection.rpkmf,
            meanCoverage: detection.meanCoverage,
            avgReadIdentity: detection.avgReadIdentity,
            contigs: [detection]
        )
    }

    private func makeNvdManifest() -> NvdManifest {
        NvdManifest(
            experiment: "exp-1",
            sampleCount: 1,
            contigCount: 1,
            hitCount: 1,
            blastDbVersion: nil,
            snakemakeRunId: nil,
            sourceDirectoryPath: "/tmp/nvd",
            samples: [
                NvdSampleSummary(
                    sampleId: "sample-1",
                    contigCount: 1,
                    hitCount: 1,
                    totalReads: 100,
                    bamRelativePath: "sample-1.sorted.bam",
                    fastaRelativePath: "sample-1.fasta"
                )
            ],
            cachedTopContigs: nil
        )
    }

    private func makeNvdRow() -> NvdContigRow {
        NvdContigRow(
            sampleId: "sample-1",
            qseqid: "NODE_1",
            qlen: 1000,
            adjustedTaxidName: "Example virus",
            adjustedTaxidRank: "species",
            sseqid: "NC_000001.1",
            stitle: "Example virus reference",
            pident: 99.0,
            evalue: 0,
            bitscore: 1000,
            mappedReads: 50,
            readsPerBillion: 1_000_000
        )
    }

    private func makeNaoMgsManifest() -> NaoMgsManifest {
        NaoMgsManifest(
            sampleName: "sample-1",
            sourceFilePath: "/tmp/naomgs.tsv",
            hitCount: 10,
            taxonCount: 1,
            topTaxon: "Example virus",
            topTaxonId: 1234
        )
    }

    private func makeNaoMgsRow() -> NaoMgsTaxonSummaryRow {
        NaoMgsTaxonSummaryRow(
            sample: "sample-1",
            taxId: 1234,
            name: "Example virus",
            hitCount: 10,
            uniqueReadCount: 8,
            avgIdentity: 99.5,
            avgBitScore: 200,
            avgEditDistance: 1,
            pcrDuplicateCount: 0,
            accessionCount: 1,
            topAccessions: ["NC_000001.1"],
            bamPath: nil,
            bamIndexPath: nil
        )
    }

    private func setLayoutPreference(
        _ layout: MetagenomicsPanelLayout,
        legacyTableOnLeft: Bool
    ) {
        UserDefaults.standard.set(layout.rawValue, forKey: MetagenomicsPanelLayout.defaultsKey)
        UserDefaults.standard.set(legacyTableOnLeft, forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey)
    }

    nonisolated private static func clearLayoutPreference() {
        UserDefaults.standard.removeObject(forKey: "metagenomicsPanelLayout")
        UserDefaults.standard.removeObject(forKey: "metagenomicsTableOnLeft")
    }

    override func tearDown() {
        Self.clearLayoutPreference()
        super.tearDown()
    }

    func testTaxonomyViewStacksTableAboveDetailWhenLayoutIsStacked() {
        setLayoutPreference(.stacked, legacyTableOnLeft: false)

        let vc = TaxonomyViewController()
        _ = vc.view

        XCTAssertFalse(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0].subviews.contains(vc.testTableView))
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1].subviews.contains(vc.testSunburstView))
    }

    func testTaxonomyLiveWindowKeepsBothPanesVisibleInStackedMode() {
        setLayoutPreference(.stacked, legacyTableOnLeft: false)

        let vc = TaxonomyViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[0].frame.height, 120)
        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[1].frame.height, 120)
    }

    func testTaxonomyLiveWindowKeepsBothPanesVisibleInListLeadingMode() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = TaxonomyViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[0].frame.width, 180)
        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[1].frame.width, 180)
    }

    func testNaoMgsViewStacksTaxonomyTableAboveDetailWhenLayoutIsStacked() {
        setLayoutPreference(.stacked, legacyTableOnLeft: false)

        let vc = NaoMgsResultViewController()
        _ = vc.view

        XCTAssertFalse(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === vc.testTableContainer)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === vc.testDetailContainer)
    }

    func testNaoMgsLiveWindowKeepsBothPanesVisibleInListLeadingMode() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = NaoMgsResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[0].frame.width, 180)
        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[1].frame.width, 180)
    }

    func testNaoMgsLiveWindowPreservesUserMovedVerticalDivider() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = NaoMgsResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let initialWidth = vc.testSplitView.arrangedSubviews[0].frame.width
        let minimumLeadingWidth: CGFloat = 320
        let maximumLeadingWidth = vc.testSplitView.bounds.width - 320
        let targetPosition: CGFloat
        if maximumLeadingWidth - initialWidth >= 120 {
            targetPosition = initialWidth + 160
        } else {
            targetPosition = max(minimumLeadingWidth, initialWidth - 160)
        }
        XCTAssertGreaterThan(abs(targetPosition - initialWidth), 80)

        vc.testSplitView.setPosition(targetPosition, ofDividerAt: 0)
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let movedWidth = vc.testSplitView.arrangedSubviews[0].frame.width
        XCTAssertGreaterThan(
            abs(movedWidth - initialWidth),
            80,
            "initial=\(initialWidth) target=\(targetPosition) moved=\(movedWidth) bounds=\(vc.testSplitView.bounds.width)"
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(vc.testSplitView.arrangedSubviews[0].frame.width, movedWidth, accuracy: 2)
    }

    func testNvdViewStacksOutlineAboveDetailWhenLayoutIsStacked() {
        setLayoutPreference(.stacked, legacyTableOnLeft: false)

        let vc = NvdResultViewController()
        _ = vc.view

        XCTAssertFalse(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === vc.testOutlineContainer)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === vc.testDetailContainer)
    }

    func testNvdLiveWindowKeepsBothPanesVisibleInListLeadingMode() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = NvdResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[0].frame.width, 180)
        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[1].frame.width, 180)
    }

    func testNvdLiveWindowPreservesUserMovedVerticalDivider() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = NvdResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let initialWidth = vc.testSplitView.arrangedSubviews[0].frame.width
        let minimumLeadingWidth: CGFloat = 320
        let maximumLeadingWidth = vc.testSplitView.bounds.width - 320
        let targetPosition: CGFloat
        if maximumLeadingWidth - initialWidth >= 120 {
            targetPosition = initialWidth + 160
        } else {
            targetPosition = max(minimumLeadingWidth, initialWidth - 160)
        }
        XCTAssertGreaterThan(abs(targetPosition - initialWidth), 80)

        vc.testSplitView.setPosition(targetPosition, ofDividerAt: 0)
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let movedWidth = vc.testSplitView.arrangedSubviews[0].frame.width
        XCTAssertGreaterThan(
            abs(movedWidth - initialWidth),
            80,
            "initial=\(initialWidth) target=\(targetPosition) moved=\(movedWidth) bounds=\(vc.testSplitView.bounds.width)"
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(vc.testSplitView.arrangedSubviews[0].frame.width, movedWidth, accuracy: 2)
    }

    func testNvdLiveWindowResizesDetailDocumentWidthAfterDividerMove() throws {
        setLayoutPreference(.detailLeading, legacyTableOnLeft: false)

        let vc = NvdResultViewController()
        _ = vc.view
        vc.configureWithCachedRows([makeNvdRow()], manifest: makeNvdManifest(), bundleURL: URL(fileURLWithPath: "/tmp/nvd"))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let detailContainer = try XCTUnwrap(vc.testDetailContainer)
        let scrollView = try XCTUnwrap(detailContainer.subviews.first as? NSScrollView)
        let documentView = try XCTUnwrap(scrollView.documentView)
        documentView.frame = NSRect(x: 0, y: 0, width: scrollView.contentView.bounds.width, height: 400)
        let initialWidth = scrollView.contentView.bounds.width

        vc.testSplitView.setPosition(initialWidth + 160, ofDividerAt: 0)
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let resizedWidth = scrollView.contentView.bounds.width
        XCTAssertGreaterThan(abs(resizedWidth - initialWidth), 80)
        XCTAssertEqual(documentView.frame.width, resizedWidth, accuracy: 2)
    }

    func testTaxTriageViewStacksListAboveDetailWhenLayoutIsStacked() {
        setLayoutPreference(.stacked, legacyTableOnLeft: false)

        let vc = TaxTriageResultViewController()
        _ = vc.view

        XCTAssertFalse(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === vc.testRightPaneContainer)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === vc.testLeftPaneContainer)
    }

    func testTaxTriageLiveWindowKeepsBothPanesVisibleInListLeadingMode() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = TaxTriageResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[0].frame.width, 180)
        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[1].frame.width, 180)
    }

    func testTaxTriageLiveWindowHonorsListLeadingMinimumPaneWidths() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = TaxTriageResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let debugContext = "left=\(vc.testSplitView.arrangedSubviews[0].frame.width) right=\(vc.testSplitView.arrangedSubviews[1].frame.width) leftFit=\(vc.testRightPaneContainer.fittingSize.width) rightFit=\(vc.testLeftPaneContainer.fittingSize.width) min=\(vc.testSplitView.minPossiblePositionOfDivider(at: 0)) max=\(vc.testSplitView.maxPossiblePositionOfDivider(at: 0)) requested=\(String(describing: vc.testRequestedDividerPosition)) needsValidation=\(vc.testNeedsInitialSplitValidation)"
        XCTAssertGreaterThanOrEqual(vc.testSplitView.arrangedSubviews[0].frame.width, 298, debugContext)
        XCTAssertGreaterThanOrEqual(vc.testSplitView.arrangedSubviews[1].frame.width, 248, debugContext)
    }

    func testTaxTriageLiveWindowPreservesUserMovedVerticalDivider() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = TaxTriageResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let initialWidth = vc.testSplitView.arrangedSubviews[0].frame.width
        let minimumLeadingWidth: CGFloat = 320
        let maximumLeadingWidth = vc.testSplitView.bounds.width - 320
        let targetPosition: CGFloat
        if maximumLeadingWidth - initialWidth >= 120 {
            targetPosition = initialWidth + 160
        } else {
            targetPosition = max(minimumLeadingWidth, initialWidth - 160)
        }
        XCTAssertGreaterThan(abs(targetPosition - initialWidth), 80)

        vc.testSplitView.setPosition(targetPosition, ofDividerAt: 0)
        vc.testSplitView.adjustSubviews()
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let movedWidth = vc.testSplitView.arrangedSubviews[0].frame.width
        XCTAssertGreaterThan(
            abs(movedWidth - initialWidth),
            80,
            "initial=\(initialWidth) target=\(targetPosition) moved=\(movedWidth) bounds=\(vc.testSplitView.bounds.width) leftFit=\(vc.testRightPaneContainer.fittingSize.width) rightFit=\(vc.testLeftPaneContainer.fittingSize.width) min=\(vc.testSplitView.minPossiblePositionOfDivider(at: 0)) max=\(vc.testSplitView.maxPossiblePositionOfDivider(at: 0))"
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(vc.testSplitView.arrangedSubviews[0].frame.width, movedWidth, accuracy: 2)
    }

    func testTaxTriageImmediateUserDividerMoveSurvivesDeferredValidation() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = TaxTriageResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let initialWidth = vc.testSplitView.arrangedSubviews[0].frame.width
        let minimumLeadingWidth: CGFloat = 320
        let maximumLeadingWidth = vc.testSplitView.bounds.width - 320
        let targetPosition: CGFloat
        if maximumLeadingWidth - initialWidth >= 120 {
            targetPosition = initialWidth + 160
        } else {
            targetPosition = max(minimumLeadingWidth, initialWidth - 160)
        }
        vc.testSplitView.setPosition(targetPosition, ofDividerAt: 0)
        vc.testSplitView.adjustSubviews()
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let movedWidth = vc.testSplitView.arrangedSubviews[0].frame.width
        XCTAssertGreaterThan(
            abs(movedWidth - initialWidth),
            80,
            "initial=\(initialWidth) target=\(targetPosition) moved=\(movedWidth) bounds=\(vc.testSplitView.bounds.width)"
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(vc.testSplitView.arrangedSubviews[0].frame.width, movedWidth, accuracy: 2)
    }

    func testTaxTriageDidResizeSubviewsDoesNotReapplyStaleTrackedDividerPosition() {
        setLayoutPreference(.detailLeading, legacyTableOnLeft: false)

        let vc = TaxTriageResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let initialWidth = vc.testSplitView.arrangedSubviews[0].frame.width
        let draggedWidth = initialWidth - 160
        let dividerThickness = vc.testSplitView.dividerThickness
        let totalWidth = vc.testSplitView.bounds.width

        var firstFrame = vc.testSplitView.arrangedSubviews[0].frame
        firstFrame.size.width = draggedWidth
        vc.testSplitView.arrangedSubviews[0].frame = firstFrame

        var secondFrame = vc.testSplitView.arrangedSubviews[1].frame
        secondFrame.origin.x = draggedWidth + dividerThickness
        secondFrame.size.width = totalWidth - draggedWidth - dividerThickness
        vc.testSplitView.arrangedSubviews[1].frame = secondFrame

        vc.splitViewDidResizeSubviews(Notification(name: .init("TestSplitResize"), object: vc.testSplitView))

        XCTAssertEqual(
            vc.testSplitView.arrangedSubviews[0].frame.width,
            draggedWidth,
            accuracy: 2,
            "initial=\(initialWidth) dragged=\(draggedWidth) tracked=\(String(describing: vc.testRequestedDividerPosition)) current=\(vc.testSplitView.arrangedSubviews[0].frame.width)"
        )
    }

    func testTaxTriageMiniBAMScrollViewTracksDetailPaneResize() throws {
        setLayoutPreference(.detailLeading, legacyTableOnLeft: false)

        let vc = TaxTriageResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let bamView = try XCTUnwrap(
            vc.testLeftPaneContainer.subviews.first(where: { subview in
                subview.subviews.contains(where: { $0 is NSScrollView })
            })
        )
        let scrollView = try XCTUnwrap(
            bamView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView
        )

        let minimumLeadingWidth: CGFloat = 250
        let maximumLeadingWidth = vc.testSplitView.bounds.width - 300
        let initialContainerWidth = vc.testLeftPaneContainer.bounds.width
        let targetPosition: CGFloat
        if maximumLeadingWidth - initialContainerWidth >= 120 {
            targetPosition = initialContainerWidth + 160
        } else {
            targetPosition = max(minimumLeadingWidth, initialContainerWidth - 160)
        }

        vc.testSplitView.setPosition(targetPosition, ofDividerAt: 0)
        vc.testSplitView.adjustSubviews()
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(
            scrollView.frame.width,
            bamView.bounds.width,
            accuracy: 2,
            "scrollWidth=\(scrollView.frame.width) bamWidth=\(bamView.bounds.width) containerWidth=\(vc.testLeftPaneContainer.bounds.width)"
        )
    }

    func testEsVirituLiveWindowKeepsBothPanesVisibleInListLeadingMode() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = EsVirituResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[0].frame.width, 180)
        XCTAssertGreaterThan(vc.testSplitView.arrangedSubviews[1].frame.width, 180)
    }

    func testEsVirituLiveWindowHonorsListLeadingMinimumPaneWidths() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = EsVirituResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let debugContext = "left=\(vc.testSplitView.arrangedSubviews[0].frame.width) right=\(vc.testSplitView.arrangedSubviews[1].frame.width) requested=\(String(describing: vc.testRequestedDividerPosition)) needsValidation=\(vc.testNeedsInitialSplitValidation)"
        XCTAssertGreaterThanOrEqual(vc.testSplitView.arrangedSubviews[0].frame.width, 248, debugContext)
        XCTAssertGreaterThanOrEqual(vc.testSplitView.arrangedSubviews[1].frame.width, 248, debugContext)
    }

    func testEsVirituLiveWindowPreservesUserMovedVerticalDivider() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = EsVirituResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let initialWidth = vc.testSplitView.arrangedSubviews[0].frame.width
        let minimumLeadingWidth: CGFloat = 320
        let maximumLeadingWidth = vc.testSplitView.bounds.width - 320
        let targetPosition: CGFloat
        if maximumLeadingWidth - initialWidth >= 120 {
            targetPosition = initialWidth + 160
        } else {
            targetPosition = max(minimumLeadingWidth, initialWidth - 160)
        }
        XCTAssertGreaterThan(abs(targetPosition - initialWidth), 80)

        vc.testSplitView.setPosition(targetPosition, ofDividerAt: 0)
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let movedWidth = vc.testSplitView.arrangedSubviews[0].frame.width
        XCTAssertGreaterThan(
            abs(movedWidth - initialWidth),
            80,
            "initial=\(initialWidth) target=\(targetPosition) moved=\(movedWidth) bounds=\(vc.testSplitView.bounds.width)"
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(vc.testSplitView.arrangedSubviews[0].frame.width, movedWidth, accuracy: 2)
    }

    func testEsVirituDetailPaneTracksDocumentWidthToClipViewAfterResize() throws {
        let pane = EsVirituDetailPane(frame: NSRect(x: 0, y: 0, width: 420, height: 280))
        let miniBAM = MiniBAMViewController()
        _ = miniBAM.view
        pane.miniBAMViewController = miniBAM

        let host = NSView(frame: pane.frame)
        pane.autoresizingMask = [.width, .height]
        host.addSubview(pane)

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host

        pane.showVirusDetail(
            assembly: makeEsVirituAssembly(),
            coverageWindows: [:],
            bamURL: URL(fileURLWithPath: "/tmp/esviritu-placeholder.bam")
        )

        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        pane.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let scrollContainer = try XCTUnwrap(pane.subviews.first as? ScrollViewSplitPaneContainerView)
        let scrollView = try XCTUnwrap(scrollContainer.subviews.first as? NSScrollView)
        let documentView = try XCTUnwrap(scrollView.documentView)
        XCTAssertEqual(documentView.frame.width, scrollView.contentView.bounds.width, accuracy: 2)

        host.setFrameSize(NSSize(width: 620, height: 280))
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        pane.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(documentView.frame.width, scrollView.contentView.bounds.width, accuracy: 2)
    }

    func testEsVirituImmediateUserDividerMoveSurvivesDeferredValidation() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = EsVirituResultViewController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let initialWidth = vc.testSplitView.arrangedSubviews[0].frame.width
        let minimumLeadingWidth: CGFloat = 320
        let maximumLeadingWidth = vc.testSplitView.bounds.width - 320
        let targetPosition: CGFloat
        if maximumLeadingWidth - initialWidth >= 120 {
            targetPosition = initialWidth + 160
        } else {
            targetPosition = max(minimumLeadingWidth, initialWidth - 160)
        }
        vc.testSplitView.setPosition(targetPosition, ofDividerAt: 0)
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let movedWidth = vc.testSplitView.arrangedSubviews[0].frame.width
        XCTAssertGreaterThan(
            abs(movedWidth - initialWidth),
            80,
            "initial=\(initialWidth) target=\(targetPosition) moved=\(movedWidth) bounds=\(vc.testSplitView.bounds.width)"
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(vc.testSplitView.arrangedSubviews[0].frame.width, movedWidth, accuracy: 2)
    }

    func testTaxonomyViewDidLayoutDoesNotApplyNewPreferenceWithoutNotification() {
        setLayoutPreference(.detailLeading, legacyTableOnLeft: false)

        let vc = TaxonomyViewController()
        _ = vc.view
        vc.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)

        let initialFirstPane = vc.testSplitView.arrangedSubviews[0]
        let initialSecondPane = vc.testSplitView.arrangedSubviews[1]

        setLayoutPreference(.stacked, legacyTableOnLeft: false)
        vc.viewDidLayout()

        XCTAssertTrue(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === initialFirstPane)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === initialSecondPane)
    }

    func testTaxonomyViewDidLayoutDoesNotSynchronouslyMoveDivider() {
        setLayoutPreference(.stacked, legacyTableOnLeft: false)

        let vc = TaxonomyViewController()
        _ = vc.view

        SplitViewPositionSpy.setPositionCallCount = 0
        let originalClass: AnyClass = object_getClass(vc.testSplitView)!
        object_setClass(vc.testSplitView, SplitViewPositionSpy.self)
        defer { object_setClass(vc.testSplitView, originalClass) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        XCTAssertEqual(SplitViewPositionSpy.setPositionCallCount, 0)
    }

    func testNaoMgsViewDidLayoutDoesNotApplyNewPreferenceWithoutNotification() {
        setLayoutPreference(.detailLeading, legacyTableOnLeft: false)

        let vc = NaoMgsResultViewController()
        _ = vc.view
        vc.view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)

        let initialFirstPane = vc.testSplitView.arrangedSubviews[0]
        let initialSecondPane = vc.testSplitView.arrangedSubviews[1]

        setLayoutPreference(.stacked, legacyTableOnLeft: false)
        vc.viewDidLayout()

        XCTAssertTrue(vc.testSplitView.isVertical)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[0] === initialFirstPane)
        XCTAssertTrue(vc.testSplitView.arrangedSubviews[1] === initialSecondPane)
    }

    func testNaoMgsLiveWindowResizesDetailDocumentWidthAfterDividerMove() throws {
        setLayoutPreference(.detailLeading, legacyTableOnLeft: false)

        let vc = NaoMgsResultViewController()
        _ = vc.view
        vc.configureWithCachedRows([makeNaoMgsRow()], manifest: makeNaoMgsManifest())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let detailContainer = try XCTUnwrap(vc.testDetailContainer)
        let scrollView = try XCTUnwrap(detailContainer.subviews.first as? NSScrollView)
        let documentView = try XCTUnwrap(scrollView.documentView)
        documentView.frame = NSRect(x: 0, y: 0, width: scrollView.contentView.bounds.width, height: 400)
        let initialWidth = scrollView.contentView.bounds.width

        vc.testSplitView.setPosition(initialWidth + 160, ofDividerAt: 0)
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let resizedWidth = scrollView.contentView.bounds.width
        XCTAssertGreaterThan(abs(resizedWidth - initialWidth), 80)
        XCTAssertEqual(documentView.frame.width, resizedWidth, accuracy: 2)
    }

    func testNaoMgsListLeadingDividerCanRecoverAfterExtremeCollapseDrag() {
        setLayoutPreference(.listLeading, legacyTableOnLeft: true)

        let vc = NaoMgsResultViewController()
        _ = vc.view
        vc.configureWithCachedRows([makeNaoMgsRow()], manifest: makeNaoMgsManifest())

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        vc.testSplitView.setPosition(0, ofDividerAt: 0)
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let collapsedWidth = vc.testSplitView.arrangedSubviews[0].frame.width
        XCTAssertGreaterThanOrEqual(collapsedWidth, 298)

        let restoredTarget = collapsedWidth + 180
        vc.testSplitView.setPosition(restoredTarget, ofDividerAt: 0)
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertGreaterThan(
            vc.testSplitView.arrangedSubviews[0].frame.width,
            collapsedWidth + 120
        )
    }

    func testTaxTriageLayoutChangeResetsCollapsedStackedPaneToSensibleWidth() {
        setLayoutPreference(.stacked, legacyTableOnLeft: false)

        let vc = TaxTriageResultViewController()
        _ = vc.view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        vc.testSplitView.setPosition(80, ofDividerAt: 0)

        setLayoutPreference(.listLeading, legacyTableOnLeft: true)
        NotificationCenter.default.post(name: .metagenomicsLayoutSwapRequested, object: nil)
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()

        let firstPaneWidth = vc.testSplitView.arrangedSubviews[0].frame.width
        let secondPaneWidth = vc.testSplitView.arrangedSubviews[1].frame.width
        XCTAssertGreaterThan(firstPaneWidth, 200)
        XCTAssertGreaterThan(secondPaneWidth, 80)
    }

    func testTaxTriageSplitAllowsHiddenTrailingDetailPaneToFullyCollapse() {
        setLayoutPreference(.stacked, legacyTableOnLeft: false)

        let vc = TaxTriageResultViewController()
        _ = vc.view
        vc.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        vc.testSplitView.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        vc.testSplitView.layoutSubtreeIfNeeded()
        vc.viewDidLayout()
        vc.testLeftPaneContainer.isHidden = true

        let totalExtent = vc.testSplitView.bounds.height
        let clamped = vc.splitView(
            vc.testSplitView,
            constrainSplitPosition: totalExtent,
            ofSubviewAt: 0
        )

        XCTAssertEqual(clamped, totalExtent, accuracy: 0.5)
    }
}

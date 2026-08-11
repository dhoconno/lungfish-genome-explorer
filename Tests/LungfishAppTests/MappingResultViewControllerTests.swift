import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishKit

@MainActor
final class MappingResultViewControllerTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.removeObject(forKey: "mappingPanelLayout")
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mapping_result_view_tests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "mappingPanelLayout")
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    func testViewportUsesClassifierStyleColumnsAndDefaultMappedReadSort() {
        let vc = MappingResultViewController()
        _ = vc.view
        vc.configureForTesting(result: makeMappingResult())

        XCTAssertEqual(
            vc.testContigTableView.testTableView.tableColumns.map(\.title),
            ["Sample", "Track", "Contig", "Length", "Mapped Reads", "% Mapped", "Mean Depth", "Coverage Breadth", "Median MAPQ", "Mean Identity"]
        )
        XCTAssertEqual(vc.testContigTableView.record(at: 0)?.contigName, "beta")
    }

    func testMappingCompatibilityKeepsRootAccessibilityIdentifier() {
        let vc = MappingResultViewController()
        _ = vc.view

        XCTAssertEqual(vc.view.accessibilityIdentifier(), "mapping-result-view")
    }

    func testTableSupportsTextAndNumericFilters() {
        let table = MappingContigTableView()
        table.configure(rows: makeContigs())

        table.applyTestFilter(columnID: "contig", op: .contains, value: "alp")
        XCTAssertEqual(table.displayedRows.map(\.contigName), ["alpha"])

        table.clearTestFilters()
        table.applyTestFilter(columnID: "reads", op: .greaterOrEqual, value: "150")
        XCTAssertEqual(table.displayedRows.map(\.contigName), ["beta"])
    }

    func testTextAndNumericColumnsUseClassifierFonts() {
        let table = MappingContigTableView()
        let row = makeContigs()[0]

        let textCell = table.cellContent(for: NSUserInterfaceItemIdentifier("contig"), row: row)
        let numericCell = table.cellContent(for: NSUserInterfaceItemIdentifier("reads"), row: row)

        XCTAssertEqual(textCell.font, .systemFont(ofSize: 12))
        XCTAssertEqual(
            numericCell.font,
            .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        )
    }

    // MARK: - Item 2: bundle display name in selector + track label

    func testMappingContigCellShowsBundleNamePrimaryAndContigSecondary() {
        let table = MappingContigTableView()
        table.bundleDisplayName = "Fixture"
        table.configure(rows: makeContigs())

        let cell = table.cellContent(for: NSUserInterfaceItemIdentifier("contig"), row: makeContigs()[0])
        let secondary = table.secondaryCellText(for: NSUserInterfaceItemIdentifier("contig"), row: makeContigs()[0])

        XCTAssertEqual(cell.text, "Fixture")
        XCTAssertEqual(secondary, "alpha")
    }

    func testMappingContigCellOmitsSecondaryWhenContigEqualsBundleName() {
        let table = MappingContigTableView()
        table.bundleDisplayName = "alpha"
        let row = makeContigs()[0]
        table.configure(rows: [row])

        let secondary = table.secondaryCellText(for: NSUserInterfaceItemIdentifier("contig"), row: row)

        XCTAssertNil(secondary)
    }

    func testMappingContigColumnValueAndCopyKeepContigID() {
        let table = MappingContigTableView()
        table.bundleDisplayName = "Fixture"
        let row = makeContigs()[0]
        table.configure(rows: [row])

        XCTAssertEqual(table.columnValue(for: "contig", row: row), "alpha")

        // Copy (both the production Cmd-click path in
        // BatchTableView.tableView(_:viewFor:row:) and this DEBUG test
        // helper) is keyed on `columnValue`, i.e. the contig id — NOT the
        // displayed bundle label — even though the cell visibly shows
        // "Fixture" as its primary line.
        let pasteboard = RecordingPasteboard()
        table.scalarPasteboard = pasteboard
        table.copyValue(row: 0, columnID: "contig", pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.lastString, "alpha", "copy must keep the contig id, not the displayed bundle label")
    }

    func testMappingContigSortAndReselectionKeyedOnContigName() {
        let table = MappingContigTableView()
        table.bundleDisplayName = "Fixture"
        table.configure(rows: makeContigs())

        table.testTableView.sortDescriptors = [NSSortDescriptor(key: "contig", ascending: true)]
        XCTAssertEqual(table.displayedRows.map(\.contigName), ["alpha", "beta"])

        // Row identity remains keyed to the canonical sample plus contig, not
        // the display-label decoration.
        XCTAssertEqual(table.rowIdentity(for: makeContigs()[0]), "mapping\u{1F}unmatched\u{1F}legacy\u{1F}alpha")
    }

    func testFilterMatchesBundleDisplayLabel() {
        let table = MappingContigTableView()
        table.bundleDisplayName = "Fixture"
        table.configure(rows: makeContigs())

        table.setFilterText("Fixture")
        XCTAssertEqual(
            table.displayedRows.count,
            makeContigs().count,
            "filtering by the bundle display name should match every row"
        )

        table.setFilterText("")
        table.setFilterText("alpha")
        XCTAssertEqual(table.displayedRows.map(\.contigName), ["alpha"])
    }

    func testReferenceRecordCellShowsBundleNameWithSecondaryAccession() {
        let table = ReferenceBundleRecordTable(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        table.bundleDisplayName = "Macaque MHC Reference"
        let summary = BundleBrowserSequenceSummary(
            name: "NC_041754.1",
            displayDescription: "Macaca mulatta chromosome 1",
            length: 100,
            aliases: [],
            isPrimary: true,
            isMitochondrial: false,
            metrics: nil
        )
        let row = ReferenceBundleRecordRow(summary: summary, values: [:])
        table.configure(dynamicFields: [], rows: [row])

        let cell = table.cellContent(for: NSUserInterfaceItemIdentifier("sequence"), row: row)
        let secondary = table.secondaryCellText(for: NSUserInterfaceItemIdentifier("sequence"), row: row)

        XCTAssertEqual(cell.text, "Macaque MHC Reference")
        XCTAssertEqual(secondary, "NC_041754.1 (Macaca mulatta chromosome 1)")
    }

    func testReferenceRecordColumnValueKeepsSequenceName() {
        let table = ReferenceBundleRecordTable(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        table.bundleDisplayName = "Macaque MHC Reference"
        let summary = BundleBrowserSequenceSummary(
            name: "NC_041754.1",
            displayDescription: nil,
            length: 100,
            aliases: [],
            isPrimary: true,
            isMitochondrial: false,
            metrics: nil
        )
        let row = ReferenceBundleRecordRow(summary: summary, values: [:])
        table.configure(dynamicFields: [], rows: [row])

        XCTAssertEqual(table.columnValue(for: "sequence", row: row), "NC_041754.1")
    }

    func testTrackHeaderShowsManifestNameForSingleContigBundle() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        let bundleURL = try makeReferenceBundleWithAnnotationDatabase()
        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: bundleURL))

        let embeddedViewer = try XCTUnwrap(
            vc.children.compactMap { $0 as? ViewerViewController }.first
        )
        XCTAssertEqual(embeddedViewer.headerView.testTrackNames.first, "Fixture")
    }

    func testTrackHeaderShowsNameWithParentheticalContigForMultiContig() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        let bundleURL = try makeReferenceBundleWithAlignmentTracks()
        vc.configureForTesting(result: makeAlphaGammaMappingResult(viewerBundleURL: bundleURL))
        vc.testSelectContig(named: "alpha")

        let embeddedViewer = try XCTUnwrap(
            vc.children.compactMap { $0 as? ViewerViewController }.first
        )
        XCTAssertEqual(embeddedViewer.headerView.testTrackNames.first, "Alignment Tracks (alpha)")

        vc.testSelectContig(named: "gamma")
        XCTAssertEqual(embeddedViewer.headerView.testTrackNames.first, "Alignment Tracks (gamma)")
    }

    func testTrackHeaderFallsBackToContigNameWithoutCachedManifest() throws {
        let host = ViewerViewController()
        _ = host.view

        XCTAssertNil(host.currentBundleDisplayName)
        XCTAssertEqual(host.referenceTrackHeaderLabel(forContig: "chr1", fastaDescription: nil), "chr1")
    }

    func testNavigateToChromosomeKeepsBundleDisplayLabelInHeader() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        let bundleURL = try makeReferenceBundleWithAlignmentTracks()
        vc.configureForTesting(result: makeAlphaGammaMappingResult(viewerBundleURL: bundleURL))
        vc.testSelectContig(named: "alpha")

        let embeddedViewer = try XCTUnwrap(
            vc.children.compactMap { $0 as? ViewerViewController }.first
        )
        embeddedViewer.navigateToChromosomeAndPosition(
            chromosome: "gamma",
            chromosomeLength: 100,
            start: 0,
            end: 100
        )

        XCTAssertEqual(embeddedViewer.headerView.testTrackNames.first, "Alignment Tracks (gamma)")
    }

    func testMappingResultInputCarryingManifestKeepsDocumentTitle() throws {
        let resultDirectory = tempDir.appendingPathComponent("mapping-run", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
        let viewerBundleURL = try makeReferenceBundleWithAnnotationDatabase()
        let result = makeMappingResult(viewerBundleURL: viewerBundleURL, resultDirectoryURL: resultDirectory)
        let viewerManifest = try BundleManifest.load(from: viewerBundleURL)

        let input = ReferenceBundleViewportInput.mappingResult(
            result: result,
            resultDirectoryURL: resultDirectory,
            provenance: nil as MappingProvenance?,
            viewerBundleManifest: viewerManifest
        )

        XCTAssertEqual(input.documentTitle, "mapping-run", "documentTitle must stay keyed on the result directory, not the bundle name")
        XCTAssertNil(input.manifest, "viewerBundleManifest must NOT populate the existing manifest field")
        XCTAssertEqual(input.viewerBundleManifest?.name, "Fixture")
    }

    func testViewportShowsExplicitPlaceholderWhenViewerBundleIsMissing() {
        let vc = MappingResultViewController()
        _ = vc.view

        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: nil))

        XCTAssertEqual(
            vc.testDetailPlaceholderMessage,
            "Reference bundle viewer unavailable for this mapping result."
        )
    }

    func testMappingResultInputAndFilteredAlignmentTargetUseExplicitResultDirectory() throws {
        let vc = MappingResultViewController()
        _ = vc.view
        let resultDirectory = tempDir.appendingPathComponent("mapping-run", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
        let result = makeMappingResult(
            viewerBundleURL: try makeReferenceBundleWithAnnotationDatabase(),
            resultDirectoryURL: resultDirectory
        )

        vc.configureForTesting(result: result, resultDirectoryURL: resultDirectory)

        XCTAssertEqual(vc.currentInput?.kind, .mappingResult)
        XCTAssertEqual(vc.currentInput?.mappingResultDirectoryURL, resultDirectory.standardizedFileURL)
        XCTAssertEqual(
            vc.testFilteredAlignmentServiceTarget,
            .mappingResult(resultDirectory.standardizedFileURL)
        )
    }

    func testEmbeddedViewerDoesNotPublishGlobalViewportNotifications() {
        let vc = MappingResultViewController()
        _ = vc.view

        XCTAssertFalse(vc.testEmbeddedViewerPublishesGlobalViewportNotifications)
    }

    func testEmbeddedViewerBuildsLocalAnnotationIndexForViewerBundle() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        let bundleURL = try makeReferenceBundleWithAnnotationDatabase()
        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: bundleURL))

        let embeddedViewer = try XCTUnwrap(
            vc.children.compactMap { $0 as? ViewerViewController }.first,
            "Mapping result view should embed a viewer controller"
        )

        XCTAssertNotNil(
            embeddedViewer.annotationSearchIndex,
            "Embedded mapping viewers should build their own annotation index even when global bundle notifications are disabled"
        )
        XCTAssertFalse(embeddedViewer.annotationSearchIndex?.isBuilding ?? true)
        XCTAssertEqual(embeddedViewer.annotationSearchIndex?.entryCount, 1)
    }

    func testEmbeddedViewerLoadsDirectSequenceModeInsteadOfNestedReferenceViewport() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: try makeReferenceBundleWithAnnotationDatabase()))

        XCTAssertFalse(vc.testEmbeddedViewerShowsReferenceViewport)
    }

    func testEmbeddedViewerDoesNotInstallChromosomeNavigator() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: try makeReferenceBundleWithAnnotationDatabase()))

        XCTAssertFalse(vc.testEmbeddedViewerShowsChromosomeNavigator)
    }

    func testEmbeddedViewerNotifiesHostWhenReferenceBundleLoads() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        let bundleURL = try makeReferenceBundleWithAnnotationDatabase()
        var deliveredBundle: ReferenceBundle?
        vc.onEmbeddedReferenceBundleLoaded = { deliveredBundle = $0 }

        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: bundleURL))

        XCTAssertEqual(deliveredBundle?.manifest.name, "Fixture")
    }

    func testReloadViewerBundleForInspectorChangesReloadsExistingViewerBundle() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        let bundleURL = try makeReferenceBundleWithAnnotationDatabase()
        var deliveredBundle: ReferenceBundle?
        var loadCount = 0
        vc.onEmbeddedReferenceBundleLoaded = {
            deliveredBundle = $0
            loadCount += 1
        }

        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: bundleURL))
        deliveredBundle = nil
        loadCount = 0

        XCTAssertNoThrow(try invokeInspectorReload(on: vc))
        XCTAssertEqual(loadCount, 1)
        XCTAssertEqual(deliveredBundle?.url.standardizedFileURL, bundleURL.standardizedFileURL)
    }

    func testReloadViewerBundleForInspectorChangesPreservesSelectedContig() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        let bundleURL = try makeReferenceBundleWithAnnotationDatabase()
        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: bundleURL))
        vc.testSelectContig(named: "alpha")

        XCTAssertEqual(vc.testSelectedContigName, "alpha")

        XCTAssertNoThrow(try invokeInspectorReload(on: vc))

        XCTAssertEqual(vc.testSelectedContigName, "alpha")
    }

    func testFilteredAlignmentServiceTargetUsesCurrentMappingResultDirectory() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        let outputDirectory = tempDir.appendingPathComponent("mapping-run", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let viewerBundleURL = try makeReferenceBundleWithAnnotationDatabase()
        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: viewerBundleURL,
            bamURL: outputDirectory.appendingPathComponent("example.sorted.bam"),
            baiURL: outputDirectory.appendingPathComponent("example.sorted.bam.bai"),
            totalReads: 200,
            mappedReads: 198,
            unmappedReads: 2,
            wallClockSeconds: 1.5,
            contigs: makeContigs()
        )

        vc.configureForTesting(result: result)

        XCTAssertEqual(
            vc.testFilteredAlignmentServiceTarget,
            .mappingResult(outputDirectory.standardizedFileURL)
        )
    }

    func testFilteredAlignmentServiceTargetPreservesExplicitResultDirectoryWhenBAMLivesOutsideResultFolder() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        let resultDirectory = tempDir.appendingPathComponent("mapping-run", isDirectory: true)
        let externalBAMDirectory = tempDir.appendingPathComponent("external-bams", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalBAMDirectory, withIntermediateDirectories: true)

        let viewerBundleURL = try makeReferenceBundleWithAnnotationDatabase()
        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: viewerBundleURL,
            bamURL: externalBAMDirectory.appendingPathComponent("example.sorted.bam"),
            baiURL: externalBAMDirectory.appendingPathComponent("example.sorted.bam.bai"),
            totalReads: 200,
            mappedReads: 198,
            unmappedReads: 2,
            wallClockSeconds: 1.5,
            contigs: makeContigs()
        )

        vc.configureForTesting(result: result, resultDirectoryURL: resultDirectory)

        XCTAssertEqual(
            vc.testFilteredAlignmentServiceTarget,
            .mappingResult(resultDirectory.standardizedFileURL)
        )
    }

    func testVisibleAlignmentTrackSelectionRefreshesContigRowsFromThatTrack() async throws {
        let vc = MappingResultViewController()
        _ = vc.view

        let resultDirectory = tempDir.appendingPathComponent("mapping-run", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
        let bundleURL = try makeReferenceBundleWithAlignmentTracks()
        let result = makeMappingResult(viewerBundleURL: bundleURL, resultDirectoryURL: resultDirectory)
        let filteredBuilderCalled = expectation(description: "filtered alignment summary builder called")
        var originalTrackCallCount = 0
        var filteredTrackCallCount = 0

        vc.setAlignmentTrackSummaryBuilderForTesting { bamURL, totalReads in
            switch bamURL.lastPathComponent {
            case "original.bam":
                XCTAssertEqual(totalReads, 10)
                originalTrackCallCount += 1
                return [
                    MappingContigSummary(
                        contigName: "alpha",
                        contigLength: 100,
                        mappedReads: 10,
                        mappedReadPercent: 100,
                        meanDepth: 4.5,
                        coverageBreadth: 0.84,
                        medianMAPQ: 60,
                        meanIdentity: 1.0
                    )
                ]
            case "filtered.bam":
                XCTAssertEqual(totalReads, 4)
                filteredTrackCallCount += 1
                if filteredTrackCallCount == 1 {
                    filteredBuilderCalled.fulfill()
                }
                return [
                    MappingContigSummary(
                        contigName: "alpha",
                        contigLength: 100,
                        mappedReads: 0,
                        mappedReadPercent: 0,
                        meanDepth: 0,
                        coverageBreadth: 0,
                        medianMAPQ: 0,
                        meanIdentity: 0
                    ),
                    MappingContigSummary(
                        contigName: "gamma",
                        contigLength: 100,
                        mappedReads: 4,
                        mappedReadPercent: 100,
                        meanDepth: 7.5,
                        coverageBreadth: 0.42,
                        medianMAPQ: 60,
                        meanIdentity: 1.0
                    ),
                ]
            default:
                XCTFail("Unexpected alignment track summary request: \(bamURL.path)")
                return []
            }
        }

        vc.configureForTesting(result: result, resultDirectoryURL: resultDirectory)
        XCTAssertEqual(vc.testContigTableView.displayedRows.map(\.contigName), ["beta", "alpha"])

        vc.applyEmbeddedReadDisplaySettings([
            NotificationUserInfoKey.visibleAlignmentTrackID: "filtered-track"
        ])

        await fulfillment(of: [filteredBuilderCalled], timeout: 2.0)
        try await waitUntil {
            vc.testContigTableView.displayedRows.map(\.contigName) == ["gamma"]
        }
        XCTAssertEqual(vc.testContigTableView.record(at: 0)?.mappedReads, 4)
        XCTAssertEqual(vc.testContigTableView.record(at: 0)?.meanDepth, 7.5)
        XCTAssertEqual(vc.testSummaryText, "Exact matches — 4 / 4 reads mapped (100.0%)")

        vc.applyEmbeddedReadDisplaySettings([
            NotificationUserInfoKey.visibleAlignmentTrackID: ""
        ])

        try await waitUntil {
            originalTrackCallCount >= 2
                && filteredTrackCallCount >= 2
                && vc.testContigTableView.displayedRows.map(\.contigName) == ["alpha", "gamma"]
        }
        XCTAssertNil(vc.testVisibleAlignmentTrackID)
        XCTAssertEqual(
            vc.testContigTableView.displayedRows.map { "\($0.sampleID ?? "unmatched"):\($0.contigName)" },
            ["unmatched:alpha", "unmatched:gamma"]
        )
        XCTAssertEqual(vc.testContigTableView.record(at: 0)?.mappedReads, 10)
        XCTAssertEqual(vc.testSummaryText, "minimap2 Mapping — 198 / 200 reads mapped (99.0%)")
    }

    func testMultiSampleTrackBuildsRGFilteredRowsAndSelectionAppliesEverySampleRG() async throws {
        let vc = MappingResultViewController()
        _ = vc.view
        let bundleURL = try makeReferenceBundleWithAlignmentTracks(includeSampleMetadata: true)
        let result = makeMappingResult(viewerBundleURL: bundleURL)
        var requestedReadGroups: [Set<String>] = []
        vc.setAlignmentTrackSummaryBuilderForTesting { _, _, readGroups in
            requestedReadGroups.append(readGroups)
            let reads = readGroups == Set(["S1-A", "S1-B"]) ? 4 : 1
            return [
                MappingContigSummary(
                    contigName: "gamma", contigLength: 100, mappedReads: reads,
                    mappedReadPercent: Double(reads) * 10, meanDepth: Double(reads),
                    coverageBreadth: 0.1, medianMAPQ: 60, meanIdentity: 99
                )
            ]
        }
        vc.configureForTesting(result: result)
        try await waitUntil {
            Set(vc.testContigTableView.displayedRows.compactMap(\.sampleID)) == Set(["S1", "S2"])
        }

        XCTAssertEqual(Set(requestedReadGroups), Set([Set(["S1-A", "S1-B"]), Set(["S2-A"])]))
        XCTAssertEqual(vc.testContigTableView.displayedRows.first { $0.sampleID == "S1" }?.mappedReads, 4)
        vc.testSelectContig(named: "gamma")
        XCTAssertEqual(vc.testSelectedReadGroups, Set(["S1-A", "S1-B"]))

        vc.applyEmbeddedReadDisplaySettings([
            NotificationUserInfoKey.visibleAlignmentTrackID: ""
        ])
        try await waitUntil {
            requestedReadGroups.filter { $0 == Set(["S1-A", "S1-B"]) }.count == 2
                && requestedReadGroups.filter { $0 == Set(["S2-A"]) }.count == 2
                && requestedReadGroups.contains([])
                && Set(vc.testContigTableView.displayedRows.compactMap(\.sampleID)) == Set(["S1", "S2"])
        }
        XCTAssertEqual(
            vc.testContigTableView.displayedRows.first { $0.sampleID == "S1" }?.mappedReads,
            4,
            "All Alignments must rebuild each multi-sample read-group slice instead of caching aggregate stats"
        )
        XCTAssertNil(vc.testVisibleAlignmentTrackID)
        XCTAssertEqual(vc.testSelectedReadGroups, [])

        vc.testSelectContig(sampleID: "S2", alignmentTrackID: "filtered-track", named: "gamma")
        XCTAssertEqual(vc.testVisibleAlignmentTrackID, "filtered-track")
        XCTAssertEqual(vc.testSelectedReadGroups, Set(["S2-A"]))

        vc.testSelectContig(sampleID: "S1", alignmentTrackID: "filtered-track", named: "gamma")
        XCTAssertEqual(vc.testVisibleAlignmentTrackID, "filtered-track")
        XCTAssertEqual(vc.testSelectedReadGroups, Set(["S1-A", "S1-B"]))
    }

    func testAllAlignmentRowsPreserveTrackIdentityForSameUnmatchedContig() async throws {
        let vc = MappingResultViewController()
        _ = vc.view
        let bundleURL = try makeReferenceBundleWithAlignmentTracks()
        vc.setAlignmentTrackSummaryBuilderForTesting { bamURL, totalReads in
            [
                MappingContigSummary(
                    contigName: "gamma", contigLength: 100, mappedReads: totalReads,
                    mappedReadPercent: 100, meanDepth: 1, coverageBreadth: 1,
                    medianMAPQ: 60, meanIdentity: 1
                )
            ]
        }
        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: bundleURL))
        vc.applyEmbeddedReadDisplaySettings([
            NotificationUserInfoKey.visibleAlignmentTrackID: ""
        ])

        try await waitUntil {
            vc.testContigTableView.displayedRows.filter { $0.contigName == "gamma" }.count == 2
        }
        let gammaRows = vc.testContigTableView.displayedRows.filter { $0.contigName == "gamma" }
        XCTAssertEqual(Set(gammaRows.map(\.alignmentTrackID)), Set(["original-track", "filtered-track"]))
        XCTAssertEqual(Set(gammaRows.compactMap { vc.testContigTableView.rowIdentity(for: $0) }), Set([
            "mapping\u{1F}unmatched\u{1F}original-track\u{1F}gamma",
            "mapping\u{1F}unmatched\u{1F}filtered-track\u{1F}gamma",
        ]))
        XCTAssertEqual(Set(gammaRows.map { vc.testContigTableView.columnValue(for: "track", row: $0) }), Set(["original-track", "filtered-track"]))
        XCTAssertEqual(vc.testContigTableView.testTableView.selectedRow, -1)
        XCTAssertNil(vc.testVisibleAlignmentTrackID)
        XCTAssertEqual(vc.testSelectedReadGroups, [])

        vc.testSelectContig(sampleID: nil, alignmentTrackID: "original-track", named: "gamma")
        XCTAssertEqual(vc.testVisibleAlignmentTrackID, "original-track")
        XCTAssertEqual(vc.testSelectedReadGroups, [])
    }

    func testAllAlignmentsMissingMetadataLeavesAnExplicitUnmatchedRowInsteadOfFocusedRows() async throws {
        let vc = MappingResultViewController()
        _ = vc.view
        let bundleURL = try makeReferenceBundleWithAlignmentTracks()
        let result = makeMappingResult(viewerBundleURL: bundleURL)
        var filteredCallCount = 0
        vc.setAlignmentTrackSummaryBuilderForTesting { bamURL, _, _ in
            if bamURL.lastPathComponent == "filtered.bam" {
                filteredCallCount += 1
                return [
                    MappingContigSummary(
                        contigName: "gamma", contigLength: 100, mappedReads: 4,
                        mappedReadPercent: 100, meanDepth: 2, coverageBreadth: 0.5,
                        medianMAPQ: 60, meanIdentity: 1
                    )
                ]
            }
            return []
        }

        vc.configureForTesting(result: result)
        vc.applyEmbeddedReadDisplaySettings([
            NotificationUserInfoKey.visibleAlignmentTrackID: "filtered-track"
        ])
        try await waitUntil {
            filteredCallCount >= 1
                && vc.testContigTableView.displayedRows.map(\.contigName) == ["gamma"]
        }

        vc.applyEmbeddedReadDisplaySettings([
            NotificationUserInfoKey.visibleAlignmentTrackID: ""
        ])
        try await waitUntil {
            filteredCallCount >= 2
                && vc.testContigTableView.displayedRows.map(\.contigName) == ["gamma"]
                && vc.testContigTableView.displayedRows.allSatisfy { $0.sampleID == nil }
        }
        XCTAssertNil(vc.testVisibleAlignmentTrackID)
    }

    func testUnresolvedMetadataBuildsUnmatchedRowsInsteadOfCachingAggregateStats() async throws {
        let vc = MappingResultViewController()
        _ = vc.view
        let bundleURL = try makeReferenceBundleWithAlignmentTracks(includeAmbiguousSampleMetadata: true)
        let result = makeMappingResult(viewerBundleURL: bundleURL)
        var filteredCallCount = 0
        vc.setAlignmentTrackSummaryBuilderForTesting { bamURL, _, readGroups in
            if bamURL.lastPathComponent == "filtered.bam" {
                XCTAssertTrue(readGroups.isEmpty, "ambiguous persisted identity must not invent an RG filter")
                filteredCallCount += 1
                return [
                    MappingContigSummary(
                        contigName: "gamma", contigLength: 100, mappedReads: 4,
                        mappedReadPercent: 100, meanDepth: 2, coverageBreadth: 0.5,
                        medianMAPQ: 60, meanIdentity: 1
                    )
                ]
            }
            return []
        }

        vc.configureForTesting(result: result)
        try await waitUntil { filteredCallCount >= 1 }
        XCTAssertEqual(vc.testContigTableView.displayedRows.map(\.contigName), ["gamma"])
        XCTAssertTrue(vc.testContigTableView.displayedRows.allSatisfy { $0.sampleID == nil })
    }

    func testRapidTrackAndAllAlignmentChangesDiscardSupersededRows() async throws {
        let vc = MappingResultViewController()
        _ = vc.view
        let bundleURL = try makeReferenceBundleWithAlignmentTracks()
        let result = makeMappingResult(viewerBundleURL: bundleURL)
        vc.setAlignmentTrackSummaryBuilderForTesting { bamURL, _, _ in
            if bamURL.lastPathComponent == "filtered.bam" {
                try await Task.sleep(nanoseconds: 200_000_000)
                return [
                    MappingContigSummary(
                        contigName: "gamma", contigLength: 100, mappedReads: 4,
                        mappedReadPercent: 100, meanDepth: 2, coverageBreadth: 0.5,
                        medianMAPQ: 60, meanIdentity: 1
                    )
                ]
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            return [
                MappingContigSummary(
                    contigName: "alpha", contigLength: 100, mappedReads: 10,
                    mappedReadPercent: 100, meanDepth: 2, coverageBreadth: 0.5,
                    medianMAPQ: 60, meanIdentity: 1
                )
            ]
        }

        vc.configureForTesting(result: result)
        vc.applyEmbeddedReadDisplaySettings([
            NotificationUserInfoKey.visibleAlignmentTrackID: "filtered-track"
        ])
        vc.applyEmbeddedReadDisplaySettings([
            NotificationUserInfoKey.visibleAlignmentTrackID: ""
        ])

        try await waitUntil {
            vc.testContigTableView.displayedRows.map(\.contigName) == ["alpha", "gamma"]
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(
            vc.testContigTableView.displayedRows.map(\.contigName),
            ["alpha", "gamma"],
            "a late focused-track result must not replace the newer All Alignments rows"
        )
        XCTAssertNil(vc.testVisibleAlignmentTrackID)
    }

    func testConsensusExportUsesSelectedContigNameInSuggestedStem() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: try makeReferenceBundleWithAnnotationDatabase()))

        let request = try vc.testBuildConsensusExportRequest()

        XCTAssertEqual(request.chromosome, "beta")
        XCTAssertEqual(request.suggestedName, "example-beta-consensus")
        XCTAssertFalse(request.showDeletions)
        XCTAssertTrue(request.showInsertions)
    }

    func testConsensusExportFallsBackToVisibleChromosomeWhenSelectionClears() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: try makeReferenceBundleWithAnnotationDatabase()))
        vc.testClearContigSelection()

        let request = try vc.testBuildConsensusExportRequest()

        XCTAssertEqual(request.chromosome, "chr1")
        XCTAssertEqual(request.suggestedName, "example-chr1-consensus")
    }

    func testConsensusExportUsesEffectiveMaximumMapQFloor() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: try makeReferenceBundleWithAnnotationDatabase()))
        vc.testSetEmbeddedReadDisplaySettings(
            minMapQ: 27,
            consensusMinMapQ: 11
        )

        let request = try vc.testBuildConsensusExportRequest()

        XCTAssertEqual(request.minMapQ, 27)
    }

    func testInspectorConsensusExportUsesVisibleViewportScope() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: try makeReferenceBundleWithAnnotationDatabase()))

        let request = try vc.testBuildInspectorConsensusExportRequest()

        XCTAssertEqual(request.chromosome, "chr1")
        XCTAssertEqual(request.start, 0)
        XCTAssertEqual(request.end, 100)
        XCTAssertEqual(request.recordName, "example chr1:1-100 visible consensus")
        XCTAssertEqual(request.suggestedName, "example-chr1-1-100-visible-consensus")
    }

    func testInspectorConsensusExportPrefersUserSelectedRegion() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: try makeReferenceBundleWithAnnotationDatabase()))
        vc.testSetEmbeddedSelectionRange(10..<40)

        let request = try vc.testBuildInspectorConsensusExportRequest()

        XCTAssertEqual(request.chromosome, "chr1")
        XCTAssertEqual(request.start, 10)
        XCTAssertEqual(request.end, 40)
        XCTAssertEqual(request.recordName, "example chr1:11-40 selection consensus")
        XCTAssertEqual(request.suggestedName, "example-chr1-11-40-selection-consensus")
    }

    func testInspectorConsensusExportIgnoresNonUserViewportSelectionState() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: try makeReferenceBundleWithAnnotationDatabase()))
        vc.testSetEmbeddedSelectionRange(10..<40, isUserColumnSelection: false)

        let request = try vc.testBuildInspectorConsensusExportRequest()

        XCTAssertEqual(request.chromosome, "chr1")
        XCTAssertEqual(request.start, 0)
        XCTAssertEqual(request.end, 100)
        XCTAssertEqual(request.suggestedName, "example-chr1-1-100-visible-consensus")
    }

    func testChangingMappingContigsClearsStaleUserSelectedRegionBeforeConsensusExport() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: try makeReferenceBundleWithAlignmentTracks(),
            bamURL: URL(fileURLWithPath: "/tmp/example.sorted.bam"),
            baiURL: URL(fileURLWithPath: "/tmp/example.sorted.bam.bai"),
            totalReads: 200,
            mappedReads: 198,
            unmappedReads: 2,
            wallClockSeconds: 1.5,
            contigs: [
                MappingContigSummary(
                    contigName: "alpha",
                    contigLength: 100,
                    mappedReads: 120,
                    mappedReadPercent: 60,
                    meanDepth: 10,
                    coverageBreadth: 90,
                    medianMAPQ: 60,
                    meanIdentity: 99
                ),
                MappingContigSummary(
                    contigName: "gamma",
                    contigLength: 100,
                    mappedReads: 80,
                    mappedReadPercent: 40,
                    meanDepth: 8,
                    coverageBreadth: 85,
                    medianMAPQ: 55,
                    meanIdentity: 98
                ),
            ]
        )

        vc.configureForTesting(result: result)
        vc.testSelectContig(named: "alpha")
        vc.testSetEmbeddedSelectionRange(10..<40)
        XCTAssertEqual(
            try vc.testBuildInspectorConsensusExportRequest().suggestedName,
            "example-alpha-11-40-selection-consensus"
        )

        vc.testSelectContig(named: "gamma")
        let request = try vc.testBuildInspectorConsensusExportRequest()

        XCTAssertEqual(request.chromosome, "gamma")
        XCTAssertEqual(request.start, 0)
        XCTAssertEqual(request.end, 100)
        XCTAssertEqual(request.suggestedName, "example-gamma-1-100-visible-consensus")
    }

    func testExportResultsWritesMappingSummaryCSV() throws {
        let vc = MappingResultViewController()
        _ = vc.view
        let resultDirectory = tempDir.appendingPathComponent("mapping-run", isDirectory: true)
        try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
        let result = MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            bamURL: resultDirectory.appendingPathComponent("example.sorted.bam"),
            baiURL: resultDirectory.appendingPathComponent("example.sorted.bam.bai"),
            totalReads: 200,
            mappedReads: 198,
            unmappedReads: 2,
            wallClockSeconds: 1.5,
            contigs: [
                MappingContigSummary(
                    contigName: "alpha,quoted",
                    contigLength: 100,
                    mappedReads: 42,
                    mappedReadPercent: 21,
                    meanDepth: 2.4,
                    coverageBreadth: 8,
                    medianMAPQ: 32,
                    meanIdentity: 98.5
                ),
            ]
        )
        try Data("bam".utf8).write(to: result.bamURL)
        try Data("bai".utf8).write(to: result.baiURL)
        try result.save(to: resultDirectory)

        vc.configureForTesting(result: result, resultDirectoryURL: resultDirectory)

        let outputURL = tempDir.appendingPathComponent("mapping-summary.csv")
        try vc.exportResults(to: outputURL, format: .csv)

        let content = try String(contentsOf: outputURL, encoding: .utf8)
        XCTAssertEqual(
            content,
            """
            Contig,Length,Mapped Reads,% Mapped,Mean Depth,Coverage Breadth,Median MAPQ,Mean Identity
            "alpha,quoted",100,42,21.0000,2.4000,8.0000,32.0000,98.5000

            """
        )

        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        )
        XCTAssertEqual(envelope.workflowName, "lungfish app mapping result export")
        XCTAssertEqual(envelope.output?.path, outputURL.path)
        XCTAssertEqual(envelope.output?.format, .text)
        XCTAssertNotNil(envelope.output?.checksumSHA256)
        XCTAssertEqual(envelope.options.explicit["format"]?.stringValue, "csv")
        XCTAssertEqual(envelope.options.resolvedDefaults["contigCount"]?.integerValue, 1)
        XCTAssertEqual(envelope.options.resolvedDefaults["totalReads"]?.integerValue, 200)
        XCTAssertTrue(envelope.argv.contains("export-mapping-results"))
        XCTAssertTrue(envelope.files.contains { $0.path == resultDirectory.standardizedFileURL.path && $0.role == .input })
    }

    func testExportResultsWritesMappingSummaryTSV() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        vc.configureForTesting(result: makeMappingResult())

        let outputURL = tempDir.appendingPathComponent("mapping-summary.tsv")
        try vc.exportResults(to: outputURL, format: .tsv)

        let lines = try String(contentsOf: outputURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(
            String(lines[0]),
            "Contig\tLength\tMapped Reads\t% Mapped\tMean Depth\tCoverage Breadth\tMedian MAPQ\tMean Identity"
        )
        XCTAssertEqual(
            String(lines[1]),
            "alpha\t29903\t42\t21.0000\t2.4000\t8.0000\t32.0000\t98.5000"
        )
    }

    func testExportResultsRejectsFASTAExplicitly() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        vc.configureForTesting(result: makeMappingResult())

        XCTAssertThrowsError(
            try vc.exportResults(to: tempDir.appendingPathComponent("mapping.fa"), format: .fasta)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("not supported for mapping results"))
        }
    }

    func testExportResultsRejectsJSONExplicitly() throws {
        let vc = MappingResultViewController()
        _ = vc.view

        vc.configureForTesting(result: makeMappingResult())

        XCTAssertThrowsError(
            try vc.exportResults(to: tempDir.appendingPathComponent("mapping.json"), format: .json)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("not supported for mapping results"))
        }
    }

    func testLiveResizeDelegatePreservesUserMovedVerticalDivider() {
        UserDefaults.standard.set(
            MappingPanelLayout.listLeading.rawValue,
            forKey: MappingPanelLayout.defaultsKey
        )

        let vc = MappingResultViewController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: nil))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 1400, height: 800))
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        let initialWidth = vc.testListContainer.frame.width
        let targetPosition = initialWidth + 160
        vc.testSplitView.setPosition(targetPosition, ofDividerAt: 0)
        vc.splitViewDidResizeSubviews(Notification(name: .init("TestMappingSplitResize"), object: vc.testSplitView))

        let movedWidth = vc.testListContainer.frame.width
        XCTAssertGreaterThan(Swift.abs(movedWidth - initialWidth), CGFloat(80))

        let oldSize = vc.testSplitView.frame.size
        vc.testSplitView.setFrameSize(NSSize(width: oldSize.width + 220, height: oldSize.height))
        invokeOptionalSplitResizeDelegate(on: vc, splitView: vc.testSplitView, oldSize: oldSize)

        XCTAssertEqual(vc.testListContainer.frame.width, movedWidth, accuracy: 2)
    }

    func testSidebarLayoutChangesApplyDeterministicPaneOrderAndDefaultExtent() {
        UserDefaults.standard.set(
            MappingPanelLayout.detailLeading.rawValue,
            forKey: MappingPanelLayout.defaultsKey
        )

        let vc = MappingResultViewController()
        vc.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: nil))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.setContentSize(NSSize(width: 1400, height: 800))
        window.layoutIfNeeded()
        vc.view.layoutSubtreeIfNeeded()
        vc.viewDidLayout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        vc.reapplyMappingLayoutPreferenceForTesting()

        assertMappingLayout(
            vc,
            firstPane: vc.testDetailContainer,
            secondPane: vc.testListContainer,
            isVertical: true,
            expectedLeadingFraction: 0.6
        )

        MappingPanelLayout.listLeading.persist()
        vc.view.layoutSubtreeIfNeeded()
        vc.reapplyMappingLayoutPreferenceForTesting()

        assertMappingLayout(
            vc,
            firstPane: vc.testListContainer,
            secondPane: vc.testDetailContainer,
            isVertical: true,
            expectedLeadingFraction: 0.4
        )

        MappingPanelLayout.stacked.persist()
        vc.view.layoutSubtreeIfNeeded()
        vc.reapplyMappingLayoutPreferenceForTesting()

        assertMappingLayout(
            vc,
            firstPane: vc.testListContainer,
            secondPane: vc.testDetailContainer,
            isVertical: false,
            expectedLeadingFraction: 0.4
        )

        MappingPanelLayout.listLeading.persist()
        vc.view.layoutSubtreeIfNeeded()
        vc.reapplyMappingLayoutPreferenceForTesting()

        assertMappingLayout(
            vc,
            firstPane: vc.testListContainer,
            secondPane: vc.testDetailContainer,
            isVertical: true,
            expectedLeadingFraction: 0.4
        )
    }

    func testTopLevelMappingDisplayLaysOutPanesBeforeReturning() throws {
        let priorLayout = UserDefaults.standard.string(forKey: MappingPanelLayout.defaultsKey)
        defer {
            if let priorLayout {
                UserDefaults.standard.set(priorLayout, forKey: MappingPanelLayout.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: MappingPanelLayout.defaultsKey)
            }
        }

        UserDefaults.standard.set(
            MappingPanelLayout.detailLeading.rawValue,
            forKey: MappingPanelLayout.defaultsKey
        )

        let host = ViewerViewController()
        host.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 800)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1400, height: 800))
        window.layoutIfNeeded()
        host.view.layoutSubtreeIfNeeded()

        host.displayMappingResult(
            makeMappingResult(viewerBundleURL: try makeReferenceBundleWithAnnotationDatabase())
        )

        let controller = try XCTUnwrap(host.mappingResultController)
        XCTAssertGreaterThan(controller.testDetailContainer.frame.width, CGFloat(300))
        XCTAssertGreaterThan(controller.testListContainer.frame.width, CGFloat(300))
        XCTAssertFalse(controller.testDetailContainer.isHidden)
        XCTAssertFalse(controller.testListContainer.isHidden)
    }

    private func makeMappingResult(
        viewerBundleURL: URL? = nil,
        resultDirectoryURL: URL? = nil
    ) -> MappingResult {
        let directory = resultDirectoryURL ?? URL(fileURLWithPath: "/tmp", isDirectory: true)
        return MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: viewerBundleURL,
            bamURL: directory.appendingPathComponent("example.sorted.bam"),
            baiURL: directory.appendingPathComponent("example.sorted.bam.bai"),
            totalReads: 200,
            mappedReads: 198,
            unmappedReads: 2,
            wallClockSeconds: 1.5,
            contigs: makeContigs()
        )
    }

    /// A `MappingResult` whose contigs match `makeReferenceBundleWithAlignmentTracks()`'s
    /// chromosome set (`alpha`/`gamma`), so `testSelectContig(named:)` can
    /// select either row and drive the embedded viewer to that chromosome.
    private func makeAlphaGammaMappingResult(viewerBundleURL: URL?) -> MappingResult {
        MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: viewerBundleURL,
            bamURL: URL(fileURLWithPath: "/tmp/alpha-gamma.sorted.bam"),
            baiURL: URL(fileURLWithPath: "/tmp/alpha-gamma.sorted.bam.bai"),
            totalReads: 200,
            mappedReads: 198,
            unmappedReads: 2,
            wallClockSeconds: 1.5,
            contigs: [
                MappingContigSummary(
                    contigName: "alpha",
                    contigLength: 100,
                    mappedReads: 120,
                    mappedReadPercent: 60,
                    meanDepth: 10,
                    coverageBreadth: 90,
                    medianMAPQ: 60,
                    meanIdentity: 99
                ),
                MappingContigSummary(
                    contigName: "gamma",
                    contigLength: 100,
                    mappedReads: 80,
                    mappedReadPercent: 40,
                    meanDepth: 8,
                    coverageBreadth: 85,
                    medianMAPQ: 55,
                    meanIdentity: 98
                ),
            ]
        )
    }

    private func makeContigs() -> [MappingContigSummary] {
        [
            MappingContigSummary(
                contigName: "alpha",
                contigLength: 29_903,
                mappedReads: 42,
                mappedReadPercent: 21.0,
                meanDepth: 2.4,
                coverageBreadth: 8.0,
                medianMAPQ: 32.0,
                meanIdentity: 98.5
            ),
            MappingContigSummary(
                contigName: "beta",
                contigLength: 29_903,
                mappedReads: 197,
                mappedReadPercent: 98.5,
                meanDepth: 9.1,
                coverageBreadth: 96.2,
                medianMAPQ: 60.0,
                meanIdentity: 99.7
            ),
        ]
    }

    private func makeReferenceBundleWithAnnotationDatabase() throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("fixture.lungfishref", isDirectory: true)
        let genomeURL = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let annotationsURL = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: annotationsURL, withIntermediateDirectories: true)

        try Data().write(to: genomeURL.appendingPathComponent("sequence.fa.gz"))
        try Data().write(to: genomeURL.appendingPathComponent("sequence.fa.gz.fai"))
        try Data().write(to: genomeURL.appendingPathComponent("sequence.fa.gz.gzi"))

        let bedURL = tempDir.appendingPathComponent("annotations.bed")
        try "chr1\t10\t40\tORF1ab\t0\t+\t10\t40\t0,0,0\t1\t30\t0\tgene\tgene=ORF1ab\n"
            .write(to: bedURL, atomically: true, encoding: .utf8)
        let annotationDBURL = annotationsURL.appendingPathComponent("annotations.db")
        try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: annotationDBURL)

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Fixture",
            identifier: "org.test.fixture",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: "genome/sequence.fa.gz.gzi",
                totalLength: 100,
                chromosomes: [
                    ChromosomeInfo(name: "chr1", length: 100, offset: 0, lineBases: 80, lineWidth: 81)
                ]
            ),
            annotations: [
                AnnotationTrackInfo(
                    id: "genes",
                    name: "Genes",
                    path: "annotations/annotations.db",
                    databasePath: "annotations/annotations.db",
                    annotationType: .gene,
                    featureCount: 1,
                    source: "Test"
                )
            ]
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    private func makeReferenceBundleWithAlignmentTracks(
        includeSampleMetadata: Bool = false,
        includeAmbiguousSampleMetadata: Bool = false
    ) throws -> URL {
        let bundleURL = tempDir.appendingPathComponent("alignment-tracks.lungfishref", isDirectory: true)
        let genomeURL = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let alignmentsURL = bundleURL.appendingPathComponent("alignments", isDirectory: true)
        let filteredURL = alignmentsURL.appendingPathComponent("filtered", isDirectory: true)
        try FileManager.default.createDirectory(at: genomeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: filteredURL, withIntermediateDirectories: true)

        try Data().write(to: genomeURL.appendingPathComponent("sequence.fa.gz"))
        try Data().write(to: genomeURL.appendingPathComponent("sequence.fa.gz.fai"))
        try Data().write(to: genomeURL.appendingPathComponent("sequence.fa.gz.gzi"))
        try Data().write(to: alignmentsURL.appendingPathComponent("original.bam"))
        try Data().write(to: alignmentsURL.appendingPathComponent("original.bam.bai"))
        try Data().write(to: filteredURL.appendingPathComponent("filtered.bam"))
        try Data().write(to: filteredURL.appendingPathComponent("filtered.bam.bai"))
        let metadataPath = "alignments/filtered/filtered.stats.db"
        if includeSampleMetadata || includeAmbiguousSampleMetadata {
            let database = try AlignmentMetadataDatabase.create(at: bundleURL.appendingPathComponent(metadataPath))
            if includeAmbiguousSampleMetadata {
                database.addReadGroup(id: "unresolved-rg", sample: nil)
                database.addChromosomeStats(chromosome: "gamma", length: 100, mapped: 99, unmapped: 0)
            } else {
                database.addReadGroup(id: "S1-A", sample: "S1")
                database.addReadGroup(id: "S1-B", sample: "S1")
                database.addReadGroup(id: "S2-A", sample: "S2")
            }
        }

        let manifest = BundleManifest(
            formatVersion: "1.0",
            name: "Alignment Tracks",
            identifier: "org.test.alignment-tracks",
            source: SourceInfo(organism: "Test organism", assembly: "fixture"),
            genome: GenomeInfo(
                path: "genome/sequence.fa.gz",
                indexPath: "genome/sequence.fa.gz.fai",
                gzipIndexPath: "genome/sequence.fa.gz.gzi",
                totalLength: 200,
                chromosomes: [
                    ChromosomeInfo(name: "alpha", length: 100, offset: 0, lineBases: 80, lineWidth: 81),
                    ChromosomeInfo(name: "gamma", length: 100, offset: 100, lineBases: 80, lineWidth: 81),
                ]
            ),
            alignments: [
                AlignmentTrackInfo(
                    id: "original-track",
                    name: "Original",
                    sourcePath: "alignments/original.bam",
                    indexPath: "alignments/original.bam.bai",
                    mappedReadCount: 10,
                    unmappedReadCount: 0
                ),
                AlignmentTrackInfo(
                    id: "filtered-track",
                    name: "Exact matches",
                    sourcePath: "alignments/filtered/filtered.bam",
                    indexPath: "alignments/filtered/filtered.bam.bai",
                    metadataDBPath: (includeSampleMetadata || includeAmbiguousSampleMetadata) ? metadataPath : nil,
                    mappedReadCount: 4,
                    unmappedReadCount: 0
                ),
            ]
        )
        try manifest.save(to: bundleURL)
        return bundleURL
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        predicate: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func invokeInspectorReload(on controller: MappingResultViewController) throws {
        let selector = NSSelectorFromString("reloadViewerBundleForInspectorChangesAndReturnError:")
        let object = controller as AnyObject
        XCTAssertTrue(
            object.responds(to: selector),
            "MappingResultViewController should expose an Inspector reload hook"
        )

        typealias ReloadIMP = @convention(c) (
            AnyObject,
            Selector,
            UnsafeMutablePointer<NSError?>?
        ) -> Bool
        let implementation = try XCTUnwrap(object.method(for: selector))
        let function = unsafeBitCast(implementation, to: ReloadIMP.self)
        var error: NSError?
        let succeeded = function(object, selector, &error)

        XCTAssertTrue(succeeded, "Inspector-triggered mapping reload should succeed")
        XCTAssertNil(error)
    }

    private func invokeOptionalSplitResizeDelegate(
        on controller: NSObject,
        splitView: NSSplitView,
        oldSize: NSSize
    ) {
        let selector = NSSelectorFromString("splitView:resizeSubviewsWithOldSize:")
        XCTAssertTrue(controller.responds(to: selector), "Expected custom split live-resize delegate")
        guard let method = controller.method(for: selector) else { return XCTFail("Missing split resize delegate method") }
        typealias ResizeIMP = @convention(c) (AnyObject, Selector, NSSplitView, NSSize) -> Void
        unsafeBitCast(method, to: ResizeIMP.self)(controller, selector, splitView, oldSize)
    }

    private func assertMappingLayout(
        _ controller: MappingResultViewController,
        firstPane: NSView,
        secondPane: NSView,
        isVertical: Bool,
        expectedLeadingFraction: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let splitView = controller.testSplitView
        XCTAssertEqual(splitView.isVertical, isVertical, file: file, line: line)
        XCTAssertTrue(splitView.arrangedSubviews[0] === firstPane, file: file, line: line)
        XCTAssertTrue(splitView.arrangedSubviews[1] === secondPane, file: file, line: line)

        let totalExtent = isVertical ? splitView.bounds.width : splitView.bounds.height
        let leadingExtent = isVertical ? firstPane.frame.width : firstPane.frame.height
        let trailingExtent = isVertical ? secondPane.frame.width : secondPane.frame.height
        let expectedLeadingExtent = SplitPaneSizing.clampedDividerPosition(
            proposed: round(totalExtent * expectedLeadingFraction),
            containerExtent: totalExtent,
            minimumLeadingExtent: 320,
            minimumTrailingExtent: 320
        )
        XCTAssertEqual(leadingExtent, expectedLeadingExtent, accuracy: 4, file: file, line: line)
        XCTAssertGreaterThan(leadingExtent, CGFloat(300), file: file, line: line)
        XCTAssertGreaterThan(trailingExtent, CGFloat(300), file: file, line: line)
    }
}

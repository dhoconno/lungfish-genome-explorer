import XCTest
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
final class MappingResultViewControllerTests: XCTestCase {
    nonisolated(unsafe) private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
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
            ["Contig", "Length", "Mapped Reads", "% Mapped", "Mean Depth", "Coverage Breadth", "Median MAPQ", "Mean Identity"]
        )
        XCTAssertEqual(vc.testContigTableView.record(at: 0)?.contigName, "beta")
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

    func testViewportShowsExplicitPlaceholderWhenViewerBundleIsMissing() {
        let vc = MappingResultViewController()
        _ = vc.view

        vc.configureForTesting(result: makeMappingResult(viewerBundleURL: nil))

        XCTAssertEqual(
            vc.testDetailPlaceholderMessage,
            "Reference bundle viewer unavailable for this mapping result."
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

    private func makeMappingResult(viewerBundleURL: URL? = nil) -> MappingResult {
        MappingResult(
            mapper: .minimap2,
            modeID: MappingMode.defaultShortRead.id,
            sourceReferenceBundleURL: nil,
            viewerBundleURL: viewerBundleURL,
            bamURL: URL(fileURLWithPath: "/tmp/example.sorted.bam"),
            baiURL: URL(fileURLWithPath: "/tmp/example.sorted.bam.bai"),
            totalReads: 200,
            mappedReads: 198,
            unmappedReads: 2,
            wallClockSeconds: 1.5,
            contigs: makeContigs()
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
}

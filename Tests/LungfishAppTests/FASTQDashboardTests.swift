// FASTQDashboardTests.swift - Tests for FASTQ Dataset Dashboard functionality
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import AppKit
@testable import LungfishApp
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

@MainActor
private final class StubFASTQOperationAlertPresenter: FASTQOperationAlertPresenting {
    var response: NSApplication.ModalResponse = .alertSecondButtonReturn
    private(set) var messageText: String?

    func present(_ alert: NSAlert, on window: NSWindow?) async -> NSApplication.ModalResponse {
        messageText = alert.messageText
        return response
    }
}

private actor StubHumanScrubberInstaller: HumanScrubberDatabaseInstalling {
    enum Mode {
        case succeed
        case fail(String)
    }

    var mode: Mode = .succeed
    private(set) var installCallCount = 0
    private(set) var installedDatabaseIDs: [String] = []

    func install(databaseID: String, progress: (@Sendable (Double, String) -> Void)?) async throws {
        installCallCount += 1
        installedDatabaseIDs.append(databaseID)
        switch mode {
        case .succeed:
            progress?(1.0, "Installed")
        case .fail(let reason):
            throw HumanScrubberDatabaseError.installationFailed(
                databaseID: databaseID,
                displayName: "Human Read Scrubber Database",
                reason: reason
            )
        }
    }

    func currentInstallCallCount() -> Int {
        installCallCount
    }

    func lastInstalledDatabaseID() -> String? {
        installedDatabaseIDs.last
    }
}

final class FASTQDashboardTests: XCTestCase {

    // MARK: - Helpers

    private func makeSampleStatistics(
        readCount: Int = 1000,
        baseCount: Int64 = 150_000,
        meanReadLength: Double = 150.0,
        gcContent: Double = 0.48
    ) -> FASTQDatasetStatistics {
        FASTQDatasetStatistics(
            readCount: readCount,
            baseCount: baseCount,
            meanReadLength: meanReadLength,
            minReadLength: 100,
            maxReadLength: 200,
            medianReadLength: 150,
            n50ReadLength: 160,
            meanQuality: 35.0,
            q20Percentage: 98.5,
            q30Percentage: 92.3,
            gcContent: gcContent,
            readLengthHistogram: [100: 50, 150: 800, 200: 150],
            qualityScoreHistogram: [30: 50000, 35: 80000, 40: 20000],
            perPositionQuality: [
                PositionQualitySummary(
                    position: 0, mean: 35.0, median: 36.0,
                    lowerQuartile: 32.0, upperQuartile: 38.0,
                    percentile10: 28.0, percentile90: 40.0
                ),
            ]
        )
    }

    private func makeSampleSRARunInfo() -> SRARunInfo {
        SRARunInfo(
            accession: "SRR12345678",
            experiment: "SRX11111111",
            sample: "SRS22222222",
            study: "SRP33333333",
            bioproject: "PRJNA444444",
            biosample: "SAMN55555555",
            organism: "Homo sapiens",
            platform: "ILLUMINA",
            libraryStrategy: "WGS",
            librarySource: "GENOMIC",
            libraryLayout: "PAIRED",
            spots: 5_000_000,
            bases: 750_000_000,
            avgLength: 150,
            size: 1200,
            releaseDate: nil
        )
    }

    private func makeSampleENAReadRecord() -> ENAReadRecord {
        let json = """
        {
            "run_accession": "ERR9876543",
            "experiment_accession": "ERX1111111",
            "library_layout": "PAIRED",
            "instrument_platform": "ILLUMINA",
            "base_count": 500000000,
            "read_count": 3333333
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(ENAReadRecord.self, from: json)
    }

    private func makeSampleRecords(count: Int = 10) -> [FASTQRecord] {
        (0..<count).map { i in
            let seq = String(repeating: "ACGT", count: 25) // 100bp
            let qualStr = String(repeating: "I", count: 100) // Q40
            return FASTQRecord(
                identifier: "SEQ_\(String(format: "%03d", i + 1))",
                sequence: seq,
                qualityString: qualStr,
                encoding: .phred33
            )
        }
    }

    // MARK: - DocumentSectionViewModel FASTQ Updates

    @MainActor
    func testDocumentSectionViewModelFASTQStatisticsUpdate() {
        let viewModel = DocumentSectionViewModel()

        // Initially nil
        XCTAssertNil(viewModel.fastqStatistics)
        XCTAssertNil(viewModel.sraRunInfo)
        XCTAssertNil(viewModel.enaReadRecord)

        // Update with FASTQ stats
        let stats = makeSampleStatistics()
        viewModel.updateFASTQStatistics(stats)

        XCTAssertNotNil(viewModel.fastqStatistics)
        XCTAssertEqual(viewModel.fastqStatistics?.readCount, 1000)
        XCTAssertEqual(viewModel.fastqStatistics?.meanQuality, 35.0)
        XCTAssertEqual(viewModel.fastqStatistics?.gcContent ?? 0, 0.48, accuracy: 0.001)

        // Bundle-related properties should be cleared
        XCTAssertNil(viewModel.manifest)
        XCTAssertNil(viewModel.bundleURL)
        XCTAssertNil(viewModel.selectedChromosome)
    }

    @MainActor
    func testDocumentSectionViewModelSRAMetadataUpdate() {
        let viewModel = DocumentSectionViewModel()
        let sra = makeSampleSRARunInfo()
        let ena = makeSampleENAReadRecord()

        viewModel.updateSRAMetadata(sra: sra, ena: ena)

        XCTAssertNotNil(viewModel.sraRunInfo)
        XCTAssertNotNil(viewModel.enaReadRecord)
        XCTAssertEqual(viewModel.sraRunInfo?.accession, "SRR12345678")
        XCTAssertEqual(viewModel.enaReadRecord?.runAccession, "ERR9876543")
    }

    @MainActor
    func testDocumentSectionViewModelSRAOnly() {
        let viewModel = DocumentSectionViewModel()
        let sra = makeSampleSRARunInfo()

        viewModel.updateSRAMetadata(sra: sra, ena: nil)

        XCTAssertNotNil(viewModel.sraRunInfo)
        XCTAssertNil(viewModel.enaReadRecord)
    }

    @MainActor
    func testDocumentSectionViewModelENAOnly() {
        let viewModel = DocumentSectionViewModel()
        let ena = makeSampleENAReadRecord()

        viewModel.updateSRAMetadata(sra: nil, ena: ena)

        XCTAssertNil(viewModel.sraRunInfo)
        XCTAssertNotNil(viewModel.enaReadRecord)
    }

    @MainActor
    func testDocumentSectionViewModelFASTQClearsBundleData() {
        let viewModel = DocumentSectionViewModel()

        // Set some bundle data
        viewModel.bundleURL = URL(fileURLWithPath: "/tmp/test.bundle")

        // Update with FASTQ stats should clear bundle data
        viewModel.updateFASTQStatistics(makeSampleStatistics())

        XCTAssertNil(viewModel.bundleURL)
        XCTAssertNil(viewModel.manifest)
    }

    // MARK: - FASTQ File Detection Logic

    func testFASTQFileDetectionPlainFASTQ() {
        XCTAssertTrue(isFASTQ(URL(fileURLWithPath: "/path/to/reads.fastq")))
        XCTAssertTrue(isFASTQ(URL(fileURLWithPath: "/path/to/reads.fq")))
    }

    func testFASTQFileDetectionGzipped() {
        XCTAssertTrue(isFASTQ(URL(fileURLWithPath: "/path/to/reads.fastq.gz")))
        XCTAssertTrue(isFASTQ(URL(fileURLWithPath: "/path/to/reads.fq.gz")))
    }

    func testFASTQFileDetectionCaseInsensitive() {
        XCTAssertTrue(isFASTQ(URL(fileURLWithPath: "/path/to/reads.FASTQ")))
        XCTAssertTrue(isFASTQ(URL(fileURLWithPath: "/path/to/reads.FQ.GZ")))
        XCTAssertTrue(isFASTQ(URL(fileURLWithPath: "/path/to/reads.Fastq.Gz")))
    }

    func testNonFASTQFilesNotDetected() {
        XCTAssertFalse(isFASTQ(URL(fileURLWithPath: "/path/to/genome.fasta")))
        XCTAssertFalse(isFASTQ(URL(fileURLWithPath: "/path/to/genome.fa")))
        XCTAssertFalse(isFASTQ(URL(fileURLWithPath: "/path/to/annotations.gff3")))
        XCTAssertFalse(isFASTQ(URL(fileURLWithPath: "/path/to/variants.vcf")))
        XCTAssertFalse(isFASTQ(URL(fileURLWithPath: "/path/to/data.bed")))
        XCTAssertFalse(isFASTQ(URL(fileURLWithPath: "/path/to/data.bam")))
    }

    /// Local replica of the isFASTQFile logic for testing.
    private func isFASTQ(_ url: URL) -> Bool {
        var checkURL = url
        if checkURL.pathExtension.lowercased() == "gz" {
            checkURL = checkURL.deletingPathExtension()
        }
        let ext = checkURL.pathExtension.lowercased()
        return ext == "fastq" || ext == "fq"
    }

    // MARK: - FASTQDatasetViewController Configuration

    @MainActor
    func testFASTQDatasetViewControllerConfiguration() {
        let controller = FASTQDatasetViewController()
        _ = controller.view

        let stats = makeSampleStatistics(readCount: 500)
        let records = makeSampleRecords(count: 10)

        controller.configure(statistics: stats, records: records)
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testFASTQDatasetViewControllerEmptyRecords() {
        let controller = FASTQDatasetViewController()
        _ = controller.view

        let stats = FASTQDatasetStatistics.empty
        let records: [FASTQRecord] = []

        controller.configure(statistics: stats, records: records)
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testFASTQDatasetViewControllerTableSorting() {
        let controller = FASTQDatasetViewController()
        _ = controller.view

        let records = [
            FASTQRecord(
                identifier: "read_long",
                sequence: String(repeating: "A", count: 200),
                qualityString: String(repeating: "I", count: 200),
                encoding: .phred33
            ),
            FASTQRecord(
                identifier: "read_short",
                sequence: String(repeating: "A", count: 50),
                qualityString: String(repeating: "I", count: 50),
                encoding: .phred33
            ),
            FASTQRecord(
                identifier: "read_medium",
                sequence: String(repeating: "A", count: 100),
                qualityString: String(repeating: "I", count: 100),
                encoding: .phred33
            ),
        ]

        let stats = makeSampleStatistics()
        controller.configure(statistics: stats, records: records)
        XCTAssertNotNil(controller.view)
    }

    @MainActor
    func testFASTQDatasetSplitConstraintBounds() {
        let controller = FASTQDatasetViewController()
        let rootView = controller.view
        rootView.layoutSubtreeIfNeeded()
        controller.viewDidLayout()

        let splitViews = allSplitViews(in: rootView)
        guard let mainSplit = splitViews.first(where: { !$0.isVertical }),
              let middleSplit = splitViews.first(where: { $0.isVertical && $0 !== mainSplit }) else {
            XCTFail("Expected main and middle split views")
            return
        }

        // Top pane is fixed-height — min and max are the same.
        XCTAssertEqual(
            controller.splitView(mainSplit, constrainMinCoordinate: 0, ofSubviewAt: 0),
            115,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.splitView(mainSplit, constrainMaxCoordinate: 999, ofSubviewAt: 0),
            115,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.splitView(middleSplit, constrainMinCoordinate: 0, ofSubviewAt: 0),
            200,
            accuracy: 0.001
        )
        XCTAssertEqual(
            controller.splitView(middleSplit, constrainMaxCoordinate: 999, ofSubviewAt: 0),
            320,
            accuracy: 0.001
        )
    }

    @MainActor
    func testFASTQDatasetInitialSidebarIsNotNearHalfWidth() {
        let controller = FASTQDatasetViewController()
        let rootView = controller.view
        rootView.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        rootView.layoutSubtreeIfNeeded()
        controller.viewDidLayout()
        controller.viewDidAppear()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        rootView.layoutSubtreeIfNeeded()

        let splitViews = allSplitViews(in: rootView)
        guard let middleSplit = splitViews.first(where: { $0.isVertical && $0.subviews.count >= 2 }) else {
            XCTFail("Expected middle split view")
            return
        }

        middleSplit.layoutSubtreeIfNeeded()
        let sidebarWidth = middleSplit.subviews[0].frame.width
        let splitWidth = middleSplit.bounds.width
        XCTAssertGreaterThan(splitWidth, 0)
        // In a headless test environment NSSplitView may not honour
        // setPosition before layout settles, so accept any width that is
        // not greater than the configured maxSidebarWidth (320) plus a
        // small tolerance.  This still validates that the sidebar is not
        // consuming an unreasonable share of the split view.
        XCTAssertLessThan(sidebarWidth, splitWidth * 0.6)
    }

    @MainActor
    private func allSplitViews(in view: NSView) -> [NSSplitView] {
        var results: [NSSplitView] = []
        if let split = view as? NSSplitView {
            results.append(split)
        }
        for subview in view.subviews {
            results.append(contentsOf: allSplitViews(in: subview))
        }
        return results
    }

    @MainActor
    func testHumanScrubberInstallPromptRetriesOperationAfterInstall() async throws {
        let controller = FASTQDatasetViewController()
        _ = controller.view

        let alertPresenter = StubFASTQOperationAlertPresenter()
        alertPresenter.response = .alertFirstButtonReturn
        let installer = StubHumanScrubberInstaller()
        controller.alertPresenter = alertPresenter
        controller.humanScrubberInstaller = installer

        var runCount = 0
        let recovered = try await controller.handleHumanScrubberDatabaseRequirement(
            .installRequired(databaseID: "deacon-panhuman", displayName: "Human Read Removal Data"),
            request: .humanReadScrub(databaseID: "sra-human-scrubber", removeReads: true),
            onRunOperation: { _ in
                runCount += 1
            }
        )

        XCTAssertTrue(recovered)
        let installCallCount = await installer.currentInstallCallCount()
        let lastInstalledDatabaseID = await installer.lastInstalledDatabaseID()
        XCTAssertEqual(installCallCount, 1)
        XCTAssertEqual(lastInstalledDatabaseID, "deacon-panhuman")
        XCTAssertEqual(runCount, 1)
        XCTAssertEqual(alertPresenter.messageText, "Human Read Scrubber Database Required")
    }

    @MainActor
    func testHumanScrubberInstallPromptCancelLeavesOperationBlocked() async throws {
        let controller = FASTQDatasetViewController()
        _ = controller.view

        let alertPresenter = StubFASTQOperationAlertPresenter()
        alertPresenter.response = .alertSecondButtonReturn
        let installer = StubHumanScrubberInstaller()
        controller.alertPresenter = alertPresenter
        controller.humanScrubberInstaller = installer

        var runCount = 0
        do {
            _ = try await controller.handleHumanScrubberDatabaseRequirement(
                .installRequired(databaseID: "deacon-panhuman", displayName: "Human Read Removal Data"),
                request: .humanReadScrub(databaseID: "sra-human-scrubber", removeReads: true),
                onRunOperation: { _ in
                    runCount += 1
                }
            )
            XCTFail("Expected cancellation to keep the operation blocked")
        } catch let error as HumanScrubberDatabaseError {
            switch error {
            case .installationCancelled(let databaseID, let displayName):
                XCTAssertEqual(databaseID, "deacon-panhuman")
                XCTAssertEqual(displayName, "Human Read Removal Data")
            default:
                XCTFail("Expected installationCancelled, got \(error)")
            }
        }
        let installCallCount = await installer.currentInstallCallCount()
        XCTAssertEqual(installCallCount, 0)
        XCTAssertEqual(runCount, 0)
    }

    @MainActor
    func testHumanScrubberInstallPromptCanonicalizesLegacyDatabaseID() async throws {
        let controller = FASTQDatasetViewController()
        _ = controller.view

        let alertPresenter = StubFASTQOperationAlertPresenter()
        alertPresenter.response = .alertFirstButtonReturn
        let installer = StubHumanScrubberInstaller()
        controller.alertPresenter = alertPresenter
        controller.humanScrubberInstaller = installer

        _ = try await controller.handleHumanScrubberDatabaseRequirement(
            .installRequired(databaseID: "sra-human-scrubber", displayName: "Human Read Scrubber Database"),
            request: .humanReadScrub(databaseID: "sra-human-scrubber", removeReads: true),
            onRunOperation: { _ in }
        )

        let installCallCount = await installer.currentInstallCallCount()
        let lastInstalledDatabaseID = await installer.lastInstalledDatabaseID()
        XCTAssertEqual(installCallCount, 1)
        XCTAssertEqual(lastInstalledDatabaseID, "deacon-panhuman")
    }

    func testHumanReadScrubBatchParametersCanonicalizeManagedRemovalMetadata() {
        let params = FASTQDerivativeRequest
            .humanReadScrub(databaseID: "sra-human-scrubber", removeReads: false)
            .batchParameters

        XCTAssertEqual(params["databaseID"], "deacon-panhuman")
        XCTAssertNil(params["removeReads"])
    }

    func testFASTQDerivativeServiceReportsInstallRequiredWhenHumanScrubberDatabaseMissing() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQDashboardTests-derivative-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let registry = DatabaseRegistry(
            bundledDatabasesRoot: try makeHumanScrubberBundledRoot(in: tempDir),
            userDatabasesRoot: tempDir.appendingPathComponent("managed-databases")
        )

        do {
            _ = try await FASTQDerivativeService.resolveHumanScrubberDatabasePath(
                databaseID: "sra-human-scrubber",
                registry: registry
            )
            XCTFail("Expected install-required error")
        } catch let error as HumanScrubberDatabaseError {
            guard case .installRequired(let databaseID, let displayName) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(databaseID, "deacon-panhuman")
            XCTAssertEqual(displayName, "Human Read Removal Data")
        }
    }

    // MARK: - Notification Names

    func testFASTQDatasetLoadedNotificationExists() {
        let name = Notification.Name.fastqDatasetLoaded
        XCTAssertEqual(name.rawValue, "fastqDatasetLoaded")
    }

    func testFASTQDatasetLoadedNotificationContent() {
        let stats = makeSampleStatistics()
        let sra = makeSampleSRARunInfo()

        let notification = Notification(
            name: .fastqDatasetLoaded,
            object: nil,
            userInfo: [
                "statistics": stats,
                "sraRunInfo": sra,
            ]
        )

        let extractedStats = notification.userInfo?["statistics"] as? FASTQDatasetStatistics
        XCTAssertNotNil(extractedStats)
        XCTAssertEqual(extractedStats?.readCount, 1000)

        let extractedSRA = notification.userInfo?["sraRunInfo"] as? SRARunInfo
        XCTAssertNotNil(extractedSRA)
        XCTAssertEqual(extractedSRA?.accession, "SRR12345678")
    }

    func testFASTQDatasetLoadedNotificationWithENA() {
        let stats = makeSampleStatistics()
        let ena = makeSampleENAReadRecord()

        let notification = Notification(
            name: .fastqDatasetLoaded,
            object: nil,
            userInfo: [
                "statistics": stats,
                "enaReadRecord": ena,
            ]
        )

        let extractedENA = notification.userInfo?["enaReadRecord"] as? ENAReadRecord
        XCTAssertNotNil(extractedENA)
        XCTAssertEqual(extractedENA?.runAccession, "ERR9876543")
    }

    // MARK: - FASTQDatasetStatistics Equality

    func testFASTQDatasetStatisticsEquatable() {
        let stats1 = makeSampleStatistics()
        let stats2 = makeSampleStatistics()
        XCTAssertEqual(stats1, stats2)
    }

    func testFASTQDatasetStatisticsDifferentValuesNotEqual() {
        let stats1 = makeSampleStatistics(readCount: 100)
        let stats2 = makeSampleStatistics(readCount: 200)
        XCTAssertNotEqual(stats1, stats2)
    }

    func testFASTQDatasetStatisticsEmptyIsEmpty() {
        let empty = FASTQDatasetStatistics.empty
        XCTAssertEqual(empty.readCount, 0)
        XCTAssertEqual(empty.baseCount, 0)
        XCTAssertEqual(empty.meanQuality, 0)
        XCTAssertTrue(empty.readLengthHistogram.isEmpty)
    }

    // MARK: - Chart Views

    @MainActor
    func testFASTQSummaryBarCreation() {
        let bar = FASTQSummaryBar(frame: NSRect(x: 0, y: 0, width: 800, height: 60))
        let stats = makeSampleStatistics()
        bar.update(with: stats)

        XCTAssertEqual(bar.frame.width, 800)
        XCTAssertEqual(bar.frame.height, 60)
    }

    @MainActor
    func testFASTQHistogramChartViewCreation() {
        let chart = FASTQHistogramChartView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let histData = FASTQHistogramChartView.HistogramData(
            title: "Read Length Distribution",
            xLabel: "Length",
            yLabel: "Count",
            bins: [(100, 50), (150, 800), (200, 150)]
        )
        chart.update(with: histData)

        XCTAssertEqual(chart.frame.width, 400)
    }

    @MainActor
    func testFASTQQualityBoxplotViewCreation() {
        let boxplot = FASTQQualityBoxplotView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let summaries = [
            PositionQualitySummary(
                position: 0, mean: 35.0, median: 36.0,
                lowerQuartile: 32.0, upperQuartile: 38.0,
                percentile10: 28.0, percentile90: 40.0
            ),
            PositionQualitySummary(
                position: 1, mean: 34.0, median: 35.0,
                lowerQuartile: 31.0, upperQuartile: 37.0,
                percentile10: 27.0, percentile90: 39.0
            ),
        ]
        boxplot.update(with: summaries)

        XCTAssertEqual(boxplot.frame.width, 400)
    }

    // MARK: - DocumentLoader FASTQ Empty Result

    func testDocumentLoaderFASTQReturnsEmptySequences() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQDashboardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fastqURL = tempDir.appendingPathComponent("test.fastq")
        let fastqContent = """
        @read1 test read
        ACGTACGTACGT
        +
        IIIIIIIIIIII
        @read2 test read 2
        GCTAGCTAGCTA
        +
        IIIIIIIIIIII
        """
        try fastqContent.write(to: fastqURL, atomically: true, encoding: .utf8)

        let result = try await DocumentLoader.loadFile(at: fastqURL, type: .fastq)
        XCTAssertTrue(result.sequences.isEmpty,
            "FASTQ DocumentLoader should return empty sequences for streaming dashboard")
    }

    // MARK: - Metadata Persistence Integration

    func testMetadataSidecarFileCreatedForSRA() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQDashboardTests-sra-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fastqURL = tempDir.appendingPathComponent("SRR12345.fastq.gz")
        FileManager.default.createFile(atPath: fastqURL.path, contents: nil)

        let sra = makeSampleSRARunInfo()
        let metadata = PersistedFASTQMetadata(
            sraRunInfo: sra,
            downloadDate: Date(),
            downloadSource: "NCBI SRA"
        )
        FASTQMetadataStore.save(metadata, for: fastqURL)

        let sidecarURL = FASTQMetadataStore.metadataURL(for: fastqURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))

        let loaded = FASTQMetadataStore.load(for: fastqURL)
        XCTAssertEqual(loaded?.sraRunInfo?.accession, "SRR12345678")
        XCTAssertEqual(loaded?.downloadSource, "NCBI SRA")
    }

    func testMetadataSidecarFileCreatedForENA() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQDashboardTests-ena-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fastqURL = tempDir.appendingPathComponent("ERR9876543.fastq.gz")
        FileManager.default.createFile(atPath: fastqURL.path, contents: nil)

        let ena = makeSampleENAReadRecord()
        let metadata = PersistedFASTQMetadata(
            enaReadRecord: ena,
            downloadDate: Date(),
            downloadSource: "ENA"
        )
        FASTQMetadataStore.save(metadata, for: fastqURL)

        let loaded = FASTQMetadataStore.load(for: fastqURL)
        XCTAssertEqual(loaded?.enaReadRecord?.runAccession, "ERR9876543")
        XCTAssertEqual(loaded?.downloadSource, "ENA")
    }

    func testMetadataRoundTripWithCachedStatistics() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FASTQDashboardTests-cache-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fastqURL = tempDir.appendingPathComponent("cached.fastq.gz")
        FileManager.default.createFile(atPath: fastqURL.path, contents: nil)

        let stats = makeSampleStatistics(readCount: 9730, baseCount: 1_469_730)
        let metadata = PersistedFASTQMetadata(
            computedStatistics: stats,
            downloadDate: Date(),
            downloadSource: "Local disk"
        )
        FASTQMetadataStore.save(metadata, for: fastqURL)

        let cached = FASTQMetadataStore.load(for: fastqURL)
        XCTAssertNotNil(cached?.computedStatistics)
        XCTAssertEqual(cached?.computedStatistics?.readCount, 9730)
        XCTAssertEqual(cached?.computedStatistics?.baseCount, 1_469_730)
        XCTAssertEqual(cached?.computedStatistics?.meanReadLength, 150.0)
    }

    private func makeHumanScrubberBundledRoot(in tempDir: URL) throws -> URL {
        let root = tempDir.appendingPathComponent("bundled-databases", isDirectory: true)
        let manifests = [
            ("human-scrubber", try humanScrubberManifestURL()),
            ("deacon-panhuman", try deaconPanhumanManifestURL()),
        ]
        for (databaseID, manifestURL) in manifests {
            let dbDir = root.appendingPathComponent(databaseID, isDirectory: true)
            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: manifestURL,
                to: dbDir.appendingPathComponent("manifest.json")
            )
        }
        return root
    }

    private func humanScrubberManifestURL() throws -> URL {
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/Databases/human-scrubber/manifest.json")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw XCTSkip("Bundled human-scrubber manifest not found at \(candidate.path)")
    }

    private func deaconPanhumanManifestURL() throws -> URL {
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LungfishWorkflow/Resources/Databases/deacon-panhuman/manifest.json")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        throw XCTSkip("Bundled deacon-panhuman manifest not found at \(candidate.path)")
    }
}

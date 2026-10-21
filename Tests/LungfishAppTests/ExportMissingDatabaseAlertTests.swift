// ExportMissingDatabaseAlertTests.swift - an export whose result database is gone ends in one alert in the app's words
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.40 M3 (UX ruling W4, MD26 Reading A, MD61). Each of the five exports checks that the result's
// database file is still in the result folder before it opens the save panel. When it is gone the viewer shows one
// alert titled `The <tool> result could not be exported` with W4's text, begins no Operations row, runs no leaf and
// writes no file. NAO-MGS, NVD and EsViritu are driven through their real export actions. TaxTriage and Kraken2 keep
// their export actions private behind menus that need a full result, so their checks are tested on a real controller.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishEsVirituUI
import LungfishCore
import LungfishIO
import LungfishKit
@testable import LungfishNaoMgsUI
@testable import LungfishNvdUI
@testable import LungfishTaxTriageUI
import LungfishTestSupport

private final class WarningRecorder {
    var alerts: [(title: String, message: String)] = []
}

@MainActor
final class ExportMissingDatabaseAlertTests: XCTestCase {
    private let w4Text = "Its database is missing from the result folder. Import the result again, then export."
    private var folders: [URL] = []
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
    }

    override func tearDown() async throws {
        for window in windows {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        windows = []
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        try await super.tearDown()
    }

    private func makeFolder(_ name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        return folder
    }

    private func host(_ vc: NSViewController) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 520),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        windows.append(window)
        _ = vc.view
        return window
    }

    private func assertOneAlert(
        _ alerts: [(title: String, message: String)], tool: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(alerts.count, 1, "one alert", file: file, line: line)
        XCTAssertEqual(alerts.first?.title, "The \(tool) result could not be exported", file: file, line: line)
        XCTAssertEqual(alerts.first?.message, w4Text, file: file, line: line)
    }

    private func assertNothingStarted(
        _ window: NSWindow?, rowsBefore: Int, folder: URL, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertNil(window?.attachedSheet, "no save panel opened", file: file, line: line)
        XCTAssertEqual(
            OperationCenter.shared.items.count, rowsBefore, "no Operations row began and no leaf ran",
            file: file, line: line
        )
        XCTAssertEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? ["unreadable"], [],
            "the export wrote no file", file: file, line: line
        )
    }

    private static func naoMgsManifest() -> NaoMgsManifest {
        NaoMgsManifest(
            sampleName: "sample-1", sourceFilePath: "/tmp/naomgs.tsv", hitCount: 10, taxonCount: 1,
            topTaxon: "Example virus", topTaxonId: 1234
        )
    }

    private static func naoMgsRow() -> NaoMgsTaxonSummaryRow {
        NaoMgsTaxonSummaryRow(
            sample: "sample-1", taxId: 1234, name: "Example virus", hitCount: 10, uniqueReadCount: 8,
            avgIdentity: 99.5, avgBitScore: 200, avgEditDistance: 1, pcrDuplicateCount: 2, accessionCount: 1,
            topAccessions: ["NC_000001.1"], bamPath: nil, bamIndexPath: nil
        )
    }

    private static func nvdManifest(samples: [NvdSampleSummary] = []) -> NvdManifest {
        NvdManifest(
            experiment: "exp-1", sampleCount: samples.count, contigCount: 0, hitCount: 0, blastDbVersion: "db",
            snakemakeRunId: "run-1", sourceDirectoryPath: "/tmp", samples: samples, cachedTopContigs: nil
        )
    }

    func testNaoMgsExportStopsWithOneAlertWhenTheDatabaseIsGone() throws {
        let folder = try makeFolder("naomgs-gone")
        let vc = NaoMgsResultViewController()
        let window = host(vc)
        let presenter = RecordingExportFailurePresenter()
        vc.exportFailurePresenter = presenter
        vc.configureWithCachedRows([Self.naoMgsRow()], manifest: Self.naoMgsManifest(), bundleURL: folder)
        let rowsBefore = OperationCenter.shared.items.count

        vc.exportResults()

        assertOneAlert(presenter.alerts, tool: "NAO-MGS")
        assertNothingStarted(window, rowsBefore: rowsBefore, folder: folder)
    }

    func testNvdExportStopsWithOneAlertWhenTheDatabaseIsGone() throws {
        NvdResultViewController.testMetadataUserDefaultsOverride = makeTestDefaultsSuite(prefix: "ExportMissingDatabaseAlertTests").defaults
        addTeardownBlock { NvdResultViewController.testMetadataUserDefaultsOverride = nil }
        let folder = try makeFolder("nvd-gone")
        let databaseFolder = try makeFolder("nvd-database")
        let database = try NvdDatabase.create(
            at: databaseFolder.appendingPathComponent("nvd.sqlite"),
            hits: [],
            samples: [NvdSampleMetadata(
                sampleId: "sample1", bamPath: "sample1.bam", fastaPath: "sample1.fasta",
                totalReads: 1000, contigCount: 0, hitCount: 0
            )]
        )
        let manifest = Self.nvdManifest(samples: [NvdSampleSummary(
            sampleId: "sample1", contigCount: 0, hitCount: 0, totalReads: 1000,
            bamRelativePath: "sample1.bam", bamIndexRelativePath: "sample1.bam.bai",
            fastaRelativePath: "sample1.fasta"
        )])
        let vc = NvdResultViewController()
        let window = host(vc)
        let presenter = RecordingExportFailurePresenter()
        vc.exportFailurePresenter = presenter
        vc.configure(database: database, manifest: manifest, bundleURL: folder)
        XCTAssertEqual(vc.selectedSamples, ["sample1"], "a sample is picked, so only the database is missing")
        let rowsBefore = OperationCenter.shared.items.count

        vc.exportResults()

        assertOneAlert(presenter.alerts, tool: "NVD")
        assertNothingStarted(window, rowsBefore: rowsBefore, folder: folder)
    }

    func testEsVirituExportStopsWithOneAlertWhenTheDatabaseIsGone() throws {
        let folder = try makeFolder("esviritu-gone")
        let vc = EsVirituResultViewController()
        let window = host(vc)
        let presenter = RecordingExportFailurePresenter()
        vc.exportFailurePresenter = presenter
        vc.batchURL = folder
        vc.isBatchMode = true
        vc.samplePickerState = ClassifierSamplePickerState(allSamples: Set(["sample-A"]))
        vc.samplePickerState.selectedSamples = ["sample-A"]
        vc.applyBatchSampleFilter()
        XCTAssertNotNil(vc.esVirituResult, "a sample is picked, so only the database is missing")
        let item = try XCTUnwrap(vc.buildExportMenu().items.first { $0.action == NSSelectorFromString("exportCSVAction:") })
        let rowsBefore = OperationCenter.shared.items.count

        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))

        assertOneAlert(presenter.alerts, tool: "EsViritu")
        assertNothingStarted(window, rowsBefore: rowsBefore, folder: folder)
    }

    func testTaxTriageCheckShowsOneAlertWhenTheDatabaseIsGone() throws {
        let folder = try makeFolder("taxtriage-gone")
        let vc = TaxTriageResultViewController()
        let presenter = RecordingExportFailurePresenter()
        vc.exportFailurePresenter = presenter
        vc.batchGroupURL = folder

        XCTAssertFalse(vc.exportDatabaseIsPresent(in: nil))

        assertOneAlert(presenter.alerts, tool: "TaxTriage")
        assertNothingStarted(nil, rowsBefore: OperationCenter.shared.items.count, folder: folder)
    }

    private static func taxTriageRow() -> TaxTriageTaxonomyRow {
        TaxTriageTaxonomyRow(
            sample: "sample-1", organism: "Alpha virus", taxId: 1001, status: nil, tassScore: 0.9,
            readsAligned: 10, uniqueReads: 5, pctReads: nil, pctAlignedReads: nil,
            coverageBreadth: 50, meanCoverage: nil, meanDepth: nil, confidence: "High",
            k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil, meanBaseQ: nil, meanMapQ: nil,
            mapqScore: nil, disparityScore: nil, minhashScore: nil, diamondIdentity: nil,
            k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil, hhsPercentile: nil,
            isAnnotated: nil, annClass: nil, microbialCategory: nil, highConsequence: nil,
            isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil, bamPath: nil,
            bamIndexPath: nil, primaryAccession: "NC_1001", accessionLength: 1000
        )
    }

    /// A TaxTriage viewer in a window with its one sample picked. It opened from a database that sits in another
    /// folder, so the result folder it exports from holds no database, the shape the NVD test above uses.
    private func makeTaxTriageViewWithoutItsDatabase(
        _ name: String
    ) throws -> (vc: TaxTriageResultViewController, window: NSWindow, presenter: RecordingExportFailurePresenter, folder: URL) {
        let folder = try makeFolder(name)
        let databaseURL = try makeFolder("\(name)-database").appendingPathComponent("taxtriage.sqlite")
        _ = try TaxTriageDatabase.create(at: databaseURL, rows: [Self.taxTriageRow()], metadata: ["tool": "taxtriage"])
        let vc = TaxTriageResultViewController()
        let window = host(vc)
        let presenter = RecordingExportFailurePresenter()
        vc.exportFailurePresenter = presenter
        vc.configureFromDatabase(try TaxTriageDatabase(at: databaseURL), resultURL: folder)
        XCTAssertEqual(vc.sampleIds, ["sample-1"], "a sample is picked, so only the database is missing")
        return (vc, window, presenter, folder)
    }

    func testTaxTriageOrganismMatrixExportStopsWithOneAlertWhenTheDatabaseIsGone() throws {
        let (vc, window, presenter, folder) = try makeTaxTriageViewWithoutItsDatabase("taxtriage-matrix-gone")
        let rowsBefore = OperationCenter.shared.items.count

        _ = vc.perform(NSSelectorFromString("exportBatchMatrixAction:"), with: vc)

        assertOneAlert(presenter.alerts, tool: "TaxTriage")
        assertNothingStarted(window, rowsBefore: rowsBefore, folder: folder)
    }

    func testKraken2CheckShowsOneAlertWhenTheSourceFileIsGone() throws {
        let folder = try makeFolder("kraken2-gone")
        let vc = TaxonomyViewController()
        let recorder = WarningRecorder()
        vc.warningPresenter = { title, message in recorder.alerts.append((title, message)) }

        XCTAssertFalse(vc.exportDatabaseIsPresent(folder.appendingPathComponent("kraken2.sqlite"), in: nil))

        assertOneAlert(recorder.alerts, tool: "Kraken2")
        assertNothingStarted(nil, rowsBefore: OperationCenter.shared.items.count, folder: folder)
    }

    func testTheChecksPassWithoutAnAlertWhenTheDatabaseIsThere() throws {
        NvdResultViewController.testMetadataUserDefaultsOverride = makeTestDefaultsSuite(prefix: "ExportMissingDatabaseAlertTests").defaults
        addTeardownBlock { NvdResultViewController.testMetadataUserDefaultsOverride = nil }
        let presenter = RecordingExportFailurePresenter()
        let recorder = WarningRecorder()

        let naoMgsFolder = try makeFolder("naomgs-here")
        try Data().write(to: naoMgsFolder.appendingPathComponent("hits.sqlite"))
        let naoMgs = NaoMgsResultViewController()
        naoMgs.exportFailurePresenter = presenter
        naoMgs.configureWithCachedRows([], manifest: Self.naoMgsManifest(), bundleURL: naoMgsFolder)
        XCTAssertTrue(naoMgs.exportDatabaseIsPresent(in: nil), "NAO-MGS")

        let nvdFolder = try makeFolder("nvd-here")
        try Data().write(to: nvdFolder.appendingPathComponent("hits.sqlite"))
        let nvd = NvdResultViewController()
        _ = nvd.view
        nvd.exportFailurePresenter = presenter
        nvd.configureWithCachedRows([], manifest: Self.nvdManifest(), bundleURL: nvdFolder)
        XCTAssertTrue(nvd.exportDatabaseIsPresent(in: nil), "NVD")

        let esFolder = try makeFolder("esviritu-here")
        try Data().write(to: esFolder.appendingPathComponent("esviritu.sqlite"))
        let es = EsVirituResultViewController()
        es.exportFailurePresenter = presenter
        es.batchURL = esFolder
        XCTAssertTrue(es.exportDatabaseIsPresent(in: nil), "EsViritu")

        let taxTriageFolder = try makeFolder("taxtriage-here")
        try Data().write(to: taxTriageFolder.appendingPathComponent("taxtriage.sqlite"))
        let taxTriage = TaxTriageResultViewController()
        taxTriage.exportFailurePresenter = presenter
        taxTriage.batchGroupURL = taxTriageFolder
        XCTAssertTrue(taxTriage.exportDatabaseIsPresent(in: nil), "TaxTriage")

        let krakenFolder = try makeFolder("kraken2-here")
        let krakenFile = krakenFolder.appendingPathComponent("kraken2.sqlite")
        try Data().write(to: krakenFile)
        let taxonomy = TaxonomyViewController()
        taxonomy.warningPresenter = { title, message in recorder.alerts.append((title, message)) }
        XCTAssertTrue(taxonomy.exportDatabaseIsPresent(krakenFile, in: nil), "Kraken2")

        XCTAssertTrue(presenter.alerts.isEmpty, "no alert from the four viewers")
        XCTAssertTrue(recorder.alerts.isEmpty, "no alert from Kraken2")
    }
}

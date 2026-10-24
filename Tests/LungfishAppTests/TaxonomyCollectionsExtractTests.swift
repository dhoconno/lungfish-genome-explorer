// TaxonomyCollectionsExtractTests.swift - Extract in the Collections drawer of a sidebar-opened Kraken2 result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.14 lane ROW69 (walk row 69, a Stable blocker, vote V9). The sidebar opens a Kraken2 batch through
// `displayTaxonomyFromDatabase`, which never wired the drawer's Extract, so the button returned with one log
// line, no Operations row and no alert. These tests open a database-backed batch of two samples the way the
// sidebar route does, show one sample, press Extract on the drawer's own hook and read what happens. They
// drive the route and read no source text (QA 2). The read ID half runs the real command, so it sits in
// `TaxonomyCollectionsExtractReadIDConformanceTests`, which skips without seqkit unless
// `LUNGFISH_REQUIRE_TOOLS=1`.

import os
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

/// A project that holds one Kraken2 batch of two samples as the sidebar opens it. The batch folder holds
/// `kraken2.sqlite`, the batch manifest and one result folder a sample, each over loose read files with its
/// own read names, so the reads of the sample shown tell it from the other.
struct TwoSampleKraken2Batch {
    static let sampleA = "sample-A"
    static let sampleB = "sample-B"
    /// Reads `a1` and `a2` belong to Species A1, `a3` to Species A2, `b1` and `b2` to Species B and `u1` is unclassified.
    static let readsA = ["a1", "a2", "a3", "b1", "b2", "u1"]
    static let readsB = ["x1", "x2", "x3", "y1", "y2", "w1"]

    let projectURL: URL
    let batchURL: URL
    let sampleADirectory: URL
    let sampleBDirectory: URL

    var databaseURL: URL { batchURL.appendingPathComponent("kraken2.sqlite") }

    init(in root: URL) throws {
        projectURL = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        batchURL = projectURL.appendingPathComponent("Analyses/kraken2-batch", isDirectory: true)
        try FileManager.default.createDirectory(at: batchURL, withIntermediateDirectories: true)
        let single = TaxaCollectionFixtures.single
        let a = TaxaCollectionFixtures.speciesA1, a2 = TaxaCollectionFixtures.speciesA2, b = TaxaCollectionFixtures.speciesB
        sampleADirectory = try Self.writeSample(
            Self.sampleA, reads: Self.readsA, in: batchURL, project: projectURL,
            lines: [single("a1", a), single("a2", a), single("a3", a2), single("b1", b), single("b2", b), "U\tu1\t0\t10\t0:3"]
        )
        sampleBDirectory = try Self.writeSample(
            Self.sampleB, reads: Self.readsB, in: batchURL, project: projectURL,
            lines: [single("x1", a), single("x2", a), single("x3", a2), single("y1", b), single("y2", b), "U\tw1\t0\t10\t0:3"]
        )
        try Kraken2Database.create(
            at: databaseURL,
            rows: [Self.sampleA, Self.sampleB].flatMap(Self.rows(for:)),
            metadata: [
                "total_reads_sample-A": "6", "total_reads_sample-B": "6",
                "unclassified_reads_sample-A": "1", "unclassified_reads_sample-B": "1",
            ]
        )
        let records = [Self.sampleA, Self.sampleB].map {
            MetagenomicsBatchSampleRecord(sampleId: $0, resultDirectory: $0, inputFiles: ["\($0)_reads.fastq"], isPairedEnd: false)
        }
        try MetagenomicsBatchResultStore.saveClassification(
            ClassificationBatchResultManifest(
                header: MetagenomicsBatchManifestHeader(schemaVersion: 2, createdAt: Date(timeIntervalSince1970: 0), sampleCount: 2),
                goal: "classify", databaseName: "Viral", databaseVersion: "test", summaryTSV: "summary.tsv", samples: records
            ),
            to: batchURL
        )
    }

    func directory(of sample: String) -> URL {
        sample == Self.sampleA ? sampleADirectory : sampleBDirectory
    }

    /// A sample's result folder as a classification run leaves it, naming its reads relative to itself.
    private static func writeSample(
        _ name: String, reads: [String], in batchURL: URL, project: URL, lines: [String]
    ) throws -> URL {
        let directory = batchURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let readFile = project.appendingPathComponent("\(name)_reads.fastq")
        try ReadSetFixtures.fastq(reads).write(to: readFile, atomically: true, encoding: .utf8)
        let relative = URL(string: "../../../\(readFile.lastPathComponent)")!
        var config = ClassificationConfig(
            inputFiles: [relative], isPairedEnd: false, databaseName: "Viral",
            databasePath: URL(string: ".")!, outputDirectory: URL(string: ".")!
        )
        config.originalInputFiles = [relative]
        let kreportURL = directory.appendingPathComponent("classification.kreport")
        try TaxaCollectionFixtures.kreport.write(to: kreportURL, atomically: true, encoding: .utf8)
        let krakenURL = directory.appendingPathComponent("classification.kraken")
        try (lines.joined(separator: "\n") + "\n").write(to: krakenURL, atomically: true, encoding: .utf8)
        try ClassificationResult(
            config: config, tree: try KreportParser.parse(url: kreportURL), reportURL: kreportURL, outputURL: krakenURL,
            brackenURL: nil, runtime: 1, toolVersion: "2.17.1", provenanceId: nil
        ).save(to: directory)
        return directory
    }

    /// The database rows of one sample. Genus 10 holds species 11 and 12 and species 20 stands alone.
    private static func rows(for sample: String) -> [Kraken2ClassificationRow] {
        func row(_ name: String, _ taxId: Int, direct: Int, clade: Int, parent: Int?, depth: Int) -> Kraken2ClassificationRow {
            Kraken2ClassificationRow(
                sample: sample, taxonName: name, taxId: taxId, rank: depth == 0 ? "R" : (taxId == 10 ? "G" : "S"),
                rankDisplayName: depth == 0 ? "Root" : (taxId == 10 ? "Genus" : "Species"),
                readsDirect: direct, readsClade: clade, percentage: Double(clade) * 100 / 6,
                parentTaxId: parent, depth: depth
            )
        }
        return [
            row("root", 1, direct: 0, clade: 5, parent: nil, depth: 0),
            row("Genus A", 10, direct: 0, clade: 3, parent: 1, depth: 1),
            row("Species A1", 11, direct: 2, clade: 2, parent: 10, depth: 2),
            row("Species A2", 12, direct: 1, clade: 1, parent: 10, depth: 2),
            row("Species B", 20, direct: 2, clade: 2, parent: 1, depth: 1),
        ]
    }
}

/// Opens a batch the way the sidebar route does, presses Extract on the drawer and watches the Operations panel.
@MainActor
final class DrawerExtractHarness {
    /// The viewer owns the display, and the extraction callback holds it weakly, so the test keeps it.
    private var viewer: ViewerViewController?
    /// The suite that takes the drawer's height and open state, so no test writes the standard defaults.
    private var defaultsSuite: TestDefaultsSuite?
    /// The `LUNGFISH_CLI_PATH` the process held when `isolate(for:)` ran, or nil when it held none. The
    /// conformance gate sets it to the built `lungfish-cli`, and a class that runs after this one in the
    /// same process reads it.
    private(set) var priorCLIPath: String?

    /// Isolates the drawer from the machine until `testCase` ends. Its defaults go to a test suite, so no
    /// test writes the standard defaults. Its launch goes to a command that fails at once, so a test that
    /// reads only the row's beginning starts no real extraction and does not search for the built
    /// `lungfish-cli`. A test that wants the real command sets `LUNGFISH_CLI_PATH` after this. When
    /// `testCase` ends the variable goes back to the value it held before, or to unset when it held none.
    func isolate(for testCase: XCTestCase) {
        let suite = TestDefaultsSuite(prefix: "TaxonomyCollectionsExtractTests")
        defaultsSuite = suite
        TaxaCollectionsDrawerSeams.defaults = suite.defaults
        let priorCLIPath = getenv("LUNGFISH_CLI_PATH").map { String(cString: $0) }
        self.priorCLIPath = priorCLIPath
        setenv("LUNGFISH_CLI_PATH", "/usr/bin/false", 1)
        testCase.addTeardownBlock { @MainActor in
            TaxaCollectionsDrawerSeams.defaults = .standard
            if let priorCLIPath { setenv("LUNGFISH_CLI_PATH", priorCLIPath, 1) } else { unsetenv("LUNGFISH_CLI_PATH") }
        }
    }

    /// Opens `batch` through `displayTaxonomyFromDatabase`, the call the Kraken2 sidebar route makes, and picks
    /// `samples` in the sample picker when given. The default picks every sample, which the table shows merged.
    func openFromSidebar(_ batch: TwoSampleKraken2Batch, showing samples: Set<String>? = nil) throws -> TaxonomyViewController {
        let database = try Kraken2Database(at: batch.databaseURL)
        let viewer = ViewerViewController()
        _ = viewer.view
        viewer.displayTaxonomyFromDatabase(db: database, resultURL: batch.batchURL)
        self.viewer = viewer
        let taxonomy = try XCTUnwrap(viewer.taxonomyViewController)
        if let samples {
            taxonomy.samplePickerState.selectedSamples = samples
            taxonomy.testApplyBatchSampleFilter()
        }
        return taxonomy
    }

    /// Presses Extract of `collection` on the drawer, which opens it first. The drawer's hook is what its Extract button calls.
    func pressExtract(_ collection: TaxaCollection, on taxonomy: TaxonomyViewController) throws {
        taxonomy.toggleTaxaCollectionsDrawer()
        let drawer = try XCTUnwrap(taxonomy.testCollectionsDrawer)
        drawer.onBatchExtract?(collection)
    }

    /// The ID of the first row titled `title` that is not in `before`, as soon as it begins, or nil after `timeout`.
    static func waitForNewRow(titled title: String, excluding before: Set<UUID>, timeout: Duration = .seconds(30)) async -> UUID? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let row = OperationCenter.shared.items.first(where: { !before.contains($0.id) && $0.title == title }) {
                return row.id
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    /// Returns once the row `id` is no longer running, or after `timeout`.
    static func waitUntilEnded(_ id: UUID, timeout: Duration = .seconds(30)) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard let row = OperationCenter.shared.items.first(where: { $0.id == id }), row.state.isActive else { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
final class TaxonomyCollectionsExtractTests: XCTestCase {
    private var root: URL!
    private let harness = DrawerExtractHarness()

    override func setUp() async throws {
        harness.isolate(for: self)
        root = try TestTempDirectory.make(prefix: "taxonomy-collections-extract")
    }

    override func tearDown() async throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    /// The red test of row 69. A two-sample batch opened through the sidebar route shows sample A alone. Extract
    /// on a collection begins an Operations row whose command is `lungfish-cli extract taxa-collection` over
    /// sample A's own result folder and writes into that folder. At the base the drawer returned at once.
    func testExtractFromSidebarOpenedResultStartsExtraction() async throws {
        let batch = try TwoSampleKraken2Batch(in: root)
        let taxonomy = try harness.openFromSidebar(batch, showing: [TwoSampleKraken2Batch.sampleA])
        let collection = TaxaCollectionFixtures.collection
        let before = Set(OperationCenter.shared.items.map(\.id))

        try harness.pressExtract(collection, on: taxonomy)

        let began = await DrawerExtractHarness.waitForNewRow(titled: "Extract \(collection.name)", excluding: before)
        let id = try XCTUnwrap(began, "Extract began no Operations row")
        let command = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == id }?.cliCommand)
        XCTAssertTrue(command.hasPrefix("lungfish-cli extract taxa-collection --result "), command)
        let parsed = try RecordedCLICommand.parse(command, as: ExtractTaxaCollectionSubcommand.self)
        let shown = batch.sampleADirectory.resolvingSymlinksInPath().path
        XCTAssertEqual(URL(fileURLWithPath: parsed.result).resolvingSymlinksInPath().path, shown, "the command names the sample shown")
        XCTAssertEqual(
            URL(fileURLWithPath: parsed.outputDirectory).resolvingSymlinksInPath().path,
            batch.sampleADirectory.appendingPathComponent("extracted-\(collection.id)").resolvingSymlinksInPath().path,
            "the output sits in the shown sample's folder"
        )
        XCTAssertFalse(command.contains(TwoSampleKraken2Batch.sampleB), "the other sample is not in the command: \(command)")
        await DrawerExtractHarness.waitUntilEnded(id)
    }

    // MARK: - The load and the refusals

    /// The sample's result loads off the main thread, and no row has begun while it loads (SWIFT 2). The
    /// injected loader holds the load open, so the test reads the Operations panel in the middle of it.
    func testExtractLoadsTheSampleResultOffTheMainThread() async throws {
        let batch = try TwoSampleKraken2Batch(in: root)
        let taxonomy = try harness.openFromSidebar(batch, showing: [TwoSampleKraken2Batch.sampleA])
        let collection = TaxaCollectionFixtures.collection
        let probe = LoaderProbe()
        let live = TaxaCollectionsDrawerSeams.loadSampleResult
        TaxaCollectionsDrawerSeams.loadSampleResult = { url in
            probe.entered(url, onMainThread: Thread.isMainThread)
            probe.waitForRelease()
            return try live(url)
        }
        addTeardownBlock { @MainActor in TaxaCollectionsDrawerSeams.loadSampleResult = live }
        let before = Set(OperationCenter.shared.items.map(\.id))
        let title = "Extract \(collection.name)"

        try harness.pressExtract(collection, on: taxonomy)

        let loading = await probe.waitUntilEntered()
        XCTAssertTrue(loading, "Extract never loaded the sample's result")
        XCTAssertEqual(probe.threads, [false], "ClassificationResult.load ran on the main thread")
        XCTAssertEqual(
            probe.urls.map { $0.resolvingSymlinksInPath().path },
            [batch.sampleADirectory.resolvingSymlinksInPath().path],
            "one load, of the sample shown"
        )
        XCTAssertNil(
            OperationCenter.shared.items.first { !before.contains($0.id) && $0.title == title },
            "a row began before the result loaded"
        )
        probe.release()
        let began = await DrawerExtractHarness.waitForNewRow(titled: title, excluding: before)
        let id = try XCTUnwrap(began, "Extract began no Operations row once the result loaded")
        await DrawerExtractHarness.waitUntilEnded(id)
    }

    /// A sample whose result folder is gone gets the alert and no row, where the base returned with a log line.
    func testExtractWithoutTheSampleResultAlertsWithTheWords() async throws {
        let batch = try TwoSampleKraken2Batch(in: root)
        let taxonomy = try harness.openFromSidebar(batch, showing: [TwoSampleKraken2Batch.sampleA])
        try FileManager.default.removeItem(at: batch.sampleADirectory)
        let shown = recordRefusals()
        let before = Set(OperationCenter.shared.items.map(\.id))

        try harness.pressExtract(TaxaCollectionFixtures.collection, on: taxonomy)

        XCTAssertEqual(shown.all, [
            "Could not extract reads | Lungfish could not find the classification result for the sample shown. "
                + "Open the result again from the sidebar, then choose Extract.",
        ])
        XCTAssertFalse(OperationCenter.shared.items.contains { !before.contains($0.id) }, "a refusal begins no row")
    }

    /// The default display of a batch picks every sample and shows them merged, so no one sample is shown.
    func testExtractWithSeveralSamplesShownAsksToChooseOne() async throws {
        let batch = try TwoSampleKraken2Batch(in: root)
        let taxonomy = try harness.openFromSidebar(batch)
        XCTAssertEqual(taxonomy.samplePickerState.selectedSamples.count, 2, "the sidebar route picks every sample")
        let shown = recordRefusals()
        let before = Set(OperationCenter.shared.items.map(\.id))

        try harness.pressExtract(TaxaCollectionFixtures.collection, on: taxonomy)

        XCTAssertEqual(shown.all, ["Could not extract reads | Choose one sample, then choose Extract."])
        XCTAssertFalse(OperationCenter.shared.items.contains { !before.contains($0.id) }, "a refusal begins no row")
    }

    /// Records what the drawer's alert would show, in place of a sheet no test could answer.
    private func recordRefusals() -> EventLog {
        let log = EventLog()
        let live = TaxaCollectionsDrawerSeams.presentRefusal
        TaxaCollectionsDrawerSeams.presentRefusal = { title, text, _ in log.append("\(title) | \(text)") }
        addTeardownBlock { @MainActor in TaxaCollectionsDrawerSeams.presentRefusal = live }
        return log
    }

    final class EventLog: Sendable {
        private let lines = OSAllocatedUnfairLock(initialState: [String]())
        func append(_ line: String) { lines.withLock { $0.append(line) } }
        var all: [String] { lines.withLock { $0 } }
    }

    /// A loader that records its thread and holds the load until the test releases it.
    final class LoaderProbe: Sendable {
        struct State: Sendable {
            var urls: [URL] = []
            var threads: [Bool] = []
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let gate = DispatchSemaphore(value: 0)

        func entered(_ url: URL, onMainThread: Bool) {
            state.withLock {
                $0.urls.append(url)
                $0.threads.append(onMainThread)
            }
        }

        func waitForRelease() { _ = gate.wait(timeout: .now() + 30) }
        func release() { gate.signal() }
        var urls: [URL] { state.withLock { $0.urls } }
        var threads: [Bool] { state.withLock { $0.threads } }

        func waitUntilEntered() async -> Bool {
            let deadline = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < deadline {
                if !urls.isEmpty { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
    }
}

/// The read IDs of the drawer's Extract against the command's own run. It launches the built `lungfish-cli`
/// and the managed seqkit, so its name holds Conformance and it skips without them unless `LUNGFISH_REQUIRE_TOOLS=1`.
@MainActor
final class TaxonomyCollectionsExtractReadIDConformanceTests: XCTestCase {
    private var root: URL!
    private let harness = DrawerExtractHarness()

    override func setUp() async throws {
        harness.isolate(for: self)
        root = try TestTempDirectory.make(prefix: "taxonomy-collections-readids")
    }

    override func tearDown() async throws {
        if let root { TestTempDirectory.cleanup(root) }
    }

    /// Sample B is shown, so a route that took the first sample would write sample A's reads. The drawer's output
    /// holds the read IDs `extract taxa-collection` gives for sample B and the collection, and none of sample A's.
    func testExtractedReadIDsAreTheCommandsForTheShownSampleOnly() async throws {
        try await requireSeqkit()
        // The harness points the launch at a command that fails at once, and the resolver reads that variable first.
        // The resolver reads the environment as it was before the harness, so it finds the CLI the gate named.
        var environment = ProcessInfo.processInfo.environment
        environment["LUNGFISH_CLI_PATH"] = harness.priorCLIPath
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products, environment: environment),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH"
        )
        // The drawer launches the bundled CLI, which a test points at the built one. The harness puts the
        // variable back to its earlier value when the test ends, so the next class in the process finds it.
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        let batch = try TwoSampleKraken2Batch(in: root)
        let taxonomy = try harness.openFromSidebar(batch, showing: [TwoSampleKraken2Batch.sampleB])
        let collection = TaxaCollectionFixtures.collection
        let before = Set(OperationCenter.shared.items.map(\.id))

        try harness.pressExtract(collection, on: taxonomy)

        let began = await DrawerExtractHarness.waitForNewRow(titled: "Extract \(collection.name)", excluding: before)
        let id = try XCTUnwrap(began, "Extract began no Operations row")
        await DrawerExtractHarness.waitUntilEnded(id, timeout: .seconds(120))
        let row = try XCTUnwrap(OperationCenter.shared.items.first { $0.id == id })
        XCTAssertEqual(row.state, .completed, "detail: \(row.detail)")
        XCTAssertEqual(row.detail, "Extracted 2 taxa from \(collection.name)")

        // The command's own run for sample B and the collection, into a folder outside the project.
        let commandFolder = root.appendingPathComponent("command-output", isDirectory: true)
        let arguments = ViewerViewController.taxaCollectionExtractionArguments(
            collection: collection, resultDirectory: batch.sampleBDirectory, outputDirectory: commandFolder
        )
        let command = try ExtractTaxaCollectionSubcommand.parse(Array(arguments.dropFirst(2)))
        _ = try await command.extract(events: CLIEventEmitter(enabled: false, emit: { _ in }))

        let drawerNames = try Self.namesByFile(in: batch.sampleBDirectory.appendingPathComponent("extracted-\(collection.id)"))
        XCTAssertEqual(drawerNames, try Self.namesByFile(in: commandFolder), "the drawer reads what the command reads")
        XCTAssertEqual(drawerNames["Genus_A_taxid10.fastq.gz"], ["x1", "x2", "x3"])
        XCTAssertEqual(drawerNames["Species_B_taxid20.fastq.gz"], ["y1", "y2"])
        let sampleAReads = Set(TwoSampleKraken2Batch.readsA)
        XCTAssertTrue(Set(drawerNames.values.flatMap { $0 }).isDisjoint(with: sampleAReads), "no read of the other sample")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: batch.sampleADirectory.appendingPathComponent("extracted-\(collection.id)").path),
            "the other sample's folder holds no extraction"
        )
    }

    /// The record names of every gzip FASTQ of `folder`, by file name.
    private static func namesByFile(in folder: URL) throws -> [String: [String]] {
        var names: [String: [String]] = [:]
        for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) where file.hasSuffix(".fastq.gz") {
            names[file] = try TaxaCollectionFixtures.recordNames(in: folder.appendingPathComponent(file))
        }
        return names
    }

    private func requireSeqkit(file: StaticString = #filePath, line: UInt = #line) async throws {
        do {
            _ = try await NativeToolRunner.shared.findTool(.seqkit)
        } catch {
            try ToolAvailability.skipOrFail("Managed seqkit is required: \(error)", file: file, line: line)
        }
    }
}

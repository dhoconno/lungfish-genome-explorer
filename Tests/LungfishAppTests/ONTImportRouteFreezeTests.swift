// ONTImportRouteFreezeTests.swift - What the ONT import writes and shows, on the CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A53. M1 froze the import as the app ran it in process, and M3 moved it onto
// `lungfish-cli fastq import-ont --format json` on the L6 runner. The facts that M1 froze stay, and the
// ones that the move changes are changed here, each on purpose. The in-process route itself is side A of
// ONTImportCLIGUIParityReplayTests, which compares it with this route.
//
// 1. The route's result on a three-barcode run folder (ONTImportFreezeFixture). The bundles, the reads of
//    each barcode, the folder around them, the row's words and the provenance (BIO 1, ARCH 2). The one
//    changed fact is the provenance, which names `cli` as its caller (ruling A53-M3) and records the
//    `--format json` the row's command carries, so the record and the row name one command.
// 2. What the window does after the import. `performONTImport` asks the sidebar to reload, posts the
//    drop-completed notice and opens the first barcode bundle, in that order (UX 1). The test runs the
//    real method on a real split controller and reads what each step left.

import AppKit
import XCTest
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishApp

@MainActor
final class ONTImportRouteFreezeTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "ont-import-route-freeze")
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - The route's result

    func testTheRouteWritesTheBarcodeBundlesTheirReadCountsAndTheRecordedFacts() async throws {
        let reporter = RecordingOperationReporter()
        let source = try ONTImportFreezeFixture.makeSource(in: root)
        let project = root.appendingPathComponent("project", isDirectory: true)

        let result = try await ONTImportOperationCoordinator(
            operationCenter: reporter, runner: try ONTImportFreezeFixture.cliRunner(for: Self.self)
        ).importDirectory(
            sourceURL: source,
            projectURL: project,
            includeUnclassified: true,
            concurrency: 2,
            routeContext: nil
        )

        let output = project
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(root.lastPathComponent, isDirectory: true)
        XCTAssertEqual(
            result.bundleURLs.map(\.lastPathComponent),
            ["barcode01.lungfishfastq", "barcode02.lungfishfastq", "unclassified.lungfishfastq"],
            "one bundle for each barcode folder, in barcode order"
        )
        XCTAssertEqual(
            result.bundleURLs.map { $0.deletingLastPathComponent().standardizedFileURL.path },
            Array(repeating: output.standardizedFileURL.path, count: 3),
            "the bundles sit under Imports/<run name>"
        )
        let manifest = try XCTUnwrap(DemultiplexManifest.load(from: output))
        XCTAssertEqual(
            manifest.barcodes.map { "\($0.barcodeID)=\($0.readCount)" },
            ONTImportFreezeFixture.readsPerBarcode.map { "\($0.barcode)=\($0.reads)" },
            "the reads of each barcode, gzip chunk included"
        )
        XCTAssertEqual(
            try Self.names(in: output),
            [
                "barcode01.lungfishfastq", "barcode01.lungfishfastq.lungfish-meta.json",
                "barcode02.lungfishfastq", "barcode02.lungfishfastq.lungfish-meta.json",
                "unclassified.lungfishfastq", "unclassified.lungfishfastq.lungfish-meta.json",
                DemultiplexManifest.filename, ProvenanceWriter.provenanceFilename,
            ].sorted(),
            "the run folder holds the bundles with their metadata sidecars, the demultiplex manifest and the run's provenance"
        )
        for bundle in result.bundleURLs {
            XCTAssertTrue(FASTQBundle.isBundleURL(bundle), "\(bundle.lastPathComponent) is a FASTQ bundle")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename).path),
                "\(bundle.lastPathComponent) records its own run"
            )
        }
        XCTAssertEqual(
            try result.bundleURLs.map { try XCTUnwrap(FASTQBundle.resolveAllFASTQURLs(for: $0)).count },
            [2, 1, 1],
            "a chunked bundle keeps one file for each chunk"
        )

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(item.title, "ONT Import: fastq_pass")
        XCTAssertEqual(item.initialDetail, "Detecting layout...")
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.detail, "3 barcode bundles, 6 reads")
        XCTAssertEqual(item.bundleURLs, result.bundleURLs)

        let envelope = try Self.readEnvelope(output.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        XCTAssertEqual(envelope.workflowName, "lungfish fastq import-ont")
        XCTAssertEqual(envelope.toolName, "lungfish fastq import-ont")
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.options.resolvedDefaults["caller"], .string("cli"))
        XCTAssertEqual(envelope.argv, [
            CLICommandIdentity.executableName, "fastq", "import-ont",
            source.path, "--output", output.path, "--include-unclassified", "--concurrency", "2", "--quality-binning", "fiveStep", "--format", "json",
        ])
        XCTAssertEqual(envelope.reproducibleCommand, item.cliCommand, "the provenance records the command the row shows")
    }

    // MARK: - After the import

    func testTheWindowReloadsTheSidebarPostsTheNoticeThenOpensTheFirstBarcodeBundle() async throws {
        OperationCenter.useTemporaryFailureReportsForTesting()
        let rowsBefore = Set(OperationCenter.shared.items.map(\.id))
        let savedBundleReady = OperationCenter.shared.onBundleReadyWithContext
        OperationCenter.shared.onBundleReadyWithContext = { _, _ in }
        // The window builds its coordinator itself, so the runner finds the command the way the app does.
        let cli = try ONTImportFreezeFixture.builtCLI(for: Self.self)
        let savedCLIPath = getenv("LUNGFISH_CLI_PATH").map { String(cString: $0) }
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        defer {
            if let savedCLIPath { setenv("LUNGFISH_CLI_PATH", savedCLIPath, 1) } else { unsetenv("LUNGFISH_CLI_PATH") }
            OperationCenter.shared.onBundleReadyWithContext = savedBundleReady
            for item in OperationCenter.shared.items where !rowsBefore.contains(item.id) {
                OperationCenter.shared.clearItem(id: item.id)
            }
        }
        XCTAssertEqual(CLIBinaryLocator.cliBinaryPath()?.path, cli.path, "the window's runner would launch another command")
        let source = try ONTImportFreezeFixture.makeSource(in: root)
        let project = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let split = MainSplitViewController()
        _ = split.view
        split.sidebarController.openProject(at: project)
        defer {
            split.fastqLoadTask?.cancel()
            split.sidebarController.closeProject()
        }

        let notices = NoticeRecorder()
        let openedSource: @MainActor @Sendable () -> URL? = { [unowned split] in split.activeFASTQSourceURL }
        let token = NotificationCenter.default.addObserver(
            forName: .sidebarFileDropCompleted, object: split, queue: nil
        ) { note in
            let info = note.userInfo ?? [:]
            let success = info["success"] as? Bool ?? false
            let requestID = info["requestID"] as? String
            let url = info["url"] as? URL
            MainActor.assumeIsolated {
                notices.record(success: success, requestID: requestID, url: url, openedAtNotice: openedSource())
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        split.performONTImport(
            sourceURL: source,
            projectURL: project,
            includeUnclassified: true,
            storageMode: .chunked,
            optimizeStorage: false,
            qualityBinning: .none,
            viewerController: split.viewerController,
            requestID: "ont-route-freeze"
        )

        let posted = await waitUntil(timeout: .seconds(30)) { !notices.entries.isEmpty }
        XCTAssertTrue(posted, "the import never posted its drop-completed notice")
        let notice = try XCTUnwrap(notices.entries.first)
        XCTAssertEqual(notices.entries.count, 1)
        XCTAssertTrue(notice.success)
        XCTAssertEqual(notice.requestID, "ont-route-freeze")
        XCTAssertEqual(notice.url, source)
        XCTAssertNil(notice.openedAtNotice, "the notice comes before the first bundle opens")

        let row = try XCTUnwrap(OperationCenter.shared.items.first { !rowsBefore.contains($0.id) })
        XCTAssertEqual(row.state, .completed)
        XCTAssertTrue(row.cliCommand?.hasSuffix(" --format json") == true, "the row records the argv the runner launched")
        let firstBundle = try XCTUnwrap(row.bundleURLs.first)
        XCTAssertEqual(firstBundle.lastPathComponent, "barcode01.lungfishfastq")
        let opened = await waitUntil(timeout: .seconds(30)) {
            split.activeFASTQSourceURL?.standardizedFileURL == firstBundle.standardizedFileURL
        }
        XCTAssertTrue(opened, "the first barcode bundle never opened, the window shows \(String(describing: split.activeFASTQSourceURL))")

        // The sidebar scanned the project again and shows the new bundles (the reload the import asked for).
        let expectedRows = Set(row.bundleURLs.map { $0.resolvingSymlinksInPath().path })
        let shown = await waitUntil(timeout: .seconds(30)) {
            expectedRows.isSubset(of: Self.rowPaths(of: split.sidebarController))
        }
        XCTAssertTrue(shown, "the sidebar never showed the imported bundles")
    }

    // MARK: - Helpers

    private final class NoticeRecorder: @unchecked Sendable {
        struct Entry {
            let success: Bool
            let requestID: String?
            let url: URL?
            let openedAtNotice: URL?
        }

        private(set) var entries: [Entry] = []

        func record(success: Bool, requestID: String?, url: URL?, openedAtNotice: URL?) {
            entries.append(Entry(success: success, requestID: requestID, url: url, openedAtNotice: openedAtNotice))
        }
    }

    /// The names directly inside `folder`, hidden ones included.
    private static func names(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: []
        ).map(\.lastPathComponent).sorted()
    }

    private static func readEnvelope(_ url: URL) throws -> ProvenanceEnvelope {
        try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: Data(contentsOf: url))
    }

    private static func rowPaths(of sidebar: SidebarViewController) -> Set<String> {
        var paths: Set<String> = []
        func walk(_ items: [SidebarItem]) {
            for item in items {
                if let url = item.url { paths.insert(url.resolvingSymlinksInPath().path) }
                walk(item.children)
            }
        }
        walk(sidebar.rootItems)
        return paths
    }
}

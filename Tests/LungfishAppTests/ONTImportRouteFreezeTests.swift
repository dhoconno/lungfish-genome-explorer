// ONTImportRouteFreezeTests.swift - What the ONT import writes and shows today, before it moves onto the CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A53 M1 (pins at the base, no Sources edit). `performONTImport` runs
// `ONTImportWorkflow.importDirectory` inside the app through `ONTImportOperationCoordinator`, and
// `lungfish-cli fastq import-ont` runs the same workflow. Three facts are frozen here, so M3 can move
// the launch onto the leaf and see what it changed.
//
// 1. The in-process route's result on a three-barcode run folder (ONTImportFreezeFixture). The bundles,
//    the reads of each barcode, the folder around them, the row's words and its stage words, and the
//    provenance the coordinator writes (BIO 1, ARCH 2).
// 2. The same run on the CLI leaf, run in process with the argv the row records. The two routes write
//    the same files, the same read counts and the same recorded facts, and the one difference is the
//    caller. This is the base the parity class of M3 declares its differences against.
// 3. What the window does after the import. `performONTImport` asks the sidebar to reload, posts the
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
@testable import LungfishCLI

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

    // MARK: - The in-process route

    func testTheInProcessRouteWritesTheBarcodeBundlesTheirReadCountsAndTheRowWords() async throws {
        let reporter = RecordingOperationReporter()
        let source = try ONTImportFreezeFixture.makeSource(in: root)
        let project = root.appendingPathComponent("project", isDirectory: true)

        let result = try await ONTImportOperationCoordinator(operationCenter: reporter).importDirectory(
            sourceURL: source,
            projectURL: project,
            includeUnclassified: true,
            concurrency: 2,
            routeContext: nil
        )

        let imported = result.importResult
        let output = project
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(root.lastPathComponent, isDirectory: true)
        XCTAssertEqual(
            imported.bundleURLs.map(\.lastPathComponent),
            ["barcode01.lungfishfastq", "barcode02.lungfishfastq", "unclassified.lungfishfastq"],
            "one bundle for each barcode folder, in barcode order"
        )
        XCTAssertEqual(
            imported.bundleURLs.map { $0.deletingLastPathComponent().standardizedFileURL.path },
            Array(repeating: output.standardizedFileURL.path, count: 3),
            "the bundles sit under Imports/<run name>"
        )
        XCTAssertEqual(
            imported.manifest.barcodes.map { "\($0.barcodeID)=\($0.readCount)" },
            ONTImportFreezeFixture.readsPerBarcode.map { "\($0.barcode)=\($0.reads)" },
            "the reads of each barcode, gzip chunk included"
        )
        XCTAssertEqual(imported.totalReadCount, ONTImportFreezeFixture.totalReads)
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
        for bundle in imported.bundleURLs {
            XCTAssertTrue(FASTQBundle.isBundleURL(bundle), "\(bundle.lastPathComponent) is a FASTQ bundle")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: bundle.appendingPathComponent(ProvenanceWriter.provenanceFilename).path),
                "\(bundle.lastPathComponent) records its own run"
            )
        }
        XCTAssertEqual(
            try imported.bundleURLs.map { try XCTUnwrap(FASTQBundle.resolveAllFASTQURLs(for: $0)).count },
            [2, 1, 1],
            "a chunked bundle keeps one file for each chunk"
        )

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(item.title, "ONT Import: fastq_pass")
        XCTAssertEqual(item.initialDetail, "Detecting layout...")
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.detail, "3 barcode bundles, 6 reads")
        XCTAssertEqual(item.bundleURLs, imported.bundleURLs)

        // The stage words reach the row through the main queue, so the last one lands after the call.
        let finished = await waitUntil(timeout: .seconds(30)) {
            reporter.items.first?.progressUpdates.last?.detail.hasPrefix("Import complete (6 reads, ") == true
        }
        let words = reporter.items.first?.progressUpdates.map(\.detail) ?? []
        XCTAssertTrue(finished, "the row never showed the closing stage word, it showed \(words)")
        XCTAssertEqual(words.first, "Detecting ONT directory layout...")
        XCTAssertTrue(words.contains { $0.hasPrefix("barcode01: ") }, "a per-barcode stage word names its barcode: \(words)")
        XCTAssertTrue(words.contains("Completed 3/3 barcodes"), "the count of finished barcodes: \(words)")

        let envelope = try Self.readEnvelope(output.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        XCTAssertEqual(envelope.workflowName, "lungfish fastq import-ont")
        XCTAssertEqual(envelope.toolName, "lungfish fastq import-ont")
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.options.resolvedDefaults["caller"], .string("gui"))
        XCTAssertEqual(envelope.argv, [
            CLICommandIdentity.executableName, "fastq", "import-ont",
            source.path, "--output", output.path, "--include-unclassified", "--concurrency", "2",
        ])
        XCTAssertEqual(envelope.reproducibleCommand, item.cliCommand, "the provenance records the command the row shows")
    }

    // MARK: - The CLI leaf on the same run folder

    func testTheCLILeafWritesTheSameBundlesCountsAndRecordedFactsAsTheInProcessRoute() async throws {
        let source = try ONTImportFreezeFixture.makeSource(in: root)
        let guiRoot = root.appendingPathComponent("gui", isDirectory: true)
        let cliRoot = root.appendingPathComponent("cli", isDirectory: true)
        let runFolder = "Imports/" + root.lastPathComponent
        let guiOutput = guiRoot.appendingPathComponent(runFolder, isDirectory: true)
        let cliOutput = cliRoot.appendingPathComponent(runFolder, isDirectory: true)

        let reporter = RecordingOperationReporter()
        _ = try await ONTImportOperationCoordinator(operationCenter: reporter).importDirectory(
            sourceURL: source,
            projectURL: guiRoot,
            includeUnclassified: true,
            concurrency: 2,
            routeContext: nil
        )
        // The row records this command, and the leaf runs it with the output the row names.
        let recorded = try RecordedCLICommand.parse(
            try XCTUnwrap(reporter.items.first?.cliCommand), as: FastqImportONTSubcommand.self
        )
        XCTAssertEqual(recorded.output, guiOutput.path)
        try await FastqImportONTSubcommand.parse([
            recorded.input, "--output", cliOutput.path, "--include-unclassified", "--concurrency", "2",
        ]).run()

        XCTAssertEqual(
            try Self.relativeFiles(in: cliOutput), try Self.relativeFiles(in: guiOutput),
            "both routes write the same files"
        )
        let guiManifest = try XCTUnwrap(DemultiplexManifest.load(from: guiOutput))
        let cliManifest = try XCTUnwrap(DemultiplexManifest.load(from: cliOutput))
        XCTAssertEqual(
            cliManifest.barcodes.map { "\($0.barcodeID)=\($0.readCount)=\($0.baseCount)=\($0.bundleRelativePath)" },
            guiManifest.barcodes.map { "\($0.barcodeID)=\($0.readCount)=\($0.baseCount)=\($0.bundleRelativePath)" },
            "equal reads per barcode (BIO 1)"
        )
        XCTAssertEqual(cliManifest.barcodes.map(\.readCount), ONTImportFreezeFixture.readsPerBarcode.map(\.reads))
        for bundle in ["barcode01", "barcode02", "unclassified"] {
            let name = "\(bundle).lungfishfastq"
            XCTAssertEqual(
                try Self.payloadDigests(of: cliOutput.appendingPathComponent(name)),
                try Self.payloadDigests(of: guiOutput.appendingPathComponent(name)),
                "\(name) holds the same read files"
            )
        }

        let guiEnvelope = try Self.readEnvelope(guiOutput.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        let cliEnvelope = try Self.readEnvelope(cliOutput.appendingPathComponent(ProvenanceWriter.provenanceFilename))
        func normalized(_ text: String, root route: URL) -> String {
            text.replacingOccurrences(of: route.path, with: "<ROOT>")
        }
        XCTAssertEqual(cliEnvelope.workflowName, guiEnvelope.workflowName)
        XCTAssertEqual(cliEnvelope.toolName, guiEnvelope.toolName)
        XCTAssertEqual(cliEnvelope.exitStatus, guiEnvelope.exitStatus)
        XCTAssertEqual(
            cliEnvelope.argv.map { normalized($0, root: cliRoot) },
            guiEnvelope.argv.map { normalized($0, root: guiRoot) },
            "the leaf records the argv the row records"
        )
        XCTAssertEqual(
            normalized(cliEnvelope.reproducibleCommand, root: cliRoot),
            normalized(guiEnvelope.reproducibleCommand, root: guiRoot)
        )
        XCTAssertEqual(cliEnvelope.options.defaults, guiEnvelope.options.defaults)
        var guiResolved = guiEnvelope.options.resolvedDefaults
        var cliResolved = cliEnvelope.options.resolvedDefaults
        XCTAssertEqual(guiResolved.removeValue(forKey: "caller"), .string("gui"))
        XCTAssertEqual(cliResolved.removeValue(forKey: "caller"), .string("cli"))
        for key in ["output"] {
            guiResolved.removeValue(forKey: key)
            cliResolved.removeValue(forKey: key)
        }
        XCTAssertEqual(cliResolved, guiResolved, "the caller and the output root are the only resolved options that differ")
    }

    // MARK: - After the import

    func testTheWindowReloadsTheSidebarPostsTheNoticeThenOpensTheFirstBarcodeBundle() async throws {
        OperationCenter.useTemporaryFailureReportsForTesting()
        let rowsBefore = Set(OperationCenter.shared.items.map(\.id))
        let savedBundleReady = OperationCenter.shared.onBundleReadyWithContext
        OperationCenter.shared.onBundleReadyWithContext = { _, _ in }
        defer {
            OperationCenter.shared.onBundleReadyWithContext = savedBundleReady
            for item in OperationCenter.shared.items where !rowsBefore.contains(item.id) {
                OperationCenter.shared.clearItem(id: item.id)
            }
        }
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

    /// Every regular file under `folder`, hidden ones included, by its path from the folder.
    private static func relativeFiles(in folder: URL) throws -> [String] {
        let base = folder.resolvingSymlinksInPath().path + "/"
        var files: [String] = []
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            files.append(String(url.resolvingSymlinksInPath().path.dropFirst(base.count)))
        }
        return files.sorted()
    }

    /// The bytes of each read file of a bundle, by name. The sidecars hold dates, so they stay out.
    private static func payloadDigests(of bundle: URL) throws -> [String: Data] {
        var digests: [String: Data] = [:]
        for file in try relativeFiles(in: bundle) where file.hasSuffix(".fastq") || file.hasSuffix(".fastq.gz") {
            digests[file] = try Data(contentsOf: bundle.appendingPathComponent(file))
        }
        return digests
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

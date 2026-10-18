// NaoMgsNvdImportRecordTests.swift - The folder, record, options and row words of the NAO-MGS and NVD imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.05 (A63-M2b, QA 1). The Import Center imports a NAO-MGS or NVD result through the app's
// `--metagenomics-import-helper` mode until lane 12.05 moved these kinds to `lungfish-cli`. These cases pin what that
// path writes for a fixture result with the dotted sample ids `S1.2024` and `S2.2024` (BIO 5): the folder name, the
// record's command (`MetagenomicsImportHelper.canonicalProvenanceCommand`), the sample facts it records, the digest of
// each source file, and the words of the row (its title, command and the detail it completes with). The one NAO-MGS
// option, `fetchReferences`, must reach a flag of the leaf.
//
// The managed storage of the process is a folder under the scratch folder that holds a fixture taxonomy, so the
// import resolves taxon names without the network and without writing into the user's managed storage.

import Darwin
import Foundation
import Synchronization
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishOperations
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class NaoMgsNvdImportRecordTests: XCTestCase {
    private var root: URL!
    private var storageBefore: String?

    override func setUp() async throws {
        root = try TestTempDirectory.make(prefix: "naomgs-nvd-import-record")
        storageBefore = NaoMgsNvdAppFixtures.useStorage(try await NaoMgsNvdAppFixtures.installFixtureTaxonomy(in: root))
    }

    override func tearDownWithError() throws {
        NaoMgsNvdAppFixtures.restoreStorage(storageBefore)
        TestTempDirectory.cleanup(root)
    }

    func testTheNaoMgsHelperPathWritesItsFolderRecordAndRowWords() throws {
        let input = try NaoMgsNvdAppFixtures.naoMgsResult(in: root)
        let run = try runHelper(kind: .naomgs, input: input, extra: ["--fetch-references", "false"], fetchReferences: false)
        XCTAssertEqual(run.folderName, "naomgs-S1", "today the folder name drops the sample id after its dot")
        XCTAssertEqual(run.doneMessage, "Imported NAO-MGS result: 5 reads, 1 taxa")
        let defaults = run.envelope.options.resolvedDefaults
        XCTAssertEqual(defaults["sampleName"], .string("S1.2024"), "the first sample's id, whole")
        XCTAssertEqual(defaults["totalHitReads"], .integer(5))
        XCTAssertNil(defaults["sampleNames"], "today the record names one sample")
        XCTAssertNil(defaults["sourceDigest"], "today the record holds no digest of the source")
        try assertEachSourceFileDigested(run.envelope, sources: ClassifierImportAppFixtures.regularFiles(in: input))
    }

    func testTheNvdHelperPathWritesItsFolderRecordAndRowWords() throws {
        let input = try NaoMgsNvdAppFixtures.nvdRun(in: root)
        let run = try runHelper(kind: .nvd, input: input, extra: [], fetchReferences: true)
        XCTAssertEqual(run.folderName, "nvd-EXP001")
        XCTAssertEqual(run.doneMessage, "Imported NVD result: 3 hits, 2 samples")
        let defaults = run.envelope.options.resolvedDefaults
        XCTAssertEqual(defaults["sampleCount"], .integer(2))
        XCTAssertEqual(defaults["hitCount"], .integer(3))
        XCTAssertNil(defaults["sampleNames"], "today the record names no sample")
        XCTAssertNil(defaults["sourceDigest"], "today the record holds no digest of the source")
        try assertEachSourceFileDigested(run.envelope, sources: ClassifierImportAppFixtures.regularFiles(in: input))
    }

    /// `NaoMgsOptions` holds one option, `fetchReferences`, which defaults to fetching. It reaches the leaf as
    /// `--no-fetch-references`, and the preferred name reaches it as `--sample-name`.
    func testEveryNaoMgsOptionReachesAFlagOfTheLeaf() throws {
        XCTAssertTrue(MetagenomicsImportHelperClient.NaoMgsOptions().fetchReferences)
        let input = root.appendingPathComponent("S1.2024", isDirectory: true)
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        for fetch in [true, false] {
            let argv = MetagenomicsImportHelper.canonicalProvenanceCommand(
                kind: .naomgs, inputURL: input, outputDirectory: imports, secondaryInputURL: nil,
                preferredName: "Sample 7", fetchReferences: fetch
            )
            XCTAssertEqual(
                argv,
                ["lungfish-cli", "import", "nao-mgs", input.path, "--output-dir", imports.path, "--sample-name", "Sample 7"]
                    + (fetch ? [] : ["--no-fetch-references"])
            )
            let leaf = try ImportCommand.NaoMgsSubcommand.parse(Array(argv.dropFirst(3)))
            XCTAssertEqual(leaf.inputPath, input.path)
            XCTAssertEqual(leaf.outputDir, imports.path)
            XCTAssertEqual(leaf.sampleName, "Sample 7")
            XCTAssertEqual(leaf.fetchReferences, fetch)
        }
    }

    /// The row the Import Center begins for each kind, whose command is the record's command after `lungfish-cli`.
    func testTheRowWordsOfBothKinds() throws {
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        let naoMgsInput = root.appendingPathComponent("S1.2024", isDirectory: true)
        let naoMgs = RecordingOperationReporter()
        var naoMgsLaunched: UUID?
        AppDelegate.beginClassifierResultImportOperation(
            kind: .naomgs, operationTitle: "NAO-MGS Import", inputURL: naoMgsInput, outputDirectory: imports, preferredName: nil,
            naoMgsOptions: .init(fetchReferences: false), routeContext: nil, reporter: naoMgs, launch: { naoMgsLaunched = $0 }
        )
        let naoMgsItem = try XCTUnwrap(naoMgs.items.first)
        XCTAssertNotNil(naoMgsLaunched)
        XCTAssertEqual(naoMgsItem.title, "NAO-MGS Import")
        XCTAssertEqual(naoMgsItem.operationType, .classification)
        XCTAssertEqual(
            naoMgsItem.cliCommand,
            OperationCenter.buildCLICommand(subcommand: "import", args: ["nao-mgs", naoMgsInput.path, "--output-dir", imports.path, "--no-fetch-references"])
        )

        let nvdInput = root.appendingPathComponent("nvd.2024", isDirectory: true)
        let nvd = RecordingOperationReporter()
        var nvdLaunched: UUID?
        AppDelegate.beginNvdImportOperation(
            sourceURL: nvdInput, importsDirectory: imports, routeContext: nil, reporter: nvd, launch: { nvdLaunched = $0 }
        )
        let nvdItem = try XCTUnwrap(nvd.items.first)
        XCTAssertNotNil(nvdLaunched)
        XCTAssertEqual(nvdItem.title, "NVD Import")
        XCTAssertEqual(nvdItem.operationType, .classification)
        XCTAssertEqual(
            nvdItem.cliCommand,
            OperationCenter.buildCLICommand(subcommand: "import", args: ["nvd", nvdInput.path, "--output-dir", imports.path])
        )
    }

    // MARK: - The helper in process

    private struct HelperRun {
        let folderName: String
        let doneMessage: String?
        let envelope: ProvenanceEnvelope
    }

    /// Runs the helper mode in process, as the app's helper process ran it, into a project's Imports folder, and
    /// reads the folder it made, its `done` message and its record. The record's command is the canonical one.
    private func runHelper(kind: MetagenomicsImportKind, input: URL, extra: [String], fetchReferences: Bool) throws -> HelperRun {
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let arguments = ["--metagenomics-import-helper", "--kind", kind.rawValue, "--input-path", input.path, "--output-dir", imports.path] + extra
        let (status, lines) = try ClassifierImportAppFixtures.standardOutput(in: root) {
            Self.helperStatus(arguments)
        }
        XCTAssertEqual(status, 0, lines.joined(separator: "\n"))
        let folders = try FileManager.default.contentsOfDirectory(atPath: imports.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(folders.count, 1, "\(folders)")
        let folder = imports.appendingPathComponent(try XCTUnwrap(folders.first), isDirectory: true)
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: folder), "the result folder holds its record")
        XCTAssertEqual(envelope.argv, MetagenomicsImportHelper.canonicalProvenanceCommand(
            kind: kind, inputURL: input, outputDirectory: imports, secondaryInputURL: nil, preferredName: nil, fetchReferences: fetchReferences
        ))
        let done = lines.compactMap { line -> String? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["event"] as? String == "done" else { return nil }
            return object["message"] as? String
        }.last
        return HelperRun(folderName: folder.lastPathComponent, doneMessage: done, envelope: envelope)
    }

    /// The helper waits on a semaphore for its own task, so it runs on a dispatch thread rather than the main thread.
    nonisolated private static func helperStatus(_ arguments: [String]) -> Int32? {
        let status = Mutex<Int32?>(nil)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            status.withLock { $0 = MetagenomicsImportHelper.runIfRequested(arguments: arguments) }
            finished.signal()
        }
        finished.wait()
        return status.withLock { $0 }
    }

    /// Each source file is an input of the record with the SHA-256 of its bytes. The fixtures' file names are unique.
    private func assertEachSourceFileDigested(
        _ envelope: ProvenanceEnvelope,
        sources: [URL],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertFalse(sources.isEmpty, file: file, line: line)
        let inputs = envelope.files.filter { $0.role == .input }
        for source in sources {
            let descriptor = inputs.first { URL(fileURLWithPath: $0.path).lastPathComponent == source.lastPathComponent }
            XCTAssertEqual(descriptor?.checksumSHA256, try ProvenanceFileHasher.sha256(of: source), source.lastPathComponent, file: file, line: line)
        }
    }
}

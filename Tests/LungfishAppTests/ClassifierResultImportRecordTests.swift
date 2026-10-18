// ClassifierResultImportRecordTests.swift - The folder, record and row words of the three classifier result imports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.04 (A63-M2a, QA 1). The Import Center imports a Kraken2, EsViritu or TaxTriage result
// through the app's `--metagenomics-import-helper` mode until lane 12.04 moved these kinds to `lungfish-cli`. These cases pin what that path
// writes for a fixture result with the dotted sample id `S1.2024` (BIO 5): the folder name, the record's
// command (`MetagenomicsImportHelper.canonicalProvenanceCommand`), the sample names it records, the digest of
// each source file, and the words of the row (its title, command and the detail it completes with).

import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class ClassifierResultImportRecordTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "classifier-import-record")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    func testTheKraken2HelperPathWritesItsFolderRecordAndRowWords() throws {
        let input = try ClassifierImportAppFixtures.kraken2Report(in: root)
        let run = try runHelper(kind: .kraken2, input: input)
        XCTAssertEqual(run.folderName, "classification-S1_2024")
        XCTAssertEqual(run.doneMessage, "Imported Kraken2 result: 2,504,263 reads, 738 species")
        XCTAssertEqual(run.envelope.options.resolvedDefaults["sampleNames"], .array([.string("S1.2024")]), "the kreport's sample id, whole")
        XCTAssertEqual(run.envelope.options.resolvedDefaults["sourceDigest"], .string(try ProvenanceFileHasher.sha256(of: input)))
        try assertEachSourceFileDigested(run.envelope, sources: [input])
    }

    func testTheEsVirituHelperPathWritesItsFolderRecordAndRowWords() throws {
        let input = try ClassifierImportAppFixtures.esVirituResult(in: root)
        let run = try runHelper(kind: .esviritu, input: input)
        XCTAssertEqual(run.folderName, "esviritu-S1", "today the folder name drops the sample id after its dot")
        XCTAssertEqual(run.doneMessage, "Imported EsViritu result: 3 files, 3 detections")
        XCTAssertEqual(run.envelope.options.resolvedDefaults["sampleName"], .string("S1.2024"), "the detection file's sample id, whole")
        XCTAssertEqual(run.envelope.options.resolvedDefaults["sampleNames"], .array([.string("S1.2024")]))
        try assertFolderDigest(run.envelope, of: input)
        try assertEachSourceFileDigested(run.envelope, sources: ClassifierImportAppFixtures.regularFiles(in: input))
    }

    func testTheTaxTriageHelperPathWritesItsFolderRecordAndRowWords() throws {
        let input = try ClassifierImportAppFixtures.taxTriageResult(in: root)
        let run = try runHelper(kind: .taxtriage, input: input)
        XCTAssertEqual(run.folderName, "taxtriage-run")
        XCTAssertEqual(run.doneMessage, "Imported TaxTriage result: 6 files")
        XCTAssertEqual(
            run.envelope.options.resolvedDefaults["sampleNames"],
            .array(["S1.2024", "SRR35517702", "SRR35517703", "SRR35517705"].map(ParameterValue.string)),
            "the sample ids the per-sample report and maps spell, whole"
        )
        try assertFolderDigest(run.envelope, of: input)
        try assertEachSourceFileDigested(run.envelope, sources: ClassifierImportAppFixtures.regularFiles(in: input))
    }

    /// The digest of a source folder is the SHA-256 of one `<relative path>\t<SHA-256>` line per file in path order.
    private func assertFolderDigest(_ envelope: ProvenanceEnvelope, of folder: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let root = folder.resolvingSymlinksInPath().path
        let lines = try ClassifierImportAppFixtures.regularFiles(in: folder).map { url in
            "\(url.resolvingSymlinksInPath().path.dropFirst(root.count + 1))\t\(try ProvenanceFileHasher.sha256(of: url))\n"
        }.sorted()
        let expected = SHA256.hash(data: Data(lines.joined().utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(envelope.options.resolvedDefaults["sourceDigest"], .string(expected), file: file, line: line)
    }

    /// The row the Import Center begins for each kind, whose command is the record's command after `lungfish-cli`.
    func testTheRowWordsOfEachKind() throws {
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        let input = root.appendingPathComponent("S1.2024.kreport")
        for (kind, title) in [(MetagenomicsImportKind.kraken2, "Kraken2 Import"), (.esviritu, "EsViritu Import"), (.taxtriage, "TaxTriage Import")] {
            let reporter = RecordingOperationReporter()
            var launched: UUID?
            AppDelegate.beginClassifierResultImportOperation(
                kind: kind, operationTitle: title, inputURL: input, outputDirectory: imports, preferredName: nil,
                naoMgsOptions: nil, routeContext: nil, reporter: reporter, launch: { launched = $0 }
            )
            let item = try XCTUnwrap(reporter.items.first)
            XCTAssertNotNil(launched)
            XCTAssertEqual(item.title, title)
            XCTAssertEqual(item.operationType, .classification)
            XCTAssertEqual(
                item.cliCommand,
                ClassifierResultImportCLIRoute.rowCommand(kind: kind, inputURL: input, outputDirectory: imports, preferredName: nil)
            )
        }
    }

    // MARK: - The helper in process

    private struct HelperRun {
        let folderName: String
        let doneMessage: String?
        let envelope: ProvenanceEnvelope
    }

    /// Runs the helper mode in process, as the app's helper process ran it, into a project's Imports folder, and
    /// reads the folder it made, its `done` message and its record. The record's command is the canonical one.
    private func runHelper(kind: MetagenomicsImportKind, input: URL) throws -> HelperRun {
        let imports = root.appendingPathComponent("Project.lungfish/Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let arguments = ["--metagenomics-import-helper", "--kind", kind.rawValue, "--input-path", input.path, "--output-dir", imports.path]
        let (status, lines) = try ClassifierImportAppFixtures.standardOutput(in: root) {
            MetagenomicsImportHelper.runIfRequested(arguments: arguments)
        }
        XCTAssertEqual(status, 0, lines.joined(separator: "\n"))
        let folders = try FileManager.default.contentsOfDirectory(atPath: imports.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(folders.count, 1, "\(folders)")
        let folder = imports.appendingPathComponent(try XCTUnwrap(folders.first), isDirectory: true)
        let envelope = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: folder), "the result folder holds its record")
        XCTAssertEqual(envelope.argv, MetagenomicsImportHelper.canonicalProvenanceCommand(
            kind: kind, inputURL: input, outputDirectory: imports, secondaryInputURL: nil, preferredName: nil, fetchReferences: true
        ))
        let done = lines.compactMap { line -> String? in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["event"] as? String == "done" else { return nil }
            return object["message"] as? String
        }.last
        return HelperRun(folderName: folder.lastPathComponent, doneMessage: done, envelope: envelope)
    }

    /// Each source file is an input of the record with the SHA-256 of its bytes. The fixtures' file names are unique.
    private func assertEachSourceFileDigested(
        _ envelope: ProvenanceEnvelope,
        sources: [URL],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let inputs = envelope.files.filter { $0.role == .input }
        for source in sources {
            let descriptor = inputs.first { URL(fileURLWithPath: $0.path).lastPathComponent == source.lastPathComponent }
            XCTAssertEqual(descriptor?.checksumSHA256, try ProvenanceFileHasher.sha256(of: source), source.lastPathComponent, file: file, line: line)
        }
    }
}

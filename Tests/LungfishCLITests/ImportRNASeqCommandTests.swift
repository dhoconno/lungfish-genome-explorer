// ImportRNASeqCommandTests.swift - `import rnaseq` on salmon folders and a plain table (Phase 5.1 lane RS-BULK-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class ImportRNASeqCommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "import-rnaseq") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    private func project(_ name: String) throws -> URL {
        let url = root.appendingPathComponent("\(name).lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Each run of three transcripts of the fixture is one gene.
    private func tx2gene() throws -> URL {
        let text = try String(contentsOf: RNASeqFixtures.salmonRun("SRR896663").appendingPathComponent("quant.sf"), encoding: .utf8)
        let ids = text.split(separator: "\n").dropFirst().map { String($0.prefix { $0 != "\t" }) }
        let lines = ["transcript_id\tgene_id"] + ids.enumerated().map { "\($1)\tG\($0 / 3)" }
        let url = root.appendingPathComponent("tx2gene.tsv")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func salmonArguments(into project: URL) throws -> [String] {
        RNASeqFixtures.salmonRunIDs.map { RNASeqFixtures.salmonRun($0).path }
            + ["--project", project.path, "--name", "seqc-c1", "--tx2gene", try tx2gene().path]
    }

    private func run(_ arguments: [String]) async throws {
        let command = try ImportCommand.RNASeqSubcommand.parse(arguments + ["--quiet"])
        try await command.run()
    }

    /// The results in the project's Analyses folder, stages included.
    private func analyses(_ project: URL) -> [String] {
        let folder = project.appendingPathComponent("Analyses", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func result(in project: URL) throws -> URL {
        let names = analyses(project).filter { $0.hasSuffix(".lungfishrnaseq") && !$0.hasPrefix(".") }
        XCTAssertEqual(names.count, 1, "\(names)")
        return project.appendingPathComponent("Analyses/\(try XCTUnwrap(names.first))", isDirectory: true)
    }

    private func manifest(_ result: URL) throws -> RNASeqResultManifest {
        try JSONDecoder().decode(RNASeqResultManifest.self, from: Data(contentsOf: result.appendingPathComponent(RNASeqResultManifest.filename)))
    }

    private func record(_ result: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: result))
    }

    func testImportCommandRegistersRNASeq() {
        XCTAssertTrue(ImportCommand.configuration.subcommands.map { $0.configuration.commandName }.contains("rnaseq"))
    }

    func testSalmonFoldersImportAsGivenWithGeneSums() async throws {
        let project = try project("Salmon")
        try await run(try salmonArguments(into: project))
        let result = try result(in: project)
        for run in RNASeqFixtures.salmonRunIDs {
            for file in RNASeqFixtures.salmonFiles {
                XCTAssertEqual(
                    try Data(contentsOf: result.appendingPathComponent("source/\(run)/\(file)")),
                    try Data(contentsOf: RNASeqFixtures.salmonRun(run).appendingPathComponent(file)), "\(run)/\(file)")
            }
        }
        let manifest = try manifest(result)
        XCTAssertNil(manifest.referenceSet)
        XCTAssertEqual(manifest.origin, .init(kind: .imported, tool: "salmon", toolVersion: "2.11.0"))
        XCTAssertEqual(Set(manifest.counts.map(\.path)), ["counts/genes.counts.tsv", "counts/transcripts.counts.tsv"])
        XCTAssertEqual(Set(manifest.counts.map(\.unit)), [.estimated])
        let quality = try XCTUnwrap(record(result).options.resolvedDefaults["quality"])
        guard case .dictionary(let samples) = quality, case .dictionary(let first)? = samples["SRR896663"] else {
            return XCTFail("the record holds no quality numbers by sample: \(quality)")
        }
        XCTAssertEqual(first["num_processed"], .integer(5_728_703))
        XCTAssertEqual(first["library_type"], .string("IU"))
        XCTAssertEqual(first["salmon_version"], .string("2.11.0"))
    }

    // MARK: - A plain table and what the files do not state

    func testATableImportRecordsWhatTheFilesDoNotStateAsNotRecorded() async throws {
        let project = try project("Table")
        try await run([RNASeqFixtures.umiCounts.path, "--project", project.path, "--name", "c9-umis", "--unit", "umis"])
        let result = try result(in: project)
        XCTAssertEqual(
            try Data(contentsOf: result.appendingPathComponent("source/tables/counts.tsv")),
            try Data(contentsOf: RNASeqFixtures.umiCounts))
        let facts = try record(result).options.resolvedDefaults
        for key in ["referenceSet", "instrument", "kit", "polyGTrimming", "duplicates"] {
            XCTAssertEqual(facts[key]?.stringValue, "Not recorded", key)
        }
        XCTAssertNil(try manifest(result).referenceSet)
        let genes = try RNASeqGeneRecord.records(tsv: Data(contentsOf: result.appendingPathComponent("genes.tsv")), path: "genes.tsv")
        XCTAssertEqual(genes.count, 203)
        XCTAssertTrue(genes.allSatisfy { $0.name == nil && $0.biotype == nil && $0.notHost == nil })
        let samples = try RNASeqSampleRecord.records(tsv: Data(contentsOf: result.appendingPathComponent("samples.tsv")), path: "samples.tsv")
        XCTAssertEqual(samples.count, 33)
        XCTAssertTrue(samples.allSatisfy { $0.species == nil && $0.animal == nil })
    }

    func testSampleIDsThatDifferAreRefusedAndNothingIsPublished() async throws {
        let project = try project("Refused")
        let sheet = root.appendingPathComponent("sheet.tsv")
        try "sample\tspecies\nB1\tMacaca mulatta\nZ7\tMacaca mulatta\n".write(to: sheet, atomically: true, encoding: .utf8)
        do {
            try await run([RNASeqFixtures.umiCounts.path, "--project", project.path, "--name", "c9", "--unit", "umis", "--samples", sheet.path])
            XCTFail("a sheet that names other samples than the table imports nothing")
        } catch {
            XCTAssertEqual((error as? ExitCode)?.rawValue, CLIExitCode.inputError.exitCode.rawValue)
        }
        XCTAssertEqual(analyses(project).filter { $0.contains(".lungfishrnaseq") }, [], "no result and no stage")
    }

    // MARK: - The recorded command

    func testTheRecordedArgvParsesToEqualOptions() async throws {
        let project = try project("RoundTrip")
        let original = try ImportCommand.RNASeqSubcommand.parse(try salmonArguments(into: project))
        try await run(try salmonArguments(into: project))
        let argv = try record(try result(in: project)).argv
        XCTAssertEqual(Array(argv.prefix(3)), [CLICommandIdentity.executableName, "import", "rnaseq"])
        let replayed = try ImportCommand.RNASeqSubcommand.parse(Array(argv.dropFirst(3)))
        func standard(_ path: String?) -> String? { path.map { URL(fileURLWithPath: $0).standardizedFileURL.path } }
        XCTAssertEqual(replayed.inputPaths.map(standard), original.inputPaths.map(standard))
        XCTAssertEqual(standard(replayed.projectPath), standard(original.projectPath))
        XCTAssertEqual(replayed.name, original.name)
        XCTAssertEqual(standard(replayed.tx2genePath), standard(original.tx2genePath))
        XCTAssertEqual(standard(replayed.samplesPath), standard(original.samplesPath))
        XCTAssertEqual(replayed.unit, original.unit)
    }

    func testReplayingTheRecordedCommandGivesCountTablesOfEqualSha256() async throws {
        let first = try project("First")
        try await run(try salmonArguments(into: first))
        let firstResult = try result(in: first)
        var argv = Array(try record(firstResult).argv.dropFirst(3))
        let second = try project("Second")
        let projectIndex = try XCTUnwrap(argv.firstIndex(of: "--project"))
        argv[projectIndex + 1] = second.path
        try await run(argv)
        let counts = { (result: URL) throws -> [String: String] in
            Dictionary(uniqueKeysWithValues: try self.manifest(result).counts.map { ($0.path, $0.sha256) })
        }
        let firstCounts = try counts(firstResult)
        XCTAssertEqual(firstCounts.count, 2)
        XCTAssertEqual(try counts(try result(in: second)), firstCounts)
    }
}

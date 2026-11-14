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
    private func tx2gene(in folder: URL) throws -> URL {
        let text = try String(contentsOf: RNASeqFixtures.salmonRun("SRR896663").appendingPathComponent("quant.sf"), encoding: .utf8)
        let ids = text.split(separator: "\n").dropFirst().map { String($0.prefix { $0 != "\t" }) }
        let lines = ["transcript_id\tgene_id"] + ids.enumerated().map { "\($1)\tG\($0 / 3)" }
        let url = folder.appendingPathComponent("tx2gene.tsv")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The fixture's salmon folders and a tx2gene table, put in the project's `Inputs/` folder so the record names
    /// them by the project's own `@/` paths, which a load resolves. A record names a path outside the project as
    /// `<external>/<file name>`, which never resolves (`PortablePath`, rule 7), so only inputs in the project replay.
    private func salmonArguments(into project: URL) throws -> [String] {
        let inputs = project.appendingPathComponent("Inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let folders = try RNASeqFixtures.salmonRunIDs.map { run -> URL in
            let copy = inputs.appendingPathComponent(run, isDirectory: true)
            if !FileManager.default.fileExists(atPath: copy.path) {
                try FileManager.default.copyItem(at: RNASeqFixtures.salmonRun(run), to: copy)
            }
            return copy
        }
        return folders.map(\.path) + ["--project", project.path, "--name", "seqc-c1", "--tx2gene", try tx2gene(in: inputs).path]
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
    }

    /// ADJ-ARCH-51 item 3: salmon's own numbers go to the writer's `quality/samples.quality.tsv`, which the manifest
    /// hashes, and the record holds none of them, so each number has one home.
    func testSalmonsQualityNumbersAreInTheQualityTableAndNotInTheRecord() async throws {
        let project = try project("Quality")
        try await run(try salmonArguments(into: project))
        let result = try result(in: project)
        let entry = try XCTUnwrap(try manifest(result).quality, "the manifest lists no quality table")
        XCTAssertEqual(entry.path, RNASeqQualityTable.path)
        let bytes = try Data(contentsOf: result.appendingPathComponent(entry.path))
        XCTAssertEqual(entry.sha256, RNASeqResultBundle.sha256Hex(bytes))
        XCTAssertEqual(try RNASeqResultBundle.verifyChecksums(of: result), [])

        let quality = try XCTUnwrap(try RNASeqResultBundle.load(from: result).quality)
        XCTAssertEqual(quality.rows.map(\.sample), RNASeqFixtures.salmonRunIDs)
        for row in quality.rows {
            func value(_ column: String) -> String? { quality.columns.firstIndex(of: column).flatMap { row.values[$0] } }
            let metaURL = RNASeqFixtures.salmonRun(row.sample).appendingPathComponent("aux_info/meta_info.json")
            let meta = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any])
            let processed = try XCTUnwrap(meta["num_processed"] as? NSNumber)
            XCTAssertEqual(value("library_type"), "IU", row.sample)
            XCTAssertEqual(value("num_processed"), processed.stringValue, row.sample)
            XCTAssertEqual(value("salmon_version"), "2.11.0", row.sample)
        }
        XCTAssertNil(try record(result).options.resolvedDefaults["quality"], "the record holds no quality numbers")
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
        XCTAssertNil(try manifest(result).quality, "a plain table states no quality numbers (ADJ-ARCH-51 item 4)")
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

    // MARK: - The result's provenance folder (ADJ-ARCH-51 items 8 to 10)

    private func rollupURL(_ result: URL) -> URL {
        result.appendingPathComponent(ProvenanceWriter.bundleProvenanceDirectoryName, isDirectory: true)
            .appendingPathComponent(ProvenanceWriter.bundleRollupFilename)
    }

    /// The writer writes `provenance/` into the stage, so it arrives with the rename. The import's envelope names no
    /// output, so the roll-up is the envelope itself, and neither record names the stage.
    func testTheResultsBundleRecordMatchesItsRootRecordAndNamesNoStage() async throws {
        let project = try project("Layout")
        try await run(try salmonArguments(into: project))
        let result = try result(in: project)
        let rootURL = result.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let root = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(fromSidecar: rootURL))
        let rollup = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(fromSidecar: rollupURL(result)), "no roll-up")
        XCTAssertEqual(rollup.workflowName, root.workflowName)
        XCTAssertEqual(rollup.argv, root.argv)
        XCTAssertEqual(Array(root.argv.prefix(3)), [CLICommandIdentity.executableName, "import", "rnaseq"])
        for url in [rootURL, rollupURL(result)] {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains(".creating-"), "\(url.path) names the stage")
        }
        XCTAssertEqual(analyses(project).filter { $0.contains(".creating-") }, [], "no stage is left")
    }

    /// ADJ-ARCH-51 item 10: `provenance verify` on a result whose envelope names no output. The import's own plan and
    /// envelope go through the writer with a throwaway local key, as a run with a signing key set would sign them.
    func testProvenanceVerifyPassesOnASignedImportedResult() async throws {
        let project = try project("Signed")
        let arguments = try salmonArguments(into: project)
        let command = try ImportCommand.RNASeqSubcommand.parse(arguments)
        let plan = ImportCommand.RNASeqSubcommand.Plan(
            inputs: command.inputPaths.map { URL(fileURLWithPath: $0) }, isTable: false, unit: .estimated,
            tx2gene: command.tx2genePath.map { URL(fileURLWithPath: $0) }, sheet: nil, name: command.name,
            command: [CLICommandIdentity.executableName, "import", "rnaseq"] + arguments, explicit: [:])
        let (request, facts, _) = try plan.request()
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let result = analyses.appendingPathComponent("seqc-c1.lungfishrnaseq", isDirectory: true)
        let signer = LocalProvenanceSigningProvider(privateKey: "rs-bulk-import-throwaway-signing-key")
        try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: signer))
            .write(request, to: result, envelope: plan.envelope(facts: facts, startedAt: Date()))

        try await ProvenanceCommand.VerifySubcommand.parse([result.path]).run()
        try await ProvenanceCommand.VerifySubcommand.parse([rollupURL(result).path]).run()
    }
}

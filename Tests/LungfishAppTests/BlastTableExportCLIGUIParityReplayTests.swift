// BlastTableExportCLIGUIParityReplayTests.swift - The BLAST drawer table export in the app against its CLI leaf
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.33, ARCH ruling T5 condition 5 and ruling 1.7, BIO rulings 4, 6 and 7, on lane Q30's harness,
// reduced to C against C' in Phase 2.13 when the drawer's own writer and the in-process routes that needed it went.
// Each case runs on two sides that start as copies of one result folder that holds the file the drawer's result was
// read from, a `blast submit` record (`blast-result.json`) or a BLAST verification archive file. Both hold one
// result with a hit, a read with no hit and a quoted field.
//
// - Side C is the drawer's begin helper, `beginBlastTableExportOperation`, with the invocation the drawer builds for
//   the file. It begins the row and runs the built `lungfish-cli blast export table` on `CLIViewerExportRunner`.
// - Side C' is the harness's replay of the command side C's row recorded.
//
// C against C' compares everything under the contract's masks, and nothing is declared (R-A1, C4). Side C's table
// and record are pinned directly, since no writer is left to compare them with. The payload is the table builder's
// bytes with the shape the fixture predicts, the output's digest and size are the payload's, and the record names
// the leaf, the one file it read with its digest and the keys it resolves (BIO 4, 6 and 7), which
// `assertTheLeafRecord` checks.
//
// The cancel runs through the real transport. The leaf holds inside its transaction on
// `LUNGFISH_VIEWER_EXPORT_HOLD_FILE`, the row's Cancel stops it, and neither the output nor its record is left
// (ARCH ruling 1.6, X14). Every root lies at least five levels below the temporary folder, so the provenance walk
// of an input, which lists the input's folder and the four above it, never lists the temporary folder, which holds
// more than a hundred thousand entries (`SCR/lanes/12.31/12.31-cancel.md`).
//
// It launches the built lungfish-cli, so its name ends in ReplayTests, which sends it to the integration tier.

import CryptoKit
import Foundation
import XCTest
@testable import LungfishCore
@testable import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
private final class BlastExportFailureCalls {
    var messages: [String] = []
}

@MainActor
final class BlastTableExportCLIGUIParityReplayTests: XCTestCase {
    /// The two forms of file the drawer's result is read from, each in both table formats.
    enum Case: String, Sendable, CaseIterable {
        case archiveTSV
        case archiveCSV
        case submitRecordTSV
        case submitRecordCSV

        var isArchive: Bool { self == .archiveTSV || self == .archiveCSV }
        var format: ViewerExportDelimitedFormat { rawValue.hasSuffix("TSV") ? .tsv : .csv }
        var fileExtension: String { format.rawValue }
        var inputKind: String { isArchive ? "blast-verification-archive" : "blast-submit-record" }
    }

    /// The `resolved` keys the leaf writes (BIO 6 and 7).
    static let leafResolvedKeys: Set<String> = [
        "database", "inputKind", "outputByteCount", "program", "rid", "taxId", "taxonName", "totalReads",
    ]
    static let holdFileVariable = "LUNGFISH_VIEWER_EXPORT_HOLD_FILE"
    /// The folders a root lies below the temporary folder, at least, so no provenance walk reaches it.
    static let minimumDepth = 5

    private var scratch: URL!
    private var harness: RouteParityHarness!

    override func setUpWithError() throws {
        scratch = try TestTempDirectory.make(prefix: "blast-export-parity")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH, so no side can run"
        )
        harness = RouteParityHarness(cliBinary: cli, kind: .files, replayTimeout: .seconds(60))
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(scratch)
    }

    /// A `blast submit` record, the file the drawer's result is read from after a search, exported as TSV.
    func testASubmitRecordInTSVMatches() async throws {
        try await assertParity(.submitRecordTSV)
    }

    /// The same record exported as CSV, where a read id with a comma is quoted too.
    func testASubmitRecordInCSVMatches() async throws {
        try await assertParity(.submitRecordCSV)
    }

    /// An archive file, the form a restored Kraken2 search shows, exported as TSV.
    func testAnArchiveFileInTSVMatches() async throws {
        try await assertParity(.archiveTSV)
    }

    /// The same archive file exported as CSV.
    func testAnArchiveFileInCSVMatches() async throws {
        try await assertParity(.archiveCSV)
    }

    /// ARCH ruling T5 condition 3 and UX 4. When the file the drawer's result came from has gone, the leaf fails the
    /// row because its input is missing and names the path, the failure reaches the alert handler once, and the
    /// drawer holds no other writer. Nothing is written.
    func testAMissingFileFailsTheRowAndWritesNothing() async throws {
        let root = scratch.appendingPathComponent("missing/case/run/root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeFixture(.submitRecordTSV, in: root)
        let input = try Self.inputURL(.submitRecordTSV, in: root)
        let output = Self.outputURL(.submitRecordTSV, in: root)
        try FileManager.default.removeItem(at: input)
        let invocation = BlastVerificationTableExport.invocation(
            recordURL: input, format: .tsv, outputURL: output, force: false
        )

        let failures = BlastExportFailureCalls()
        let begun = try XCTUnwrap(BlastResultsDrawerTab.beginBlastTableExportOperation(
            invocation: invocation,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary)
        ) { failure in failures.messages.append(failure.message) })
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        guard case .failed(let failure) = outcome else { return XCTFail("the leaf refused, the run ended \(outcome)") }
        XCTAssertEqual(item?.state, .failed)
        XCTAssertEqual(failures.messages, [failure.message], "the alert handler gets the failure once")
        XCTAssertTrue(failure.message.contains(input.standardizedFileURL.path), failure.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a refusal leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: output).path))
    }

    /// ARCH ruling 1.6 and X14. The row's Cancel stops the leaf inside its transaction, the row reads Cancelled with
    /// no alert, and the row's command, cancelled on the launcher every CLI route uses, exits 125 inside the grace.
    /// Neither leaves the output or its record.
    func testACancelledExportExits125AndLeavesNoFileAndNoRecord() async throws {
        let root = scratch.appendingPathComponent("cancel/case/run/root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeFixture(.submitRecordTSV, in: root)
        let input = try Self.inputURL(.submitRecordTSV, in: root)
        let output = Self.outputURL(.submitRecordTSV, in: root)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: output)
        let hold = root.appendingPathComponent("held")
        XCTAssertGreaterThanOrEqual(Self.levels(of: root), Self.minimumDepth, "the root lies below the walk")
        XCTAssertGreaterThanOrEqual(Self.levels(of: input.deletingLastPathComponent()), Self.minimumDepth)
        let invocation = BlastVerificationTableExport.invocation(
            recordURL: input, format: .tsv, outputURL: output, force: false
        )

        let failures = BlastExportFailureCalls()
        let begun = try XCTUnwrap(BlastResultsDrawerTab.beginBlastTableExportOperation(
            invocation: invocation,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            environmentAdditions: [Self.holdFileVariable: hold.path]
        ) { failure in failures.messages.append(failure.message) })
        let held = try await Self.waitForFile(hold)
        XCTAssertTrue(held, "the leaf reached its transaction")
        OperationCenter.shared.cancel(id: begun.operationID)
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(item?.state, .cancelled)
        XCTAssertEqual(failures.messages, [], "a cancel shows no alert")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")

        try FileManager.default.removeItem(at: hold)
        let arguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(item?.cliCommand))
        let run = await RouteParityHarness.runCLI(
            harness.cliBinary, arguments: arguments, timeout: .seconds(60),
            environment: [Self.holdFileVariable: hold.path],
            cancelWhen: { FileManager.default.fileExists(atPath: hold.path) }
        )
        let observed = try XCTUnwrap(run.cancel, "the run was cancelled through the transport, it ended \(run.detail)")
        CLISIGTERMHarness.assertCancelledExit(status: observed.status, elapsed: observed.elapsed, detail: " \(run.detail)")
        await CLISIGTERMHarness.assertNoProcessLeft(observed.tree)
        XCTAssertEqual(run.end, .cancelled)
        XCTAssertTrue(run.stdout.contains("The export was cancelled. No file was written."), run.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "a cancel leaves no output")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path), "a cancel leaves no record")
    }
}

// MARK: - The fixture and the sides

extension BlastTableExportCLIGUIParityReplayTests {
    static let resultFolderName = "kraken2-run"
    static let submitFolderName = "Escherichia-coli-a"

    /// The output each side writes, in its root.
    static func outputURL(_ parityCase: Case, in root: URL) -> URL {
        root.appendingPathComponent("blast-hits.\(parityCase.fileExtension)")
    }

    static func envelope(_ parityCase: Case, in root: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.load(
            fromSidecar: ProvenanceRecorder.fileSidecarURL(for: outputURL(parityCase, in: root))
        ))
    }

    /// How many folders `url` lies below the temporary folder.
    static func levels(of url: URL) -> Int {
        func parts(_ url: URL) -> [String] {
            url.resolvingSymlinksInPath().path.split(separator: "/").map(String.init)
        }
        return parts(url).count - parts(FileManager.default.temporaryDirectory).count
    }

    /// A result with hits, a read with no hit and a quoted field, as the drawer's pin and the leaf's tests use.
    static var verification: BlastVerificationResult {
        let hits = [
            BlastHitSummary(
                rank: 1, accession: "NC_000001.1", organism: "Escherichia coli, strain \"K-12\"", taxId: 562,
                percentIdentity: 99.5, queryCoverage: 98.25, eValue: 1e-50, bitScore: 250.46, alignmentLength: 150
            ),
            BlastHitSummary(
                rank: 2, accession: "NC_000002.1", organism: nil, taxId: nil,
                percentIdentity: 90, queryCoverage: 80.126, eValue: 0.0, bitScore: 100.04, alignmentLength: 120
            ),
        ]
        return BlastVerificationResult(
            taxonName: "Escherichia coli",
            taxId: 562,
            readResults: [
                BlastReadResult(
                    id: "read,1", verdict: .verified, topHitOrganism: "Escherichia coli", topHitAccession: "NC_000001.1",
                    percentIdentity: 99.5, queryCoverage: 98.25, eValue: 1e-50, alignmentLength: 150, bitScore: 250.46,
                    topHits: hits, hasLCADisagreement: true, matchesQueriedTaxon: true
                ),
                BlastReadResult(id: "read_2", verdict: .unverified),
                BlastReadResult(
                    id: "read_3", verdict: .ambiguous, topHitOrganism: "Shigella", topHitAccession: "NC_000003.1",
                    percentIdentity: 88.126, queryCoverage: 70.5, eValue: 0.002, alignmentLength: 99, bitScore: 55.5
                ),
            ],
            submittedAt: Date(timeIntervalSince1970: 1_790_000_000),
            completedAt: Date(timeIntervalSince1970: 1_790_000_060),
            rid: "PIN-RID",
            blastProgram: "megablast",
            database: "core_nt"
        )
    }

    /// The result folder a Kraken2 run holds, with the one file the drawer's result is read from. The archive form
    /// is the file `BlastVerificationArchive.save` writes. The submit form is the `blast-result.json` of a
    /// `blast submit` folder, which sits in the same archive directory.
    static func makeFixture(_ parityCase: Case, in root: URL) throws {
        let resultFolder = root.appendingPathComponent(resultFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: resultFolder, withIntermediateDirectories: true)
        if parityCase.isArchive {
            _ = try BlastVerificationArchive.save(verification, request: nil, in: resultFolder, toolName: "lungfish-cli", toolKind: "cli")
            return
        }
        let folder = BlastVerificationArchive.directoryURL(for: resultFolder)
            .appendingPathComponent(submitFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let request = BlastVerificationRequest(
            taxonName: "Escherichia coli", taxId: 562, sequences: [(id: "read,1", sequence: "ACGTACGTAC")],
            database: BlastDatabaseID.coreNT.rawValue
        )
        let record = BlastSubmissionRecord(
            savedAt: Date(timeIntervalSince1970: 1_790_000_060),
            query: .init(fileName: BlastSubmissionRecord.queryFileName, sha256: String(repeating: "0", count: 64), sequenceCount: 3),
            lineage: .init(sourceResult: "@/Analyses/kraken2-run", taxId: 562, subsampleCount: 3, subsampleSeed: 0),
            search: .init(request),
            result: verification
        )
        try BlastSubmissionRecord.encoder.encode(record)
            .write(to: folder.appendingPathComponent(BlastSubmissionRecord.recordFileName))
    }

    /// The file the drawer's result was read from, in a side root.
    static func inputURL(_ parityCase: Case, in root: URL) throws -> URL {
        let resultFolder = root.appendingPathComponent(resultFolderName, isDirectory: true)
        if parityCase.isArchive {
            return try XCTUnwrap(BlastVerificationArchive.latestEntry(forTaxId: 562, in: resultFolder)?.url)
        }
        return BlastVerificationArchive.directoryURL(for: resultFolder)
            .appendingPathComponent(submitFolderName, isDirectory: true)
            .appendingPathComponent(BlastSubmissionRecord.recordFileName)
    }

    static func waitForFile(_ url: URL) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Side C. The drawer's invocation and begin helper, which run the built CLI behind the row on the shared runner.
    private func sideC(_ parityCase: Case, root: URL) async throws -> RouteParitySideOutcome {
        let invocation = BlastVerificationTableExport.invocation(
            recordURL: try Self.inputURL(parityCase, in: root),
            format: parityCase.format,
            outputURL: Self.outputURL(parityCase, in: root),
            force: false
        )
        let failures = BlastExportFailureCalls()
        guard let begun = BlastResultsDrawerTab.beginBlastTableExportOperation(
            invocation: invocation,
            runner: CLIViewerExportRunner(cliURLOverride: harness.cliBinary),
            onFailure: { failure in failures.messages.append(failure.message) }
        ) else {
            return RouteParitySideOutcome(end: .failed, detail: "the row did not start")
        }
        let outcome = await begun.task.value
        let item = OperationCenter.shared.items.first { $0.id == begun.operationID }
        switch outcome {
        case .completed:
            XCTAssertEqual(item?.state, .completed)
            XCTAssertEqual(failures.messages, [])
            return RouteParitySideOutcome(end: .completed, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .cancelled:
            return RouteParitySideOutcome(end: .cancelled, detail: item?.detail ?? "no row", recordedCommand: item?.cliCommand)
        case .failed(let failure):
            return RouteParitySideOutcome(end: .failed, detail: failure.message, recordedCommand: item?.cliCommand)
        }
    }

    /// Runs the case on its two sides and checks it. Each side completes, every root lies below the provenance walk,
    /// C against C' differs in nothing, and side C's table and record are what the leaf is predicted to write.
    @discardableResult
    private func assertParity(_ parityCase: Case) async throws -> RouteParityRuns {
        let runs = try await ReadsRouteParity.runCAndCPrime(
            harness,
            in: scratch.appendingPathComponent("cases/\(parityCase.rawValue)/run", isDirectory: true),
            fixture: { root in try Self.makeFixture(parityCase, in: root) },
            sideC: { root in try await self.sideC(parityCase, root: root) }
        )
        for run in [runs.c, runs.cPrime] {
            XCTAssertEqual(run.outcome.end, .completed, "side \(run.side): \(run.outcome.detail)")
            XCTAssertGreaterThanOrEqual(Self.levels(of: run.root), Self.minimumDepth, "side \(run.side) lies below the walk")
        }
        let input = try Self.inputURL(parityCase, in: runs.c.root)
        XCTAssertGreaterThanOrEqual(Self.levels(of: input.deletingLastPathComponent()), Self.minimumDepth, "the input's walk")
        let result = try harness.evaluate(parityCase, declared: [], runs: runs)
        RouteParityHarness.assertNoFailures(result.failures, in: "\(parityCase), C against C'")
        try assertTheLeafRecord(parityCase, runs)
        return runs
    }

    /// The table holds the hits of the result in the fixture.
    private static func assertTableShape(_ parityCase: Case, payload: Data) {
        let separator = parityCase.format.separator
        let lines = String(decoding: payload, as: UTF8.self).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 5, "a header, two hits, a read with no hit and a read with top-level fields only")
        guard lines.count == 5 else { return }
        XCTAssertTrue(lines[0].hasPrefix(["Read ID", "Verdict", "LCA Flag"].joined(separator: separator)), lines[0])
        let readID = parityCase.format == .csv ? "\"read,1\"" : "read,1"
        XCTAssertTrue(lines[1].hasPrefix([readID, BlastVerdict.verified.rawValue, "true", "1"].joined(separator: separator)), lines[1])
        XCTAssertTrue(lines[1].contains("\"Escherichia coli, strain \"\"K-12\"\"\""), "the quoted field, \(lines[1])")
        XCTAssertTrue(lines[2].hasPrefix(readID + separator), "the second hit of the same read, \(lines[2])")
        XCTAssertEqual(
            lines[3],
            ["read_2", BlastVerdict.unverified.rawValue, "false", "1", "", "", "", "", "", "", "", ""].joined(separator: separator),
            "a read with no hit"
        )
        XCTAssertTrue(lines[4].hasPrefix(["read_3", BlastVerdict.ambiguous.rawValue].joined(separator: separator)), lines[4])
    }

    /// Side C's table and record as the leaf writes them (BIO 4, 6 and 7). The payload is the table builder's bytes,
    /// the record's output digest and size are the payload's, the identity fields are the leaf's, the options hold
    /// the output format, the one file the leaf read comes with its digest, and the record's argv is the row's
    /// command (ARCH 2).
    private func assertTheLeafRecord(_ parityCase: Case, _ runs: RouteParityRuns) throws {
        let c = try Self.envelope(parityCase, in: runs.c.root)
        let payload = try Data(contentsOf: Self.outputURL(parityCase, in: runs.c.root))
        let builderBytes = BlastVerificationTableExport.tableContent(
            result: Self.verification, separator: parityCase.format.separator
        )
        XCTAssertEqual(payload, Data(builderBytes.utf8), "the payload is the table builder's bytes")
        Self.assertTableShape(parityCase, payload: payload)
        let output = try XCTUnwrap(c.output)
        XCTAssertEqual(
            output.checksumSHA256,
            SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            "the output digest"
        )
        XCTAssertEqual(output.fileSize, UInt64(payload.count), "the output size")
        XCTAssertEqual(c.options.resolvedDefaults["outputByteCount"]?.integerValue, payload.count)

        let rowArguments = try RouteParityHarness.arguments(ofLine: try XCTUnwrap(runs.c.outcome.recordedCommand))
        XCTAssertEqual(c.toolName, CLICommandIdentity.executableName)
        XCTAssertEqual(c.tool.kind, "cli")
        XCTAssertEqual(c.argv, [CLICommandIdentity.executableName] + rowArguments, "the record's argv is the row's command")
        XCTAssertEqual(c.durableReplayArgv, c.argv)
        XCTAssertEqual(c.workflowName, BlastVerificationTableExport.workflowName)
        XCTAssertEqual(c.options.explicit.keys.sorted(), ["outputFormat", "outputPath"])
        XCTAssertEqual(c.options.explicit["outputFormat"]?.stringValue, parityCase.fileExtension)
        XCTAssertTrue(c.options.defaults.isEmpty)

        let inputFile = try Self.inputURL(parityCase, in: runs.c.root)
        let digest = SHA256.hash(data: try Data(contentsOf: inputFile)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            Self.inputs(of: c, under: runs.c.root),
            [Self.relativeName(of: inputFile, under: runs.c.root): digest],
            "the one file the leaf read, with its digest, a BIO 6 prediction row"
        )
        let resolved = c.options.resolvedDefaults
        XCTAssertEqual(Set(resolved.keys), Self.leafResolvedKeys)
        XCTAssertEqual(resolved["inputKind"]?.stringValue, parityCase.inputKind)
        XCTAssertEqual(resolved["database"]?.stringValue, "core_nt")
        XCTAssertEqual(resolved["program"]?.stringValue, "megablast")
        XCTAssertEqual(resolved["rid"]?.stringValue, "PIN-RID")
        XCTAssertEqual(resolved["taxId"]?.integerValue, 562)
        XCTAssertEqual(resolved["taxonName"]?.stringValue, "Escherichia coli")
        XCTAssertEqual(resolved["totalReads"]?.integerValue, 3)
    }

    private static func relativeName(of file: URL, under root: URL) -> String {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return String(file.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(rootPath.count))
    }

    /// Each input's path below `root`, with its digest.
    private static func inputs(of envelope: ProvenanceEnvelope, under root: URL) -> [String: String] {
        let rootPaths = [root.standardizedFileURL.path, root.resolvingSymlinksInPath().standardizedFileURL.path]
        var inputs: [String: String] = [:]
        for file in envelope.files where file.role == .input {
            let rootPath = rootPaths.first { file.path.hasPrefix($0 + "/") }
            inputs[rootPath.map { String(file.path.dropFirst($0.count)) } ?? file.path] = file.checksumSHA256 ?? "no digest"
        }
        return inputs
    }
}

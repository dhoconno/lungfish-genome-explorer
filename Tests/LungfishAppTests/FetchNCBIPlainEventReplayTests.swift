// FetchNCBIPlainEventReplayTests.swift - lungfish-cli fetch ncbi --save-to speaks events under --format json
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45 M1b, ruling section 2. Every `fetch genome` mode prints events (lane A44), and
// `fetch ncbi --bundle` does since M1, so the plain mode that saves one file for all its accessions
// prints them too, with no split of the contract row. These tests run the built CLI on a loopback
// NCBI stand-in that answers the E-utilities fetches of the pinned GenBank record. A run is a
// `start` line, one `progress` line for each accession, a `log` line at level `warning` for a GFF3
// with no feature rows, and one `complete` line that names the `--save-to` file in `outputs`, or one
// `failed` line. Standard output holds nothing but those lines. With `LUNGFISH_RECAPTURE_CLI_EVENTS=1`
// the complete run writes its transcript, `complete-save-to`. Text mode keeps its lines.
//
// It launches the built CLI, so its name ends in ReplayTests, which sends it to the integration tier.

import Foundation
import XCTest
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishWorkflow

final class FetchNCBIPlainEventReplayTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fetch-ncbi-plain")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// What one run of the CLI printed and how it ended.
    private struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
        let work: URL

        var lines: [String] { stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) }

        var events: [CLIEvent] {
            let decoder = CLIEventLineDecoder()
            return lines.compactMap { try? decoder.decode(line: $0) }
        }
    }

    /// Runs `fetch ncbi <accessions> <options>` on a stand-in that serves the pinned GenBank record and,
    /// as its GFF3, `gff3`. `options` may name `$FILE`, which becomes `records.gb` in the run's folder.
    private func run(_ accessions: [String], options: [String], gff3: String = NCBIDownloadPinFixtures.genBankGFF3) async throws -> Run {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let cli = try XCTUnwrap(
            CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: products),
            "No lungfish-cli beside \(products.path) and none named by LUNGFISH_CLI_PATH")
        let server = try LoopbackHTTPStandIn.start { request in
            func value(_ name: String) -> String? { request.queryItems.first { $0.name == name }?.value }
            guard request.path == "/entrez/eutils/efetch.fcgi" else { return .notFound }
            let record = NCBIDownloadPinFixtures.genBankRecord
            switch (value("id"), value("rettype")) {
            case (NCBIDownloadPinFixtures.genBankAccession, "gb"): return .text(record)
            case (NCBIDownloadPinFixtures.genBankAccession, "gff3"): return .text(gff3)
            case (NCBIGenomeStandIn.recordWithoutGFF3Accession, "gb"): return .text(NCBIGenomeStandIn.aboutRecordWithoutGFF3(record))
            default: return .notFound
            }
        }
        defer { server.stop() }
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let file = work.appendingPathComponent("records.gb").path
        let result = await RouteParityHarness.runCLI(
            cli,
            arguments: ["fetch", "ncbi"] + accessions + options.map { $0 == "$FILE" ? file : $0 },
            timeout: .seconds(60),
            environment: [NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString, "NCBI_API_KEY": ""])
        return Run(status: result.status ?? -1, stdout: result.stdout, stderr: result.stderr, work: work)
    }

    func testAPlainRunNamesTheSavedFile() async throws {
        let accessions = [NCBIDownloadPinFixtures.genBankAccession, NCBIGenomeStandIn.recordWithoutGFF3Accession]
        let run = try await run(accessions, options: ["--save-to", "$FILE", "--format", "json"])
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertEqual(run.events.count, run.lines.count, "standard output holds only event lines:\n\(run.stdout)")
        let file = run.work.appendingPathComponent("records.gb")
        guard case .start? = run.events.first else { return XCTFail("The run starts with a start line:\n\(run.stdout)") }
        XCTAssertEqual(run.events.filter { if case .progress = $0 { true } else { false } }.count, accessions.count)
        guard case let .complete(outputs, message)? = run.events.last else { return XCTFail("The run ends with a complete line:\n\(run.stdout)") }
        XCTAssertEqual(outputs.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, [file.resolvingSymlinksInPath().path])
        XCTAssertEqual(message, "Fetched 2 record(s)")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains(NCBIDownloadPinFixtures.genBankAccession), "the file holds the first record")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.appendingPathExtension("lungfish-provenance.json").path))

        let lines = run.lines.map { FetchGenomeEventTranscriptReplayTests.normalized($0, work: run.work) }
        let url = CLIEventTranscriptLocation.url(leaf: "fetch ncbi", name: "complete-save-to")
        if ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_CLI_EVENTS"] == "1" {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(lines.first, expected.first, "The run starts as complete-save-to.ndjson does")
        XCTAssertEqual(lines.last, expected.last, "The run ends as complete-save-to.ndjson does")
    }

    func testAGFF3WithNoFeatureRowsIsAWarningEvent() async throws {
        let run = try await run(
            [NCBIDownloadPinFixtures.genBankAccession],
            options: ["--fetch-format", "gff3", "--save-to", "$FILE", "--format", "json"],
            gff3: "##gff-version 3\n")
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertEqual(run.events.count, run.lines.count, "standard output holds only event lines:\n\(run.stdout)")
        let warnings = run.events.compactMap { event -> String? in
            if case let .log(level, message) = event, level == .warning { return message }
            return nil
        }
        XCTAssertEqual(warnings.count, 1, run.stdout)
        XCTAssertTrue(warnings.first?.contains("no GFF3 feature rows") ?? false, "\(warnings)")
        guard case .complete? = run.events.last else { return XCTFail("The run ends with a complete line:\n\(run.stdout)") }
    }

    func testAFailedPlainRunEndsWithAFailedLineAndSavesNothing() async throws {
        let run = try await run(["ZZ999999.1"], options: ["--save-to", "$FILE", "--format", "json"])
        XCTAssertEqual(run.status, 1, run.stderr)
        XCTAssertEqual(run.events.count, run.lines.count, "standard output holds only event lines:\n\(run.stdout)")
        guard case let .failed(message, _)? = run.events.last else { return XCTFail("The run ends with a failed line:\n\(run.stdout)") }
        XCTAssertTrue(message.contains("ZZ999999.1"), message)
        XCTAssertFalse(run.events.contains { if case .complete = $0 { true } else { false } })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: run.work.path), [], "a failed run saves nothing")
    }

    /// Text mode keeps its lines on standard output and prints no event.
    func testTextModeKeepsItsLines() async throws {
        let run = try await run([NCBIDownloadPinFixtures.genBankAccession], options: ["--save-to", "$FILE"])
        XCTAssertEqual(run.status, 0, run.stderr)
        let file = run.work.appendingPathComponent("records.gb")
        XCTAssertEqual(run.lines.count, 2, run.stdout)
        XCTAssertTrue(run.lines.first?.hasSuffix("Fetching 1 accession(s) from NCBI nucleotide...") ?? false, run.stdout)
        XCTAssertTrue(run.lines.last?.hasSuffix("Saved to \(file.path)") ?? false, run.stdout)
        XCTAssertEqual(run.events, [], "text mode prints no event")
    }
}

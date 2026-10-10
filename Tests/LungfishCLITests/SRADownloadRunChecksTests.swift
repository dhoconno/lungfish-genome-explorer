// SRADownloadRunChecksTests.swift - fetch sra download takes one run, keeps it whole and records what served it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

/// Lane L1 of sub-phase 2.1 checks four things in `lungfish-cli fetch sra download`.
/// - it takes one run accession (F5-N6),
/// - it applies the window's lone-mate rule, reading NCBI's LibraryLayout
///   when ENA's record is missing (F7-N1),
/// - it fails with one line when no archive serves the run (F5-N3),
/// - its provenance marks the steps of a failed attempt and records the
///   sra-tools version, as the window's does (F5-N8 and the MSA session's
///   follow-up on the NCBI-to-ENA fallback).
/// ENA and NCBI are a scripted `SRAScriptedArchives` and the SRA Toolkit a
/// scripted runner, so no test reaches the network or spawns a tool.
final class SRADownloadRunChecksTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sra-cli-run-checks")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testOnlyARunAccessionIsAccepted() throws {
        for accession in ["SRR11140748", "ERR12390094", "DRR000001"] {
            XCTAssertNoThrow(try SRADownloadSubcommand.parse([accession]), accession)
        }
        for accession in ["SRX100", "SRP100", "PRJNA100", "srr100", " SRR100", "SRR100/..", ".."] {
            XCTAssertThrowsError(try SRADownloadSubcommand.parse([accession]), accession) { error in
                let message = SRADownloadSubcommand.message(for: error)
                XCTAssertTrue(message.contains("one run accession"), message)
            }
        }
    }

    func testALoneMateOneOfARunNCBIListsAsPairedFailsAndIsRemoved() async throws {
        let archives = SRAScriptedArchives()
        archives.listOnNCBI("SRR1", layout: "PAIRED")
        let output = root.appendingPathComponent("out", isDirectory: true)

        do {
            _ = try await Self.download(
                "SRR1", into: output, archives: archives,
                toolkit: Self.toolkit(writes: ["SRR1_1.fastq"]), flags: ["--use-toolkit"]
            )
            XCTFail("a lone mate 1 of a run NCBI lists as paired must fail")
        } catch {
            let message = error.localizedDescription
            XCTAssertFalse(message.contains("\n"), message)
            XCTAssertTrue(message.contains("Only mate 1 of SRR1 arrived and NCBI lists the run as paired"), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("SRR1_1.fastq").path))
        XCTAssertNil(ProvenanceRecorder.load(from: output), "a refused run records no download")
        XCTAssertEqual(archives.ncbiRequests, ["ncbi SRR1"])
    }

    func testOneFileOfARunNCBIListsAsPairedIsKeptWithTheWarningRecorded() async throws {
        let archives = SRAScriptedArchives()
        archives.listOnNCBI("SRR1", layout: "PAIRED")
        let output = root.appendingPathComponent("out", isDirectory: true)

        let run = try await Self.download(
            "SRR1", into: output, archives: archives,
            toolkit: Self.toolkit(writes: ["SRR1.fastq"]), flags: ["--use-toolkit"]
        )

        XCTAssertEqual(
            run.parameters["layoutWarning"],
            .string("NCBI lists SRR1 as paired but only one read file arrived; imported as single-end reads")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("SRR1.fastq").path))
    }

    func testThePairServedByTheToolkitAsksNCBINothing() async throws {
        let archives = SRAScriptedArchives()
        let output = root.appendingPathComponent("out", isDirectory: true)

        let run = try await Self.download(
            "SRR1", into: output, archives: archives,
            toolkit: Self.toolkit(writes: ["SRR1_1.fastq", "SRR1_2.fastq"]), flags: ["--use-toolkit"]
        )

        XCTAssertNil(run.parameters["layoutWarning"])
        XCTAssertEqual(archives.ncbiRequests, [])
    }

    func testAToolkitFailureThenENAMarksTheToolkitStepsAndDependsOnENAOnly() async throws {
        let archives = SRAScriptedArchives()
        archives.listOnENA("SRR1", .init(files: Self.pair("SRR1")))
        let output = root.appendingPathComponent("out", isDirectory: true)

        let run = try await Self.download(
            "SRR1", into: output, archives: archives,
            toolkit: Self.toolkit(writes: [], fasterqExit: 3), flags: ["--prefer-source", "ncbi"]
        )

        XCTAssertEqual(run.parameters["downloadSource"], .string("ENA (SRA Toolkit failed)"))
        XCTAssertEqual(run.steps.map(\.toolName), ["prefetch", "fasterq-dump", "https-download", "https-download", "lungfish-cli"])
        let failed = run.steps.filter { $0.resolvedOptions?["attempt"] == .string("failed") }
        XCTAssertEqual(failed.map(\.toolName), ["prefetch", "fasterq-dump"], "the failed toolkit attempt is marked")
        let downloads = run.steps.filter { $0.toolName == "https-download" }
        XCTAssertEqual(run.steps.last?.dependsOn, downloads.map(\.id), "the command depends only on what served the run")
    }

    func testAMirrorFailureThenTheToolkitMarksTheENAStepAndRecordsTheSRAToolsVersion() async throws {
        let archives = SRAScriptedArchives()
        archives.listOnENA("SRR1", .init(files: Self.pair("SRR1")))
        archives.failOnMirror("SRR1_2.fastq.gz", .status(503))
        let output = root.appendingPathComponent("out", isDirectory: true)

        let run = try await Self.download(
            "SRR1", into: output, archives: archives, toolkit: Self.toolkit(writes: ["SRR1_1.fastq", "SRR1_2.fastq"])
        )

        XCTAssertEqual(run.parameters["downloadSource"], .string("SRA Toolkit (ENA transfer failed)"))
        XCTAssertEqual(run.parameters["selectedStrategy"], .string("sra-toolkit-fallback"))
        XCTAssertEqual(
            run.parameters["fallbackMessage"],
            .string("ENA could not serve SRR1, so the SRA Toolkit (prefetch + fasterq-dump) fetches it instead. ENA's mirror answered HTTP 503 for SRR1_2.fastq.gz")
        )
        XCTAssertEqual(run.steps.map(\.toolName), ["https-download", "prefetch", "fasterq-dump", "lungfish-cli"])
        XCTAssertEqual(run.steps[0].resolvedOptions?["attempt"], .string("failed"), "mate 1 arrived in a failed attempt")
        XCTAssertNil(run.steps[1].resolvedOptions?["attempt"], "the toolkit step that served the run is not marked failed")
        let version = try XCTUnwrap(ManagedToolLock.loadFromBundle().tool(named: "sra-tools")?.version)
        XCTAssertEqual(run.steps[1].toolVersion, "sra-tools \(version)")
        XCTAssertEqual(run.steps.last?.dependsOn, [run.steps[1].id, run.steps[2].id])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: output.path).filter { $0.hasSuffix(".gz") },
            [],
            "no file of the failed ENA attempt stays"
        )
    }

    func testWhenBothArchivesFailTheCommandFailsWithOneLine() async throws {
        let archives = SRAScriptedArchives()
        archives.takeENADown()
        let output = root.appendingPathComponent("out", isDirectory: true)

        do {
            _ = try await Self.download("SRR1", into: output, archives: archives, toolkit: Self.toolkit(writes: [], prefetchExit: 3))
            XCTFail("both archives failed")
        } catch {
            let message = error.localizedDescription
            XCTAssertFalse(message.contains("\n"), message)
            XCTAssertTrue(message.contains("ENA: ENA returned HTTP 500 (server error) for SRR1; Toolkit: prefetch exited with status 3."), message)
        }
    }

    // MARK: - Helpers

    static let mate1 = Data([
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    ])
    static let mate2 = Data([
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    ])

    static func pair(_ run: String) -> [(name: String, data: Data)] {
        [("\(run)_1.fastq.gz", mate1), ("\(run)_2.fastq.gz", mate2)]
    }

    /// Runs `fetch sra download <accession> --output-dir <folder> --quiet
    /// <flags>` against the scripted archives and toolkit and returns the
    /// provenance it wrote.
    @discardableResult
    static func download(
        _ accession: String,
        into folder: URL,
        archives: SRAScriptedArchives,
        toolkit: SRAToolkitRunner,
        flags: [String] = []
    ) async throws -> WorkflowRun {
        let service = SRAService(
            ncbiService: NCBIService(httpClient: archives, environment: [:]),
            httpClient: archives,
            toolkitRunner: toolkit
        )
        let command = try SRADownloadSubcommand.parse([accession, "--output-dir", folder.path, "--quiet"] + flags)
        try await SRADownloadSubcommand.$makeService.withValue({ service }) {
            try await command.run()
        }
        return try XCTUnwrap(ProvenanceRecorder.load(from: folder))
    }

    /// A toolkit whose `prefetch` writes the run's archive or fails, and whose
    /// `fasterq-dump` writes `writes` and exits with `fasterqExit`.
    static func toolkit(writes names: [String], prefetchExit: Int32 = 0, fasterqExit: Int32 = 0) -> SRAToolkitRunner {
        let prefetch = URL(fileURLWithPath: "/managed/sra-tools/bin/prefetch")
        return SRAToolkitRunner(
            prefetch: prefetch,
            fasterqDump: URL(fileURLWithPath: "/managed/sra-tools/bin/fasterq-dump")
        ) { executable, arguments in
            let outputIndex = try XCTUnwrap(arguments.firstIndex(of: "-O"))
            let output = URL(fileURLWithPath: arguments[outputIndex + 1], isDirectory: true)
            if executable == prefetch {
                guard prefetchExit == 0 else {
                    return SRAToolkitRunner.Result(
                        exitCode: prefetchExit,
                        stderr: "2026-10-06T12:00:00 prefetch.3.4.1 err: name not found\n\n2026-10-06T12:00:00 prefetch.3.4.1: 1) failed to download"
                    )
                }
                let folder = output.appendingPathComponent(arguments[0], isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("archive".utf8).write(to: folder.appendingPathComponent("\(arguments[0]).sra"))
                return SRAToolkitRunner.Result(exitCode: 0)
            }
            for name in names {
                try Data("@\(name).1\nACGT\n+\nIIII\n".utf8).write(to: output.appendingPathComponent(name))
            }
            return SRAToolkitRunner.Result(exitCode: fasterqExit, stderr: fasterqExit == 0 ? "" : "fasterq-dump.3.4.1 err: disk full\nfasterq-dump quit with error code 3")
        }
    }
}

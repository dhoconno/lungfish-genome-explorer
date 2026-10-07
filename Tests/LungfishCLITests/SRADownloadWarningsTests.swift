// SRADownloadWarningsTests.swift - fetch sra download names what it leaves out, a refusal and a cancellation for what they are
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

/// Review B of sub-phase 2.1, the `lungfish-cli fetch sra download` side.
/// - B-N2. A third read file, `<run>_3`, that ENA lists or the SRA Toolkit
///   writes is named in a warning the command prints and records under
///   `layoutWarning`.
/// - B-N3. A lone mate 1 of a run neither archive gives a layout for is kept
///   as single reads with a warning, and a cancelled NCBI lookup cancels the
///   download and leaves no mate behind.
/// - B-N6. A layout refusal is reported as a refusal in one line, never as a
///   network error, and with `--format json` the status and warning lines go
///   to standard error, so standard output is the JSON result alone.
/// ENA and NCBI are a scripted `SRAScriptedArchives` and the SRA Toolkit a
/// scripted runner, so no test reaches the network or spawns a tool.
final class SRADownloadWarningsTests: XCTestCase {

    private var root: URL!
    private var output: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sra-cli-warnings")
        output = root.appendingPathComponent("out", isDirectory: true)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    static let thirdFileWarning = "SRR1_3.fastq.gz holds reads beyond mates 1 and 2 and is not imported with the run"

    // MARK: - B-N2

    func testAThirdReadFileENAListsIsWarnedAndRecorded() async throws {
        let archives = SRAScriptedArchives()
        archives.listOnENA("SRR1", .init(files: Self.runWithAThirdFile))

        let run = try await SRADownloadRunChecksTests.download(
            "SRR1", into: output, archives: archives, toolkit: SRADownloadRunChecksTests.toolkit(writes: [])
        )

        XCTAssertEqual(run.parameters["layoutWarning"], .string(Self.thirdFileWarning))
    }

    func testAThirdReadFileTheToolkitWritesIsWarnedAndRecorded() async throws {
        let archives = SRAScriptedArchives()

        let run = try await SRADownloadRunChecksTests.download(
            "SRR1", into: output, archives: archives,
            toolkit: SRADownloadRunChecksTests.toolkit(writes: ["SRR1_1.fastq", "SRR1_2.fastq", "SRR1_3.fastq"]),
            flags: ["--use-toolkit"]
        )

        XCTAssertEqual(
            run.parameters["layoutWarning"],
            .string("SRR1_3.fastq holds reads beyond mates 1 and 2 and is not imported with the run")
        )
    }

    func testInTextFormatTheWarningIsPrintedWithTheResult() async throws {
        let archives = SRAScriptedArchives()
        archives.listOnENA("SRR1", .init(files: Self.runWithAThirdFile))

        let printed = try await capturingOutput {
            try await self.run(["SRR1", "--output-dir", self.output.path], archives: archives)
        }

        XCTAssertTrue(printed.standardOutput.contains(Self.thirdFileWarning), printed.standardOutput)
    }

    // MARK: - B-N3

    func testALoneMateOneOfARunNeitherArchiveListsIsKeptWithTheWarningRecorded() async throws {
        let archives = SRAScriptedArchives()
        archives.failOnNCBI(.down)

        let run = try await SRADownloadRunChecksTests.download(
            "SRR1", into: output, archives: archives,
            toolkit: SRADownloadRunChecksTests.toolkit(writes: ["SRR1_1.fastq"]), flags: ["--use-toolkit"]
        )

        XCTAssertEqual(
            run.parameters["layoutWarning"],
            .string("No layout of SRR1 came from ENA or NCBI and only SRR1_1.fastq arrived, so its reads import as single-end reads")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("SRR1_1.fastq").path))
        XCTAssertEqual(archives.ncbiRequests, ["ncbi SRR1"])
    }

    func testACancelledNCBILookupCancelsTheDownloadAndLeavesNoMate() async throws {
        let archives = SRAScriptedArchives()
        archives.failOnNCBI(.cancelled)
        let output = output!

        let download = Task {
            try await SRADownloadRunChecksTests.download(
                "SRR1", into: output, archives: archives,
                toolkit: SRADownloadRunChecksTests.toolkit(writes: ["SRR1_1.fastq"]), flags: ["--use-toolkit"]
            )
        }

        do {
            _ = try await download.value
            XCTFail("a cancelled NCBI lookup must cancel the download")
        } catch {
            guard case .cancelled? = error as? CLIError else {
                return XCTFail("expected a cancellation, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("SRR1_1.fastq").path), "no lone mate stays")
        XCTAssertNil(ProvenanceRecorder.load(from: output), "a cancelled download records nothing")
    }

    // MARK: - B-N6

    func testALayoutRefusalIsReportedAsARefusalNotANetworkError() async throws {
        let archives = SRAScriptedArchives()
        archives.listOnNCBI("SRR1", layout: "PAIRED")

        do {
            _ = try await SRADownloadRunChecksTests.download(
                "SRR1", into: output, archives: archives,
                toolkit: SRADownloadRunChecksTests.toolkit(writes: ["SRR1_1.fastq"]), flags: ["--use-toolkit"]
            )
            XCTFail("a lone mate 1 of a run NCBI lists as paired must be refused")
        } catch {
            let message = error.localizedDescription
            XCTAssertFalse(message.contains("\n"), message)
            XCTAssertFalse(message.contains("Network error"), message)
            XCTAssertFalse(message.contains("Download failed"), message)
            XCTAssertTrue(
                message.contains("Only mate 1 of SRR1 arrived and NCBI lists the run as paired, so the run was refused"),
                message
            )
            XCTAssertNotEqual((error as? CLIError)?.exitCode, .networkError)
        }
    }

    func testWithJSONFormatStandardOutputIsTheResultAndTheWarningGoesToStandardError() async throws {
        let archives = SRAScriptedArchives()
        archives.listOnENA("SRR1", .init(files: Self.runWithAThirdFile))

        let printed = try await capturingOutput {
            try await self.run(["SRR1", "--output-dir", self.output.path, "--format", "json"], archives: archives)
        }

        let result = try JSONSerialization.jsonObject(with: Data(printed.standardOutput.utf8)) as? [String: Any]
        XCTAssertEqual(result?["accession"] as? String, "SRR1", printed.standardOutput)
        XCTAssertTrue(printed.standardError.contains(Self.thirdFileWarning), printed.standardError)
    }

    // MARK: - Helpers

    static let mate3 = Data([
        0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
    ])

    /// Both mates of SRR1 and a third read file, as ENA lists a run whose
    /// spots hold three reads.
    static var runWithAThirdFile: [(name: String, data: Data)] {
        SRADownloadRunChecksTests.pair("SRR1") + [("SRR1_3.fastq.gz", mate3)]
    }

    /// Runs `fetch sra download` with `arguments` against `archives`, with a
    /// toolkit that is never needed.
    private func run(_ arguments: [String], archives: SRAScriptedArchives) async throws {
        let service = SRAService(
            ncbiService: NCBIService(httpClient: archives, environment: [:]),
            httpClient: archives,
            toolkitRunner: SRADownloadRunChecksTests.toolkit(writes: [])
        )
        let command = try SRADownloadSubcommand.parse(arguments)
        try await SRADownloadSubcommand.$makeService.withValue({ service }) {
            try await command.run()
        }
    }

    /// Runs `operation` with standard output and standard error written to
    /// files, and returns what each received.
    private func capturingOutput(
        _ operation: () async throws -> Void
    ) async throws -> (standardOutput: String, standardError: String) {
        let outURL = root.appendingPathComponent("stdout.txt")
        let errURL = root.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let outFile = try FileHandle(forWritingTo: outURL)
        let errFile = try FileHandle(forWritingTo: errURL)
        fflush(stdout)
        fflush(stderr)
        let savedOut = dup(STDOUT_FILENO)
        let savedErr = dup(STDERR_FILENO)
        dup2(outFile.fileDescriptor, STDOUT_FILENO)
        dup2(errFile.fileDescriptor, STDERR_FILENO)
        var thrown: Error?
        do {
            try await operation()
        } catch {
            thrown = error
        }
        fflush(stdout)
        fflush(stderr)
        dup2(savedOut, STDOUT_FILENO)
        dup2(savedErr, STDERR_FILENO)
        close(savedOut)
        close(savedErr)
        try outFile.close()
        try errFile.close()
        if let thrown {
            throw thrown
        }
        return (
            try String(contentsOf: outURL, encoding: .utf8),
            try String(contentsOf: errURL, encoding: .utf8)
        )
    }
}

// AssembleCommandFinishedFolderTests.swift - assemble never runs into a folder that holds a finished assembly
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REPLACED (ruling BIO-ASSEMBLY-REPLACED, Fix D). The app runs this command, so the one refusal covers the
// app too. The file `assembly-result.json` is the test, because the app pre-creates an empty folder for the sidebar and a
// failed run leaves a folder with no record. A stand-in SPAdes lets the whole command run in this process.

import ArgumentParser
import Darwin
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishCore
@testable import LungfishWorkflow
import LungfishTestSupport

final class AssembleCommandFinishedFolderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "assemble-finished-folder")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testAssembleRefusesAFolderThatHoldsAFinishedRun() async throws {
        let output = root.appendingPathComponent("Assemblies/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let record = output.appendingPathComponent("assembly-result.json")
        let contigs = output.appendingPathComponent("contigs.fasta")
        try "{\"finished\":true}\n".write(to: record, atomically: true, encoding: .utf8)
        try ">k141_0\nACGTACGT\n".write(to: contigs, atomically: true, encoding: .utf8)

        let run = try await assemble(into: output)

        XCTAssertEqual((run.error as? ExitCode)?.rawValue, CLIExitCode.inputError.rawValue, "\(String(describing: run.error))")
        let failed = try XCTUnwrap(run.failed)
        XCTAssertTrue(failed.contains("already holds a finished assembly"), failed)
        XCTAssertTrue(failed.contains("Choose another name or output folder"), "the refusal says what to try next: \(failed)")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: output.path).sorted(),
            ["assembly-result.json", "contigs.fasta"],
            "no assembler started in the folder"
        )
        XCTAssertEqual(try String(contentsOf: record, encoding: .utf8), "{\"finished\":true}\n")
        XCTAssertEqual(try String(contentsOf: contigs, encoding: .utf8), ">k141_0\nACGTACGT\n", "the finished run is untouched")
    }

    func testAssembleRunsInAnEmptyPreCreatedFolder() async throws {
        let output = root.appendingPathComponent("Assemblies/demo", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let run = try await assemble(into: output)

        XCTAssertNil(run.error, "\(String(describing: run.error))")
        XCTAssertNil(run.failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("assembly-result.json").path))
    }

    // MARK: - Running the command

    private struct Run {
        let failed: String?
        let error: (any Error)?
    }

    /// Runs `assemble --format json` on one read file with the project `demo` and `--output output`, and reads its events.
    private func assemble(into output: URL) async throws -> Run {
        let reads = root.appendingPathComponent("sample.fastq")
        try "@r1\nACGTACGT\n+\nIIIIIIII\n@r2\nACGTACGT\n+\nIIIIIIII\n".write(to: reads, atomically: true, encoding: .utf8)
        let command = try AssembleCommand.parse([
            reads.path, "--assembler", "spades", "--read-type", "illumina-short-reads",
            "--project-name", "demo", "--threads", "1", "--output", output.path, "--format", "json",
        ])
        let spades = try StandInSPAdesConda(root: root.appendingPathComponent("tool", isDirectory: true))
        let (standardOutput, error) = await Self.capturingStandardOutput {
            try await command.execute(pipeline: ManagedAssemblyPipeline(condaManager: spades.condaManager))
        }
        var failed: String?
        for line in standardOutput.split(separator: "\n") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if event["event"] as? String == "failed" { failed = event["error"] as? String }
        }
        return Run(failed: failed, error: error)
    }

    /// Runs `body` with standard output in a file and returns what it printed and what it threw.
    private static func capturingStandardOutput(_ body: () async throws -> Void) async -> (String, (any Error)?) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("assemble-stdout-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return ("", CocoaError(.fileWriteUnknown)) }
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        dup2(handle.fileDescriptor, STDOUT_FILENO)
        var thrown: (any Error)?
        do {
            try await body()
        } catch {
            thrown = error
        }
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        try? handle.close()
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return (text, thrown)
    }
}

// ImportFastqEventStreamTests.swift - What `import fastq --format json` prints on each stream
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishWorkflow
@testable import LungfishCLI

/// Lane Q4 of Phase 2.7 retired the private stream S1. With `--format json` standard output holds
/// version 2 events only, one `start` line first and one `complete` or `failed` line last, and the
/// human text goes to standard error. The runs need no external tool. The checked-in transcripts in
/// `Tests/Fixtures/cli-events/commands/import-fastq` come from real runs of the built CLI.
final class ImportFastqEventStreamTests: XCTestCase {
    func testAPairWhoseThirdFileIsLeftOutCompletesWithItsBundleAndTwoWarnings() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let files = try [
            scratch.write("download/SRR125_1.fastq", Self.records(["SRR125.1.1 1", "SRR125.2.1 2"], bases: "ACGTACGT")),
            scratch.write("download/SRR125_2.fastq", Self.records(["SRR125.1.2 1", "SRR125.2.2 2"], bases: "TTGGCCAA")),
            scratch.write("download/SRR125.fastq", Self.records(["SRR125.3.1 3"], bases: "GATTACAG")),
        ]

        let output = try await Self.run(files.map(\.path) + ["--pairing", "paired"], in: scratch)

        XCTAssertNil(output.thrown)
        let lines = try Self.events(output)
        XCTAssertEqual(lines.first?.event, .start(message: "Starting FASTQ import"))
        let bundle = "/work/Project.lungfish/Imports/SRR125.lungfishfastq"
        XCTAssertEqual(lines.last?.event, .complete(outputs: [bundle], message: "Imported 1 sample(s)"))
        XCTAssertEqual(lines.last?.artifacts.map(\.role), ["bundle"])
        XCTAssertEqual(lines.last?.artifacts.first?.kind, "fastq")
        XCTAssertEqual(lines.last?.artifacts.first?.provenancePath, bundle + "/.lungfish-provenance.json")
        let warnings = lines.compactMap { line -> String? in
            guard case let .log(.warning, message)? = line.event else { return nil }
            return message
        }
        XCTAssertEqual(warnings.count, 2, "\(warnings)")
        XCTAssertTrue(warnings.first?.hasPrefix("SRR125 — SRR125.fastq was not joined to SRR125_1.fastq") == true, "\(warnings)")
        XCTAssertEqual(warnings.last, "SRR125 skipped: Bundle already exists")
        let fractions = lines.compactMap { line -> Double? in
            guard case let .progress(fraction, _)? = line.event else { return nil }
            return fraction
        }
        XCTAssertEqual(fractions, fractions.sorted(), "the bar only moves forward")
        XCTAssertTrue(output.standardError.contains("FASTQ Import"), "the human text is on standard error")
    }

    func testASampleTheRecipeRefusesEndsInOneFailedLine() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let file = try scratch.write("download/Solo.fastq", Self.records(["Solo.1 1", "Solo.2 2"], bases: "ACGTACGT"))

        let output = try await Self.run([file.path, "--pairing", "single", "--recipe", "wgs"], in: scratch)

        XCTAssertNotNil(output.thrown)
        let lines = try Self.events(output)
        let failure = "Solo: Recipe 'Illumina WGS Standard' cannot be applied to sample 'Solo': requires paired-end reads "
            + "(R1 and R2), but only R1 was detected."
        XCTAssertEqual(lines.last?.event, .failed(message: failure, detail: nil))
        XCTAssertTrue(lines.contains { $0.event == .log(level: .error, message: "Solo failed: " + failure.dropFirst("Solo: ".count)) })
    }

    func testAnInputThatDoesNotExistEndsInOneFailedLine() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }

        let output = try await Self.run([scratch.root.appendingPathComponent("missing.fastq").path], in: scratch)

        XCTAssertNotNil(output.thrown)
        XCTAssertEqual(try Self.events(output).map(\.event), [
            .start(message: "Starting FASTQ import"),
            .failed(message: "Input not found: /work/missing.fastq", detail: nil),
        ])
    }

    /// The scan of an input folder can fail with an error that is not a `BatchImportError`, such as a
    /// folder this user may not list. The run has printed `start` by then, so it still ends in one
    /// `failed` line that holds the error (finding 1 of the Q4 review).
    func testAFolderTheScanCannotReadEndsInOneFailedLine() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let folder = try Self.unreadableFolder(in: scratch)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: folder.path), "this user can list a folder with no permissions")

        let output = try await Self.run([folder.path], in: scratch)

        let thrown = try XCTUnwrap(output.thrown, "the error still reaches ArgumentParser")
        XCTAssertEqual(try Self.events(output).map(\.event), [
            .start(message: "Starting FASTQ import"),
            .failed(message: scratch.normalized(thrown.localizedDescription), detail: nil),
        ])
    }

    /// The same run in text mode prints nothing before the error, as at the base, so the added `failed`
    /// line belongs to `--format json` alone.
    func testAFolderTheScanCannotReadPrintsNothingInTextMode() async throws {
        let scratch = try ImportStreamCapture.Scratch()
        defer { scratch.remove() }
        let folder = try Self.unreadableFolder(in: scratch)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        try XCTSkipIf(FileManager.default.isReadableFile(atPath: folder.path), "this user can list a folder with no permissions")

        let output = try await Self.run([folder.path], in: scratch, json: false)

        XCTAssertNotNil(output.thrown, "the error still reaches ArgumentParser")
        XCTAssertEqual(output.standardOutput, [])
        XCTAssertEqual(output.standardError, [])
    }

    // MARK: Helpers

    private static func run(
        _ arguments: [String],
        in scratch: ImportStreamCapture.Scratch,
        json: Bool = true
    ) async throws -> ImportStreamCapture.Output {
        let command = try ImportCommand.FastqSubcommand.parse(arguments + [
            "--project", scratch.project.path, "--platform", "illumina", "--quality-binning", "none",
            "--no-optimize-storage", "--no-color", "--threads", "2",
        ] + (json ? ["--format", "json"] : []))
        return try await ImportStreamCapture.capture(in: scratch) { try await command.run() }
    }

    /// A folder with no permissions, which exists but cannot be listed.
    private static func unreadableFolder(in scratch: ImportStreamCapture.Scratch) throws -> URL {
        let folder = scratch.root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        return folder
    }

    /// Every line of standard output, each a version 2 event.
    private static func events(_ output: ImportStreamCapture.Output) throws -> [CLIEventLine] {
        try output.standardOutput.map { line in
            let decoded = try XCTUnwrap(try CLIEventLineDecoder().decodeLine(line), "not an event: \(line)")
            XCTAssertEqual(decoded.schemaVersion, CLIEventLine.currentSchemaVersion, line)
            XCTAssertNotNil(decoded.event, line)
            return decoded
        }
    }

    /// One record for each read name, each with `bases`.
    private static func records(_ names: [String], bases: String) -> String {
        names.map { "@\($0) length=\(bases.count)\n\(bases)\n+\n\(String(repeating: "I", count: bases.count))\n" }.joined()
    }
}

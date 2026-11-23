// LoosePairIngestAndRiboRoutesTests.swift - `fastq ingest`, `debug fastq-ingest`, `fastq ribodetector` and `fastq deacon-ribo` refuse an R1 and R2 that do not pair before any tool starts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

/// FIX-ROUTES-6 (the QA read of Preview 2026.11.16, round 3, Blocker 1). Four commands took a loose R1 and R2 as one
/// pair and checked only that both files exist. `fastq ingest --pair` and `debug fastq-ingest --pair` handed them to
/// the ingestion pipeline, which pairs by position (BIO-ROUTES-3 D1, S1). `fastq ribodetector R1 R2` and `fastq
/// deacon-ribo R1 R2` handed them to a tool that was never measured on a cut or shuffled R2. Each command now reads
/// both files whole before anything starts, and refuses with the exit code of its input errors, 3.
///
/// No pin starts a tool. The ingest check is asked on its own (`checkInputs`), the debug command is stopped by an output
/// folder that is a file, which it meets after its input checks and before its pipeline, RiboDetector is a recording
/// stand-in, and the Deacon check is asked on its own (`validateInputs`).
final class LoosePairIngestAndRiboRoutesTests: XCTestCase {

    var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "loose-pair-ingest-ribo").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    /// What a command did with its pair: it passed the mate check, or it refused with these words and this exit code.
    enum Outcome: Equatable {
        case passed
        case refused(words: String, exitCode: Int32)
        case other(String)
    }

    /// The interleaver's words, which `fastq ingest` and `debug fastq-ingest` keep (BIO-ROUTES-3 D1).
    static let ingestCutWords = "Validation failed:\n  - Paired FASTQ mates do not match: S_R1.fastq has 200 reads but S_R2.fastq has 120. Nothing was imported."
    static let ingestOutOfStepWords = "Validation failed:\n  - Paired FASTQ mates are out of step at record 2: S_R1.fastq has 'frag2/1' but S_R2.fastq has 'frag3/2'. The two files do not list the same fragments in the same order, so nothing was written."
    /// The run words B1 and B2, which the routes that run a tool on a pair give (`LooseMatePairCheck.refusal`).
    static let runCutWords = "Validation failed:\n  - Paired FASTQ mates do not match. S_R1.fastq has 200 reads, but S_R2.fastq has 120. Nothing ran. Check that both files are complete or run each as single reads."
    static let runOutOfStepWords = "Validation failed:\n  - Paired FASTQ mates are out of step at read 2. S_R1.fastq has 'frag2/1', but S_R2.fastq has 'frag3/2'. Nothing ran. Check that both files are from the same run and neither was sorted or subsampled on its own, or run each file as single reads."

    // MARK: - fastq ingest --pair

    func testIngestRefusesA200ReadR1WithA120ReadR2() throws {
        let (r1, r2) = try cutPair()
        XCTAssertEqual(try ingestCheck(r1: r1, r2: r2), .refused(words: Self.ingestCutWords, exitCode: 3))
    }

    func testIngestRefusesAShuffledR2() throws {
        let (r1, r2) = try shuffledPair()
        XCTAssertEqual(try ingestCheck(r1: r1, r2: r2), .refused(words: Self.ingestOutOfStepWords, exitCode: 3))
    }

    /// Guard: an equal pair in step passes the command's input check.
    func testIngestPassesAnInStepPair() throws {
        let (r1, r2) = try inStepPair()
        XCTAssertEqual(try ingestCheck(r1: r1, r2: r2), .passed)
    }

    // MARK: - debug fastq-ingest --pair

    func testDebugIngestRefusesA200ReadR1WithA120ReadR2() async throws {
        let (r1, r2) = try cutPair()
        let outcome = await debugIngest(r1: r1, r2: r2)
        XCTAssertEqual(outcome, .refused(words: Self.ingestCutWords, exitCode: 3))
    }

    func testDebugIngestRefusesAShuffledR2() async throws {
        let (r1, r2) = try shuffledPair()
        let outcome = await debugIngest(r1: r1, r2: r2)
        XCTAssertEqual(outcome, .refused(words: Self.ingestOutOfStepWords, exitCode: 3))
    }

    /// Guard: an equal pair in step passes the input check and stops at the output folder, which is a file here.
    func testDebugIngestPassesAnInStepPair() async throws {
        let (r1, r2) = try inStepPair()
        let outcome = await debugIngest(r1: r1, r2: r2)
        XCTAssertEqual(outcome, .passed)
    }

    // MARK: - fastq ribodetector R1 R2

    func testRiboDetectorRefusesA200ReadR1WithA120ReadR2BeforeTheToolStarts() async throws {
        let (r1, r2) = try cutPair()
        let run = await ribodetector(r1: r1, r2: r2)
        XCTAssertEqual(run.outcome, .refused(words: Self.runCutWords, exitCode: 3))
        XCTAssertEqual(run.toolRuns, 0)
    }

    func testRiboDetectorRefusesAShuffledR2BeforeTheToolStarts() async throws {
        let (r1, r2) = try shuffledPair()
        let run = await ribodetector(r1: r1, r2: r2)
        XCTAssertEqual(run.outcome, .refused(words: Self.runOutOfStepWords, exitCode: 3))
        XCTAssertEqual(run.toolRuns, 0)
    }

    /// Guard: an equal pair in step reaches the tool, once.
    func testRiboDetectorHandsAnInStepPairToTheTool() async throws {
        let (r1, r2) = try inStepPair()
        let run = await ribodetector(r1: r1, r2: r2)
        XCTAssertEqual(run.outcome, .passed)
        XCTAssertEqual(run.toolRuns, 1)
    }

    // MARK: - fastq deacon-ribo R1 R2

    func testDeaconRiboRefusesA200ReadR1WithA120ReadR2() async throws {
        let (r1, r2) = try cutPair()
        let outcome = try await deaconInputCheck(r1: r1, r2: r2)
        XCTAssertEqual(outcome, .refused(words: Self.runCutWords, exitCode: 3))
    }

    func testDeaconRiboRefusesAShuffledR2() async throws {
        let (r1, r2) = try shuffledPair()
        let outcome = try await deaconInputCheck(r1: r1, r2: r2)
        XCTAssertEqual(outcome, .refused(words: Self.runOutOfStepWords, exitCode: 3))
    }

    /// Guard: an equal pair in step passes the command's input check.
    func testDeaconRiboPassesAnInStepPair() async throws {
        let (r1, r2) = try inStepPair()
        let outcome = try await deaconInputCheck(r1: r1, r2: r2)
        XCTAssertEqual(outcome, .passed)
    }

    // MARK: - The routes

    /// The input check of `fastq ingest`, built the way `execute` builds the run, and asked on its own.
    func ingestCheck(r1: URL, r2: URL) throws -> Outcome {
        let command = try FastqIngestSubcommand.parse([r1.path, "--pair", r2.path, "--binning", "none", "--skip-clumpify"])
        let inputs = command.inputURLs()
        let run = FastqIngestRun(
            inputs: inputs,
            options: command.runOptions(),
            command: command.replayArgv(),
            parameters: command.provenanceParameters(inputs: inputs),
            defaults: FastqIngestSubcommand.provenanceDefaults,
            events: CLIEventEmitter(enabled: false, emit: { _ in }),
            clock: ProvenanceRunClock()
        )
        do {
            try run.checkInputs()
            return .passed
        } catch {
            return Self.outcome(of: error)
        }
    }

    /// `debug fastq-ingest --pair`, with an output folder that is a file. The command makes that folder after its input
    /// checks and before its pipeline, so it can only stop there: a refusal means the mate check ran first, and a
    /// folder error means the pair passed it.
    func debugIngest(r1: URL, r2: URL) async -> Outcome {
        let notAFolder = root.appendingPathComponent("not-a-folder")
        do {
            try Data("x".utf8).write(to: notAFolder)
            let command = try FASTQIngestSubcommand.parse([
                r1.path, "--pair", r2.path, "--output-dir", notAFolder.path, "--binning", "none", "--skip-clumpify",
            ])
            try await command.run()
            return .other("the command ran to its end")
        } catch let error as CLIError {
            return Self.outcome(of: error)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain || error.domain == NSPOSIXErrorDomain {
            return .passed
        } catch {
            return Self.outcome(of: error)
        }
    }

    /// `fastq ribodetector R1 R2` with a stand-in for the tool, and the number of times the stand-in was started.
    func ribodetector(r1: URL, r2: URL) async -> (outcome: Outcome, toolRuns: Int) {
        let fake = RecordingRiboDetector()
        let original = FastqRiboDetectorSubcommand.toolRunner
        FastqRiboDetectorSubcommand.toolRunner = fake
        defer { FastqRiboDetectorSubcommand.toolRunner = original }
        let output = root.appendingPathComponent("ribo-out-\(UUID().uuidString)", isDirectory: true)
        do {
            try await FastqRiboDetectorSubcommand.parse([r1.path, r2.path, "--read-length", "60", "-o", output.path]).run()
            return (.passed, fake.invocations.count)
        } catch {
            return (Self.outcome(of: error), fake.invocations.count)
        }
    }

    /// The input check of `fastq deacon-ribo`, asked on its own after the inputs are resolved as the command resolves them.
    func deaconInputCheck(r1: URL, r2: URL) async throws -> Outcome {
        let output = root.appendingPathComponent("deacon-out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let command = try FastqDeaconRiboSubcommand.parse([r1.path, r2.path, "-o", output.path])
        let resolved = try await FASTQSubcommandInput.resolve([r1.path, r2.path], operationName: "deacon-ribo", contextURL: output)
        defer { resolved.cleanup() }
        do {
            _ = try command.validateInputs(resolved)
            return .passed
        } catch {
            return Self.outcome(of: error)
        }
    }

    static func outcome(of error: Error) -> Outcome {
        if let error = error as? CLIError {
            return .refused(words: error.localizedDescription, exitCode: error.exitCode.rawValue)
        }
        return .other("\(type(of: error)): \(error.localizedDescription)")
    }

    // MARK: - Fixtures

    func cutPair() throws -> (URL, URL) {
        (try writeMates("S_R1.fastq", names: (1...200).map { "frag\($0)/1" }),
         try writeMates("S_R2.fastq", names: (1...120).map { "frag\($0)/2" }))
    }

    func shuffledPair() throws -> (URL, URL) {
        var names = (1...200).map { "frag\($0)/2" }
        names.swapAt(1, 2)
        return (try writeMates("S_R1.fastq", names: (1...200).map { "frag\($0)/1" }),
                try writeMates("S_R2.fastq", names: names))
    }

    func inStepPair() throws -> (URL, URL) {
        (try writeMates("S_R1.fastq", names: (1...200).map { "frag\($0)/1" }),
         try writeMates("S_R2.fastq", names: (1...200).map { "frag\($0)/2" }))
    }

    func writeMates(_ name: String, names: [String]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(ReadSetFixtures.fastq(names).utf8).write(to: url)
        return url
    }

    /// Stands in for `ribodetector_cpu`: writes each input as the matching output, as the tool does for reads it keeps,
    /// and counts how many times it was started.
    final class RecordingRiboDetector: RiboDetectorToolRunning, @unchecked Sendable {
        private(set) var invocations: [[String]] = []

        func detectVersion() async -> String { "0.3.3-fake" }

        func run(arguments: [String], workingDirectory: URL) async throws -> (stdout: String, stderr: String, exitCode: Int32) {
            invocations.append(arguments)
            let inputs = Self.values(after: "-i", in: arguments)
            let outputs = Self.values(after: "-o", in: arguments)
            for (input, output) in zip(inputs, outputs) {
                try FileManager.default.copyItem(atPath: input, toPath: output)
            }
            return ("", "", 0)
        }

        static func values(after flag: String, in arguments: [String]) -> [String] {
            guard let start = arguments.firstIndex(of: flag) else { return [] }
            return Array(arguments[(start + 1)...].prefix { !$0.hasPrefix("-") })
        }
    }
}

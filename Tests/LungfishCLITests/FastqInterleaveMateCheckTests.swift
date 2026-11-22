// FastqInterleaveMateCheckTests.swift - `fastq interleave` refuses an R1 and R2 that do not pair before reformat runs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
import LungfishWorkflow

/// BIO ruling BIO-ROUTES-2, binding items 2 and 7 (S1). `lungfish-cli fastq interleave --in1 --in2` handed two loose
/// files to BBTools reformat, which pairs them by position: an R2 out of step came out as a file of 200 wrong pairs and
/// exit 0, and a cut R2 failed with a Java stack trace. The command now reads both files whole first and refuses them
/// with its own words, exit 3, and writes no file.
///
/// Each run starts in a task that is already cancelled, so reformat never starts at the base or after the fix:
/// `NativeToolRunner.runProcess` checks for a cancel before it spawns, and the mate check of 200 records polls none.
final class FastqInterleaveMateCheckTests: XCTestCase {

    var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "fastq-interleave-mates").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    static let cutWords = "Validation failed:\n  - Paired FASTQ mates do not match. S_R1.fastq has 200 reads, but S_R2.fastq has 120. Nothing was written. Check that both files are complete."
    static let outOfStepWords = "Validation failed:\n  - Paired FASTQ mates are out of step at read 2. S_R1.fastq has 'frag2/1', but S_R2.fastq has 'frag3/2'. Nothing was written. Check that both files are from the same run and neither was sorted or subsampled on its own."

    func testA200ReadR1WithA120ReadR2IsRefusedAndWritesNothing() async throws {
        let r1 = try writeMates("S_R1.fastq", names: (1...200).map { "frag\($0)/1" })
        let r2 = try writeMates("S_R2.fastq", names: (1...120).map { "frag\($0)/2" })

        let outcome = try await interleave(r1: r1, r2: r2)
        XCTAssertEqual(outcome.words, Self.cutWords)
        XCTAssertEqual(outcome.exitCode, 3)
        XCTAssertEqual(outcome.outputExists, false)
    }

    func testAShuffledR2IsRefusedAndWritesNothing() async throws {
        let r1 = try writeMates("S_R1.fastq", names: (1...200).map { "frag\($0)/1" })
        var names = (1...200).map { "frag\($0)/2" }
        names.swapAt(1, 2)
        let r2 = try writeMates("S_R2.fastq", names: names)

        let outcome = try await interleave(r1: r1, r2: r2)
        XCTAssertEqual(outcome.words, Self.outOfStepWords)
        XCTAssertEqual(outcome.exitCode, 3)
        XCTAssertEqual(outcome.outputExists, false)
    }

    /// Guard: the command's check passes an equal pair, so reformat runs on it as before. The check is asked alone,
    /// so no reformat runs here.
    func testAnEqualPairPassesTheInterleaveCheck() async throws {
        let r1 = try writeMates("S_R1.fastq", names: (1...200).map { "frag\($0)/1" })
        let r2 = try writeMates("S_R2.fastq", names: (1...200).map { "frag\($0)/2" })

        XCTAssertEqual(try LooseMatePairCheck.interleaveRefusal(r1: r1, r2: r2), nil)
    }

    /// The words and exit code of `fastq interleave` on `r1` and `r2`, whether it stopped at the tool's launch (a
    /// `CancellationError`), and whether it left an output file. The red run at the base (commit 76a8aa6d4) started
    /// the task cancelled, so reformat could not launch; the mate check polls for a cancel at its first record, so
    /// after the fix the task is not cancelled, and the refusal comes before any launch.
    func interleave(r1: URL, r2: URL) async throws -> (words: String?, exitCode: Int32?, reachedTheTool: Bool, outputExists: Bool) {
        let output = root.appendingPathComponent("interleaved-\(UUID().uuidString).fastq")
        let command = try FastqInterleaveSubcommand.parse(["--in1", r1.path, "--in2", r2.path, "--output", output.path])
        let caught = await Task { () -> Error? in
            do {
                try await command.run()
                return nil
            } catch {
                return error
            }
        }.value
        let outputExists = FileManager.default.fileExists(atPath: output.path)
        switch caught {
        case let error as CLIError:
            return (error.localizedDescription, error.exitCode.rawValue, false, outputExists)
        case is CancellationError:
            return (nil, nil, true, outputExists)
        case let error?:
            return (error.localizedDescription, nil, false, outputExists)
        case nil:
            return (nil, nil, false, outputExists)
        }
    }

    func writeMates(_ name: String, names: [String]) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(ReadSetFixtures.fastq(names).utf8).write(to: url)
        return url
    }
}

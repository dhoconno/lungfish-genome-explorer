// StorageQualityEncodingConformanceTests.swift - The Mac storage argv states Phred+33 and keeps every score up to Q93
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore
import LungfishPortable
import LungfishTestSupport
@testable import LungfishWorkflow

/// Phase 3.0 lane BIN, fix round 2 (BIO-BIN-QIN, S1). With no `qin` BBTools reads the quality offset from the reads.
/// bbmap 40.02 then switches to ASCII-64 at the first score of about Q55 in a short read and stores every later score 31
/// too low, stops with exit 1 or hangs, and its called-quality cap of 50 lowers HiFi scores that `none` should keep. Each
/// storage argv now states `qin=33 qout=33 maxcalledquality=93` (``PortableStoragePlan/qualityEncodingArguments``).
///
/// Each test runs the argv its builder gives, through the managed tool, on reads that reach Q93. Red is a failure, a wrong
/// score or the 120 s deadline, since reformat can hang when it guesses the offset wrong. The executor's reformat argv has
/// its own class in the executor's test target, which is the only one that sees `PlanRunner`.
///
/// Real-tool suites. Their names put them in the conformance tier, and each test skips when its managed tool is missing,
/// or fails under LUNGFISH_REQUIRE_TOOLS=1.
final class StorageQualityEncodingConformanceTests: XCTestCase {
    /// BIO's `HighQualityShortReads` set (`qin_flagset_probe.py`): 300 reads of 150 bases, each holding every score Q0 to
    /// Q93 in shuffled order and 56 random scores. `fiveStep` must store each as the middle of its step of five, and
    /// `none` through clumpify keeps every score except a called Q0 or Q1, which BBTools stores as Q2.
    func testClumpifyStorageArgvKeepsShortHighQualityReads() async throws {
        guard (try? await NativeToolRunner.shared.toolPath(for: .clumpify)) != nil else {
            try ToolAvailability.skipOrFail("Managed clumpify is not available")
        }
        let reads = Self.highQualityShortReads()
        let root = try scratchFolder()
        let input = root.appendingPathComponent("short.fastq")
        try reads.fastq.write(to: input, atomically: true, encoding: .utf8)

        let cases: [(scheme: QualityBinningScheme, expected: (Int) -> Int)] = [
            (.fiveStep, Self.fiveStep), (.none, Self.keptWithFloor),
        ]
        for (scheme, expected) in cases {
            let output = root.appendingPathComponent("short.\(scheme.rawValue).clumped.fastq")
            let result = try await NativeToolRunner.shared.run(
                .clumpify,
                arguments: PortableStoragePlan.clumpifyArguments(
                    input: input, output: output, interleaved: false, heapGB: 2, threads: 2, qualityBinning: scheme
                ),
                timeout: 120
            )
            guard result.isSuccess else {
                XCTFail("clumpify.sh with \(scheme.rawValue) stopped: \(result.stderr.suffix(600))")
                continue
            }
            try Self.assertStored(in: output, reads: reads, expected: expected, label: "clumpify \(scheme.rawValue)")
        }
    }

    /// The same reads through the Mac's `reformat.sh` argv, which `binQualities` launches (a no-clumping import and an
    /// ONT chunk take this argv). The call runs under a 120 s deadline and is cancelled when it passes.
    func testReformatStorageArgvKeepsShortHighQualityReads() async throws {
        guard (try? await NativeToolRunner.shared.toolPath(for: .reformat)) != nil else {
            try ToolAvailability.skipOrFail("Managed reformat is not available")
        }
        let reads = Self.highQualityShortReads()
        let root = try scratchFolder()
        let input = root.appendingPathComponent("short.fastq")
        let output = root.appendingPathComponent("short.binned.fastq")
        try reads.fastq.write(to: input, atomically: true, encoding: .utf8)

        let outcome = RunOutcome()
        let work = Task {
            do {
                _ = try await FASTQIngestionPipeline().binQualities(
                    of: input, into: output, scheme: .fiveStep, threads: 2
                )
                outcome.finish(nil)
            } catch {
                outcome.finish(error)
            }
        }
        let finished = await waitUntil(
            budget: WaitBudget.lookup.raised(to: .seconds(120)), pollInterval: .milliseconds(250)
        ) { outcome.isFinished }
        guard finished else {
            work.cancel()
            XCTFail("reformat.sh did not finish within 120 s on reads that reach Q93")
            return
        }
        if let failure = outcome.error {
            XCTFail("reformat.sh stopped: \(failure.localizedDescription)")
            return
        }
        try Self.assertStored(in: output, reads: reads, expected: Self.fiveStep, label: "reformat fiveStep")
    }

    /// The HiFi set that `none` keeps through clumpify: 200 reads of 3,000 bases with no score below Q31, of which 70% are
    /// Q93. With BBTools' called-quality cap of 50 in place, 89.8% of the scores came back as Q50.
    func testLongHiFiNoneThroughClumpifyKeepsScoresAboveFifty() async throws {
        guard (try? await NativeToolRunner.shared.toolPath(for: .clumpify)) != nil else {
            try ToolAvailability.skipOrFail("Managed clumpify is not available")
        }
        let reads = Self.hifiCleanReads()
        let root = try scratchFolder()
        let input = root.appendingPathComponent("hifi.fastq")
        let output = root.appendingPathComponent("hifi.none.clumped.fastq")
        try reads.fastq.write(to: input, atomically: true, encoding: .utf8)

        let result = try await NativeToolRunner.shared.run(
            .clumpify,
            arguments: PortableStoragePlan.clumpifyArguments(
                input: input, output: output, interleaved: false, heapGB: 2, threads: 2, qualityBinning: .none
            ),
            timeout: 120
        )
        guard result.isSuccess else {
            XCTFail("clumpify.sh with none stopped: \(result.stderr.suffix(600))")
            return
        }
        try Self.assertStored(in: output, reads: reads, expected: { $0 }, label: "clumpify none, HiFi")
    }

    // MARK: - Helpers

    private func scratchFolder() throws -> URL {
        let root = try TestTempDirectory.make(prefix: "storage-qin")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        return root
    }

    /// The middle of the step of five that `fiveStep` stores a score as.
    private static func fiveStep(_ score: Int) -> Int { min(score / 5, 7) * 5 + 2 }

    /// `none` through clumpify keeps a score, and stores a called Q0 or Q1 as Q2 (the ruling's finding 3b).
    private static func keptWithFloor(_ score: Int) -> Int { max(score, 2) }

    /// Fails once, with the count and a few examples, when a stored score differs from `expected(sequenced score)`.
    private static func assertStored(
        in output: URL, reads: ReadSet, expected: (Int) -> Int, label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let stored = try storedScores(in: output)
        XCTAssertEqual(stored.count, reads.names.count, "\(label): reads stored", file: file, line: line)
        var total = 0
        var wrong = 0
        var examples = Set<String>()
        for (name, scores) in zip(reads.names, reads.scores) {
            guard let kept = stored[name] else { continue }
            XCTAssertEqual(kept.count, scores.count, "\(label): bases stored for \(name)", file: file, line: line)
            for (sequenced, got) in zip(scores, kept) {
                total += 1
                guard got != expected(sequenced) else { continue }
                wrong += 1
                if examples.count < 6 { examples.insert("Q\(sequenced) stored as Q\(got), expected Q\(expected(sequenced))") }
            }
        }
        XCTAssertEqual(
            wrong, 0, "\(label): \(wrong) of \(total) stored scores are not the scheme's map, for example \(examples.sorted())",
            file: file, line: line
        )
    }

    /// The reads of a plain FASTQ written by BBTools, by name, with each quality byte read as Phred+33.
    private static func storedScores(in output: URL) throws -> [String: [Int]] {
        let lines = try String(contentsOf: output, encoding: .utf8).split(separator: "\n")
        var stored: [String: [Int]] = [:]
        var index = 0
        while index + 3 < lines.count {
            stored[String(lines[index].dropFirst())] = lines[index + 3].utf8.map { Int($0) - 33 }
            index += 4
        }
        return stored
    }

    private static func highQualityShortReads() -> ReadSet {
        var generator = SeededGenerator(seed: 3)
        var reads = ReadSet()
        for index in 0..<300 {
            var scores = Array(0...93) + (0..<56).map { _ in Int.random(in: 0...93, using: &generator) }
            scores.shuffle(using: &generator)
            reads.add(name: "f\(index)", scores: scores, using: &generator)
        }
        return reads
    }

    private static func hifiCleanReads() -> ReadSet {
        var generator = SeededGenerator(seed: 20_261_027)
        var reads = ReadSet()
        for index in 0..<200 {
            let scores = (0..<3_000).map { _ -> Int in
                let draw = Double.random(in: 0..<1, using: &generator)
                if draw < 0.70 { return 93 }
                if draw < 0.95 { return Int.random(in: 40...92, using: &generator) }
                return Int.random(in: 31...39, using: &generator)
            }
            reads.add(name: "hifi_\(index)", scores: scores, using: &generator)
        }
        return reads
    }
}

/// Reads in the order written, each with called bases (A, C, G or T, never an N that BBTools keeps at Q0).
private struct ReadSet {
    var names: [String] = []
    var scores: [[Int]] = []
    private var bases: [String] = []

    mutating func add(name: String, scores: [Int], using generator: inout SeededGenerator) {
        names.append(name)
        self.scores.append(scores)
        bases.append(String(scores.map { _ in ["A", "C", "G", "T"].randomElement(using: &generator) ?? "A" }.joined()))
    }

    var fastq: String {
        var text = ""
        for index in names.indices {
            text += "@\(names[index])\n\(bases[index])\n+\n"
            text += String(decoding: scores[index].map { UInt8($0 + 33) }, as: UTF8.self)
            text += "\n"
        }
        return text
    }
}

/// SplitMix64, so each read set is the same on every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// What a pipeline call left, read by the test's wait.
private final class RunOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var failure: (any Error)?

    func finish(_ error: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        done = true
        failure = error
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    var error: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }
}

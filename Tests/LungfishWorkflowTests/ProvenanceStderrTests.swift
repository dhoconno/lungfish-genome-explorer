// ProvenanceStderrTests.swift - A step keeps the head and the tail of a long stderr
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishTestSupport
@testable import LungfishWorkflow

/// Tools print their banner first and their errors, versions and summaries last,
/// so a record that keeps only the start of a long stderr loses the part that
/// explains a failure. `ProvenanceStderr.truncated` keeps the first 2,048 and the
/// last 8,192 characters around a marker that carries no count.
@Suite("Provenance stderr")
struct ProvenanceStderrTests {
    private static let marker = "\n... [truncated] ...\n"
    private static let headLength = 2_048
    private static let tailLength = 8_192
    private static let bound = headLength + tailLength

    /// A stderr of `lineCount` numbered lines between a banner and an error line.
    private static func longStderr(lineCount: Int) -> (text: String, banner: String, error: String) {
        let banner = "mytool 1.2.3 starting with 8 threads"
        let error = "ERROR: out of memory in stage 7, exiting"
        var lines = [banner]
        lines.reserveCapacity(lineCount)
        lines += (1...(lineCount - 2)).map { "[progress] processed batch \($0) of \(lineCount - 2) without a warning" }
        lines.append(error)
        return (lines.joined(separator: "\n") + "\n", banner, error)
    }

    // MARK: The bound

    @Test("stderr of up to 10,240 characters is kept whole, and nil stays nil")
    func stderrWithinTheBoundIsUnchanged() {
        for count in [0, 1, 2_048, 2_049, 8_192, 10_239, Self.bound] {
            let text = String(repeating: "x", count: count)
            #expect(ProvenanceStderr.truncated(text) == text, "\(count) characters")
        }
        let multiLine = (1...300).map { "line \($0) of a log that fits" }.joined(separator: "\n")
        #expect(multiLine.count < Self.bound)
        #expect(ProvenanceStderr.truncated(multiLine) == multiLine)
        #expect(ProvenanceStderr.truncated(nil) == nil)
        #expect(ProvenanceStderr.normalized(nil) == nil)
        #expect(ProvenanceStderr.normalized("  \n\t ") == nil)
        #expect(ProvenanceStderr.normalized("") == nil)
    }

    @Test("stderr over 10,240 characters keeps the first 2,048 and the last 8,192 around one marker")
    func longerStderrKeepsItsHeadAndItsTail() throws {
        // Distinct characters at every position, so a wrong slice cannot pass by luck.
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        for count in [Self.bound + 1, Self.bound + 2, 20_000, 123_457] {
            let text = String((0..<count).map { alphabet[($0 * 7 + $0 / 36) % alphabet.count] })
            let kept = try #require(ProvenanceStderr.truncated(text))

            #expect(kept == String(text.prefix(Self.headLength)) + Self.marker + String(text.suffix(Self.tailLength)), "\(count)")
            #expect(kept.count == Self.headLength + Self.marker.count + Self.tailLength, "\(count)")
            #expect(kept.hasPrefix(String(text.prefix(Self.headLength))), "\(count)")
            #expect(kept.hasSuffix(String(text.suffix(Self.tailLength))), "\(count)")
        }
    }

    @Test("the marker carries no count, so two cuts of different lengths read the same")
    func markerCarriesNoCount() {
        #expect(ProvenanceStderr.truncationMarker == Self.marker)
        let digits = Self.marker.filter { $0.isNumber }
        #expect(digits.isEmpty)

        let shorter = String(repeating: "a", count: 12_000)
        let longer = String(repeating: "a", count: 90_000)
        let keptShorter = ProvenanceStderr.truncated(shorter)
        let keptLonger = ProvenanceStderr.truncated(longer)
        #expect(keptShorter == keptLonger)
        #expect(keptShorter?.components(separatedBy: Self.marker).count == 2, "exactly one marker")
    }

    @Test("truncating twice changes nothing more")
    func truncationIsIdempotent() {
        let stderr = Self.longStderr(lineCount: 5_000).text
        let once = ProvenanceStderr.truncated(stderr)
        #expect(once != stderr)
        #expect(ProvenanceStderr.truncated(once) == once)
        #expect(ProvenanceStderr.normalized(once) == once)
    }

    @Test("the cut counts characters, so a multi-scalar character is never split")
    func cutCountsCharacters() throws {
        let family = "👩‍👩‍👧‍👦"
        let accented = "e\u{301}"
        for unit in [family, accented] {
            let text = String(repeating: unit, count: 12_000)
            let kept = try #require(ProvenanceStderr.truncated(text))
            #expect(kept.hasPrefix(String(repeating: unit, count: Self.headLength)))
            #expect(kept.hasSuffix(String(repeating: unit, count: Self.tailLength)))
            #expect(kept.count == Self.headLength + Self.marker.count + Self.tailLength)
        }
    }

    // MARK: T5, a 50,000-line stderr

    @Test("a 50,000-line stderr keeps its first banner line and its last error line within the bound")
    func fiftyThousandLineStderrKeepsItsFirstAndLastLines() throws {
        let log = Self.longStderr(lineCount: 50_000)
        #expect(log.text.split(separator: "\n", omittingEmptySubsequences: false).count == 50_001, "50,000 lines and the final newline")
        #expect(log.text.count > 2_000_000)

        let kept = try #require(ProvenanceStderr.truncated(log.text))

        #expect(kept.hasPrefix(log.banner + "\n"), "the banner survives")
        #expect(kept.hasSuffix(log.error + "\n"), "the last error line survives")
        #expect(kept.count == Self.bound + Self.marker.count)
        #expect(kept.contains(Self.marker))
        // The middle is gone, so a line from the middle of the log is not kept.
        #expect(!kept.contains("processed batch 25000 of"))
    }

    // MARK: The writers apply it

    @Test("the run builder stores the head and the tail of a long stderr")
    func builderStoresHeadAndTail() throws {
        let log = Self.longStderr(lineCount: 50_000)
        let output = ProvenanceFileDescriptor(
            path: "result.fastq",
            checksumSHA256: String(repeating: "f", count: 64),
            fileSize: 12,
            role: .output
        )
        let envelope = try ProvenanceRunBuilder(
            workflowName: "stderr.fixture",
            workflowVersion: "2026.10",
            toolName: "mytool",
            toolVersion: "1.2.3"
        )
        .argv(["mytool", "-o", "result.fastq"])
        .runtime(ProvenanceRuntimeIdentity.fixture())
        .step(ProvenanceStep(
            toolName: "mytool",
            toolVersion: "1.2.3",
            argv: ["mytool", "-o", "result.fastq"],
            outputs: [output],
            exitStatus: 0
        ))
        .complete(
            exitStatus: 0,
            stderr: log.text,
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101)
        )

        #expect(envelope.stderr == ProvenanceStderr.truncated(log.text))
        let kept = try #require(envelope.stderr)
        #expect(kept.hasPrefix(log.banner))
        #expect(kept.hasSuffix(log.error + "\n"))
    }

    @Test("a recorded step keeps the banner and the last error line, and so does the saved sidecar")
    func recorderStepKeepsBannerAndLastErrorLine() async throws {
        let directory = try TestTempDirectory.make(prefix: "provenance-stderr")
        defer { TestTempDirectory.cleanup(directory) }
        let log = Self.longStderr(lineCount: 50_000)
        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await recorder.beginRun(name: "Failing run")
        await recorder.recordStep(
            runID: runID,
            toolName: "mytool",
            toolVersion: "1.2.3",
            command: ["mytool", "-o", "result.fastq"],
            inputs: [],
            outputs: [],
            exitCode: 137,
            wallTime: 3,
            stderr: log.text
        )
        await recorder.completeRun(runID, status: .failed)

        let recorded = await recorder.getRun(runID)
        let stepStderr = try #require(recorded?.steps.first?.stderr)
        #expect(stepStderr == ProvenanceStderr.truncated(log.text))

        try await recorder.save(runID: runID, to: directory)
        let envelope = try #require(try ProvenanceEnvelopeReader.load(from: directory))
        let stepKept = try #require(envelope.steps.first?.stderr)
        let runKept = try #require(envelope.stderr)
        for kept in [stepKept, runKept] {
            #expect(kept.hasPrefix(log.banner))
            #expect(kept.hasSuffix(log.error + "\n"))
            #expect(kept.count == Self.bound + Self.marker.count)
        }
    }
}

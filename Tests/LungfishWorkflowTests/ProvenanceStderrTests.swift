// ProvenanceStderrTests.swift - A step keeps the head and the tail of a long stderr
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// Tools print their banner first and their errors, versions and summaries last,
/// so a record that keeps only the start of a long stderr loses the part that
/// explains a failure. `ProvenanceStderr.truncated` keeps the whole lines inside
/// the first 2,048 and the last 8,192 characters around a marker that carries no
/// count, and keeps nothing of a window that holds no line break. The
/// `ProvenanceStderrLineBoundaryTests` and `ProvenanceStderrTokenSafetyTests` in
/// LungfishCoreTests pin where the cut falls. These tests pin the bound, the
/// marker and the writers that apply it.
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

    /// A cut of `longStderr` lines holds whole lines, so each side falls short of its
    /// window by less than one line. The longest of those lines is 60 characters.
    private static func expectWholeLinesFillTheBound(
        _ kept: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(kept.count <= bound + marker.count, "at most the bound plus the marker", sourceLocation: sourceLocation)
        #expect(kept.count >= bound + marker.count - 2 * 60, "each side within one line of its window", sourceLocation: sourceLocation)
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

    @Test("a stderr of 10,240 blank characters is recorded as absent")
    func blankStderrAtTheBoundIsNil() {
        for blank in [" ", "\n", "\t", " \n"] {
            let text = String(repeating: blank, count: Self.bound / blank.count)
            #expect(text.count == Self.bound)
            #expect(ProvenanceStderr.normalized(text) == nil, "\(Self.bound) characters of \(blank.debugDescription)")
        }
    }

    @Test("a blank stderr over the bound is recorded as absent and not as the marker")
    func blankStderrOverTheBoundIsNil() {
        // The cut of a blank value keeps nothing of either window, and the marker it
        // leaves is not blank, so the blank check has to come before the cut.
        for repetitions in [Self.bound + 1, 20_000, 1_000_000] {
            for blank in [" ", "\n", "\t", " \n", "\r\n", " \t\n"] {
                let text = String(repeating: blank, count: repetitions)
                #expect(text.count > Self.bound)
                #expect(ProvenanceStderr.normalized(text) == nil, "\(text.count) characters of \(blank.debugDescription)")
            }
        }
    }

    @Test("the cut of a blank stderr over the bound comes back empty and not as the marker")
    func blankStderrOverTheBoundIsCutToNothing() {
        // `normalized` answers nil for a blank value before it cuts, but the recorder and the
        // batch writer call `truncated` on its own. The cut keeps nothing of either window of a
        // blank value, so what it left was the marker alone, which reads as a stderr that said
        // something. A blank value over the bound is cut to nothing, and a second cut agrees.
        for repetitions in [Self.bound + 1, 20_000, 1_000_000] {
            for blank in [" ", "\n", "\t", " \n", "\r\n", " \t\n"] {
                let text = String(repeating: blank, count: repetitions)
                #expect(text.count > Self.bound)
                let kept = ProvenanceStderr.truncated(text)
                #expect(kept == "", "\(text.count) characters of \(blank.debugDescription)")
                #expect(ProvenanceStderr.truncated(kept) == kept, "a second cut of \(blank.debugDescription)")
            }
        }
    }

    @Test("a stderr with text in it is cut after the blank check, as the cut alone would")
    func stderrWithTextIsStillCut() throws {
        let log = Self.longStderr(lineCount: 600)
        #expect(log.text.count > Self.bound)
        let kept = try #require(ProvenanceStderr.normalized(log.text))
        #expect(kept == ProvenanceStderr.truncated(log.text))
        #expect(kept.hasPrefix(log.banner))
        #expect(kept.hasSuffix(log.error + "\n"))
        #expect(kept.contains(Self.marker))
    }

    @Test("stderr over 10,240 characters keeps the whole lines of the first 2,048 and the last 8,192 around one marker")
    func longerStderrKeepsItsHeadAndItsTail() throws {
        // Lines of 100 characters with the line number at the start of each, so a wrong slice
        // cannot pass by luck. The head window ends inside line 21 and the tail window starts
        // inside line 119, so the head keeps 20 lines and the tail keeps lines 120 to 200.
        let lines = (1...200).map { "L" + String(format: "%04d", $0) + String(repeating: "x", count: 94) }
        let text = lines.joined(separator: "\n") + "\n"
        #expect(text.count == 20_000)

        let kept = try #require(ProvenanceStderr.truncated(text))

        #expect(kept == lines[0..<20].joined(separator: "\n") + Self.marker + lines[119...].joined(separator: "\n") + "\n")
        #expect(kept.count <= Self.bound + Self.marker.count)
    }

    @Test("stderr over 10,240 characters with no line break keeps nothing but the marker")
    func stderrWithNoLineBreakKeepsOnlyTheMarker() throws {
        // Distinct characters at every position. The text holds no line break, so neither
        // window holds a line and a cut at the character would leave a fragment of a token.
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        for count in [Self.bound + 1, Self.bound + 2, 20_000, 123_457] {
            let text = String((0..<count).map { alphabet[($0 * 7 + $0 / 36) % alphabet.count] })
            #expect(ProvenanceStderr.truncated(text) == Self.marker, "\(count)")
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
            // Lines of 39 characters and a line feed, so the head window ends inside line 52 and
            // keeps 51 lines, and the tail window starts inside line 196 and keeps lines 197 to 400.
            let line = String(repeating: unit, count: 39)
            let text = String(repeating: line + "\n", count: 400)
            #expect(text.count == 16_000)

            let kept = try #require(ProvenanceStderr.truncated(text))

            let head = Array(repeating: line, count: 51).joined(separator: "\n")
            let tail = Array(repeating: line, count: 204).joined(separator: "\n") + "\n"
            #expect(kept == head + Self.marker + tail)
            #expect(kept.count == head.count + Self.marker.count + tail.count)
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
        Self.expectWholeLinesFillTheBound(kept)
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
            Self.expectWholeLinesFillTheBound(kept)
        }
    }
}

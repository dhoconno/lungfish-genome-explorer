// ProvenanceStderrLineBoundaryTests.swift - A cut stderr holds whole lines only
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import LungfishCore

/// `ProvenanceStderr.truncated` cuts a long stderr at line boundaries. A cut inside a
/// line leaves half of an absolute path. A tail that starts inside a path has no
/// leading slash and no known root, and a head that ends inside one keeps a partial
/// root, so the sanitizer that rewrites paths when a record is written cannot
/// recognise either one and the machine and project folder names stay in a record
/// that people share (Phase 2.7, ruling 2). A window that holds no line break keeps
/// nothing, because it lies inside one line, and `ProvenanceStderrTokenSafetyTests`
/// pins that rule on project paths (Phase 2.8, decision P4).
@Suite("Provenance stderr line boundaries")
struct ProvenanceStderrLineBoundaryTests {
    private static let marker = ProvenanceStderr.truncationMarker
    private static let headLength = ProvenanceStderr.headLength
    private static let tailLength = ProvenanceStderr.tailLength
    private static let bound = ProvenanceStderr.maxLength

    // MARK: Fixtures

    private static let banner = "mytool 1.2.3 starting with 8 threads"
    private static let lastLine = "ERROR: out of memory in stage 7, exiting"
    private static let projectRoot = "/Users/analyst/Projects/\(UUID().uuidString)/Study.lungfish"

    /// A stderr of path lines between a banner and an error line, with a padding line
    /// before the paths and one after, so the two cuts can be moved along the lines.
    private static func pathLog(startPad: Int, endPad: Int, pathLines: Int = 160) -> String {
        var lines = [banner, "[pad] " + String(repeating: ".", count: startPad)]
        lines += (1...pathLines).map {
            "[bam_sort] writing to \(projectRoot)/Analyses/classify-1/part-\(String(format: "%04d", $0)).sorted.bam"
        }
        lines += ["[pad] " + String(repeating: ".", count: endPad), lastLine]
        return lines.joined(separator: "\n") + "\n"
    }

    /// True when the characters on both sides of `offset` sit in one token that starts
    /// with a slash, which is what the old cut did to a path.
    private static func cutsInsideAnAbsolutePath(_ text: String, at offset: Int) -> Bool {
        let characters = Array(text)
        guard offset > 0, offset < characters.count,
              !characters[offset - 1].isWhitespace, !characters[offset].isWhitespace else {
            return false
        }
        var start = offset - 1
        while start > 0, !characters[start - 1].isWhitespace {
            start -= 1
        }
        return characters[start] == "/"
    }

    /// A stderr whose character 2,048 and whose character count minus 8,192 both fall
    /// inside absolute paths, found by moving the two padding lines.
    private static func logCutInsidePaths() throws -> String {
        var startPad: Int?
        var endPad: Int?
        for pad in 0..<400 {
            let text = pathLog(startPad: pad, endPad: pad)
            if startPad == nil, cutsInsideAnAbsolutePath(text, at: headLength) {
                startPad = pad
            }
            if endPad == nil, cutsInsideAnAbsolutePath(text, at: text.count - tailLength) {
                endPad = pad
            }
        }
        let text = pathLog(startPad: try #require(startPad), endPad: try #require(endPad))
        #expect(cutsInsideAnAbsolutePath(text, at: headLength), "the head cut falls inside a path")
        #expect(cutsInsideAnAbsolutePath(text, at: text.count - tailLength), "the tail cut falls inside a path")
        #expect(text.count > bound)
        return text
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// The head and the tail around the one marker.
    private static func sides(of kept: String) throws -> (head: String, tail: String) {
        let parts = kept.components(separatedBy: marker)
        #expect(parts.count == 2, "exactly one marker")
        return (try #require(parts.first), try #require(parts.last))
    }

    // MARK: Whole lines

    @Test("a cut that would land inside absolute paths moves to the line boundaries")
    func cutsInsidePathsMoveToLineBoundaries() throws {
        let text = try Self.logCutInsidePaths()
        let kept = try #require(ProvenanceStderr.truncated(text))
        let (head, tail) = try Self.sides(of: kept)

        let inputLines = Set(Self.lines(text))
        for line in Self.lines(head) + Self.lines(tail) {
            #expect(inputLines.contains(line), "kept a fragment: \(line.prefix(80))")
        }
        #expect(text.hasPrefix(head), "the head is the start of the stderr")
        #expect(text.hasSuffix(tail), "the tail is the end of the stderr")
        #expect(head.hasPrefix(Self.banner + "\n"), "the first line survives")
        #expect(kept.hasSuffix(Self.lastLine + "\n"), "the last line survives")
        #expect(kept.count <= Self.bound + Self.marker.count, "at most the bound plus the marker")
        #expect(head.count <= Self.headLength)
        #expect(tail.count <= Self.tailLength)
        // Whole lines fill the windows to within one line.
        #expect(head.count + Self.lines(text)[Self.lines(head).count].count + 1 > Self.headLength)
    }

    @Test("a stderr of at most 10,240 characters comes back unchanged")
    func stderrWithinTheBoundIsUnchanged() {
        let line = "[bam_sort] writing to \(Self.projectRoot)/Analyses/classify-1/part-0001.sorted.bam\n"
        for count in [0, 1, 80, Self.headLength, Self.tailLength, Self.bound - 1, Self.bound] {
            let text = String(String(repeating: line, count: Self.bound / line.count + 1).prefix(count))
            #expect(ProvenanceStderr.truncated(text) == text, "\(count) characters")
        }
        #expect(ProvenanceStderr.truncated(nil) == nil)
    }

    @Test("a stderr one character over the bound is cut")
    func oneCharacterOverTheBoundIsCut() throws {
        let line = "[bam_sort] writing to \(Self.projectRoot)/Analyses/classify-1/part-0001.sorted.bam\n"
        let text = String(String(repeating: line, count: Self.bound / line.count + 2).prefix(Self.bound + 1))
        let kept = try #require(ProvenanceStderr.truncated(text))
        #expect(kept != text)
        #expect(kept.contains(Self.marker))
        #expect(kept.count <= Self.bound + Self.marker.count)
    }

    // MARK: A line longer than a window

    /// 400 words of about 130 characters each on one line, so no window holds a line break.
    private static let words = (1...400).map {
        "\(projectRoot)/Analyses/classify-1/part-\(String(format: "%04d", $0)).sorted.bam"
    }

    @Test("one line longer than both windows is left out whole, never cut at a space")
    func aLongLineIsLeftOutWholeAndNotCutAtASpace() throws {
        let text = Self.words.joined(separator: " ")
        #expect(text.count > Self.bound)
        #expect(ProvenanceStderr.truncated(text) == Self.marker)

        // The short lines on either side of it are kept.
        let framed = Self.banner + "\n" + text + "\n" + Self.lastLine + "\n"
        #expect(ProvenanceStderr.truncated(framed) == Self.banner + Self.marker + Self.lastLine + "\n")
    }

    @Test("the last line is left out when it is longer than the tail window, whatever ends it")
    func aLongLastLineIsLeftOut() throws {
        let text = Self.banner + "\n" + Self.words.joined(separator: " ")
        for ending in ["", "\n", "\r\n"] {
            let kept = try #require(ProvenanceStderr.truncated(text + ending))
            #expect(kept == Self.banner + Self.marker, "ending \(ending.debugDescription)")
        }
    }

    @Test("a window with no line break keeps nothing, whatever its characters")
    func aWindowWithNoLineBreakKeepsNothing() throws {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        for count in [Self.bound + 1, 20_000, 55_555] {
            let text = String((0..<count).map { alphabet[($0 * 7 + $0 / 36) % alphabet.count] })
            #expect(ProvenanceStderr.truncated(text) == Self.marker, "\(count)")
        }
    }

    // MARK: Line endings, and cutting twice

    @Test("carriage return line endings are line boundaries too")
    func carriageReturnLineEndingsAreLineBoundaries() throws {
        let text = (1...400).map {
            "[bam_sort] writing to \(Self.projectRoot)/Analyses/classify-1/part-\(String(format: "%04d", $0)).sorted.bam"
        }.joined(separator: "\r\n") + "\r\n"
        let kept = try #require(ProvenanceStderr.truncated(text))
        let (head, tail) = try Self.sides(of: kept)

        let inputLines = Set(text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init))
        for line in head.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            + tail.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            #expect(inputLines.contains(String(line)), "kept a fragment: \(line.prefix(80))")
        }
        #expect(!head.hasSuffix("\r"), "a carriage return would join the marker's line feed into one character")
        #expect(kept.hasSuffix("part-0400.sorted.bam\r\n"))
    }

    @Test("cutting a cut stderr changes nothing, even one character over the bound")
    func cuttingTwiceChangesNothing() throws {
        // The head keeps 2,028 characters and the tail 8,192, so the first cut is 10,241
        // characters long and the second pass sees a value over the bound again.
        let head = String(repeating: "h", count: 2_028)
        let tail = String(repeating: "t", count: 8_191)
        let text = head + "\n" + String(repeating: "m ", count: 600) + "\n" + tail + "\n"
        let once = try #require(ProvenanceStderr.truncated(text))
        let (keptHead, keptTail) = try Self.sides(of: once)
        #expect(keptHead == head)
        #expect(keptTail == tail + "\n")
        #expect(once.count == Self.bound + 1)
        #expect(ProvenanceStderr.truncated(once) == once)
        #expect(ProvenanceStderr.normalized(once) == once)

        let log = try Self.logCutInsidePaths()
        let kept = try #require(ProvenanceStderr.truncated(log))
        #expect(ProvenanceStderr.truncated(kept) == kept)
    }
}

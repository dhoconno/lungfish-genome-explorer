// ProvenanceStderrTokenSafetyTests.swift - A cut stderr never keeps a fragment of a token
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import LungfishCore

/// Row 438 of the Phase 2.7 plan, decision P4 of Phase 2.8. The writer of a project's
/// record rewrites an absolute path only when it sees the whole path, so a cut inside a
/// path leaves the rest of it, folder names included, in a record that people share.
/// `ProvenanceStderrLineBoundaryTests` pins the cut where a window holds a line break.
/// These tests pin the windows that hold none, which are one token longer than a window,
/// as a list of project paths is, and a path that holds a space.
@Suite("Provenance stderr token safety")
struct ProvenanceStderrTokenSafetyTests {
    private static let marker = ProvenanceStderr.truncationMarker
    private static let banner = "mytool 1.2.3 starting with 8 threads"
    private static let lastLine = "ERROR: out of memory in stage 7, exiting"

    /// Where a project sits on an invented machine. The folder names are unique, so a name
    /// that survives in a kept text can be found. `parent` holds a space in the second
    /// layout, the way "My Projects" does on a real machine.
    private struct Layout {
        let parent: String
        let outer = UUID().uuidString
        let project = "Study-\(UUID().uuidString).lungfish"

        var root: String { "\(parent)/\(outer)/\(project)" }
        var names: [String] { [outer, project] }
        var entry: String { root + "/a" }
    }

    enum Position: CaseIterable, Sendable {
        case first
        case last
    }

    private enum SetupError: Error {
        case noAlignment
    }

    // MARK: Fixtures

    /// A stderr of one short line and one line that lists 90 project paths with commas
    /// between them, which is longer than the 8,192-character tail window and so holds no
    /// line break. `pad` lengthens the last path so the cut can be moved along the paths.
    private static func stderr(_ layout: Layout, _ position: Position, pad: Int = 0) -> String {
        let paths = Array(repeating: layout.entry, count: 89) + [layout.entry + String(repeating: "a", count: pad)]
        let list = paths.joined(separator: ",")
        switch position {
        case .first: return list + "\n" + lastLine + "\n"
        case .last: return banner + "\n" + list + "\n"
        }
    }

    /// A stderr whose tail window starts 1 to 24 characters into a path, which is before
    /// both folder names of that path.
    private static func stderrWithTheTailCutInsideAPath(_ layout: Layout) throws -> String {
        let period = layout.entry.count + 1
        for pad in 0..<period {
            let text = stderr(layout, .last, pad: pad)
            let offset = (text.count - ProvenanceStderr.tailLength - (banner.count + 1)) % period
            if (1...24).contains(offset) {
                return text
            }
        }
        throw SetupError.noAlignment
    }

    /// What a kept text holds that it must not, which is a line the stderr never had and a
    /// folder name that stays in the text after the writer rewrote its paths.
    private static func fragments(in kept: String, of text: String, _ layout: Layout) -> [String] {
        let inputLines = Set(text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        var found: [String] = []
        for side in kept.components(separatedBy: marker) {
            for line in side.split(separator: "\n") where !inputLines.contains(String(line)) {
                found.append("a fragment of a line: \(line.prefix(60))")
            }
        }
        let context = PortablePath.Context(projectURL: URL(fileURLWithPath: layout.root), accountName: nil)
        let written = PortablePath.sanitize(text: kept, context: context)
        for name in layout.names where written.contains(name) {
            found.append("a folder name survives the path rewrite: \(name)")
        }
        return found
    }

    // MARK: Row 438

    @Test("a token longer than a window leaves no fragment of a private path", arguments: Position.allCases)
    func aTokenLongerThanAWindowLeavesNoFragment(position: Position) throws {
        let layout = Layout(parent: "/Users/analyst/Projects")
        let text = position == .last ? try Self.stderrWithTheTailCutInsideAPath(layout) : Self.stderr(layout, .first)
        #expect(text.count > ProvenanceStderr.maxLength)
        let listLine = try #require(text.split(separator: "\n").first { $0.count > ProvenanceStderr.tailLength })
        #expect(!listLine.contains(" "), "one token, longer than the tail window")

        let kept = try #require(ProvenanceStderr.truncated(text))
        #expect(Self.fragments(in: kept, of: text, layout) == [])
    }

    @Test("a path with a space is never cut at its space", arguments: Position.allCases)
    func aPathWithASpaceIsNeverCutAtItsSpace(position: Position) throws {
        let layout = Layout(parent: "/Users/analyst/My Projects")
        let text = Self.stderr(layout, position)
        #expect(text.count > ProvenanceStderr.maxLength)
        let listLine = try #require(text.split(separator: "\n").first { $0.count > ProvenanceStderr.tailLength })
        #expect(listLine.filter { $0 == " " }.count == 90, "the only spaces are the one inside each path")

        let kept = try #require(ProvenanceStderr.truncated(text))
        #expect(Self.fragments(in: kept, of: text, layout) == [])
    }

    // MARK: A side whose window holds no line break keeps nothing

    @Test("the side whose window holds no line break keeps nothing and the other side keeps its whole lines")
    func aSideWithoutALineBreakKeepsNothing() throws {
        let layout = Layout(parent: "/Users/analyst/Projects")
        let first = Self.stderr(layout, .first)
        let last = try Self.stderrWithTheTailCutInsideAPath(layout)

        #expect(ProvenanceStderr.truncated(first) == Self.marker + Self.lastLine + "\n", "the head is the long line")
        #expect(ProvenanceStderr.truncated(last) == Self.banner + Self.marker, "the tail is the long line")
    }

    @Test("one line longer than the bound keeps only the marker, and a cut twice changes nothing")
    func oneLongLineKeepsOnlyTheMarker() throws {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        for count in [ProvenanceStderr.maxLength + 1, 20_000, 55_555] {
            let line = String((0..<count).map { alphabet[($0 * 7 + $0 / 36) % alphabet.count] })
            for text in [line, line + "\n", "\n\n" + line + "\r\n"] {
                let kept = try #require(ProvenanceStderr.truncated(text))
                #expect(kept == Self.marker, "\(count) characters")
                #expect(ProvenanceStderr.truncated(kept) == kept)
                #expect(ProvenanceStderr.normalized(text) == Self.marker, "the marker is not a blank stderr")
            }
        }
    }

    @Test("a long line between short lines is left out whole, and the short lines on both sides are kept")
    func aLongLineInTheMiddleIsLeftOutWhole() throws {
        let layout = Layout(parent: "/Users/analyst/My Projects")
        let list = Self.stderr(layout, .last).split(separator: "\n")[1]
        let text = [Self.banner, String(list), Self.lastLine].joined(separator: "\n") + "\n"
        #expect(ProvenanceStderr.truncated(text) == Self.banner + Self.marker + Self.lastLine + "\n")
    }

    @Test("a window that holds only whitespace keeps nothing")
    func aWindowOfWhitespaceKeepsNothing() throws {
        let body = (1...200).map { "line \($0) of a log that has text in it" }.joined(separator: "\n")
        let blanks = String(repeating: " \n", count: 5_000)

        let blankHead = try #require(ProvenanceStderr.truncated(blanks + body))
        #expect(blankHead.hasPrefix(Self.marker), "nothing is kept of the blank start")
        #expect(blankHead.hasSuffix("line 200 of a log that has text in it"))

        let blankTail = try #require(ProvenanceStderr.truncated(body + "\n" + blanks))
        #expect(blankTail.hasPrefix("line 1 of a log that has text in it\n"))
        #expect(blankTail.hasSuffix(Self.marker), "nothing is kept of the blank end")
    }
}

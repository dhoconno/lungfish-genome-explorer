// ProvenanceCommandPresentation.swift - A recorded command as a reader should see it
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A step records the command that ran with every path spelt in full, so a
// record written on another machine names that machine's project folder and
// a record read here names the user's own home folder. The Inspector shows
// each path argument the way ProvenancePathPresentation shows a path on its
// own: project-relative inside the open project (or under a foreign project
// root), by name for a scratch file the project did not keep, and otherwise
// as recorded. Nothing else in the command is touched, and the recorded
// command stays whole for the tooltip, assistive technology and copying.
//
// The reader turns a recorded `@/Inputs/x` into the project's path without
// quotes, so a project folder named `Legacy Records.lungfish` reaches this
// file as two words. The splitter is told that path and keeps it in one word,
// which the presentation then shows project-relative like any other path.
//
// A shell's `-c` script is one word that holds a whole command. It is
// presented as a command of its own, so the program in it stays and each path
// in it is shortened, and the script is quoted again as one word.

import Foundation
import LungfishCore

public enum ProvenanceCommandPresentation {
    /// One shell word with the text it came from, so an untouched word goes
    /// back out exactly as recorded.
    struct Word: Equatable {
        /// The word's source text, quotes and escapes included.
        var raw: String
        /// The word after quote removal.
        var value: String
        /// True when the word holds the project's path with its white space
        /// unquoted, as a record resolved it. Its `raw` text escapes that white
        /// space, and the presentation quotes the word whether it shortens it or not.
        var joinedProjectPath = false
    }

    /// The command with each path argument presented for a reader inside
    /// `projectURL`. The word after a shell and its `-c` (or a cluster such as
    /// `-lc`) is a script and is presented as a command of its own. A command
    /// that cannot be split into shell words, or one read outside any project,
    /// is returned as recorded. A path under the reader's own managed tool root, `toolRoot`, shows the tool's name, so
    /// a record reads the same whatever storage root the Mac keeps (Phase 2.12 lane 12.25, SW17 (a), Q-U6). The caller
    /// reads that root once, off the main actor, and passes it, and with none a tool's path shows whole, so this reads
    /// no storage configuration of its own (Phase 2.13 lane 13.45, M875 TOOLROOT-ONCE).
    public static func display(
        _ command: String,
        projectURL: URL?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        toolRoot: URL? = nil
    ) -> String {
        guard let projectURL, let pieces = split(command, keeping: spacedPaths(of: projectURL)) else { return command }
        var shown = ""
        // The values of the two words before the current one.
        var recent: [String] = []
        for piece in pieces {
            switch piece {
            case .separator(let text):
                shown += text
            case .word(let word):
                let isScript = recent.count == 2 && isShell(recent[0]) && isCommandFlag(recent[1])
                shown += isScript
                    ? presentScript(word, projectURL: projectURL, fileExists: fileExists, toolRoot: toolRoot)
                    : present(word, projectURL: projectURL, fileExists: fileExists, toolRoot: toolRoot)
                recent = Array((recent + [word.value]).suffix(2))
            }
        }
        return shown
    }

    /// One path on its own, without shell quoting: project-relative inside
    /// the open project or under a foreign project root, by name for a
    /// scratch file the project did not keep, by the tool's name under `toolRoot`, otherwise as recorded.
    public static func displayPath(
        _ path: String,
        projectURL: URL?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        toolRoot: URL? = nil
    ) -> String {
        if let toolRoot, !path.hasSuffix("/"),
           Set([toolRoot.path, toolRoot.standardizedFileURL.path]).contains(where: { path.hasPrefix($0 + "/") }) {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        let shown = ProvenancePathPresentation.present(path, projectURL: projectURL, fileExists: fileExists)
        switch shown.location {
        case .project, .otherProject:
            return shown.label
        case .external:
            return shown.detail == ProvenancePathPresentation.intermediateDetail ? shown.label : path
        case .stream:
            return path
        }
    }

    /// The full command with each run of the project's path that holds white space, which the reader resolved from
    /// a recorded `@/Inputs/x` without quotes, quoted as one shell word (Phase 2.10 lane U35, row 273 of Phase 2.8).
    /// A redirection operator or a `key=` prefix stays outside the quotes. A command whose project path holds no white
    /// space, one read outside any project, and one that cannot be split into shell words are returned as recorded,
    /// and so is every word that is not such a path, with its own quotes and escapes.
    public static func quotingProjectPath(_ command: String, projectURL: URL?) -> String {
        guard let projectURL else { return command }
        let spaced = spacedPaths(of: projectURL)
        guard !spaced.isEmpty, let pieces = split(command, keeping: spaced) else { return command }
        return pieces.map { piece -> String in
            switch piece {
            case .separator(let text):
                return text
            case .word(let word):
                guard word.joinedProjectPath, let part = pathPart(of: word.value) else { return word.raw }
                return part.isRedirect ? part.prefix + shellEscape(part.path) : shellEscape(part.prefix + part.path)
            }
        }.joined()
    }

    // MARK: - Words

    private static func present(_ word: Word, projectURL: URL?, fileExists: (String) -> Bool, toolRoot: URL?) -> String {
        guard let part = pathPart(of: word.value) else { return word.raw }
        // A path glued to the `;` that ends its command, as in the guards of an older Kraken2 batch script, keeps
        // that `;` outside the shortened path and its quotes.
        let terminator = part.path.hasSuffix(";") ? ";" : ""
        let path = String(part.path.dropLast(terminator.count))
        let label = displayPath(path, projectURL: projectURL, fileExists: fileExists, toolRoot: toolRoot)
        guard label != path || word.joinedProjectPath else { return word.raw }
        let shown = part.isRedirect ? part.prefix + shellEscape(label) : shellEscape(part.prefix + label)
        return shown + terminator
    }

    /// The programs whose `-c` argument is a script.
    private static let shellNames: Set<String> = ["sh", "bash", "zsh", "dash"]

    /// True when `word` names a shell by the last component of its path, as `/bin/sh` and `bash` do.
    static func isShell(_ word: String) -> Bool {
        word.split(separator: "/").last.map { shellNames.contains(String($0)) } ?? false
    }

    /// True for `-c` and for a cluster of single-letter options that holds `c`, such as `-lc` or `-ec`.
    static func isCommandFlag(_ word: String) -> Bool {
        guard word.hasPrefix("-"), !word.hasPrefix("--") else { return false }
        let letters = word.dropFirst()
        return letters.contains("c") && letters.allSatisfy { $0.isASCII && $0.isLetter }
    }

    /// A shell's script as one word. `display` runs on its value, so the program stays and each path shortens, and the
    /// result is quoted again as one word. A script that nothing changed goes back out as recorded.
    private static func presentScript(_ word: Word, projectURL: URL?, fileExists: (String) -> Bool, toolRoot: URL?) -> String {
        let shown = display(word.value, projectURL: projectURL, fileExists: fileExists, toolRoot: toolRoot)
        return shown == word.value ? word.raw : shellEscape(shown)
    }

    /// The spellings of the project's path that hold white space, longest first.
    static func spacedPaths(of projectURL: URL) -> [String] {
        Set([projectURL.standardizedFileURL.path, projectURL.path])
            .filter { $0.contains(where: \.isWhitespace) }
            .sorted { $0.count > $1.count }
    }

    /// True when `path` starts at `index` as a whole path: at the start of a
    /// word or after `=`, `<` or `>`, and followed by `/`, white space or the
    /// end, so a folder that only starts like the project's is not joined.
    private static func startsPath(_ path: String, in command: String, at index: String.Index) -> Bool {
        guard command[index...].hasPrefix(path) else { return false }
        if index > command.startIndex {
            let before = command[command.index(before: index)]
            guard before.isWhitespace || "=<>".contains(before) else { return false }
        }
        let end = command.index(index, offsetBy: path.count, limitedBy: command.endIndex) ?? command.endIndex
        return end == command.endIndex || command[end] == "/" || command[end].isWhitespace
    }

    /// The path inside a word and whatever precedes it: nothing for a bare
    /// path, a redirection operator, or a `key=` or `--flag=` prefix.
    static func pathPart(of value: String) -> (prefix: String, path: String, isRedirect: Bool)? {
        if looksLikePath(value) { return ("", value, false) }
        if let operatorLength = redirectionOperatorLength(of: value) {
            let rest = String(value.dropFirst(operatorLength))
            return looksLikePath(rest) ? (String(value.prefix(operatorLength)), rest, true) : nil
        }
        if let equals = value.firstIndex(of: "="), equals > value.startIndex {
            let key = value[..<equals]
            let rest = String(value[value.index(after: equals)...])
            guard !key.contains("/"), !key.contains(where: \.isWhitespace), looksLikePath(rest) else { return nil }
            return (String(value[...equals]), rest, false)
        }
        return nil
    }

    private static func looksLikePath(_ text: String) -> Bool {
        if text.hasPrefix("/") { return true }
        // A portable placeholder such as `<workspace>/outputs/x.vcf`.
        guard text.hasPrefix("<"), let close = text.firstIndex(of: ">") else { return false }
        let name = text[text.index(after: text.startIndex)..<close]
        return !name.isEmpty && name.allSatisfy(\.isLetter) && text[close...].hasPrefix(">/")
    }

    /// The length of a leading `>`, `>>`, `<`, `2>` or `2>>`.
    private static func redirectionOperatorLength(of value: String) -> Int? {
        var index = value.startIndex
        while index < value.endIndex, value[index].isNumber { index = value.index(after: index) }
        guard index < value.endIndex else { return nil }
        if value[index] == "<" {
            return index == value.startIndex ? 1 : nil
        }
        guard value[index] == ">" else { return nil }
        index = value.index(after: index)
        if index < value.endIndex, value[index] == ">" { index = value.index(after: index) }
        return value.distance(from: value.startIndex, to: index)
    }

    // MARK: - Splitting

    enum Piece: Equatable {
        case word(Word)
        case separator(String)
    }

    /// Splits a command into shell words and the whitespace between them,
    /// following POSIX quoting: single quotes are literal, double quotes let a
    /// backslash escape `"`, `\`, `$` and a backquote, and a bare backslash
    /// escapes the next character. Returns nil on an unterminated quote or a
    /// trailing backslash. An unquoted run of text that spells one of `paths`
    /// stays inside its word, white space and all, and the word's `raw` text
    /// escapes that white space.
    static func split(_ command: String, keeping paths: [String] = []) -> [Piece]? {
        var pieces: [Piece] = []
        var raw = ""
        var value = ""
        var inWord = false
        var joined = false
        var separator = ""
        var index = command.startIndex

        func flushWord() {
            if inWord {
                pieces.append(.word(Word(raw: raw, value: value, joinedProjectPath: joined)))
                raw = ""
                value = ""
                inWord = false
                joined = false
            }
        }
        func flushSeparator() {
            if !separator.isEmpty {
                pieces.append(.separator(separator))
                separator = ""
            }
        }

        while index < command.endIndex {
            let character = command[index]
            if character.isWhitespace {
                flushWord()
                separator.append(character)
                index = command.index(after: index)
                continue
            }
            flushSeparator()
            inWord = true
            switch character {
            case "'":
                guard let close = command[command.index(after: index)...].firstIndex(of: "'") else { return nil }
                raw.append(contentsOf: command[index...close])
                value.append(contentsOf: command[command.index(after: index)..<close])
                index = command.index(after: close)
            case "\"":
                var cursor = command.index(after: index)
                var closed = false
                while cursor < command.endIndex {
                    let inner = command[cursor]
                    if inner == "\"" {
                        closed = true
                        break
                    }
                    if inner == "\\" {
                        let next = command.index(after: cursor)
                        guard next < command.endIndex else { return nil }
                        if ["\"", "\\", "$", "`"].contains(command[next]) {
                            value.append(command[next])
                        } else if command[next] != "\n" {
                            value.append(inner)
                            value.append(command[next])
                        }
                        cursor = command.index(after: next)
                        continue
                    }
                    value.append(inner)
                    cursor = command.index(after: cursor)
                }
                guard closed else { return nil }
                raw.append(contentsOf: command[index...cursor])
                index = command.index(after: cursor)
            case "\\":
                let next = command.index(after: index)
                guard next < command.endIndex else { return nil }
                raw.append(contentsOf: command[index...next])
                value.append(command[next])
                index = command.index(after: next)
            default:
                if let path = paths.first(where: { startsPath($0, in: command, at: index) }) {
                    raw.append(contentsOf: path.map { $0.isWhitespace ? "\\\($0)" : String($0) }.joined())
                    value.append(contentsOf: path)
                    joined = true
                    index = command.index(index, offsetBy: path.count, limitedBy: command.endIndex) ?? command.endIndex
                } else {
                    raw.append(character)
                    value.append(character)
                    index = command.index(after: index)
                }
            }
        }
        flushWord()
        flushSeparator()
        return pieces
    }
}

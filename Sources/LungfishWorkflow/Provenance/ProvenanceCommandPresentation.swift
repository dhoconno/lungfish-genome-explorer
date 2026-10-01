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
    }

    /// The command with each path argument presented for a reader inside
    /// `projectURL`. A command that cannot be split into shell words, or one
    /// read outside any project, is returned as recorded.
    public static func display(
        _ command: String,
        projectURL: URL?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        guard projectURL != nil, let pieces = split(command) else { return command }
        return pieces.map { piece -> String in
            switch piece {
            case .separator(let text):
                return text
            case .word(let word):
                return present(word, projectURL: projectURL, fileExists: fileExists)
            }
        }.joined()
    }

    /// One path on its own, without shell quoting: project-relative inside
    /// the open project or under a foreign project root, by name for a
    /// scratch file the project did not keep, otherwise as recorded.
    public static func displayPath(
        _ path: String,
        projectURL: URL?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
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

    // MARK: - Words

    private static func present(_ word: Word, projectURL: URL?, fileExists: (String) -> Bool) -> String {
        guard let part = pathPart(of: word.value) else { return word.raw }
        let label = displayPath(part.path, projectURL: projectURL, fileExists: fileExists)
        guard label != part.path else { return word.raw }
        return part.isRedirect ? part.prefix + shellEscape(label) : shellEscape(part.prefix + label)
    }

    /// The path inside a word and whatever precedes it: nothing for a bare
    /// path, a redirection operator, or a `key=` or `--flag=` prefix.
    private static func pathPart(of value: String) -> (prefix: String, path: String, isRedirect: Bool)? {
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
    /// trailing backslash.
    static func split(_ command: String) -> [Piece]? {
        var pieces: [Piece] = []
        var raw = ""
        var value = ""
        var inWord = false
        var separator = ""
        var index = command.startIndex

        func flushWord() {
            if inWord {
                pieces.append(.word(Word(raw: raw, value: value)))
                raw = ""
                value = ""
                inWord = false
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
                raw.append(character)
                value.append(character)
                index = command.index(after: index)
            }
        }
        flushWord()
        flushSeparator()
        return pieces
    }
}

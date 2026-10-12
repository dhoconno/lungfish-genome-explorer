// ProvenanceStderr.swift - The one rule for how much of a tool's stderr a provenance record keeps
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum ProvenanceStderr {
    /// Tools print their banner first and their errors, versions and summaries
    /// last, so a stderr over `maxLength` keeps its start and its end. The head
    /// holds at most `headLength` characters and the tail at most `tailLength`.
    /// Anything at or under `maxLength` is kept whole.
    public static let headLength = 2_048
    public static let tailLength = 8_192
    public static let maxLength = headLength + tailLength
    /// Joins the head and the tail. It carries no count, so two cuts of
    /// different lengths read the same.
    public static let truncationMarker = "\n... [truncated] ...\n"

    /// The stderr a record keeps, and nil for a nil stderr.
    ///
    /// A value of at most `maxLength` characters is kept whole. A longer one
    /// keeps the lines that begin it and the lines that end it around
    /// `truncationMarker`, and every kept line is a whole line the tool printed.
    /// The head ends at the last line break within its first `headLength`
    /// characters. The tail starts after the first line break within its last
    /// `tailLength` characters. A cut inside a line would leave half of an
    /// absolute path, and the sanitizer that rewrites paths when the record is
    /// written cannot recognise a path that has lost its start.
    ///
    /// A window that holds no line break lies inside one line that is longer
    /// than the window, so that side keeps nothing. The cut never falls at a
    /// space or at a character, because a token cut there leaves a fragment of
    /// a path, and a path may hold a space. A break before the first visible
    /// character or after the last one does not count, so the newline that ends
    /// a stderr never makes the tail start after the last line. The result is at
    /// most `maxLength` plus the marker long, and a value that an earlier cut
    /// produced comes back as it is, so cutting twice changes nothing more.
    public static func truncated(_ stderr: String?) -> String? {
        guard let stderr else {
            return nil
        }
        let count = stderr.count
        guard count > maxLength else {
            return stderr
        }
        if count <= maxLength + truncationMarker.count,
           stderr.range(of: truncationMarker, options: .literal) != nil {
            return stderr
        }
        return String(stderr[..<headEnd(in: stderr)]) + truncationMarker + String(stderr[tailStart(in: stderr)...])
    }

    /// ``truncated(_:)`` of a stderr that holds more than whitespace, and nil
    /// for a blank one.
    public static func normalized(_ stderr: String?) -> String? {
        guard let stderr = truncated(stderr) else {
            return nil
        }
        return stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : stderr
    }

    /// Where the kept head ends in a text longer than `maxLength`, and the start
    /// of the text when the head keeps nothing. The window is the first
    /// `headLength` characters, and the character after it also counts, because
    /// a break there means the window ends on a whole line.
    private static func headEnd(in text: String) -> String.Index {
        let limit = text.index(text.startIndex, offsetBy: headLength)
        guard let firstVisible = text.firstIndex(where: { !$0.isWhitespace }), firstVisible < limit,
              let cut = text[text.index(after: firstVisible)...limit].lastIndex(where: \.isNewline) else {
            return text.startIndex
        }
        // Blank lines before the cut say nothing, and a carriage return left at
        // the end would join the marker's line feed into one character.
        return text[..<cut].lastIndex(where: { !$0.isNewline }).map { text.index(after: $0) } ?? cut
    }

    /// Where the kept tail starts in a text longer than `maxLength`, and the end
    /// of the text when the tail keeps nothing. The window is the last
    /// `tailLength` characters, and the character before it also counts, because
    /// a break there means the window starts on a whole line.
    private static func tailStart(in text: String) -> String.Index {
        let windowStart = text.index(text.endIndex, offsetBy: -tailLength)
        guard let lastVisible = text.lastIndex(where: { !$0.isWhitespace }), lastVisible >= windowStart,
              let cut = text[text.index(before: windowStart)..<lastVisible].firstIndex(where: \.isNewline) else {
            return text.endIndex
        }
        let start = text.index(after: cut)
        return text[start...].firstIndex(where: { !$0.isNewline }) ?? start
    }
}

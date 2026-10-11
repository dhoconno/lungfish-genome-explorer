// ProvenanceInspectorViewModel+RawJSON.swift - What the Raw JSON pane shows and says about its text
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The part of a record's text the Raw JSON pane draws, and what the pane says about the rest.
///
/// The Provenance tab never shows a cut view of a record without saying so. The pane draws the
/// first 80 lines of the text, cut here by the lines of the record and not by the text view, so
/// the caption can give the lines shown and the lines there are. Copy always takes the whole text.
struct ProvenanceRawJSONDisplay: Equatable {
    /// The pane draws at most this many lines of the record.
    static let maximumShownLines = 80
    /// The pane also draws at most this many characters, so one very long line cannot make it slow.
    static let maximumShownCharacters = 20_000

    /// The text the pane draws, the start of the whole text.
    let shownText: String
    /// One sentence for each fact a reader needs about the text, in the order the pane lists them.
    let captions: [String]

    init(text: String) {
        let scan = Self.scan(text, lineLimit: Self.maximumShownLines)
        let withinLines = scan.cut.map { String(text[..<$0]) } ?? text
        if withinLines.count > Self.maximumShownCharacters {
            shownText = String(withinLines.prefix(Self.maximumShownCharacters))
            captions = [
                "Showing the first \(Self.maximumShownCharacters) of \(text.count) characters. "
                    + "Copy takes the whole record.",
            ]
        } else if scan.cut != nil {
            shownText = withinLines
            captions = [
                "Showing the first \(Self.maximumShownLines) of \(scan.lines) lines. "
                    + "Copy takes the whole record.",
            ]
        } else {
            shownText = text
            captions = []
        }
    }

    /// The number of lines in `text`, and the end of its `lineLimit`th line when it has more.
    ///
    /// A line ends at a line feed, and a final line feed does not start another line.
    private static func scan(_ text: String, lineLimit: Int) -> (lines: Int, cut: String.Index?) {
        let utf8 = text.utf8
        var lines = 0
        var cut: String.Index?
        var last: UInt8?
        var index = utf8.startIndex
        while index != utf8.endIndex {
            let byte = utf8[index]
            if byte == 0x0A {
                lines += 1
                if lines == lineLimit { cut = index }
            }
            last = byte
            index = utf8.index(after: index)
        }
        if let last, last != 0x0A { lines += 1 }
        return (lines, lines > lineLimit ? cut : nil)
    }
}

extension ProvenanceInspectorViewModel {
    /// What the Raw JSON pane draws and says, from the text Copy takes.
    var rawJSONDisplay: ProvenanceRawJSONDisplay {
        ProvenanceRawJSONDisplay(text: rawJSON)
    }
}

// ProvenanceInspectorViewModel+RawJSON.swift - What the Raw JSON pane shows and says about its text
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishWorkflow

/// Where the text of the Raw JSON pane came from.
enum ProvenanceRawJSONSource: Equatable, Sendable {
    /// No record is shown.
    case none
    /// The sidecar file's own text.
    case file
    /// The record encoded again, because no file text was read or the file cannot be shown as text.
    case decodedRecord
    /// A record past the display caps, whose text the pane does not hold.
    case tooLarge
}

/// What the Raw JSON pane draws and says about the record.
///
/// The Provenance tab never shows an empty, cut or substituted view of a record without saying
/// so. The pane draws the first 80 lines of the text, cut here by the lines of the record and
/// not by the text view, so the caption can give the lines shown and the lines there are. Copy
/// always takes the whole text.
struct ProvenanceRawJSONDisplay: Equatable {
    /// The pane draws at most this many lines of the record.
    static let maximumShownLines = 80
    /// The pane also draws at most this many characters, so one very long line cannot make it slow.
    static let maximumShownCharacters = 20_000

    static let noRecordMessage = "No raw provenance JSON is available."
    static let tooLargeMessage = "This record is too large to show here."
    static let notShownMessage = "This record could not be shown as text."

    enum Content: Equatable {
        /// There is no record, so there is no JSON.
        case noRecord
        /// The record exists and the pane holds none of its text, with the sentence that says why.
        case notShown(String)
        /// The text, or the start of it.
        case text
    }

    let content: Content
    /// The text the pane draws, the start of the whole text.
    let shownText: String
    /// One sentence for each fact a reader needs about the text, in the order the pane lists them.
    let captions: [String]
    /// The sidecar the pane offers to reveal in Finder when it holds no text.
    let revealURL: URL?

    init(text: String, source: ProvenanceRawJSONSource, hasRecord: Bool, sidecarURL: URL?) {
        guard !text.isEmpty else {
            shownText = ""
            captions = []
            if source == .tooLarge {
                content = .notShown(Self.tooLargeMessage)
            } else if hasRecord {
                content = .notShown(Self.notShownMessage)
            } else {
                content = .noRecord
            }
            revealURL = hasRecord ? sidecarURL : nil
            return
        }
        content = .text
        revealURL = nil
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
        ProvenanceRawJSONDisplay(
            text: rawJSON,
            source: rawJSONSource,
            hasRecord: resolvedEnvelope != nil,
            sidecarURL: resolvedSidecarURL
        )
    }

    /// Shows the sidecar in Finder, for a record the pane holds no text of.
    func revealSidecarInFinder() {
        guard let resolvedSidecarURL else { return }
        revealer(resolvedSidecarURL)
    }

    /// Sets the text of the pane and says where it came from.
    ///
    /// A record past the caps has no text. Otherwise the pane shows the sidecar's own text when the
    /// lookup read it, and the record encoded again when it did not.
    func applyRawJSON(for envelope: ProvenanceEnvelope, fileRowCount: Int, sidecarText: String?) {
        guard Self.shouldInlineRawJSON(fileRowCount: fileRowCount, envelope: envelope) else {
            rawJSON = ""
            rawJSONSource = .tooLarge
            return
        }
        if let sidecarText {
            rawJSON = sidecarText
            rawJSONSource = .file
        } else {
            rawJSON = Self.encodedRecordJSON(envelope)
            rawJSONSource = .decodedRecord
        }
    }

    /// Whether the record is small enough for the pane. Past 500 file rows, or 200 paths in a step,
    /// the Inspector shows no text of it.
    nonisolated static func shouldInlineRawJSON(fileRowCount: Int, envelope: ProvenanceEnvelope) -> Bool {
        guard fileRowCount <= maximumDisplayedFileRows else {
            return false
        }
        return !envelope.steps.contains {
            $0.inputs.count > maximumDisplayedStepPaths
                || $0.outputs.count > maximumDisplayedStepPaths
        }
    }

    /// The record encoded as the writers encode it, or empty when it cannot be.
    static func encodedRecordJSON(_ envelope: ProvenanceEnvelope) -> String {
        guard let data = try? ProvenanceJSON.encoder.encode(envelope) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

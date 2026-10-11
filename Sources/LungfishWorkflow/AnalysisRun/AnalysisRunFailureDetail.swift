// AnalysisRunFailureDetail.swift - Bounds the failure detail a unit hands the executor for the run's failed line
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The one place that bounds and cleans the text a unit hands over with
/// ``AnalysisRunUnitContext/recordFailureDetail(_:)`` before it rides on the run's `failed` line as
/// `detail` (2.7 A8d review, UX D11). Every tool's detail passes through it, so a reader gets the
/// same shape whatever tool failed.
///
/// The rules, in order. Carriage returns become line breaks, since kraken2 and Bracken redraw
/// their progress with them. ANSI colour sequences go, by the rule
/// `EsVirituFailureDiagnosis.tail(ofLog:count:)` strips them with, and so does every other control
/// character but a tab. Lines that are blank after trimming go. The last ``lineLimit`` lines stay,
/// each cut to ``lineLengthLimit`` characters, and whole leading lines go until the text fits in
/// ``byteLimit`` UTF-8 bytes. The text gets no heading, since its words belong to the reader, and
/// no path is rewritten, since the stream stays on this Mac.
enum AnalysisRunFailureDetail {
    /// The lines kept, today's EsViritu log tail count.
    static let lineLimit = 20
    /// The characters kept of each line.
    static let lineLengthLimit = 400
    /// The UTF-8 bytes the whole detail may take.
    static let byteLimit = 4096

    /// `text` bounded and cleaned by the rules above, or nil when nothing is left.
    static func bounded(_ text: String) -> String? {
        let unixLines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let withoutColour = unixLines.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: withoutColour.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || scalar.properties.generalCategory != .control
        })
        var lines = String(scalars)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(lineLimit)
            .map { String($0.prefix(lineLengthLimit)) }
        while !lines.isEmpty, lines.joined(separator: "\n").utf8.count > byteLimit {
            lines.removeFirst()
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

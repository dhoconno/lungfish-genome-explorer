// OutputEquivalence+BBToolsMasks.swift - Mask M-6, the BBTools run time and rates in a provenance stderr
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// docs/contracts/CLI-EQUIVALENCE.md row "Mask M-6, BBTools run time and rates" names this mask. It lives in its own
// file because OutputEquivalence+Masks.swift is over the size baseline and may not grow. Lane C2-ONTBIN, the manager's
// option (b): a chunked ONT import keeps each reformat.sh step's stderr, whose read and base counts are provenance, and
// BBTools prints its clock beside them.

import Foundation

extension OutputEquivalence.Masks {
    /// Replaces the figures BBTools prints from the clock in the `stderr` of a provenance envelope. They are the seconds
    /// of the `Time: <n> seconds.` line and the rate after the count of each `Reads Processed:`, `Bases Processed:` and
    /// `Pairs Processed:` line (`<n>k reads/sec`, `<n>m bases/sec`), each line read from its start. It reads the string
    /// value of each `stderr` key and nothing else, so the `Input:` and `Output:` lines, the counts of the processed
    /// lines, the java command, the arguments, a line added or lost and the same text under another key or in a payload
    /// are compared as written.
    public static let bbtoolsRunTimes = OutputEquivalence.Mask(name: "bbtoolsRunTimes") { text, _ in
        rewritingJSON(text) { value, changed in maskBBToolsStderr(in: value, changed: &changed) }
    }

    /// Masks the BBTools run time and rates in each string value of a `stderr` key.
    static func maskBBToolsStderr(in value: Any, changed: inout Bool) -> Any {
        if let array = value as? [Any] {
            return array.map { maskBBToolsStderr(in: $0, changed: &changed) }
        }
        guard var object = value as? [String: Any] else { return value }
        for (key, item) in object {
            if key == "stderr", let stderr = item as? String {
                let masked = maskBBToolsRunTimes(in: stderr)
                if masked != stderr {
                    object[key] = masked
                    changed = true
                }
            } else {
                object[key] = maskBBToolsStderr(in: item, changed: &changed)
            }
        }
        return object
    }

    static func maskBBToolsRunTimes(in stderr: String) -> String {
        let timed = bbtoolsTimePattern.stringByReplacingMatches(
            in: stderr,
            range: NSRange(location: 0, length: (stderr as NSString).length),
            withTemplate: "$1<DURATION>$2"
        )
        return bbtoolsRatePattern.stringByReplacingMatches(
            in: timed,
            range: NSRange(location: 0, length: (timed as NSString).length),
            withTemplate: "$1<RATE>$2"
        )
    }

    /// `Time:` at the start of a line, its padding, the seconds and ` seconds.`.
    static var bbtoolsTimePattern: NSRegularExpression { try! NSRegularExpression(
        pattern: "^(Time:[ \\t]+)\(numberPattern)( seconds\\.)",
        options: [.anchorsMatchLines]
    ) }

    /// A processed line from its start through its count, which stays, then the rate with its `k` or `m` and its unit.
    static var bbtoolsRatePattern: NSRegularExpression { try! NSRegularExpression(
        pattern: "^((?:Reads|Bases|Pairs) Processed:[ \\t]+[0-9]+[kmb]?[ \\t]+)[0-9]+(?:\\.[0-9]+)?[kmb]?"
            + "( (?:reads|bases|pairs)/sec)",
        options: [.anchorsMatchLines]
    ) }
}

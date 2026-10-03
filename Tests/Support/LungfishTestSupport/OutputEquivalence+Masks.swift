// OutputEquivalence+Masks.swift - The masks docs/contracts/CLI-EQUIVALENCE.md allows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The patterns follow the binding rules of scripts/golden/normalize.py. A mask
// is added only by a reviewed change to the contract's "Same result" table.

import Foundation

extension Array where Element == OutputEquivalence.Mask {
    /// The contract's masks. Wall-clock times, run and operation UUIDs, the
    /// two run roots, and the executable path, host, process ID and wall time
    /// inside provenance envelopes.
    public static var standard: [OutputEquivalence.Mask] {
        [
            OutputEquivalence.Masks.roots,
            OutputEquivalence.Masks.uuids,
            OutputEquivalence.Masks.runIDs,
            OutputEquivalence.Masks.isoTimestamps,
            OutputEquivalence.Masks.epochValues,
            OutputEquivalence.Masks.provenanceRuntime,
            OutputEquivalence.Masks.contentComparedDigests,
        ]
    }
}

extension OutputEquivalence {
    public enum Masks {
        public static let rootToken = "<ROOT>"

        /// Replaces every spelling of either root with `<ROOT>`, including the
        /// `/private` twin of a temporary path and the JSON-escaped form.
        public static let roots = Mask(name: "roots") { text, context in
            var result = text
            for spelling in rootSpellings(context.rootA) + rootSpellings(context.rootB) {
                result = result.replacingOccurrences(of: spelling, with: rootToken)
            }
            return result
        }

        /// Replaces each distinct UUID with `<UUID-n>`, numbered by first
        /// appearance, so links inside one file survive the mask.
        public static let uuids = Mask(name: "uuids") { text, _ in
            var seen: [String: Int] = [:]
            return replace(uuidPattern, in: text) { match in
                let value = match.lowercased()
                if seen[value] == nil { seen[value] = seen.count + 1 }
                return "<UUID-\(seen[value]!)>"
            }
        }

        /// Replaces each identifier derived from a UUID, such as the `aln_`
        /// plus 8 hex digits track ID a filter run draws, with `<RUN-ID-n>`.
        /// The number comes from the side's `runIDNumbers`, so it is the same
        /// in a file name and in a manifest value, and a track mapped to the
        /// wrong ID still differs.
        public static let runIDs = Mask(name: "runIDs") { text, context in
            var extra: [String: Int] = [:]
            return replace(runIDPattern, in: text) { match in
                let value = match.lowercased()
                if let number = context.runIDNumbers[value] { return "<RUN-ID-\(number)>" }
                if extra[value] == nil { extra[value] = context.runIDNumbers.count + extra.count + 1 }
                return "<RUN-ID-\(extra[value]!)>"
            }
        }

        /// Replaces ISO 8601 dates and date-times with `<TIMESTAMP>`.
        public static let isoTimestamps = Mask(name: "isoTimestamps") { text, _ in
            replace(isoTimestampPattern, in: text) { _ in "<TIMESTAMP>" }
        }

        /// Replaces the numeric value of a JSON wall-clock key, such as a
        /// `Date` that `JSONEncoder` wrote as seconds, with `"<EPOCH>"`.
        public static let epochValues = Mask(name: "epochValues") { text, _ in
            replaceKeyValues(epochKeys, in: text, token: "<EPOCH>")
        }

        /// Replaces the executable path, host, process ID and wall time that
        /// a provenance envelope records.
        public static let provenanceRuntime = Mask(name: "provenanceRuntime") { text, _ in
            var result = replaceKeyValues(["executablePath"], in: text, token: "<EXECUTABLE>")
            result = replaceKeyValues(["host", "hostName", "hostname"], in: result, token: "<HOST>")
            result = replaceKeyValues(["processIdentifier", "pid"], in: result, token: "<PID>")
            return replaceKeyValues(
                ["wallTimeSeconds", "wallTime", "wallClockSeconds", "durationSeconds", "elapsedSeconds"],
                in: result,
                token: "<DURATION>"
            )
        }

        /// In a JSON record that names a file compared by content rather than
        /// by bytes (a BAM, a gzip or BGZF file, a SQLite database, an index
        /// or a JSON manifest compared after masks), replaces the checksum and size the record states. The file
        /// itself is still compared under its own kind, so only the record's
        /// copy of its byte-level digest is masked.
        public static let contentComparedDigests = Mask(name: "contentComparedDigests") { text, _ in
            guard let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { return text }
            var changed = false
            let masked = maskDigests(in: value, changed: &changed)
            guard changed,
                  let encoded = try? JSONSerialization.data(
                      withJSONObject: masked,
                      options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed, .withoutEscapingSlashes]
                  ),
                  let result = String(data: encoded, encoding: .utf8)
            else { return text }
            return result
        }

        static let contentComparedSuffixes = [
            ".bam", ".bai", ".csi", ".tbi", ".crai", ".gz", ".bgz", ".bgzf", ".db", ".sqlite", ".sqlite3", ".json",
        ]
        static let digestKeys: Set<String> = ["checksumSHA256", "sha256", "checksum"]
        static let sizeKeys: Set<String> = ["fileSize", "sizeBytes", "size_bytes", "file_size_bytes"]

        static func maskDigests(in value: Any, changed: inout Bool) -> Any {
            if let array = value as? [Any] {
                return array.map { maskDigests(in: $0, changed: &changed) }
            }
            guard var object = value as? [String: Any] else { return value }
            let namesContentComparedFile = object.values.contains { item in
                guard let path = item as? String else { return false }
                let lowered = path.lowercased()
                return contentComparedSuffixes.contains { lowered.hasSuffix($0) }
            }
            for (key, item) in object {
                if namesContentComparedFile, digestKeys.contains(key) {
                    object[key] = "<CONTENT-SHA256>"
                    changed = true
                } else if namesContentComparedFile, sizeKeys.contains(key) {
                    object[key] = "<CONTENT-SIZE>"
                    changed = true
                } else {
                    object[key] = maskDigests(in: item, changed: &changed)
                }
            }
            return object
        }

        static let epochKeys = [
            "createdAt", "endTime", "endedAt", "finishedAt", "recordedAt", "startTime", "startedAt", "timestamp",
        ]

        static var uuidPattern: NSRegularExpression { try! NSRegularExpression(
            pattern: "(?<![0-9A-Fa-f])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}(?![0-9A-Fa-f])"
        ) }

        static var runIDPattern: NSRegularExpression { try! NSRegularExpression(
            pattern: "(?<![A-Za-z0-9])aln_[0-9A-Fa-f]{8}(?![0-9A-Fa-f])"
        ) }

        static var isoTimestampPattern: NSRegularExpression { try! NSRegularExpression(
            pattern: "(?<![0-9])[0-9]{4}-[0-9]{2}-[0-9]{2}"
                + "(?:[T ][0-9]{2}[:\\-][0-9]{2}(?:[:\\-][0-9]{2}(?:[.,][0-9]+)?)?"
                + "(?:Z|[+\\-][0-9]{2}:?[0-9]{2})?)?(?![0-9])"
        ) }

        /// Each spelling of `root`, longest first, without a trailing slash.
        static func rootSpellings(_ root: URL) -> [String] {
            var forms: Set<String> = [
                root.path,
                root.standardizedFileURL.path,
                root.resolvingSymlinksInPath().path,
            ]
            for form in forms {
                if form.hasPrefix("/private/") {
                    forms.insert(String(form.dropFirst("/private".count)))
                } else if form.hasPrefix("/var/") || form.hasPrefix("/tmp/") {
                    forms.insert("/private" + form)
                }
            }
            let plain = forms
                .map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
                .filter { $0.count > 1 }
            let escaped = plain.map { $0.replacingOccurrences(of: "/", with: "\\/") }
            return Array(Set(plain + escaped)).sorted { $0.count > $1.count }
        }

        static func replace(
            _ pattern: NSRegularExpression,
            in text: String,
            with token: (String) -> String
        ) -> String {
            let source = text as NSString
            var result = ""
            var cursor = 0
            for match in pattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                result += token(source.substring(with: match.range))
                cursor = match.range.location + match.range.length
            }
            result += source.substring(from: cursor)
            return result
        }

        /// Replaces the value of each JSON key in `keys`, a string or a
        /// number, with the quoted `token`.
        static func replaceKeyValues(_ keys: [String], in text: String, token: String) -> String {
            let alternatives = keys.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            let pattern = try! NSRegularExpression(
                pattern: "(\"(?:\(alternatives))\"\\s*:\\s*)(\"(?:[^\"\\\\]|\\\\.)*\"|-?[0-9]+(?:\\.[0-9]+)?(?:[eE][+\\-]?[0-9]+)?)"
            )
            return pattern.stringByReplacingMatches(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length),
                withTemplate: "$1\"\(NSRegularExpression.escapedTemplate(for: token))\""
            )
        }
    }
}

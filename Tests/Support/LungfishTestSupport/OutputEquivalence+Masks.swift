// OutputEquivalence+Masks.swift - The masks docs/contracts/CLI-EQUIVALENCE.md allows
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The patterns follow the binding rules of scripts/golden/normalize.py. A mask
// is added only by a reviewed change to the contract's "Same result" table.

import Foundation

extension OutputEquivalence {
    /// The masks each kind of text in a tree gets. A mask hides a difference,
    /// so each one applies only where the contract names it.
    public struct MaskPolicy: Sendable {
        /// A provenance envelope, a JSON file whose name contains
        /// `provenance`.
        public var provenance: [Mask]
        /// A record a run keeps of its outputs, a JSON file whose name
        /// contains `manifest` or a SQLite database, compared on its dump.
        public var records: [Mask]
        /// The relative name of a file inside a bundle.
        public var names: [Mask]
        /// Every other text. That is payload text, a BAM header, an index
        /// listing, a remote request body and a managed plan.
        public var payloads: [Mask]

        public init(provenance: [Mask], records: [Mask], names: [Mask], payloads: [Mask]) {
            self.provenance = provenance
            self.records = records
            self.names = names
            self.payloads = payloads
        }

        /// The contract's masks. A provenance envelope gets all of them. A
        /// record gets all but the executable path, host, process ID and wall
        /// time keys, which the contract masks in provenance alone, so its
        /// only wall time masks are the value of a manifest's Wall Time item
        /// and of its `parameters.wallClockSeconds`.
        /// A file name gets the UUID and run ID masks. Payload text, request
        /// bodies and plans get the roots and run wall time masks and a FASTQ
        /// sidecar's three clock values alone, so any other date, a host or a
        /// read ID in data is compared as written.
        public static var standard: MaskPolicy {
            let records = [
                Masks.contentComparedDigests,
                Masks.roots,
                Masks.uuids,
                Masks.runIDs,
                Masks.isoTimestamps,
                Masks.epochValues,
                Masks.manifestWallTime,
                Masks.demuxManifestWallClock,
            ]
            return MaskPolicy(
                provenance: records + [Masks.provenanceRuntime, Masks.minimap2RunTimes],
                records: records,
                names: [Masks.uuids, Masks.runIDs],
                payloads: [Masks.roots, Masks.runWallTime, Masks.fastqSidecarClocks]
            )
        }

        func masks(for role: TextRole) -> [Mask] {
            switch role {
            case .provenance: return provenance
            case .record: return records
            case .payload: return payloads
            }
        }
    }

    /// What a text file is to a comparison, which decides its masks.
    enum TextRole {
        case provenance
        case record
        case payload
    }

    /// The role of a text file, from its name without a compression suffix.
    static func role(ofFileNamed name: String) -> TextRole {
        let lowered = name.lowercased()
        guard lowered.hasSuffix(".json") else { return .payload }
        if lowered.contains("provenance") { return .provenance }
        if lowered.contains("manifest") { return .record }
        return .payload
    }

    public enum Masks {
        public static let rootToken = "<ROOT>"

        /// Replaces every spelling of either root with `<ROOT>`, including the
        /// `/private` twin of a temporary path and the JSON-escaped form. The
        /// spellings of both roots go longest first together, so a root whose
        /// path starts the other's, such as `C` beside `C-prime`, never leaves
        /// `<ROOT>-prime` behind.
        public static let roots = Mask(name: "roots") { text, context in
            var result = text
            let spellings = rootSpellings(context.rootA) + rootSpellings(context.rootB)
            for spelling in spellings.sorted(by: { $0.count > $1.count }) {
                result = result.replacingOccurrences(of: spelling, with: rootToken)
            }
            return result
        }

        /// Replaces each distinct UUID with `<UUID-n>`. The number comes from
        /// the side's `uuidNumbers`, so a child bundle named by a UUID and a
        /// manifest that links it carry the same number, and two children
        /// never share one.
        public static let uuids = Mask(name: "uuids") { text, context in
            var extra: [String: Int] = [:]
            return replace(uuidPattern, in: text) { match in
                let value = match.lowercased()
                if let number = context.uuidNumbers[value] { return "<UUID-\(number)>" }
                if extra[value] == nil { extra[value] = context.uuidNumbers.count + extra.count + 1 }
                return "<UUID-\(extra[value]!)>"
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

        /// Replaces the executable path, host, process ID, wall time and launch
        /// caller that a provenance envelope records. The launch caller is a
        /// `caller` of `gui` or `cli`, the entry point that launched the
        /// workflow, which is the route's identity like the executable path
        /// (ruling A53-M3, Phase 2.10). It masks these two values only, since
        /// the same key holds the variant caller of a call, such as `lofreq`.
        /// An envelope writes an option as a `ParameterValue`, an object with a
        /// `type` and a `value`, so the pattern reads the value inside that
        /// object as well as a bare string.
        public static let provenanceRuntime = Mask(name: "provenanceRuntime") { text, _ in
            var result = replaceKeyValues(["executablePath"], in: text, token: "<EXECUTABLE>")
            result = result.replacingOccurrences(
                of: #"("caller"\s*:\s*(?:\{[^{}]*?"value"\s*:\s*)?)"(?:gui|cli)""#, with: "$1\"<CALLER>\"", options: .regularExpression
            )
            result = replaceKeyValues(["host", "hostName", "hostname"], in: result, token: "<HOST>")
            result = replaceKeyValues(["processIdentifier", "pid"], in: result, token: "<PID>")
            return replaceKeyValues(
                ["wallTimeSeconds", "wallTime", "wallClockSeconds", "durationSeconds", "elapsedSeconds", "wall_time_seconds"],
                in: result,
                token: "<DURATION>"
            )
        }

        /// The wall time a run writes beside its outputs, as in assembly-result.json and mapping-result.json.
        /// Three keys only.
        public static let runWallTime = Mask(name: "runWallTime") { text, _ in
            replaceKeyValues(["wallTimeSeconds", "wall_time_seconds", "wallClockSeconds"], in: text, token: "<DURATION>")
        }

        /// The clock values a FASTQ metadata sidecar (`<file>.lungfish-meta.json`) records for its download, its
        /// import and its platform call: the top-level `downloadDate`, `ingestion.ingestionDate` and
        /// `platformAssignment.recordedAt`, each set to `<TIMESTAMP>` where it is present. Those three paths alone,
        /// so the same keys anywhere else, a key's absence, ENA's `first_public` and every statistic are compared
        /// as written (BIO ruling on lane A45 M3c).
        public static let fastqSidecarClocks = Mask(name: "fastqSidecarClocks") { text, _ in
            rewritingJSON(text) { value, changed in maskSidecarClocks(in: value, changed: &changed) }
        }

        static func maskSidecarClocks(in value: Any, changed: inout Bool) -> Any {
            guard var sidecar = value as? [String: Any] else { return value }
            if sidecar["downloadDate"] != nil {
                sidecar["downloadDate"] = "<TIMESTAMP>"
                changed = true
            }
            for (parent, key) in [("ingestion", "ingestionDate"), ("platformAssignment", "recordedAt")] {
                guard var object = sidecar[parent] as? [String: Any], object[key] != nil else { continue }
                object[key] = "<TIMESTAMP>"
                sidecar[parent] = object
                changed = true
            }
            return sidecar
        }

        /// The seconds a FASTQ demultiplex import took, which `demux-manifest.json` records as the top-level
        /// `parameters.wallClockSeconds`, set to `<DURATION>` where it is present. That one path alone, so the same
        /// key at any other path, its absence, every other parameter and every other time key are compared as
        /// written (lane A53 M3, under the rule of the BIO ruling on lane A45 M3c, section b).
        public static let demuxManifestWallClock = Mask(name: "demuxManifestWallClock") { text, _ in
            rewritingJSON(text) { value, changed in maskDemuxWallClock(in: value, changed: &changed) }
        }

        static func maskDemuxWallClock(in value: Any, changed: inout Bool) -> Any {
            guard var manifest = value as? [String: Any],
                  var parameters = manifest["parameters"] as? [String: Any],
                  parameters["wallClockSeconds"] != nil
            else { return value }
            parameters["wallClockSeconds"] = "<DURATION>"
            manifest["parameters"] = parameters
            changed = true
            return manifest
        }

        /// Sets the `value` of a display item labelled exactly `Wall Time` to `<DURATION>`, the wall time
        /// AssemblyBundleBuilder lists in a bundle manifest's metadata. A display item is a JSON object with
        /// a `label` and a `value`. The item stays where it is, so its place, its absence, every other item
        /// and every other label are compared as written.
        public static let manifestWallTime = Mask(name: "manifestWallTime") { text, _ in
            rewritingJSON(text) { value, changed in maskWallTimeItems(in: value, changed: &changed) }
        }

        static let wallTimeLabel = "Wall Time"

        /// Sets `value` to `<DURATION>` in each JSON object whose `label` is exactly `Wall Time`.
        static func maskWallTimeItems(in value: Any, changed: inout Bool) -> Any {
            if let array = value as? [Any] {
                return array.map { maskWallTimeItems(in: $0, changed: &changed) }
            }
            guard var object = value as? [String: Any] else { return value }
            for (key, item) in object {
                object[key] = maskWallTimeItems(in: item, changed: &changed)
            }
            if object["label"] as? String == wallTimeLabel, object["value"] != nil {
                object["value"] = "<DURATION>"
                changed = true
            }
            return object
        }

        /// Replaces the run times minimap2 prints in the `stderr` of a provenance envelope. They are the
        /// seconds and the CPU ratio of each `[M::<function>::<seconds>*<ratio>]` stamp and the three
        /// figures of its `Real time: <n> sec; CPU: <n> sec; Peak RSS: <n> GB` line, as in
        /// scripts/golden/normalize.py. It reads the string value of each `stderr` key and nothing else,
        /// so the version, the command, the index statistics, the reads mapped, the function names, a line
        /// added or lost and the same text under another key are compared as written.
        public static let minimap2RunTimes = Mask(name: "minimap2RunTimes") { text, _ in
            rewritingJSON(text) { value, changed in maskStderr(in: value, changed: &changed) }
        }

        /// Masks the minimap2 run times in each string value of a `stderr` key.
        static func maskStderr(in value: Any, changed: inout Bool) -> Any {
            if let array = value as? [Any] {
                return array.map { maskStderr(in: $0, changed: &changed) }
            }
            guard var object = value as? [String: Any] else { return value }
            for (key, item) in object {
                if key == "stderr", let stderr = item as? String {
                    let masked = maskMinimap2RunTimes(in: stderr)
                    if masked != stderr {
                        object[key] = masked
                        changed = true
                    }
                } else {
                    object[key] = maskStderr(in: item, changed: &changed)
                }
            }
            return object
        }

        static func maskMinimap2RunTimes(in stderr: String) -> String {
            let stamped = minimap2StampPattern.stringByReplacingMatches(
                in: stderr,
                range: NSRange(location: 0, length: (stderr as NSString).length),
                withTemplate: "$1<DURATION>*<CPU-RATIO>$2"
            )
            return minimap2RealTimePattern.stringByReplacingMatches(
                in: stamped,
                range: NSRange(location: 0, length: (stamped as NSString).length),
                withTemplate: "$1<DURATION>$2<CPU-SECONDS>$3<PEAK-RSS>$4"
            )
        }

        static let numberPattern = "-?[0-9]+(?:\\.[0-9]+)?(?:[eE][+\\-]?[0-9]+)?"

        static var minimap2StampPattern: NSRegularExpression { try! NSRegularExpression(
            pattern: "(\\[M::[A-Za-z0-9_]+::)\(numberPattern)\\*\(numberPattern)(\\])"
        ) }

        static var minimap2RealTimePattern: NSRegularExpression { try! NSRegularExpression(
            pattern: "(Real time: )\(numberPattern)( sec; CPU: )\(numberPattern)( sec; Peak RSS: )\(numberPattern)( GB)"
        ) }

        /// `text` re-encoded after `transform` rewrote its JSON value, the way `contentComparedDigests`
        /// encodes a record. Text that is not JSON, or that `transform` leaves alone, comes back as written.
        static func rewritingJSON(_ text: String, _ transform: (Any, inout Bool) -> Any) -> String {
            guard let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { return text }
            var changed = false
            let rewritten = transform(value, &changed)
            guard changed,
                  let encoded = try? JSONSerialization.data(
                      withJSONObject: rewritten,
                      options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed, .withoutEscapingSlashes]
                  ),
                  let result = String(data: encoded, encoding: .utf8)
            else { return text }
            return result
        }

        /// In a JSON record that names a file present in both trees and
        /// compared by content rather than by bytes (a BAM, a gzip or BGZF
        /// file, a SQLite database, an index or a JSON manifest compared after
        /// masks), or a folder that holds a file in each tree, replaces the
        /// checksum and size the record states. The record names it by a path
        /// beside a checksum or size key, absolute or from the `.lungfish`
        /// project that holds the record as `@/`, or by a key of a `checksums`
        /// or `fileSizes` map, or a value such as a manifest entry's
        /// `source_path`, read from the record's own folder. That file, and
        /// each file in that folder, is still compared under its own kind, so
        /// only the record's copy of a byte-level digest is masked. A record
        /// that names a run's scratch intermediate, a content-compared file
        /// or a SAM under the system temporary folder, absolute or as
        /// `<workspace>/`, that no longer exists, is masked the same way,
        /// because the run deleted it and it cannot be compared.
        /// A record that names any other file, such as an input outside the
        /// trees or a file compared byte for byte, keeps its digest.
        public static let contentComparedDigests = Mask(name: "contentComparedDigests") { text, context in
            guard let data = text.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { return text }
            var changed = false
            let roots = rootSpellings(context.rootA) + rootSpellings(context.rootB)
            let masked = maskDigests(
                in: value, paths: context.contentComparedPaths, intermediates: runIntermediates(in: value),
                roots: roots, folder: context.recordFolder, project: context.recordProject, changed: &changed
            )
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
        /// The suffixes of the files a run may delete from its scratch folder. They are the content-compared
        /// suffixes and a SAM. A SAM that both trees keep is compared byte for byte, so `contentComparedSuffixes`,
        /// which the comparison reads to decide what a record's digest may hide, leaves it out.
        static let scratchIntermediateSuffixes = contentComparedSuffixes + [".sam"]
        /// How `PortablePath` writes the system temporary folder in a record.
        static let workspacePrefix = "<workspace>/"

        /// A content-compared file or a SAM under the system temporary folder
        /// that no longer exists. The folder is spelled in full or, as
        /// `PortablePath` writes it, as `<workspace>/`, which names a deleted
        /// file when no temporary folder holds the rest of the path.
        static func isDeletedScratchIntermediate(_ path: String) -> Bool {
            let lowered = path.lowercased()
            guard scratchIntermediateSuffixes.contains(where: { lowered.hasSuffix($0) }) else { return false }
            let temporary = FileManager.default.temporaryDirectory
            let prefixes = rootSpellings(temporary) + ["/tmp", "/private/tmp"]
            if path.hasPrefix(workspacePrefix) {
                let rest = String(path.dropFirst(workspacePrefix.count))
                return !prefixes.contains { FileManager.default.fileExists(atPath: $0 + "/" + rest) }
            }
            guard prefixes.contains(where: { path.hasPrefix($0 + "/") }) else { return false }
            return !FileManager.default.fileExists(atPath: path)
        }

        /// A SAM or BAM that no longer exists, which `relative`, its path from a tree's root, puts in the
        /// record's `folder` ("" at the root, which holds any). A path outside both trees is never one.
        static func isDeletedRunIntermediate(_ path: String, relative: String, folder: String) -> Bool {
            let lowered = path.lowercased()
            guard lowered.hasSuffix(".sam") || lowered.hasSuffix(".bam"), relative != path,
                  folder.isEmpty || relative.hasPrefix(folder + "/")
            else { return false }
            return !FileManager.default.fileExists(atPath: path)
        }

        /// Each `path` that a step's `outputs` and a later step's `inputs` both name, in a record whose
        /// top-level `steps` array lists the steps of a run. A record of another shape has none.
        static func runIntermediates(in value: Any) -> Set<String> {
            guard let steps = (value as? [String: Any])?["steps"] as? [Any] else { return [] }
            func paths(_ step: [String: Any], _ key: String) -> [String] {
                (step[key] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["path"] as? String }
            }
            var written: Set<String> = []
            var intermediates: Set<String> = []
            for case let step as [String: Any] in steps {
                intermediates.formUnion(paths(step, "inputs").filter { written.contains($0) })
                written.formUnion(paths(step, "outputs"))
            }
            return intermediates
        }

        static let digestKeys: Set<String> = ["checksumSHA256", "sha256", "checksum"]
        static let sizeKeys: Set<String> = ["fileSize", "sizeBytes", "size_bytes", "file_size_bytes"]
        /// A record's maps from a path, read from the record's folder, to a
        /// checksum or a size, as a bundle manifest writes them.
        static let digestMapKeys: Set<String> = ["checksums"]
        static let sizeMapKeys: Set<String> = ["fileSizes"]

        /// Runs before every other mask, on unmasked text, so a path is
        /// checked as the run wrote it. `folder` is the record's own folder,
        /// which the keys of a checksum or size map, and a value that starts
        /// with none of `/`, `@/` and `<`, are read from. `project`
        /// is the `.lungfish` project folder that holds the record, which a
        /// `@/` path is read from. Without one a `@/` path stays as written.
        /// A `<bundle>/` path is never read, and a `<workspace>/` path only
        /// as scratch, so the digest a record states beside any other is
        /// kept. A `@/` path lies inside the project, so it is never read as
        /// a deleted scratch intermediate.
        /// A SAM or BAM in the record's folder that one step wrote, a later
        /// step read and the run deleted is masked by `isDeletedRunIntermediate`.
        /// `intermediates` holds the paths that a step wrote and a later step read.
        static func maskDigests(
            in value: Any, paths: Set<String>, intermediates: Set<String>, roots: [String], folder: String,
            project: String?, changed: inout Bool
        ) -> Any {
            if let array = value as? [Any] {
                return array.map {
                    maskDigests(
                        in: $0, paths: paths, intermediates: intermediates, roots: roots, folder: folder,
                        project: project, changed: &changed
                    )
                }
            }
            guard var object = value as? [String: Any] else { return value }
            let namesContentComparedFile = object.values.contains { item in
                guard let written = item as? String else { return false }
                let path = written.hasPrefix("@/") ? project.map { $0 + "/" + String(written.dropFirst(2)) } ?? written : written
                var relative = path
                if let root = roots.first(where: { path.hasPrefix($0 + "/") }) {
                    relative = String(path.dropFirst(root.count + 1))
                }
                let fromFolder = !folder.isEmpty && !["/", "@/", "<"].contains(where: { written.hasPrefix($0) })
                    && paths.contains(folder + "/" + written)
                return paths.contains(relative) || fromFolder || isDeletedScratchIntermediate(written)
                    || intermediates.contains(written)
                    && isDeletedRunIntermediate(path, relative: relative, folder: folder)
            }
            for (key, item) in object {
                if namesContentComparedFile, digestKeys.contains(key) {
                    object[key] = "<CONTENT-SHA256>"
                    changed = true
                } else if namesContentComparedFile, sizeKeys.contains(key) {
                    object[key] = "<CONTENT-SIZE>"
                    changed = true
                } else if digestMapKeys.contains(key) || sizeMapKeys.contains(key), var map = item as? [String: Any] {
                    let token = digestMapKeys.contains(key) ? "<CONTENT-SHA256>" : "<CONTENT-SIZE>"
                    for (name, entry) in map where entry is String || entry is NSNumber {
                        if paths.contains(folder.isEmpty ? name : folder + "/" + name) {
                            map[name] = token
                            changed = true
                        }
                    }
                    object[key] = map
                } else {
                    object[key] = maskDigests(
                        in: item, paths: paths, intermediates: intermediates, roots: roots, folder: folder,
                        project: project, changed: &changed
                    )
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

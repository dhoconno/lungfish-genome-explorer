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
        /// The masks a managed plan (`.managedPlan`) applies on top of the masks its file gets, to the text of the
        /// managed state files. No other kind applies them.
        public var managed: [Mask]
        /// The masks a managed plan applies to the relative name of each file. No other kind applies them.
        public var managedNames: [Mask]

        public init(
            provenance: [Mask], records: [Mask], names: [Mask], payloads: [Mask],
            managed: [Mask] = [], managedNames: [Mask] = []
        ) {
            self.provenance = provenance
            self.records = records
            self.names = names
            self.payloads = payloads
            self.managed = managed
            self.managedNames = managedNames
        }

        /// The contract's masks. A provenance envelope gets all of them. A
        /// record gets all but the executable path, host, process ID and wall
        /// time keys, which the contract masks in provenance alone, so its
        /// only wall time masks are the value of a manifest's Wall Time item
        /// and of its `parameters.wallClockSeconds`, and the `duration` of an
        /// alignment metadata database's `provenance` table.
        /// A file name gets the UUID and run ID masks. Payload text, request
        /// bodies and plans get the roots and run wall time masks, a FASTQ
        /// sidecar's three clock values, a demo project install record's
        /// install time, a `blast submit` record's three clock values and the run clocks of three result sidecars alone,
        /// so any other date, a host or a read ID in data is compared as written.
        /// A managed plan gives a provenance envelope the provenance masks and every other file, a manifest
        /// included, the payload masks. It also masks the clock values of its receipt and pack status cache by
        /// key and the UTC stamp that starts a record's file name, and nothing else.
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
                Masks.alignmentStatsDuration, Masks.primerOrderRecordDigests, Masks.primerExportSourceURL,
            ]
            return MaskPolicy(
                provenance: records + [Masks.provenanceRuntime, Masks.minimap2RunTimes, Masks.bbtoolsRunTimes],
                records: records,
                names: [Masks.uuids, Masks.runIDs],
                payloads: [
                    Masks.roots, Masks.runWallTime, Masks.fastqSidecarClocks, Masks.demoInstallClock, Masks.blastRecordClocks, Masks.resultSidecarClocks, Masks.primerOrderCaptureClocks,
                ],
                managed: [Masks.managedStateClocks],
                managedNames: [Masks.managedRecordStamp]
            )
        }

        /// The GATK compare's masks (Phase 2.10 decision G5, lane A50 M2, widened by the A50 M3 ruling R2): the
        /// standard masks, and in payload text two changes to the `##GATKCommandLine` header line of a VCF. The date
        /// is masked, because GATK writes it from the clock. The track ID in the line's `--output` path is numbered
        /// as a file name numbers it, because GATK writes the output's file name there and every run draws a new ID.
        /// Two runs never agree on either. Only a compare of GATK output asks for this policy, and no other key or
        /// line is masked.
        public static var gatk: MaskPolicy {
            var policy = standard
            policy.payloads.append(contentsOf: [Masks.gatkCommandLineUUIDs, Masks.gatkCommandLineDate])
            policy.keepsGATKCommandLine = true
            return policy
        }

        /// Whether a VCF's `##GATKCommandLine` header line stays in the compare. The normalizer drops every VCF
        /// header whose key holds `command`, a whole line with its `CommandLine=` value. The GATK compare keeps
        /// this one line, masks its date (`Masks.gatkCommandLineDate`) and numbers its track ID
        /// (`Masks.gatkCommandLineUUIDs`), so a changed command, folder or track still differs.
        public var keepsGATKCommandLine = false

        /// Whether a PNG, a file whose name ends in `.png` and that starts with the PNG signature, is compared by its
        /// name and presence alone. Only `primerAnalysis` sets it, since primalscheme3 draws the row name, which holds
        /// the run's fresh input ID, into its row plot. Every other policy compares a PNG by its sha256.
        public var comparesPNGByPresence = false

        /// Whether a PDF, a file whose name ends in `.pdf` and that starts with `%PDF-`, is compared by its name and
        /// presence alone. Only `primerAnalysis` sets it, since varVAMP's plots hold their creation time. Every other
        /// policy compares a PDF by its content.
        public var comparesPDFByPresence = false

        func masks(for role: TextRole) -> [Mask] {
            switch role {
            case .provenance: return provenance
            case .record: return records
            case .payload: return payloads
            }
        }
    }

    /// What a text file is to a comparison, which decides its masks.
    package enum TextRole {
        case provenance
        case record
        case payload
    }

    /// The role of a text file, from its name without a compression suffix. Package access, so the
    /// route parity harness explains a provenance envelope under the role the comparison read it
    /// under, with no second copy of the rule (lane A45).
    package static func role(ofFileNamed name: String) -> TextRole {
        let lowered = name.lowercased()
        guard lowered.hasSuffix(".json") else { return .payload }
        if lowered.contains("provenance") { return .provenance }
        if lowered.contains("manifest") { return .record }
        return .payload
    }

    public enum Masks {
        public static let rootToken = "<ROOT>"

        /// Replaces the value of `Date=` at the end of a `##GATKCommandLine=<...>` header line with `<DATE>`, as
        /// GATK 4.6 writes it (`...,Version="4.6.2.0",Date="October 16, 2026, 1:41:26 PM CDT">`). Only that
        /// trailing key of that line is masked. The line's ID, its `CommandLine=` value and its `Version=`, every
        /// other header line, whatever `Date=` they hold, and every record are compared as written (BR7).
        public static let gatkCommandLineDate = Mask(name: "gatkCommandLineDate") { text, _ in
            guard text.contains("##GATKCommandLine=<") else { return text }
            let trailingDate = try! NSRegularExpression(pattern: #",Date="[^"]*">$"#)
            return text.components(separatedBy: "\n").map { line -> String in
                guard line.hasPrefix("##GATKCommandLine=<") else { return line }
                return trailingDate.stringByReplacingMatches(
                    in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: #",Date="<DATE>">"#
                )
            }.joined(separator: "\n")
        }

        /// Numbers each UUID inside a `##GATKCommandLine=<...>` header line the way `uuids` numbers it in a file
        /// name, so `--output .../vc-<uuid>.vcf.gz` reads `vc-<UUID-n>`, where n is the number of the file's own ID.
        /// GATK writes the output path into this line and every run draws a new track ID, so two runs never agree on
        /// it (A50 M3 ruling by QA and BIO). Only that line is read. Its `ID=`, the options and folders of its
        /// `CommandLine=`, its `Version=`, every other header line and every record are compared as written, and a
        /// header that names another track's ID still differs.
        public static let gatkCommandLineUUIDs = Mask(name: "gatkCommandLineUUIDs") { text, context in
            guard text.contains("##GATKCommandLine=<") else { return text }
            return text.components(separatedBy: "\n").map { line -> String in
                guard line.hasPrefix("##GATKCommandLine=<") else { return line }
                return Masks.uuids(line, context: context)
            }.joined(separator: "\n")
        }

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

        /// The clock values a managed storage root's state files hold, which only `.managedPlan` applies: in
        /// `dependency-receipt.json` the value of each `installedAt` and `updatedAt` key, and in
        /// `conda/cache/plugin-pack-statuses.json` the value of each `timestamp` key and the number after each
        /// `mtime=` in a fingerprint component, each set to `<TIMESTAMP>`. Those keys in those two files alone, so
        /// the same keys in any other file, a database's release or version in the receipt, the `size=` and
        /// `perm=` of a fingerprint component and every other value are compared as written (lane A52 review,
        /// Fix 3 a, under the BIO ruling on lane A45 M3c).
        public static let managedStateClocks = Mask(name: "managedStateClocks") { text, context in
            switch context.recordName {
            case receiptFileName:
                return rewritingJSON(text) { value, changed in
                    maskClockKeys(receiptClockKeys, in: value, changed: &changed)
                }
            case packStatusFileName where context.recordFolder == packStatusFolder
                || context.recordFolder.hasSuffix("/" + packStatusFolder):
                return rewritingJSON(text) { value, changed in
                    maskMtimes(in: maskClockKeys(packStatusClockKeys, in: value, changed: &changed), changed: &changed)
                }
            default:
                return text
            }
        }

        static let receiptFileName = "dependency-receipt.json"
        static let receiptClockKeys: Set<String> = ["installedAt", "updatedAt"]
        static let packStatusFileName = "plugin-pack-statuses.json"
        static let packStatusFolder = "conda/cache"
        static let packStatusClockKeys: Set<String> = ["timestamp"]

        /// Sets the value of each key in `keys`, at any depth, to `<TIMESTAMP>`.
        static func maskClockKeys(_ keys: Set<String>, in value: Any, changed: inout Bool) -> Any {
            if let array = value as? [Any] {
                return array.map { maskClockKeys(keys, in: $0, changed: &changed) }
            }
            guard var object = value as? [String: Any] else { return value }
            for (key, item) in object {
                if keys.contains(key) {
                    object[key] = "<TIMESTAMP>"
                    changed = true
                } else {
                    object[key] = maskClockKeys(keys, in: item, changed: &changed)
                }
            }
            return object
        }

        /// Sets the number after each `mtime=` in a string value to `<TIMESTAMP>`.
        static func maskMtimes(in value: Any, changed: inout Bool) -> Any {
            if let array = value as? [Any] {
                return array.map { maskMtimes(in: $0, changed: &changed) }
            }
            if var object = value as? [String: Any] {
                for (key, item) in object {
                    object[key] = maskMtimes(in: item, changed: &changed)
                }
                return object
            }
            guard let string = value as? String else { return value }
            let masked = mtimePattern.stringByReplacingMatches(
                in: string, range: NSRange(location: 0, length: (string as NSString).length), withTemplate: "$1<TIMESTAMP>"
            )
            if masked != string { changed = true }
            return masked
        }

        static var mtimePattern: NSRegularExpression { try! NSRegularExpression(pattern: "(mtime=)\(numberPattern)") }

        /// The UTC stamp that starts a record's file name under `provenance/`, as in
        /// `provenance/packs/2026-10-14T120000-read-mapping-install.lungfish-provenance.json`, which a managed
        /// plan's compared name shows as `<UTC-STAMP>-`. A name mask, applied by `.managedPlan` alone. The
        /// folders, the rest of the name and a stamp anywhere else in a name are compared as written, so a
        /// record of another run, pack or database still differs (lane A52 review, Fix 3 a).
        public static let managedRecordStamp = Mask(name: "managedRecordStamp") { text, _ in
            managedRecordStampPattern.stringByReplacingMatches(
                in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$1<UTC-STAMP>-"
            )
        }

        static var managedRecordStampPattern: NSRegularExpression { try! NSRegularExpression(
            pattern: "((?:^|/)provenance/(?:[^/]+/)*)[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}-"
        ) }

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

        /// The columns of the `provenance` table that `AlignmentMetadataDatabase` writes into an alignment's
        /// `<track>.stats.db`, in the order it declares them.
        static let alignmentStatsProvenanceColumns = [
            "step_order", "tool", "subcommand", "version", "command", "timestamp", "input_file", "output_file",
            "exit_code", "duration", "parent_step",
        ]

        /// The seconds a BAM import took, the `duration` column of the `provenance` table of an alignment metadata
        /// database (`<track>.stats.db`), set to `<DURATION>` in a database dump. It reads a `table provenance`
        /// section only when its schema declares exactly the columns in `alignmentStatsProvenanceColumns`, and in
        /// each row there it replaces the second-to-last tab field when that field is a number, so a tab inside
        /// `command` moves nothing. The same column in any other table, a `provenance` table with other columns,
        /// a duration that is absent and every other column and table, such as `command`, `version`, `exit_code`
        /// and `program_records`, are compared as written (lane A62, ruling A62-ARCH, Fix 2).
        public static let alignmentStatsDuration = Mask(name: "alignmentStatsDuration") { text, _ in
            guard text.contains("table provenance\n") else { return text }
            var lines = text.components(separatedBy: "\n")
            var changed = false
            for header in lines.indices where lines[header] == "table provenance" {
                var end = header + 1
                while end < lines.count, !startsDumpTable(lines, at: end) { end += 1 }
                let section = lines[(header + 1)..<end].joined(separator: "\n")
                guard declaredColumns(inSchemaOf: section) == alignmentStatsProvenanceColumns else { continue }
                for row in (header + 1)..<end {
                    var fields = lines[row].components(separatedBy: "\t")
                    guard fields.count >= alignmentStatsProvenanceColumns.count,
                          Double(fields[fields.count - 2]) != nil
                    else { continue }
                    fields[fields.count - 2] = "<DURATION>"
                    lines[row] = fields.joined(separator: "\t")
                    changed = true
                }
            }
            return changed ? lines.joined(separator: "\n") : text
        }

        /// Whether `lines[index]` is the `table <name>` line that opens a section of a database dump, which the
        /// `CREATE` statement of its schema follows.
        static func startsDumpTable(_ lines: [String], at index: Int) -> Bool {
            lines[index].hasPrefix("table ") && index + 1 < lines.count && lines[index + 1].hasPrefix("CREATE ")
        }

        /// The column names declared by the first parenthesized list in `sql`, a `CREATE TABLE` statement and
        /// whatever follows it in a dump: the first word of each top-level piece of the list, with the table
        /// constraints left out. A list that never closes declares none.
        static func declaredColumns(inSchemaOf sql: String) -> [String] {
            var pieces = [""]
            var depth = 0
            for character in sql {
                if character == "(" {
                    depth += 1
                    if depth == 1 { continue }
                }
                if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        let constraintWords: Set<String> = ["CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"]
                        return pieces.compactMap { piece in
                            guard let word = piece.split(whereSeparator: \.isWhitespace).first else { return nil }
                            return constraintWords.contains(word.uppercased()) ? nil : String(word)
                        }
                    }
                }
                if depth == 0 { continue }
                if character == ",", depth == 1 {
                    pieces.append("")
                } else {
                    pieces[pieces.count - 1].append(character)
                }
            }
            return []
        }

        /// The time `DemoProjectInstaller` wrote into a demo project's install record (`.lgedemo.json`): the
        /// top-level `installedAt`, set to `<TIMESTAMP>`. It reads a JSON object that holds the record's four keys
        /// and no other, `id`, `installedAt`, `sha256` and `version`, so the same key in any other document, a key
        /// one level down, a record with another key, a record without `installedAt` and the record's other three
        /// values are compared as written. Two installs never take the same second (manager answer to lane A45
        /// M4's question 1, by the rule of the BIO ruling on lane A45 M3c, section b).
        public static let demoInstallClock = Mask(name: "demoInstallClock") { text, _ in
            rewritingJSON(text) { value, changed in maskDemoInstallClock(in: value, changed: &changed) }
        }

        static let demoInstallRecordKeys: Set<String> = ["id", "installedAt", "sha256", "version"]

        static func maskDemoInstallClock(in value: Any, changed: inout Bool) -> Any {
            guard var record = value as? [String: Any], Set(record.keys) == demoInstallRecordKeys else { return value }
            record["installedAt"] = "<TIMESTAMP>"
            changed = true
            return record
        }

        /// The clock values the leaf of `lungfish-cli blast submit` writes into its record (`blast-result.json`):
        /// the top-level `savedAt`, the time the leaf saved the record, and `result.submittedAt` and
        /// `result.completedAt`, the times the search was submitted and finished, each set to `<TIMESTAMP>` where
        /// it is present. It reads a JSON object that holds the record's six keys and no other, `schemaVersion`,
        /// `savedAt`, `query`, `lineage`, `search` and `result`, whose `result` is an object. So the same keys in
        /// any other document, a key one level down, a record with another key or without `savedAt`, and every
        /// other value of the record, such as the query digest, the lineage, the RID and the verdicts, are
        /// compared as written. Two searches never take the same seconds (lane A65 review, fix F1, by the rule of
        /// the BIO ruling on lane A45 M3c, section b).
        public static let blastRecordClocks = Mask(name: "blastRecordClocks") { text, _ in
            rewritingJSON(text) { value, changed in maskBlastRecordClocks(in: value, changed: &changed) }
        }

        static let blastRecordKeys: Set<String> = ["schemaVersion", "savedAt", "query", "lineage", "search", "result"]

        static func maskBlastRecordClocks(in value: Any, changed: inout Bool) -> Any {
            guard var record = value as? [String: Any], Set(record.keys) == blastRecordKeys,
                  var result = record["result"] as? [String: Any]
            else { return value }
            record["savedAt"] = "<TIMESTAMP>"
            for key in ["submittedAt", "completedAt"] where result[key] != nil {
                result[key] = "<TIMESTAMP>"
            }
            record["result"] = result
            changed = true
            return record
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
    }
}

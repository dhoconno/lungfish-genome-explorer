// OutputEquivalence+PrimerAnalysisMasks.swift - The masks of a primer analysis bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// OutputEquivalence+Masks.swift is over the size baseline and may not grow, so this family policy lives here, beside
// OutputEquivalence.MaskPolicy.gatk in an extension of the same type. Phase 2.12 lane 12.16 M1 (2), ruling 2 of the
// A67 review.

import Foundation

extension OutputEquivalence.MaskPolicy {
    /// The masks of a primer analysis bundle, a family policy like `gatk` and named in the Masks row of
    /// docs/contracts/CLI-EQUIVALENCE.md. Only a compare of a `.lungfishprimeranalysis` bundle asks for it
    /// (PrimerDesignCLIGUIParityReplayTests). Ruling 2 of the A67 review. It grows only for a host difference or a fresh
    /// ID, never for a scientific value, and each growth is reviewed. PrimerAnalysisMaskPolicyTests holds a negative
    /// control for each mask. The standard masks compare payload text as written and name a
    /// provenance envelope or a record by the file's own name. A primer bundle holds fresh UUIDs and clock values in
    /// payload text (the BED lines, the Primer3 boulder files, the template FASTA headers, `results/*.json`), and keeps
    /// `provenance/wrapper.json` and `execution-provenance/*.json`, which are provenance envelopes by content and
    /// not by name. So two runs of one command differ in each of them, and C against C' could never be empty.
    /// This policy gives that payload text the masks a record gets (UUIDs, run IDs, ISO times) and the runtime keys a
    /// provenance envelope masks. It hides every sha256, checksumSHA256, byteSize and fileSize value in every record and
    /// payload of the bundle, not only those of files that hold the run's own UUIDs. Each file is still compared as
    /// text, so a changed pair, template, option or flag still differs. argv and reproducibleCommand are hidden because
    /// PrimerDesignDialogPresenter.swift:120 still records the app's launch arguments and not the recorded command
    /// (CLI-EQUIVALENCE.md line 16), and they leave hostKeys when that is fixed. explicit is hidden because the app
    /// names its dialog controls and the CLI its flags.
    public static var primerAnalysis: OutputEquivalence.MaskPolicy {
        var policy = OutputEquivalence.MaskPolicy.standard
        let digests = OutputEquivalence.Mask(name: "primerAnalysisDigests") { text, _ in
            let pattern = try! NSRegularExpression(
                pattern: #"("(?:sha256|checksumSHA256|byteSize|fileSize)"\s*:\s*)(?:"[0-9A-Fa-f]{64}"|[0-9]+)"#
            )
            return pattern.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1\"<DIGEST>\""
            )
        }
        // What the host that wrote an envelope says about itself and its call. That is its argument vector, the options
        // it names for the run (the dialog's controls on side A, the command's flags on side C) and its name and
        // version. The class pins the CLI's vector against the recorded command apart (`assertRecordedArgv`), and the
        // resolved options (`options.resolved*`) stay in the compare, where they are equal.
        let hostKeys: Set<String> = ["argv", "reproducibleCommand", "explicit"]
        let host = OutputEquivalence.Mask(name: "primerAnalysisHost") { text, _ in
            guard hostKeys.contains(where: { text.contains("\"\($0)\"") }),
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            else { return text }
            func strip(_ value: Any) -> Any {
                if let dictionary = value as? [String: Any] {
                    return dictionary.filter { !hostKeys.contains($0.key) }.mapValues(strip)
                }
                if let array = value as? [Any] { return array.map(strip) }
                return value
            }
            guard let stripped = try? JSONSerialization.data(
                withJSONObject: strip(object),
                options: [.sortedKeys, .prettyPrinted, .fragmentsAllowed, .withoutEscapingSlashes]
            ), let result = String(data: stripped, encoding: .utf8) else { return text }
            return result
        }
        let hostNames = OutputEquivalence.Mask(name: "primerAnalysisHostNames") { text, _ in
            let pattern = try! NSRegularExpression(
                pattern: #""(?:Lungfish [0-9][^"]*|lungfish-cli [0-9][^"]*|<external>/(?:xctest|lungfish-cli))""#
            )
            return pattern.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "\"<HOST>\""
            )
        }
        policy.records.append(digests)
        policy.payloads.append(contentsOf: [
            OutputEquivalence.Masks.uuids, OutputEquivalence.Masks.runIDs, OutputEquivalence.Masks.isoTimestamps,
            OutputEquivalence.Masks.provenanceRuntime, digests, host, hostNames,
        ])
        // The PrimalScheme3 bundle (lane 12.16 M1 (3)). Each mask hides a fresh ID or what the host's clock and speed
        // write, under the same ruling, and nothing else.
        let undashed = OutputEquivalence.Masks.primerAnalysisUndashedUUIDs
        policy.names.append(undashed)
        policy.records.append(undashed)
        policy.payloads.append(contentsOf: [
            undashed, OutputEquivalence.Masks.primerAnalysisSchemeIDs, OutputEquivalence.Masks.primerAnalysisNativeDigests,
            OutputEquivalence.Masks.primerAnalysisConsole,
        ])
        // primalscheme3 titles its row plot (`native/<id>/input_<UUID>_row_<n>.png`) with the row name, so the fresh
        // input ID is drawn into its pixels and no text mask reaches it. The PNG is compared by name and presence, and
        // the plot's data stays compared in the bundle's BED, CSV and `work/plotdata.json.gz` files (the manager's grant
        // to lane 12.16, option 1 of its M1 ruling).
        policy.comparesPNGByPresence = true
        return policy
    }
}

extension OutputEquivalence.Masks {
    /// A UUID written as 32 hex digits without dashes, as the PrimalScheme3 pipeline names each input row
    /// (`input_<UUID>_row_<n>`, from the fresh ID of the input's `inputs/<UUID>.fasta`), becomes the `<UUID-n>` its
    /// dashed form gets on that side. A 32-digit value that is not the undashed form of a UUID the side numbers, such
    /// as an MD5 digest, is compared as written.
    public static let primerAnalysisUndashedUUIDs = OutputEquivalence.Mask(name: "primerAnalysisUndashedUUIDs") { text, context in
        replace(undashedUUIDPattern, in: text) { match in
            let hex = Array(match.lowercased())
            let dashed = [hex[0..<8], hex[8..<12], hex[12..<16], hex[16..<20], hex[20..<32]].map { String($0) }
                .joined(separator: "-")
            return context.uuidNumbers[dashed].map { "<UUID-\($0)>" } ?? match
        }
    }

    static var undashedUUIDPattern: NSRegularExpression { try! NSRegularExpression(
        pattern: "(?<![0-9A-Fa-f])[0-9A-Fa-f]{32}(?![0-9A-Fa-f])"
    ) }

    /// The eight hex digits primalscheme3 draws for each MSA (`str(uuid4())[:8]` in `primalscheme3/core/msa.py`), the
    /// value of `msa_uuid` in its config, bare or as a `ParameterValue`, and the prefix of every amplicon and primer
    /// name it writes (`5b5fa432_1`, `5b5fa432_1_LEFT_1`, also after the JSON-escaped `>` of a plot's hover
    /// text), each set to `<SCHEME-ID>`. The amplicon and primer numbers
    /// after the prefix, and every other hex value, are compared as written.
    public static let primerAnalysisSchemeIDs = OutputEquivalence.Mask(name: "primerAnalysisSchemeIDs") { text, _ in
        let range = { (value: String) in NSRange(location: 0, length: (value as NSString).length) }
        let valued = schemeIDValuePattern.stringByReplacingMatches(
            in: text, range: range(text), withTemplate: "$1\"<SCHEME-ID>\""
        )
        return schemeIDPrefixPattern.stringByReplacingMatches(in: valued, range: range(valued), withTemplate: "<SCHEME-ID>")
    }

    static var schemeIDValuePattern: NSRegularExpression { try! NSRegularExpression(
        pattern: #"("msa_uuid"\s*:\s*(?:\{[^{}]*?"value"\s*:\s*)?)"[0-9a-f]{8}""#
    ) }

    static var schemeIDPrefixPattern: NSRegularExpression { try! NSRegularExpression(
        pattern: #"(?:(?<![0-9A-Za-z_])|(?<=\\u003e))[0-9a-f]{8}(?=_[0-9]+(?:_(?:LEFT|RIGHT|PROBE)|\b))"#
    ) }

    /// The digests primalscheme3 and the PrimalScheme3 pipeline state for files that hold the run's fresh IDs: the value
    /// of a key that ends in `.md5` (`amplicon.bed.md5`), of `msa_checksum` and of `consumedSHA256`, bare or as a
    /// `ParameterValue`, set to `<DIGEST>`. Each of those files is still compared as text.
    public static let primerAnalysisNativeDigests = OutputEquivalence.Mask(name: "primerAnalysisNativeDigests") { text, _ in
        nativeDigestPattern.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$1\"<DIGEST>\""
        )
    }

    static var nativeDigestPattern: NSRegularExpression { try! NSRegularExpression(
        pattern: #"("(?:consumedSHA256|msa_checksum|[^"]*\.md5)"\s*:\s*(?:\{[^{}]*?"value"\s*:\s*)?)"(?:[0-9A-Fa-f]{64}|[0-9A-Fa-f]{32})""#
    ) }

    /// What the host's clock and speed write into a tool's console output, in a log file or in the `stdout` and
    /// `stderr` strings of a JSON record. The time column of a rich log line (`[13:11:20] INFO`, or its blank twin
    /// when a line repeats the time) becomes `<TIME>`. A progress bar keeps only its last state, the text after the
    /// line's last carriage return, and its elapsed time, time left and rate become `[<ELAPSED>]`, so its count
    /// (`781/781`) is compared as written. Every other line is compared as written.
    public static let primerAnalysisConsole = OutputEquivalence.Mask(name: "primerAnalysisConsole") { text, _ in
        if let data = text.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) is [String: Any] {
            return rewritingJSON(text) { value, changed in maskConsoleStreams(in: value, changed: &changed) }
        }
        return maskedConsole(text)
    }

    static func maskConsoleStreams(in value: Any, changed: inout Bool) -> Any {
        if let array = value as? [Any] { return array.map { maskConsoleStreams(in: $0, changed: &changed) } }
        guard var object = value as? [String: Any] else { return value }
        for (key, item) in object {
            if ["stdout", "stderr"].contains(key), let stream = item as? String {
                let masked = maskedConsole(stream)
                if masked != stream {
                    object[key] = masked
                    changed = true
                }
            } else {
                object[key] = maskConsoleStreams(in: item, changed: &changed)
            }
        }
        return object
    }

    static func maskedConsole(_ text: String) -> String {
        let range = { (value: String) in NSRange(location: 0, length: (value as NSString).length) }
        return text.components(separatedBy: "\n").map { line -> String in
            var line = line
            if line.contains("\r"), line.contains("it/s]") || line.contains("s/it]") {
                line = line.components(separatedBy: "\r").last { !$0.isEmpty } ?? ""
            }
            line = progressTimingPattern.stringByReplacingMatches(in: line, range: range(line), withTemplate: "[<ELAPSED>]")
            return consoleClockPattern.stringByReplacingMatches(in: line, range: range(line), withTemplate: "<TIME> ")
        }.joined(separator: "\n")
    }

    static var progressTimingPattern: NSRegularExpression { try! NSRegularExpression(
        pattern: #"\[[0-9:]+<[0-9:?]+, *[0-9.?]+ *(?:it/s|s/it)\]"#
    ) }

    static var consoleClockPattern: NSRegularExpression { try! NSRegularExpression(
        pattern: #"^(?:\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]| {10}) (?=(?:DEBUG|INFO|WARNING|ERROR|CRITICAL) )"#
    ) }
}

// OutputEquivalence+PrimerAnalysisMasks.swift - The masks of a primer analysis bundle
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// OutputEquivalence+Masks.swift is over the size baseline and may not grow, so this family policy lives here, beside
// OutputEquivalence.MaskPolicy.gatk in an extension of the same type. Phase 2.12 lane 12.16 M1 (2), ruling 2 of the
// A67 review.

import Foundation

extension OutputEquivalence.MaskPolicy {
    /// The masks of a primer analysis bundle. Ruling of the A67 review. Class-local for this class only. It is promoted
    /// to a family policy beside OutputEquivalence.MaskPolicy.gatk, with a sentence in docs/contracts/CLI-EQUIVALENCE.md
    /// line 35, when a second case or family needs it. The standard masks compare payload text as written and name a
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
        return policy
    }
}

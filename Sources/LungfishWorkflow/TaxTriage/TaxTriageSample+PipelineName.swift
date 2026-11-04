// TaxTriageSample+PipelineName.swift - The name the TaxTriage pipeline gives a sample
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension TaxTriageSample {

    /// The characters the pipeline's samplesheet check removes from a sample name.
    ///
    /// They are the list in `RowChecker._validate_sample` of `bin/check_samplesheet.py`, read at the revision the
    /// pin names (jhuapl-bio/taxtriage v3.3.8, commit e10bfebda32a62711f38a4e23ab03b61725a9675, in
    /// `Sources/LungfishWorkflow/Resources/ManagedTools/third-party-tools-lock.json`). A bump of that pin must
    /// read the function again and keep ``TaxTriagePipelineNameTests`` true.
    private static let pipelineRemovedScalars: Set<Unicode.Scalar> = Set(
        "/\\:*?\"<>|()[]{}#%&+!@$^`~;,".unicodeScalars
    )

    /// The name the pipeline gives the sample that LGE holds as `name`, which its reports and so the result's
    /// database use for it.
    ///
    /// LGE keeps the name a person typed and writes it into the samplesheet as it is. The pipeline's samplesheet
    /// check then turns each space into an underscore, removes the characters in ``pipelineRemovedScalars`` and
    /// strips the whitespace that remains from both ends. The function works on unicode scalars, as the script
    /// works on code points. It does not add the `_T<n>` that the script appends when two samples of one
    /// samplesheet end with the same name. ``TaxTriageControlMatch`` reads that part.
    ///
    /// - Parameter name: The sample name as LGE holds it.
    /// - Returns: The name as the pipeline writes it. It can be empty when the name holds nothing else.
    public static func pipelineName(of name: String) -> String {
        var kept: [Unicode.Scalar] = []
        for scalar in name.unicodeScalars {
            if scalar == " " {
                kept.append("_")
            } else if !pipelineRemovedScalars.contains(scalar) {
                kept.append(scalar)
            }
        }
        while let last = kept.last, isPipelineWhitespace(last) {
            kept.removeLast()
        }
        let leading = kept.prefix { isPipelineWhitespace($0) }.count
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: kept.dropFirst(leading))
        return String(scalars)
    }

    /// Sample names that the pipeline turns into one name.
    public struct MeetingNames: Sendable, Equatable {
        /// The name the pipeline gives them.
        public let resultsName: String
        /// The names as typed, each once, in order of first appearance.
        public let typedNames: [String]
    }

    /// The sample names in `names` that the pipeline turns into one name, such as `A (1)` and `A_1`, which both become
    /// `A_1`, in order of that name. A name typed twice counts once, since a run refuses an exact duplicate with its own
    /// words. A name that becomes the empty string claims nothing and is left out, as ``TaxTriageControlMatch`` reads it
    /// (lane TTCONTROLS, row TAXTRIAGE-NAMES-THAT-MEET-LOSE-ROWS).
    public static func namesThatMeet(in names: [String]) -> [MeetingNames] {
        var typedByResultsName: [String: [String]] = [:]
        for name in names {
            let resultsName = pipelineName(of: name)
            guard !resultsName.isEmpty, !(typedByResultsName[resultsName]?.contains(name) ?? false) else { continue }
            typedByResultsName[resultsName, default: []].append(name)
        }
        return typedByResultsName.keys.sorted().compactMap { key in
            guard let typed = typedByResultsName[key], typed.count > 1 else { return nil }
            return MeetingNames(resultsName: key, typedNames: typed)
        }
    }

    /// What a person reads when a run lists names that meet, and what to do. Nil when no names meet. The run's refusal
    /// and the dialog say these words, so the rule has one voice.
    public static func namesThatMeetWords(in names: [String]) -> String? {
        let meeting = namesThatMeet(in: names)
        guard !meeting.isEmpty else { return nil }
        let sentences = meeting.map { group in
            "\(TaxTriageControlMatch.listing(group.typedNames)) become the same name, \(group.resultsName), once the "
                + "pipeline removes spaces and symbols, so the results could keep only one of them."
        }
        return sentences.joined(separator: " ") + " Rename them so that the names stay different, then run again."
    }

    /// Python's `str.strip()` removes the characters for which `str.isspace()` holds. They are the Unicode
    /// White_Space characters and the four information separators U+001C to U+001F.
    private static func isPipelineWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }
}

// TaxTriageResultViewController+NotRecountedNotice.swift - What the viewer says about rows a rebuild did not recount
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep lane TT-m1b, Finding 1 of TT-m1. Since TT-m1, a rebuild of a result whose report for a sample is gone keeps
// that sample's rows from the earlier taxtriage.sqlite and names the sample in the metadata key `not_recounted_samples`.
// The viewer showed those rows as current with no words, while a database built before 3.2 TTREADS may have counted a
// segmented virus's Reads on its first reference only. The strip above the table now names the samples first.

import Foundation
import LungfishIO

extension TaxTriageResultViewController {

    /// The key `lungfish build-db taxtriage` writes (`BuildDbCommand.TaxTriageSubcommand.notRecountedSamplesMetadataKey`):
    /// a JSON array of the samples whose rows a rebuild kept from the earlier database without recounting them.
    static let notRecountedSamplesMetadataKey = "not_recounted_samples"

    /// The samples `db` names under ``notRecountedSamplesMetadataKey``, empty when it names none.
    static func notRecountedSamples(in db: TaxTriageDatabase) -> [String] {
        guard let value = (try? db.fetchMetadata())?[notRecountedSamplesMetadataKey],
              let samples = try? JSONDecoder().decode([String].self, from: Data(value.utf8)) else { return [] }
        return samples
    }

    /// The line that names `samples`, which a rebuild did not recount, nil when there are none.
    static func notRecountedWords(samples: [String]) -> String? {
        guard let last = samples.last else { return nil }
        let names = samples.count == 1 ? last : samples.dropLast().joined(separator: ", ") + " and " + last
        if samples.count == 1 {
            return "Lungfish could not recount \(names) because its report is missing from this result. "
                + "Its counts are from an earlier build, which may have counted a segmented virus's Reads on its first reference only. "
                + "To recount it, import the original TaxTriage run folder again, if you still have it."
        }
        return "Lungfish could not recount \(names) because their reports are missing from this result. "
            + "Their counts are from an earlier build, which may have counted a segmented virus's Reads on its first reference only. "
            + "To recount them, import the original TaxTriage run folder again, if you still have it."
    }

    /// The words of the strip above the table: the samples not recounted first, since their numbers may be wrong, then
    /// ``controlNoticeWords()``, one to a line. Nil when neither has words, which shuts the strip.
    func noticeStripWords(for db: TaxTriageDatabase) -> String? {
        let lines = [Self.notRecountedWords(samples: Self.notRecountedSamples(in: db)), controlNoticeWords()].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

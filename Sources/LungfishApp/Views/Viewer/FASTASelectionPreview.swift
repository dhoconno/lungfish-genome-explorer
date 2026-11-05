// FASTASelectionPreview.swift - The bounded preview under the FASTA list
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// What the detail under the FASTA list shows for a selection (W-34).
///
/// The detail used to format every selected record into one string on the main thread, which took 19 s and 1.7 GB more
/// at 20,000 records and passed 6 GB at 100,000. It now shows at most ``recordLimit`` records and ``baseLimit`` bases,
/// with a line that names how many records are selected. Every action from the selection still acts on all of them.
enum FASTASelectionPreview {
    static let recordLimit = 100
    static let baseLimit = 1_000_000

    struct Preview: Equatable {
        /// The FASTA text of the records shown.
        let text: String
        /// The line above the text, nil when one record shows whole.
        let note: String?
    }

    static func make(
        for sequences: [Sequence],
        recordLimit: Int = recordLimit,
        baseLimit: Int = baseLimit
    ) -> Preview {
        var records: [String] = []
        var bases = 0
        var cutLength: Int?
        for sequence in sequences.prefix(recordLimit) {
            let room = baseLimit - bases
            if sequence.length > room {
                // A first record past the bound shows its first bases, and a later one is left out.
                if records.isEmpty {
                    records.append(FASTASelectionDetailFormatter.record(for: sequence, baseLimit: room))
                    cutLength = sequence.length
                }
                break
            }
            records.append(FASTASelectionDetailFormatter.record(for: sequence))
            bases += sequence.length
        }
        let text = records.joined(separator: "\n")
        return Preview(text: text, note: note(selected: sequences.count, shown: records.count, cutLength: cutLength))
    }

    private static func note(selected: Int, shown: Int, cutLength: Int?) -> String? {
        let all = count(selected)
        if let cutLength {
            let first = "\(count(baseLimit)) of \(count(cutLength)) bases"
            if selected == 1 {
                return "1 record selected. Its first \(first) show here, and every action acts on the whole record."
            }
            return "\(all) records selected. The first \(first) of the first record show here, and every action acts on all \(all)."
        }
        if shown < selected {
            return "\(all) records selected. The first \(count(shown)) show here, and every action acts on all \(all)."
        }
        return selected > 1 ? "\(all) records selected." : nil
    }

    private static func count(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US")))
    }
}

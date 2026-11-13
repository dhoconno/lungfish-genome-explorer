// FASTQOperationPlanner+InputFolders.swift - The folder each dataset of a run writes into
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A run of several datasets writes each one's output under `<run>/<folder>`, and the folder is named for the dataset.
// Two datasets with one name (`a/reads.lungfishfastq` and `b/reads.lungfishfastq`, or `s.fastq` and `s.fastq.gz`) were
// both given `<run>/reads`, so the second command met the first one's output and refused it, with words that named
// CLI flags a person in the window cannot pass. A repeated name is now numbered the way `collisionSafeOutputURL`
// numbers a repeated file. FASTQSameStemInputsTests pins it.

import Foundation

extension FASTQOperationPlanner {
    /// The folder name each request writes into under the run, in the order of `requests`.
    ///
    /// The first request with a name keeps it. A later request whose name is taken gets `-2`, `-3` and so on after the
    /// name, and skips a number that makes the own name of another request, so a request whose name is unique never
    /// moves. Names are compared with case and Unicode form folded, because a Mac disk and ExFAT keep `Reads` and
    /// `reads` in one folder. The Operations row, the run and the grouped record all read the folder from the plan, so
    /// they agree by construction.
    static func inputFolderNames(for requests: [FASTQOperationLaunchRequest]) -> [String] {
        let stems = requests.map { request in
            request.inputURLs.first.map(Self.sanitizedStem(for:)) ?? "output-\(UUID().uuidString.prefix(8))"
        }
        let ownNames = Set(stems.map(foldedFolderName))
        var takenNames = Set<String>()
        var names: [String] = []
        for stem in stems {
            var name = stem
            var counter = 2
            while takenNames.contains(foldedFolderName(name)) {
                repeat {
                    name = "\(stem)-\(counter)"
                    counter += 1
                } while ownNames.contains(foldedFolderName(name))
            }
            takenNames.insert(foldedFolderName(name))
            names.append(name)
        }
        return names
    }

    private static func foldedFolderName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }
}

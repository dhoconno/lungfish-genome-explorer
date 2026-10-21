// GenBankFeatureLine.swift - The feature key and location GenBankWriter prints for an annotation
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The feature line rule of Phase 2.13 lane 13.41 (row M858 GENBANK-FEATURE-LINE, the BIO ruling on lane 12.13
/// section 3). A feature that ``GenBankReader`` read keeps the key and the location of its source line while they
/// still describe the annotation, so `CDS`, the partial markers `<` and `>` and `order()` survive a read and a
/// write. A feature whose type, ranges or strand changed after the read, and one the reader never read, print the
/// type's name in lower case and a location rebuilt from the ranges, as before.
extension GenBankWriter {
    /// The key the reader read, when the reader's own type map gives `annotation`'s type back, else the type's
    /// name in lower case.
    static func featureKey(of annotation: SequenceAnnotation) -> String {
        if let raw = annotation.qualifier(GenBankReader.rawFeatureTypeQualifierKey)?
            .trimmingCharacters(in: .whitespaces),
           !raw.isEmpty,
           GenBankReader.mapFeatureType(raw) == annotation.type {
            return raw
        }
        return annotation.type.rawValue.lowercased()
    }

    /// The location the reader read, when the reader's own parse of it gives `annotation`'s ranges, the strand of
    /// each range and the feature strand, else `rebuilt`. The phase is not compared, since the reader sets it from
    /// `/codon_start` and not from the location.
    static func featureLocation(of annotation: SequenceAnnotation, rebuilt: String) -> String {
        guard let raw = annotation.qualifier(GenBankReader.rawLocationQualifierKey)?
                .trimmingCharacters(in: .whitespaces),
              let parsed = try? GenBankReader.parseLocation(raw, lineNumber: 0),
              parsed.1 == annotation.strand,
              parsed.0.count == annotation.intervals.count,
              zip(parsed.0, annotation.intervals).allSatisfy({ read, held in
                  read.start == held.start && read.end == held.end && read.strand == held.strand
              })
        else { return rebuilt }
        return raw
    }
}

// FASTQQualityScoreOrigin.swift - Whether the quality scores of a FASTQ file in a bundle were measured
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Where the quality scores of the reads in a `.lungfishfastq` bundle come from (Phase 5.6 S1 sweep, lane QUALITY-2,
/// ruling BIO-QUALITY F1).
///
/// Reads built from sequence counts carry a written score of Q40 on every base that no instrument measured. Every view
/// or tool that measures such reads gets Q40 back as a measurement, so each asks this reader first and shows no score
/// for the reads it marks. The mark is the manifest's `qualityScoresArePlaceholders`. The access is `package`, since the
/// app, the workflow module and the tests share one package and no other client needs the type.
package enum FASTQQualityScoreOrigin {

    /// Whether the reads of `fastqURL` carry placeholder scores. `fastqURL` is a FASTQ file inside a `.lungfishfastq`
    /// bundle or the bundle itself. A file that sits in no bundle, or in a bundle with no derived manifest, is false.
    package static func readsCarryPlaceholderScores(fastqURL: URL) -> Bool {
        guard let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: fastqURL),
              let manifest = FASTQBundle.loadDerivedManifest(in: bundleURL) else {
            return false
        }
        return carryPlaceholderScores(manifest)
    }

    /// The same reading for a manifest in hand. True when the manifest holds the mark. A bundle made before the field
    /// existed is recognized by what both Fluidigm materializers wrote beside it, a demultiplex operation and a library
    /// prep that begins "Fluidigm Access Array" ("Fluidigm Access Array MHC amplicon" for the amplicon route).
    package static func carryPlaceholderScores(_ manifest: FASTQDerivedBundleManifest) -> Bool {
        if manifest.qualityScoresArePlaceholders == true {
            return true
        }
        return manifest.operation.kind == .demultiplex
            && manifest.provenance?.libraryPrep?.hasPrefix("Fluidigm Access Array") == true
    }
}

// VariantEditTargets.swift - The variant databases a stored variant edit changes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// The variant tracks that `variants delete` and `variants import-sample-metadata` edit, resolved
/// from a bundle's manifest the way the variant table opens them (`AnnotationSearchIndex`), so the
/// command and the drawer's own call hand a service the same targets in the same order.
package enum VariantEditTargets {
    package struct Track: Sendable, Equatable {
        /// `VariantTrackInfo.id`, the track ID a selected row travels with.
        package let id: String
        /// `VariantTrackInfo.name`, the label a deletion's record gives the track.
        package let name: String
        /// The track's database inside the bundle.
        package let databaseURL: URL
    }

    /// The tracks of the bundle at `bundleURL` that name a database inside the bundle and whose
    /// database exists, in the manifest's order. A track with an unsafe or missing database path is
    /// left out, as the variant table leaves it out.
    package static func tracks(inBundleAt bundleURL: URL) throws -> [Track] {
        let bundleURL = bundleURL.standardizedFileURL
        let bundle = ReferenceBundle(url: bundleURL, manifest: try BundleManifest.load(from: bundleURL))
        return bundle.variantTrackIds.compactMap { id in
            guard let info = bundle.variantTrack(id: id),
                  let databasePath = info.databasePath,
                  let databaseURL = try? bundle.memberURL(for: databasePath, field: "variants[\(id)].databasePath"),
                  FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
            return Track(id: id, name: info.name, databaseURL: databaseURL)
        }
    }
}

// VariantFormatOverlaySources.swift - The FORMAT overlay sources of a bundle's iVar variant tracks
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension VariantFormatOverlaySource {
    /// The overlay sources of the iVar tracks among `databases`, in their order, each with the VCF its manifest
    /// entry names, so `AnnotationSearchIndex` and `bundle export-annotation-table` project one set of FORMAT values
    /// (Phase 2.12 lane 12.39, ARCH ruling on 12.39 R1 item 5).
    ///
    /// A track the manifest does not name, or whose source is not iVar, gives no source. `aliasMaps` builds its
    /// groups on the first iVar track and never for a bundle without one.
    package static func iVarSources(
        bundle: ReferenceBundle,
        databases: [(trackId: String, db: VariantDatabase)],
        aliasMaps: inout BundleChromosomeAliasMaps
    ) -> [VariantFormatOverlaySource] {
        databases.compactMap { handle in
            guard let trackInfo = bundle.variantTrack(id: handle.trackId) else { return nil }
            let isIVar = trackInfo.source?.localizedCaseInsensitiveContains("ivar") == true
            guard isIVar else { return nil }
            let sourceURL = try? bundle.memberURL(
                for: trackInfo.path,
                field: "variants[\(handle.trackId)].path"
            )
            aliasMaps.prepare()
            return VariantFormatOverlaySource(
                trackID: handle.trackId,
                database: handle.db,
                vcfURL: sourceURL,
                isIVar: isIVar,
                aliasesByExactToken: aliasMaps.byExactToken,
                aliasesByCanonicalToken: aliasMaps.byCanonicalToken
            )
        }
    }
}

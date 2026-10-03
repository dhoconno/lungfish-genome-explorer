// BundleTrackList.swift - Track listing for JSON output
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Track listing for JSON output
struct BundleTrackList: Codable {
    let alignments: [String]
    let annotations: [String]
    let variants: [String]
    let signals: [String]

    init(manifest: BundleManifest) {
        alignments = manifest.alignments.map(\.id)
        annotations = manifest.annotations.map(\.id)
        variants = manifest.variants.map(\.id)
        signals = manifest.tracks.map(\.id)
    }
}

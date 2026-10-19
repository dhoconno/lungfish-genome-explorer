// TreeSubtreeExport.swift - The subtree export the tree viewer and `tree export subtree` share
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The subtree export of a `.lungfishtree` bundle (Phase 2.12 lane 12.35, ARCH ruling 1.1 row A15).
public enum TreeSubtreeExport {
    /// The bundle files a subtree export reads, which are the two files `PhylogeneticTreeBundle.load` decodes. The
    /// load checks that the bundle's other files exist but reads none of them, so a record names these two with
    /// their digests and never the bundle folder (BIO-12.31-G3).
    public static func inputURLs(bundleURL: URL) -> [URL] {
        ["manifest.json", "tree/primary.normalized.json"].map {
            bundleURL.appendingPathComponent($0).standardizedFileURL
        }
    }
}

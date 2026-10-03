// CLISequenceInputMaterialization+RootFiles.swift - Every root file a virtual derivative's lineage names
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension CLISequenceInputMaterialization {
    /// The root files a virtual derivative's recipe reads, each of which
    /// exists, for the lineage records that name them.
    ///
    /// A root that holds several files (an ONT chunked import or a merged
    /// bundle) is every member in `source-files.json` order, and any other
    /// root is its one recorded file. This is `FASTQBundle.rootSequenceURLs`,
    /// the resolution `FASTQCLIMaterializer` reads the derivative by and the
    /// dashboard's envelope names. The records named the recorded file
    /// alone, the first chunk of a multi-file root, or no file for a chunk's
    /// bare name (R8, final review S1).
    ///
    /// Empty when the recorded file is not a safe member of the root or a
    /// member is missing, the root the materializer refuses, so such a root
    /// is never named as a shorter bundle. A missing recorded file was left
    /// out before as well.
    static func existingRootSequenceURLs(
        for manifest: FASTQDerivedBundleManifest,
        derivedBundleURL: URL
    ) -> [URL] {
        let rootBundleURL = FASTQBundle.resolveBundle(
            relativePath: manifest.rootBundleRelativePath,
            from: derivedBundleURL
        )
        let urls = (try? FASTQBundle.rootSequenceURLs(
            rootFASTQFilename: manifest.rootFASTQFilename,
            in: rootBundleURL
        )) ?? []
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

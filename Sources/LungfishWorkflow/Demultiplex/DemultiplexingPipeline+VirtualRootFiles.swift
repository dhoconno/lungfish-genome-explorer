// DemultiplexingPipeline+VirtualRootFiles.swift - The root files a virtual barcode bundle is rebuilt from
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension DemultiplexingPipeline {
    /// The root files a virtual barcode bundle's preview and cached
    /// statistics are rebuilt from, in the order a tool reads them.
    ///
    /// A root that holds several files (an ONT chunked import or a merged
    /// bundle) is every member in `source-files.json` order, and any other
    /// root is its one recorded file. This is `FASTQBundle.rootSequenceURLs`,
    /// the resolution `FASTQCLIMaterializer` applies to the barcode bundle,
    /// so the counts describe the reads the bundle materializes to. They were
    /// rebuilt from the recorded file alone, the first chunk of a multi-file
    /// root, while the bundle listed every chunk's reads (R3, final review B1).
    ///
    /// Nil when the run has no root, the recorded file is not a safe member
    /// of the root, or a root file is missing. The caller then reads
    /// cutadapt's output instead, as it did before.
    func virtualRootSequenceURLs(config: DemultiplexConfig) -> [URL]? {
        guard let rootBundleURL = config.rootBundleURL,
              let rootFASTQFilename = config.rootFASTQFilename,
              let urls = try? FASTQBundle.rootSequenceURLs(rootFASTQFilename: rootFASTQFilename, in: rootBundleURL),
              !urls.isEmpty,
              urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            return nil
        }
        return urls
    }
}

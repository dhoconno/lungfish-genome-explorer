// SidebarViewController+AnalysisManifest.swift - Sidebar analysis history maintenance
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension SidebarViewController {
    func rewriteAnalysisManifestReferencesIfNeeded(from sourceURL: URL, to destinationURL: URL) {
        guard let projectURL,
              AnalysisManifestStore.analysisDirectoryPath(for: sourceURL, projectURL: projectURL) != nil,
              AnalysisManifestStore.analysisDirectoryPath(for: destinationURL, projectURL: projectURL) != nil else {
            return
        }

        do {
            let rewrittenCount = try AnalysisManifestStore.rewriteAnalysisDirectoryReferences(
                projectURL: projectURL,
                oldAnalysisURL: sourceURL,
                newAnalysisURL: destinationURL
            )
            if rewrittenCount > 0 {
                sidebarLogger.info("Rewrote \(rewrittenCount) analysis manifest reference(s) after sidebar move")
            }
        } catch {
            sidebarLogger.warning("Failed to rewrite analysis manifest references after sidebar move: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// AppDelegate+AnalysisManifest.swift - App analysis history helpers
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

extension AppDelegate {
    static func analysisManifestDirectoryName(for analysisDirectoryURL: URL, projectURL: URL?) -> String {
        if let projectURL,
           let relativePath = AnalysisManifestStore.analysisDirectoryPath(
               for: analysisDirectoryURL,
               projectURL: projectURL
           ) {
            return relativePath
        }
        return analysisDirectoryURL.lastPathComponent
    }
}

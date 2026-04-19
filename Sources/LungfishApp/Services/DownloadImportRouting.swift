// DownloadImportRouting.swift - Rules for deciding when downloaded bundles stay in place
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO

enum DownloadImportRouting {
    static func shouldPreserveInPlace(
        downloadedURL: URL,
        projectURL: URL?,
        workingDirectoryURL: URL?
    ) -> Bool {
        if let projectURL, isURL(downloadedURL, inside: projectURL) {
            if isURL(downloadedURL, inside: ProjectTempDirectory.tempRoot(for: projectURL)) {
                return false
            }
            return true
        }

        if let workingDirectoryURL, isURL(downloadedURL, inside: workingDirectoryURL) {
            if workingDirectoryURL.pathExtension.lowercased() == "lungfish",
               isURL(downloadedURL, inside: ProjectTempDirectory.tempRoot(for: workingDirectoryURL)) {
                return false
            }
            return true
        }

        return false
    }

    static func isURL(_ url: URL, inside directory: URL) -> Bool {
        let child = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return child.count >= parent.count && child.starts(with: parent)
    }
}

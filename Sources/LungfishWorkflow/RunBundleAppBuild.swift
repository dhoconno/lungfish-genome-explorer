// RunBundleAppBuild.swift - The app build a run bundle manifest records
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The app build that the manifest of a run bundle records beside ``LungfishAppVersion/short``.
///
/// A manifest that took its build from `Bundle.main` recorded its host's, such as xctest's, and a packaged
/// `lungfish-cli` recorded none, since its embedded plist carries no version keys. The build is read as
/// ``WorkflowRun/currentAppVersion`` reads it, from the Info.plist of the Lungfish app that is running or that
/// holds this CLI, and it is `dev` when no Lungfish plist gives one. So a manifest and the run record beside it
/// name the same app.
enum RunBundleAppBuild {
    /// What a build without a Lungfish plist is recorded as, the word ``WorkflowRun/currentAppVersion`` uses.
    static let developmentBuild = "dev"

    /// The build of this process.
    static var current: String {
        build(inAppVersion: WorkflowRun.currentAppVersion)
    }

    /// `5752` from `Lungfish 2026.9.99 (5752)`, and `dev` from `Lungfish 2026.10.10 (dev)`. A text without a build
    /// in parentheses gives `dev`.
    static func build(inAppVersion appVersion: String) -> String {
        guard appVersion.hasSuffix(")"), let open = appVersion.lastIndex(of: "(") else {
            return developmentBuild
        }
        let build = appVersion[appVersion.index(after: open)..<appVersion.index(before: appVersion.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        return build.isEmpty ? developmentBuild : build
    }
}

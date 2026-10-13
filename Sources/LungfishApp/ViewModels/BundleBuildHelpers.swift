// BundleBuildHelpers.swift - Shared utilities for bundle building ViewModels
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishKit
import LungfishWorkflow

extension BundleBuildHelpers {

    /// Resolves a managed tool executable path using the Lungfish conda layout.
    ///
    /// This intentionally avoids PATH and bundled-location fallbacks so the app
    /// matches the managed-tool resolution introduced for workflow execution.
    static func managedToolExecutablePath(
        _ tool: NativeTool,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        appIdentity: LungfishAppIdentity = .current
    ) -> String? {
        ManagedToolLocator.managedToolExecutablePath(tool, homeDirectory: homeDirectory, appIdentity: appIdentity)
    }
}

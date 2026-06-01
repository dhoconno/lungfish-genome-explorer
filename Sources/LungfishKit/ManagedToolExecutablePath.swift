// ManagedToolExecutablePath.swift - Managed-tool executable resolution for embedded viewers
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

/// Resolves managed-tool executable paths using the Lungfish conda layout.
///
/// Extracted from `BundleBuildHelpers.managedToolExecutablePath` so the
/// metagenomics result viewports (TaxTriage, NAO-MGS) can resolve tools such as
/// `samtools` without depending on the bundle-building ViewModel.
public enum ManagedToolLocator {

    /// Resolves a managed tool executable path using the Lungfish conda layout.
    ///
    /// This intentionally avoids PATH and bundled-location fallbacks so the app
    /// matches the managed-tool resolution introduced for workflow execution.
    public static func managedToolExecutablePath(
        _ tool: NativeTool,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        guard case .managed(let environment, let executableName) = tool.location else {
            return nil
        }

        let executableURL = CoreToolLocator.managedExecutableURL(
            environment: environment,
            executableName: executableName,
            homeDirectory: homeDirectory
        )
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }
        return executableURL.path
    }
}

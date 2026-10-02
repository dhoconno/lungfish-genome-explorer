// MetagenomicsImportService+ManagedSamtools.swift - The samtools an NVD import marks and counts reads with
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

extension MetagenomicsImportService {
    /// The managed samtools an NVD import marks duplicate reads and counts
    /// unique reads with, or nil when it is not installed. It is the
    /// executable the app's import helper passes, because LungfishKit's
    /// `ManagedToolLocator` resolves `NativeTool.samtools` to the same
    /// managed environment, so `lungfish-cli import nvd` and
    /// `lungfish-cli nvd import` produce the counts the Import Center
    /// produces (R3).
    public static func managedSamtoolsPath(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        appIdentity: LungfishAppIdentity = .current
    ) -> String? {
        managedSamtoolsExecutableURL(homeDirectory: homeDirectory, appIdentity: appIdentity)?.path
    }
}

// PluginManagerViewModel+PackRemoval.swift - What Remove All removes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "PluginManagerVM")

/// Lives outside the baselined PluginManagerViewModel.swift so that file does
/// not grow (scripts/ratchets/file-size.sh).
extension PluginManagerViewModel {
    /// Removes each environment `pack` installs into that is installed now.
    /// The names come from the pack's tool requirements, the list the
    /// installer runs, and not from its package names, which differ for GATK
    /// Core, Variant Phasing and Single-Cell. A failed removal is logged and
    /// the next environment is tried.
    func removeInstalledEnvironments(of pack: PluginPack) async {
        for name in pack.installEnvironmentNames where installedEnvironmentNames.contains(name) {
            do {
                try await condaManager.removeEnvironment(name: name)
                logger.info("Pack '\(pack.id, privacy: .public)': removed \(name, privacy: .public)")
            } catch {
                logger.error("Pack '\(pack.id, privacy: .public)': failed to remove \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// PluginManagerViewModel+OfflinePackGuidance.swift - Offline pack export and install commands
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishKit
import LungfishWorkflow

struct OfflinePackCommandGuidance: Equatable {
    let exportCommand: String
    let installCommand: String
    let copyText: String
}

/// Lives outside the baselined PluginManagerViewModel.swift so that file does
/// not grow (scripts/ratchets/file-size.sh).
extension PluginManagerViewModel {
    func offlinePackCommandGuidance(for pack: PluginPack) -> OfflinePackCommandGuidance {
        let archivePath = "./\(pack.id)-conda-offline-pack.tgz"
        let exportCommand = shellCommand([
            CLICommandIdentity.executableName,
            "conda",
            "export-pack",
            "--pack",
            pack.id,
            "--output",
            archivePath,
        ])
        let installCommand = shellCommand([
            CLICommandIdentity.executableName,
            "conda",
            "install",
            "--offline",
            "--from-bundle",
            archivePath,
        ])
        return OfflinePackCommandGuidance(
            exportCommand: exportCommand,
            installCommand: installCommand,
            copyText: [exportCommand, installCommand].joined(separator: "\n")
        )
    }

    func copyOfflinePackCommandGuidance(for pack: PluginPack) {
        let guidance = offlinePackCommandGuidance(for: pack)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(guidance.copyText, forType: .string)
    }
}

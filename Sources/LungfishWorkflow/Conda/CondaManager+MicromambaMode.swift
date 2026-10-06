// CondaManager+MicromambaMode.swift - Sets micromamba's executable bit only when it is missing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension CondaManager {
    /// Sets mode 0755 only when the file is not already executable. A channel that shares
    /// another channel's tool root (for example Debug using the Preview root) must not write to
    /// that root's micromamba. macOS treats it as changing another app's data and blocks the
    /// chmod on a consent prompt, which hung every tool run.
    static func makeExecutableIfNeeded(at path: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: path.path) == false else { return }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path.path
        )
    }
}

// RevealTestSupport.swift - Helpers for the tests of what a reveal tells the Inspector (Phase 2.11 lane U61)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
@testable import LungfishApp

/// The SHA-256 of every regular file under a folder, by path relative to the folder. Two digests of the
/// same folder are equal when no file was added, removed or changed between them, which is how a test shows
/// that a display and a reveal wrote nothing (UX 6).
enum TreeDigest {
    static func of(_ folder: URL) throws -> [String: String] {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [:] }
        var digests: [String: String] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count))
            let hash = SHA256.hash(data: try Data(contentsOf: url))
            digests[relative] = hash.map { String(format: "%02x", $0) }.joined()
        }
        return digests
    }
}

/// The `.sidebarSelectionChanged` notices one sidebar posts, as the standardized path each names. An empty
/// string is the notice of a cleared selection.
@MainActor
final class SelectionNoticeRecorder: NSObject {
    private(set) var paths: [String] = []

    func watch(_ sidebar: SidebarViewController) {
        NotificationCenter.default.addObserver(
            self, selector: #selector(record(_:)), name: .sidebarSelectionChanged, object: sidebar
        )
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func record(_ notification: Notification) {
        let item = notification.userInfo?["item"] as? SidebarItem
        paths.append(item?.url?.standardizedFileURL.path ?? "")
    }
}

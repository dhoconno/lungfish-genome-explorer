// ReferenceBundleBookmarkAccess.swift - Security-scoped bookmark access for reference bundles
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore

struct ReferenceBundleBookmarkAccess: Sendable {
    let resolve: @Sendable (Data) throws -> ReferenceBundleBookmarkResolution
    let startAccessing: @Sendable (URL) -> Bool
    let stopAccessing: @Sendable (URL) -> Void

    static let live = ReferenceBundleBookmarkAccess(
        resolve: { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withoutUI, .withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return ReferenceBundleBookmarkResolution(url: url, isStale: isStale)
        },
        startAccessing: { $0.startAccessingSecurityScopedResource() },
        stopAccessing: { $0.stopAccessingSecurityScopedResource() }
    )
}

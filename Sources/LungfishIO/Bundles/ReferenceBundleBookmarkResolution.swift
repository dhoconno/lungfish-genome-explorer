// ReferenceBundleBookmarkResolution.swift - Result of resolving a security-scoped bookmark
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log
import LungfishCore

struct ReferenceBundleBookmarkResolution: Sendable {
    let url: URL
    let isStale: Bool
}

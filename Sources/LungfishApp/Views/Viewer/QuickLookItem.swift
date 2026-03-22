// QuickLookItem.swift - QLPreviewItem wrapper for reliable file preview
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Quartz

/// Wrapper class that properly implements QLPreviewItem protocol.
///
/// Direct casting of URL to QLPreviewItem is unreliable - QuickLook may not
/// correctly resolve the file and shows an indefinite loading spinner.
/// This wrapper ensures proper protocol implementation.
final class QuickLookItem: NSObject, QLPreviewItem {
    let url: URL

    init(url: URL) {
        self.url = url
        super.init()
    }

    @objc dynamic var previewItemURL: URL? {
        return url
    }

    @objc dynamic var previewItemTitle: String? {
        return url.lastPathComponent
    }
}

// NSAlert+Lungfish.swift - Brand-consistent alert presentation
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

public extension NSAlert {
    /// Applies Lungfish branding to an alert.
    ///
    /// Uses the running application's icon so system warning dialogs do not show
    /// AppKit's generic placeholder glyph.
    @discardableResult
    func applyLungfishBranding() -> Self {
        if let appIcon = NSApp.applicationIconImage {
            icon = appIcon
        }
        return self
    }
}

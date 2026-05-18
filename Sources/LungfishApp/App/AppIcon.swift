// AppIcon.swift - App icon resource accessor
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

/// Provides access to the app icon from LungfishApp's bundled resources
public enum AppIcon {
    /// Returns the app icon image loaded from the bundled resources
    /// Falls back to NSApp.applicationIconImage if the resource cannot be loaded
    @MainActor
    public static var image: NSImage {
        if let url = RuntimeResourceLocator.path("Images/about-logo.png", in: .app),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSApp.applicationIconImage
    }
}

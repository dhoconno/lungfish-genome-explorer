// SettingsSection.swift - Sections of the settings UI, used for per-section reset
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

// MARK: - Settings Section

/// Sections of the settings UI, used for per-section reset.
public enum SettingsSection: String, Sendable {
    case general
    case appearance
    case rendering
    case aiServices
    case storage
    case advanced
}

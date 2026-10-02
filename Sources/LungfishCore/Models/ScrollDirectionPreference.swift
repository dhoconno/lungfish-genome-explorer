// ScrollDirectionPreference.swift - Scroll direction behavior for custom viewport interaction handling
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

/// Scroll direction behavior for custom viewport interaction handling.
public enum ScrollDirectionPreference: String, Sendable, CaseIterable, Codable {
    case system
    case natural
    case traditional

    public var label: String {
        switch self {
        case .system: return "System"
        case .natural: return "Natural"
        case .traditional: return "Traditional"
        }
    }
}

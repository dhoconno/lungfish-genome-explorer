// MetagenomicsImportKind.swift - Supported classifier result types for CLI-backed import
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import SQLite3
import os.log

/// Supported classifier result types for CLI-backed import.
public enum MetagenomicsImportKind: String, CaseIterable, Codable, Sendable {
    case kraken2
    case esviritu
    case taxtriage
    case naomgs
    case nvd

    /// Directory prefix used for imported result folders.
    public var directoryPrefix: String {
        switch self {
        case .kraken2:
            return "classification-"
        case .esviritu:
            return "esviritu-"
        case .taxtriage:
            return "taxtriage-"
        case .naomgs:
            return "naomgs-"
        case .nvd:
            return "nvd-"
        }
    }

    /// The canonical tool identifier used in `AnalysesFolder.knownTools`.
    public var toolIdentifier: String {
        rawValue
    }

    /// Token used by the `lungfish-cli import <token>` command family.
    public var importCommandToken: String {
        switch self {
        case .naomgs:
            return "nao-mgs"
        default:
            return rawValue
        }
    }
}

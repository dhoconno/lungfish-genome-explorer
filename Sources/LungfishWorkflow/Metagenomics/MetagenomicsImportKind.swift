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

    /// The registry's id for this kind. The raw value is the stored form, and it equals this id for every case.
    public var analysisToolID: AnalysisToolID {
        switch self {
        case .kraken2: return .kraken2
        case .esviritu: return .esviritu
        case .taxtriage: return .taxtriage
        case .naomgs: return .naomgs
        case .nvd: return .nvd
        }
    }

    /// Directory prefix used for imported result folders, the registry's `<id>-`. Kraken2 imports keep the
    /// `classification-` the first releases gave them where the registry's prefix is `kraken2-`, because
    /// existing projects hold folders by that name.
    public var directoryPrefix: String {
        self == .kraken2 ? "classification-" : analysisToolID.rawValue + "-"
    }

    /// The canonical tool identifier used in `AnalysesFolder.knownTools`.
    public var toolIdentifier: String {
        analysisToolID.rawValue
    }

    /// Token used by the `lungfish-cli import <token>` command family, the registry's id. The NAO-MGS command
    /// word has a hyphen that its id does not.
    public var importCommandToken: String {
        self == .naomgs ? "nao-mgs" : analysisToolID.rawValue
    }
}

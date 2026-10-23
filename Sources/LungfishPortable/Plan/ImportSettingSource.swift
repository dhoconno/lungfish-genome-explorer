// ImportSettingSource.swift - Where an import setting's value came from, shared by the import record and the plan
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Where an import setting's value came from: an option the command was given, the command's fixed default, this
/// host (its core count or its free memory), or the recipe that ran (its declared quality binning).
public enum ImportSettingSource: String, Sendable, Codable {
    case option
    case `default`
    case host
    case recipe
}

// ImportSettingSource.swift - Where an import setting's value came from, shared by the import record and the plan
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Where an import setting's value came from: an option the command was given, the command's fixed default, this
/// host (its core count or its free memory), the recipe that ran (its declared quality binning), or the plan the run
/// followed, which a run on another machine records.
public enum ImportSettingSource: String, Sendable, Codable {
    case option
    case `default`
    case host
    case recipe
    /// The value came from the plan the run followed, which the Mac wrote before the run, and was not read from the
    /// machine that ran it (ARCH ruling A1). A plan itself never stores it, nor `host`, for a value it fixes.
    case plan
}

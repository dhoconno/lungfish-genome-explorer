// CLICommandIdentity.swift - Shared public CLI executable identity
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

/// Canonical executable names for user-visible and replayable Lungfish commands.
public enum CLICommandIdentity {
    /// SwiftPM and app bundles install the command-line executable with this name.
    public static let executableName = "lungfish-cli"

    /// Pre-release provenance records used this older executable spelling.
    ///
    /// Keep accepting it only when reading or rehydrating existing provenance;
    /// newly generated commands should use ``executableName``.
    public static let legacyExecutableName = "lungfish"
}

// WorkflowVersion.swift - Semver helpers for saved workflow definitions
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum WorkflowVersion {
    public static let defaultVersion = "1.0.0"

    public static func isValidSemVer(_ value: String) -> Bool {
        let pattern = #"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    public static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidSemVer(trimmed) ? trimmed : defaultVersion
    }
}

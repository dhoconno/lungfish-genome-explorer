// ParameterValue+PathRewrite.swift - One path rewrite for the values a step's options hold
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ParameterValue {
    /// This value with `rewrite` applied to the path of every file value and to every string, through
    /// arrays and dictionaries. A site that rewrites a step's replay command with a function rewrites the
    /// step's resolved options with the same one, so a kept option never names a place the command no
    /// longer names. A file value whose path does not change comes back as it was.
    public func rewritingPaths(_ rewrite: (String) -> String) -> ParameterValue {
        switch self {
        case .file(let url):
            let rewritten = rewrite(url.path)
            return rewritten == url.path ? self : .file(URL(fileURLWithPath: rewritten))
        case .string(let string):
            return .string(rewrite(string))
        case .array(let values):
            return .array(values.map { $0.rewritingPaths(rewrite) })
        case .dictionary(let values):
            return .dictionary(values.mapValues { $0.rewritingPaths(rewrite) })
        case .integer, .number, .boolean, .null:
            return self
        }
    }
}

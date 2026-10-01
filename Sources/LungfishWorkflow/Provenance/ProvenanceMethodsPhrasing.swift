// ProvenanceMethodsPhrasing.swift - Recorded parameters as methods prose
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A methods sentence lists a tool's parameters after "with", so every
// phrase here is a noun phrase that reads after that word: "a minimum
// mapping quality of 20", "secondary alignments (flag 256) excluded".

import Foundation

public enum ProvenanceMethodsPhrasing {
    /// SAM flag bits by name, lowest bit first.
    static let samFlagNames: [(bit: Int, name: String)] = [
        (0x1, "paired reads"),
        (0x2, "properly paired reads"),
        (0x4, "unmapped reads"),
        (0x8, "reads with an unmapped mate"),
        (0x10, "reverse-strand reads"),
        (0x20, "reads with a reverse-strand mate"),
        (0x40, "first-in-pair reads"),
        (0x80, "second-in-pair reads"),
        (0x100, "secondary alignments"),
        (0x200, "reads failing quality control"),
        (0x400, "duplicate reads"),
        (0x800, "supplementary alignments"),
    ]

    /// `samtools view -F 256` as "secondary alignments (flag 256) excluded".
    public static func excludedFlags(_ value: String) -> String {
        guard let names = flagNames(value) else { return "reads with flag \(value) excluded" }
        return "\(names) (flag \(value)) excluded"
    }

    /// `samtools view -f 2` as "only properly paired reads (flag 2) kept".
    public static func requiredFlags(_ value: String) -> String {
        guard let names = flagNames(value) else { return "only reads with flag \(value) kept" }
        return "only \(names) (flag \(value)) kept"
    }

    /// The names of the bits set in a decimal or `0x` hexadecimal flag, or
    /// nil when the value is not a flag or sets an unnamed bit.
    static func flagNames(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        let flag: Int?
        if text.hasPrefix("0x") {
            flag = Int(text.dropFirst(2), radix: 16)
        } else {
            flag = Int(text)
        }
        guard let flag, flag > 0 else { return nil }
        var remaining = flag
        var names: [String] = []
        for entry in samFlagNames where flag & entry.bit != 0 {
            names.append(entry.name)
            remaining &= ~entry.bit
        }
        guard remaining == 0, !names.isEmpty else { return nil }
        return listed(names)
    }

    /// "a, b and c".
    public static func listed(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}

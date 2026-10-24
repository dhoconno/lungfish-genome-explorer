// PortableClumpifyLog.swift - The lines clumpify prints about its groups and memory
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The lines `clumpify.sh` prints about its groups and memory (tally-r2 K4-10, BIO N2-6), read from its standard
/// error: the N of its `Set groups to N` line and its `Memory Estimate` and `Memory Available` lines as printed. The
/// Mac import and the Linux executor read them through this one parser, so both records state the same count from the
/// same output (C4-10). A line clumpify printed more than once gives its last value.
package struct PortableClumpifyLog: Sendable, Equatable {
    /// The N of the last `Set groups to N` line, nil when clumpify printed none.
    package var groups: Int?
    package var memoryEstimate: String?
    package var memoryAvailable: String?

    package init(groups: Int? = nil, memoryEstimate: String? = nil, memoryAvailable: String? = nil) {
        self.groups = groups
        self.memoryEstimate = memoryEstimate
        self.memoryAvailable = memoryAvailable
    }

    /// Reads the three lines from clumpify's standard error, or its tail.
    package init(_ stderr: String) {
        for line in stderr.split(whereSeparator: \.isNewline) {
            let text = String(line)
            if text.hasPrefix("Set groups to "),
               let count = Int(text.dropFirst("Set groups to ".count).trimmingCharacters(in: .whitespaces)) {
                groups = count
            } else if text.hasPrefix("Memory Estimate:") {
                memoryEstimate = text
            } else if text.hasPrefix("Memory Available:") {
                memoryAvailable = text
            }
        }
    }
}

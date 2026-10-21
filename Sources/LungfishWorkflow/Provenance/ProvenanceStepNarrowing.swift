// ProvenanceStepNarrowing.swift - Where a step that a file's record narrowed is held whole
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// The record that holds a step whole, on a copy of the step whose inputs the record of one file narrowed to
/// that file's lineage, as the record of a BAM or BAM index of `build-db esviritu` narrows a step that read every
/// sample (ARCH ruling Q-A3-SHAPE of Phase 2.13, BIO's Q-A3). The narrowed step keeps its own `id`, so a reader
/// finds the whole step in the record at `recordPath` by that id.
public struct ProvenanceStepNarrowing: Codable, Sendable, Equatable {
    /// The absolute path of the record that holds the step whole when the step is built. The writer's portable
    /// rewrite and relocation move it with every other path of the record.
    public let recordPath: String
    /// How many inputs the step has in the record at `recordPath`.
    public let inputCount: Int

    public init(recordPath: String, inputCount: Int) {
        self.recordPath = recordPath
        self.inputCount = inputCount
    }
}

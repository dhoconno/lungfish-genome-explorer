// GATKRuntimeIdentity.swift - Conda environment and container identity of a GATK run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct GATKRuntimeIdentity: Sendable, Equatable {
    public let condaEnvironment: String?
    public let containerImage: String?
    public let containerDigest: String?

    public init(
        condaEnvironment: String? = nil,
        containerImage: String? = nil,
        containerDigest: String? = nil
    ) {
        self.condaEnvironment = condaEnvironment
        self.containerImage = containerImage
        self.containerDigest = containerDigest
    }
}

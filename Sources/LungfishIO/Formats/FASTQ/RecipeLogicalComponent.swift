// RecipeLogicalComponent.swift - A logical recipe component represented by a physical execution step
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

/// A logical recipe component represented by a physical execution step.
///
/// A physical tool invocation may fuse multiple logical recipe components.
/// These values identify the requested components without implying that each
/// component ran as a separate process.
public struct RecipeLogicalComponent: Codable, Sendable, Equatable {
    public let typeID: String
    public let displayName: String

    public init(typeID: String, displayName: String) {
        self.typeID = typeID
        self.displayName = displayName
    }
}

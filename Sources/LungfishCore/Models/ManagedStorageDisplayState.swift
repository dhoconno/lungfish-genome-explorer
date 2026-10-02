// ManagedStorageDisplayState.swift - High-level presentation state for the shared managed storage
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import os.log

/// High-level presentation state for the shared managed storage configuration.
public enum ManagedStorageDisplayState: Sendable, Equatable {
    case defaultRoot
    case customRoot(ManagedStorageLocation)
    case malformedBootstrap
}

// ReconciliationResult.swift - What one apply accomplished
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

@preconcurrency import Foundation
import CryptoKit
import LungfishCore
import os
import os.log

/// What one `apply` accomplished.
public struct ReconciliationResult: Sendable, Equatable, Codable {
    /// Item identifiers (environment names, database ids, "micromamba") that succeeded.
    public var succeeded: [String]
    /// Item identifier -> failure message.
    public var failed: [String: String]
    public var receipt: DependencyReceipt

    public init(succeeded: [String], failed: [String: String], receipt: DependencyReceipt) {
        self.succeeded = succeeded
        self.failed = failed
        self.receipt = receipt
    }
}

// GATKCommandRunning.swift - Runs one GATK command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public protocol GATKCommandRunning: Sendable {
    func run(_ command: GATKCommand) async throws -> GATKCommandExecutionResult
}

// DependencyOperationSink.swift - Where the reconciler reports progress
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

@preconcurrency import Foundation
import CryptoKit
import LungfishCore
import os
import os.log

/// Where the reconciler reports progress, without `LungfishWorkflow` having to know about
/// `OperationCenter` (which lives in `LungfishKit`). The App supplies an adapter.
public protocol DependencyOperationSink: Sendable {
    func start(title: String, detail: String) -> UUID
    func update(id: UUID, progress: Double, detail: String)
    func log(id: UUID, message: String)
    func complete(id: UUID, detail: String)
    /// Finishes an operation that did its work but hit a non-fatal problem worth surfacing.
    ///
    /// Distinct from `fail` because the user's tools really were installed; distinct from a
    /// plain `complete` because something (a receipt that could not be written, say) still
    /// deserves a note. Adapters that have no warning affordance inherit the default below and
    /// simply complete with the warning folded into the detail.
    func completeWithWarning(id: UUID, detail: String)
    func fail(id: UUID, detail: String, error: String)
}

public extension DependencyOperationSink {
    func completeWithWarning(id: UUID, detail: String) {
        complete(id: id, detail: detail)
    }
}

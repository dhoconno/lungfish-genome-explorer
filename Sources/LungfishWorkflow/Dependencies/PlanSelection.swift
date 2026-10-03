// PlanSelection.swift - Which parts of a plan the caller chose to apply
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

@preconcurrency import Foundation
import CryptoKit
import LungfishCore
import os
import os.log

/// Which parts of a plan the caller chose to apply.
public struct PlanSelection: Sendable, Equatable {
    public var environments: Set<String>
    public var databases: Set<String>
    public var includeRemovals: Bool

    public init(environments: Set<String>, databases: Set<String>, includeRemovals: Bool) {
        self.environments = environments
        self.databases = databases
        self.includeRemovals = includeRemovals
    }

    /// Everything the plan proposes.
    public static func all(from plan: ReconciliationPlan) -> PlanSelection {
        PlanSelection(
            environments: Set(
                plan.installEnvironments.map(\.environment) + plan.reinstallEnvironments.map(\.environment)
            ),
            databases: Set(plan.databaseUpdates.map(\.id)),
            includeRemovals: true
        )
    }

    /// Only the work the user cannot defer: required environments and `.required` databases.
    /// Removals are deferrable, so they are excluded.
    public static func requiredOnly(from plan: ReconciliationPlan) -> PlanSelection {
        PlanSelection(
            environments: Set(
                (plan.installEnvironments + plan.reinstallEnvironments)
                    .filter(\.isRequired)
                    .map(\.environment)
            ),
            databases: Set(plan.databaseUpdates.filter { $0.policy == .required }.map(\.id)),
            includeRemovals: false
        )
    }
}

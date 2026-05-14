// ProjectLockWarningPresentation.swift - User-facing locked-project warning text
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

struct ProjectLockWarningPresentation: Equatable, Sendable {
    let title: String
    let detail: String

    var accessibilityLabel: String {
        "\(title). \(detail)"
    }

    init?(state: ProjectOpenWarningState) {
        guard state.isReadOnlyRecommended else { return nil }

        title = "Project opened read-only"

        if let record = state.lockRecord, let lockStatus = state.lockStatus {
            let createdAt = record.createdAt.isEmpty ? "an unknown time" : record.createdAt
            detail = """
            \(record.toolName) has an \(lockStatus.rawValue) \(record.mode) lock from \(record.user)@\(record.host) pid \(record.pid), created \(createdAt). Project-writing workflows are blocked to protect shared storage.
            """
            return
        }

        if let readErrorDescription = state.readErrorDescription, !readErrorDescription.isEmpty {
            detail = """
            Project lock metadata could not be read: \(readErrorDescription). Project-writing workflows are blocked until the lock state can be checked.
            """
            return
        }

        detail = """
        Lock metadata is present, but the app could not determine who owns it. Project-writing workflows are blocked until the lock state can be checked.
        """
    }
}

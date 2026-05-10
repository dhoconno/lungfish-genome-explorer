// ProjectOpenWarningState.swift - App-facing shared project open warnings
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

public struct ProjectOpenWarningState: Sendable, Equatable {
    public let projectURL: URL?
    public let lockRecord: ProjectLockRecord?
    public let lockStatus: ProjectLockStatus?
    public let readErrorDescription: String?

    public var isReadOnlyRecommended: Bool {
        lockStatus == .active || lockStatus == .unknown || readErrorDescription != nil
    }

    public var warningMessage: String? {
        guard isReadOnlyRecommended else { return nil }

        if let lockRecord, let lockStatus {
            return "Project should be opened read-only because \(lockRecord.toolName) has a \(lockStatus.rawValue) \(lockRecord.mode) lock from \(lockRecord.user)@\(lockRecord.host) pid \(lockRecord.pid)."
        }

        if let readErrorDescription {
            return "Project should be opened read-only because its lock metadata could not be read: \(readErrorDescription)"
        }

        return "Project should be opened read-only because lock metadata is present."
    }

    public static func unlocked(projectURL: URL?) -> ProjectOpenWarningState {
        ProjectOpenWarningState(
            projectURL: projectURL?.standardizedFileURL,
            lockRecord: nil,
            lockStatus: nil,
            readErrorDescription: nil
        )
    }

    public static func evaluate(
        projectURL: URL,
        lockManager: ProjectLockManager = ProjectLockManager()
    ) -> ProjectOpenWarningState {
        let standardizedProjectURL = projectURL.standardizedFileURL
        do {
            guard let record = try lockManager.readLock(forProjectAt: standardizedProjectURL) else {
                return .unlocked(projectURL: standardizedProjectURL)
            }

            let status = lockManager.status(of: record)
            if status == .stale {
                return .unlocked(projectURL: standardizedProjectURL)
            }

            return ProjectOpenWarningState(
                projectURL: standardizedProjectURL,
                lockRecord: record,
                lockStatus: status,
                readErrorDescription: nil
            )
        } catch {
            return ProjectOpenWarningState(
                projectURL: standardizedProjectURL,
                lockRecord: nil,
                lockStatus: .unknown,
                readErrorDescription: error.localizedDescription
            )
        }
    }
}

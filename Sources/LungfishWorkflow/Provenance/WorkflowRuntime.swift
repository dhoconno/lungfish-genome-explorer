// WorkflowRuntime.swift - Runtime identity captured for a workflow execution
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishCore

// MARK: - WorkflowRuntime

/// Runtime identity captured for a workflow execution.
public struct WorkflowRuntime: Codable, Sendable, Equatable {
    /// Lungfish app version that performed this run.
    public let appVersion: String

    /// Host OS description (e.g., "macOS 26.1 (arm64)").
    public let hostOS: String

    /// OS user account that ran the operation.
    public let user: String?

    public init(appVersion: String, hostOS: String, user: String?) {
        self.appVersion = appVersion
        self.hostOS = hostOS
        self.user = user
    }
}

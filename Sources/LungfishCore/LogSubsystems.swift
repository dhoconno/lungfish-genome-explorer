// LogSubsystems - Centralized logging subsystem constants for all Lungfish modules
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import os

/// Centralized logging subsystem identifiers for each Lungfish module.
///
/// Usage:
/// ```swift
/// private let logger = Logger(subsystem: LogSubsystem.core, category: "MyService")
/// ```
///
/// All non-sensitive log interpolations should use `.public` privacy:
/// ```swift
/// logger.info("Loaded \(count, privacy: .public) sequences")
/// ```
public enum LogSubsystem {
    /// LungfishCore: data models, services, domain logic
    public static let core = "com.lungfish.core"

    /// LungfishIO: file format parsing, indexing, I/O
    public static let io = "com.lungfish.io"

    /// LungfishUI: rendering, tracks, visualization
    public static let ui = "com.lungfish.ui"

    /// LungfishPlugin: plugin system, built-in plugins
    public static let plugin = "com.lungfish.plugin"

    /// LungfishWorkflow: workflow execution, containers, native tools
    public static let workflow = "com.lungfish.workflow"

    /// LungfishApp: macOS UI, view controllers, windows
    public static let app = "com.lungfish.app"

    /// LungfishCLI: command-line interface
    public static let cli = "com.lungfish.cli"
}

// CondaToolTimeLimit.swift - The wall-clock limit of a conda tool run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// What the conda family of runners says about the wall-clock limit of a tool run.
///
/// An analysis tool has no wall-clock limit by default, and a limit is a named option that the caller
/// sets (`docs/contracts/SCOPE-AND-DELIVERY.md`, Tool run time).
enum CondaToolTimeLimit {
    /// Receives the spec of each `CondaManager.runTool` launch built in the current task, just before the launch.
    ///
    /// Production never binds it. A test binds it around one call to read the limit that call built, so no test
    /// has to run a tool for the length of a limit. It follows the task like `ToolProcessObservation.observer`,
    /// so it holds no state and one test cannot read the launches of another.
    @TaskLocal static var specProbe: (@Sendable (ToolProcessSpec) -> Void)?
}

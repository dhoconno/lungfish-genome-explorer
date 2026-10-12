// NextflowWorkflowDescriptor+Engine.swift - The engine settings of one launch of a Nextflow workflow
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S9, the bridge from a workflow's descriptor to the shared engine process (N2, N6 to
// N9). It sits in its own file, so the descriptor's files stay lane A16's.

import Foundation

extension NextflowWorkflowDescriptor {
    /// The engine settings of one launch with the effective `profile`, the profile the caller resolved
    /// and passes as `-profile`.
    ///
    /// The engine waits for the Docker daemon as ``waitsForDocker(profile:)`` decides, only when the
    /// workflow's tasks run in Docker and the launch keeps the workflow's own profile, so a conda run
    /// and a stand-in run with `local` never wait (A16 M1 review, ruling 2).
    package func engineConfiguration(profile: String) -> NextflowEngineConfiguration {
        NextflowEngineConfiguration(
            scratchPrefix: scratchPrefix,
            keepWorkEnvironmentKey: keepWorkEnvironmentKey,
            waitsForDocker: waitsForDocker(profile: profile)
        )
    }
}

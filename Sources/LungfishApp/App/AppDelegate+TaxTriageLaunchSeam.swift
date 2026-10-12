// AppDelegate+TaxTriageLaunchSeam.swift - The runner factory the GUI TaxTriage launch reads
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import LungfishWorkflow

extension AppDelegate {
    /// What `runTaxTriage` builds its serial batch runner with (Phase 2.8
    /// decision T14).
    ///
    /// The default is today's construction, `TaxTriageSerialBatchRunner()`,
    /// which runs the managed Nextflow. Only a test binds another factory, with
    /// `$makeRunner.withValue`, to run a stand-in engine through
    /// `TaxTriageSerialBatchRunner(runPipeline:)`. The factory is task-local,
    /// so nothing can assign it. `runTaxTriage` reads it on the main actor in
    /// the capture list of its detached task, because a detached task does not
    /// inherit task-local values.
    enum TaxTriageLaunchSeam {
        @TaskLocal static var makeRunner: @Sendable () -> TaxTriageSerialBatchRunner = {
            TaxTriageSerialBatchRunner()
        }
    }
}

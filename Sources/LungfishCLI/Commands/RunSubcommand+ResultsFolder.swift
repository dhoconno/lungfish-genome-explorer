// RunSubcommand+ResultsFolder.swift - A Viral Recon run refuses a results folder that already holds files
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

extension RunSubcommand {
    /// Phase 2.13 lane 13.21 (UX words W1). A run leaves its results in `--results-dir`, so a folder an earlier run
    /// used would end up with that run's files beside the new run's own. The refusal is an input error (exit status
    /// 3) like the `--timeout` refusal, it comes before anything is written, and it uses the check the app's request
    /// uses, ``ViralReconRunRequest/ResultsFolder``. A resumed run continues into the folder its earlier run used, so
    /// `--resume` is not refused. The check does not read the folder then, so a resumed run is accepted into any
    /// folder, and the record names `resume`.
    func requireUnusedViralReconResultsFolder() throws {
        guard !resume else { return }
        guard ViralReconRunRequest.ResultsFolder.holdsFiles(URL(fileURLWithPath: resultsDir)) else { return }
        throw CLIError.validationFailed(errors: [
            ViralReconRunRequest.ResultsFolder.leafRefusal(optionName: "--results-dir", path: resultsDir),
        ])
    }
}

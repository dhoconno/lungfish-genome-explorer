// TwelveSAmpliconResultViewController+ResultOnDisk.swift - The 12S viewer's actions that read the result on disk
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import LungfishWorkflow

extension TwelveSAmpliconResultViewController {
    /// Runs the export once the save panel returned `url`, behind an Operations row (lane 12.35, row B3), with the
    /// filters frozen in `snapshot`. A failure shows today's alert, and a cancel from the row shows none (UX 4).
    /// `runner` and `reporter` are seams for tests. The result is the row's ID and the task that runs the leaf,
    /// nil when no row began.
    @discardableResult
    func exportAfterSavePanel(
        snapshot: TwelveSAmpliconResultExportSnapshot,
        format: TwelveSAmpliconResultExportFormat,
        outputURL url: URL,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        Self.runResultExport(
            snapshot: snapshot, format: format, outputURL: url, runner: runner, reporter: reporter
        ) { [weak self] failure in
            self?.presentExportError(failure, fileName: url.lastPathComponent)
        }
    }
}

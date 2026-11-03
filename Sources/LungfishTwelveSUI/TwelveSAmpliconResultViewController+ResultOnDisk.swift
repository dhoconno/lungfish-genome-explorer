// TwelveSAmpliconResultViewController+ResultOnDisk.swift - The 12S viewer's actions that read the result on disk
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// The refusal of an export after the result changed on disk (ruling BIO-12S-STALE-EXPORT, Fix B).
struct TwelveSResultChangedOnDisk: LocalizedError {
    var errorDescription: String? {
        "This 12S result changed on disk after it opened, so the rows on screen are not the rows in the result. No file was written. Select another item in the sidebar, select this result again, and export again."
    }
}

extension TwelveSAmpliconResultViewController {
    /// Runs the export once the save panel returned `url`, behind an Operations row (lane 12.35, row B3), with the
    /// filters frozen in `snapshot`. A failure shows today's alert, and a cancel from the row shows none (UX 4).
    /// The leaf reads the bundle on disk and takes no rows from this view, so a result replaced after it opened
    /// would be written under the title on screen. Nothing starts unless the result tables on disk are the ones
    /// that opened, and the person reads why. `runner` and `reporter` are seams for tests. The result is the row's
    /// ID and the task that runs the leaf, nil when no row began.
    @discardableResult
    func exportAfterSavePanel(
        snapshot: TwelveSAmpliconResultExportSnapshot,
        format: TwelveSAmpliconResultExportFormat,
        outputURL url: URL,
        runner: CLIViewerExportRunner = CLIViewerExportRunner(),
        reporter: any OperationReporting = OperationCenter.shared
    ) -> (operationID: UUID, task: Task<CLIViewerExportRunner.Outcome, Never>)? {
        if let result, heldResultStamp != Self.resultTableStamp(of: result) {
            presentExportError(TwelveSResultChangedOnDisk(), fileName: url.lastPathComponent)
            return nil
        }
        return Self.runResultExport(
            snapshot: snapshot, format: format, outputURL: url, runner: runner, reporter: reporter
        ) { [weak self] failure in
            self?.presentExportError(failure, fileName: url.lastPathComponent)
        }
    }

    /// The size and modification time of each result table the export reads, as the bundle holds them now. A table
    /// the manifest names that is not on disk reads as missing. It does not read the bundle's run record, since a
    /// metadata import replaces that file and a metadata edit appends to it, and neither changes a table.
    static func resultTableStamp(of result: TwelveSAmpliconResultBundleData) -> [String] {
        let manifest = result.manifest
        let paths = [manifest.targetTablePath, manifest.countMatrixPath, manifest.sampleTablePath, manifest.readFatePath]
            + [manifest.alternateMatchesTablePath, manifest.unresolvedTablePath, manifest.reassignmentsTablePath]
                .compactMap { $0 }
        return paths.map { path in
            let url = TwelveSAmpliconResultBundle.resolvedURL(for: path, in: result.bundleURL)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize.map(String.init) ?? "missing"
            let modified = values?.contentModificationDate.map { String($0.timeIntervalSince1970) } ?? "missing"
            return "\(path) \(size) \(modified)"
        }
    }
}

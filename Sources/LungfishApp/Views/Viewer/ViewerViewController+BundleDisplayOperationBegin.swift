// ViewerViewController+BundleDisplayOperationBegin.swift - Operations panel registration for bundle display launches
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishKit

/// The begin helper for the launch in the baselined
/// ViewerViewController+BundleDisplay.swift (finding R4). It registers a row
/// through `OperationReporting` and calls `launch` only when the row started,
/// so a test can check the row and its command without touching
/// `OperationCenter.shared`. It lives here, not beside its launch site, so the
/// baselined file does not grow (scripts/ratchets/file-size.sh).
extension ViewerViewController {
    /// Registers the row for extracting the navigator's selected chromosomes
    /// into a new reference bundle and, only when it starts, calls `launch`
    /// with the operation ID. The row locks no bundle.
    ///
    /// `cliArguments` is the argv the run executes, which
    /// ``FASTASelectionReferenceBundleCLI/arguments(sourceURL:sequenceIDs:projectURL:bundleName:)``
    /// builds and the call site ends with `--quiet`. The row records it as the
    /// `lungfish-cli extract contigs --bundle` command it is.
    @discardableResult
    static func beginSelectedChromosomeExtractionOperation(
        cliArguments: [String],
        selectedCount: Int,
        routeContext: OperationRouteContext?,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Extract Sequences",
            detail: "Extracting \(selectedCount) selected sequence(s) into a new bundle...",
            operationType: .bundleBuild,
            cliCommand: OperationCenter.buildCLICommand(
                subcommand: "extract contigs",
                args: Array(cliArguments.dropFirst(2))
            ),
            routeContext: routeContext
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }
}

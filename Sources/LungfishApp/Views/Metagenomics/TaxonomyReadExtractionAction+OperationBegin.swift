// TaxonomyReadExtractionAction+OperationBegin.swift - Operations panel registration for classifier extraction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishKit
import LungfishWorkflow

/// The begin helper for classifier read extraction (finding R4), kept out of
/// the baselined TaxonomyReadExtractionAction.swift so that file does not
/// grow (scripts/ratchets/file-size.sh).
extension TaxonomyReadExtractionAction {
    /// Registers the extraction row and, only when it starts, calls `launch`
    /// with the operation ID. Extraction writes a new file or bundle and
    /// locks no existing bundle.
    ///
    /// `cliCommand` is the `lungfish-cli extract reads` command
    /// ``buildCLIString(context:options:destination:scratchFile:)`` builds,
    /// which reproduces the run for every destination. The caller also stores
    /// it as a bundle's provenance command. A clipboard or share row runs it
    /// into the scratch file of its ``ClassifierExtractionCopyRoute``, which
    /// the app then copies (Phase 2.12 lane 12.11).
    @discardableResult
    static func beginExtractionOperation(
        context: Context,
        cliCommand: String,
        reporter: any OperationReporting = OperationCenter.shared,
        launch: (UUID) -> Void
    ) -> OperationStartResult {
        let result = reporter.begin(
            title: "Extract Reads — \(context.tool.displayName)",
            detail: "Running \(context.tool.displayName) extraction…",
            operationType: .taxonomyExtraction,
            cliCommand: cliCommand,
            routeContext: context.routeContext
        )
        switch result {
        case .started(let operationID):
            launch(operationID)
        case .refused:
            break // The panel already shows the refused row. Nothing was launched.
        }
        return result
    }

    /// The folder a `.bundle` extraction writes into, the same folder
    /// `ClassifierReadResolver.bundleDestinationDirectory(projectRoot:)`
    /// returns, computed without creating it. The CLI creates its bundle
    /// beside its `-o` file, so `-o` must name a file in this folder.
    static func bundleOutputDirectory(projectRoot: URL) -> URL {
        let standardized = projectRoot.standardizedFileURL
        if standardized.lastPathComponent == ClassifierReadResolver.extractionsFolderName {
            return standardized
        }
        return standardized.appendingPathComponent(ClassifierReadResolver.extractionsFolderName, isDirectory: true)
    }
}

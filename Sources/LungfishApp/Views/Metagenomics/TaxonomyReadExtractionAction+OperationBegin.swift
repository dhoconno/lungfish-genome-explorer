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
    /// `cliCommand` comes from ``rowCLICommand(_:destination:)``. File and
    /// bundle destinations record the `lungfish-cli extract reads` command
    /// ``buildCLIString(context:options:destination:)`` builds, which the
    /// caller also stores as the bundle's provenance command and which
    /// reproduces the run.
    ///
    /// cli-parity-gap: classifier-extract-clipboard-share. Clipboard and share
    /// destinations have no CLI equivalent, so they record no command.
    @discardableResult
    static func beginExtractionOperation(
        context: Context,
        cliCommand: String?,
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

    /// The command the extraction row records for `cli`, the string
    /// ``buildCLIString(context:options:destination:)`` built for
    /// `destination`. A clipboard or share destination records nil, because
    /// the CLI writes files and no command reproduces either.
    static func rowCLICommand(_ cli: String, destination: ExtractionDestination) -> String? {
        switch destination {
        case .file, .bundle:
            return cli
        case .clipboard, .share:
            return nil
        }
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

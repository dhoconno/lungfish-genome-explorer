// FASTQOperationOutputImporter+AppImportCommand.swift - The command a FASTQ output import records for a launch that is not a derivative
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

extension AppFASTQOutputBundleWriter {
    /// The `Lungfish.app import-fastq-operation-output` form a FASTQ output
    /// bundle records in its manifest when its launch is not a FASTQ
    /// derivative.
    ///
    /// Only a derivative's FASTQ output reaches this import today, and its
    /// manifest records the `lungfish-cli` command that ran. No `lungfish-cli`
    /// command writes a FASTQ for any other launch, so the record names the
    /// app's import with descriptive flags, the launch, the input the launch
    /// read and the payload the import wrote (findings R3 and R8). It used to
    /// record `lungfish <FASTQ> -o <payload>`, the legacy executable name with
    /// arguments no command takes and the scratch FASTQ the run deletes.
    static func appImportCommandLine(
        for request: FASTQOperationLaunchRequest,
        inputURL: URL?,
        outputURL: URL
    ) -> String {
        var arguments = ["Lungfish.app", "import-fastq-operation-output", "--operation", request.operationDisplayTitle]
        if let inputURL = inputURL ?? request.inputURLs.first {
            arguments += ["--input", inputURL.path]
        }
        arguments += ["--output", outputURL.path]
        return arguments.map(shellEscape).joined(separator: " ")
    }
}

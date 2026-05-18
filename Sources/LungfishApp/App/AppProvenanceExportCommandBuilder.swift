// AppProvenanceExportCommandBuilder.swift - App provenance export command construction
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishWorkflow

enum AppProvenanceExportCommandBuilder {
    static func argv(
        format: ProvenanceExportFormat,
        sourceURL: URL,
        outputDirectory: URL
    ) -> [String] {
        [
            "lungfish",
            "provenance",
            "export",
            sourceURL.path,
            "--export-format",
            format.cliToken,
            "--output",
            outputDirectory.path,
        ]
    }
}

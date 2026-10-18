// FastqExportSubcommand.swift - lungfish-cli fastq export, the group of the FASTQ viewer exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser

/// The exports of the app's FASTQ views (Phase 2.12, ARCH ruling X-1). Lane 12.34 adds `sample-barcodes` and
/// lane 12.38 adds `reads`, so each lane adds its leaf to this list on a line of its own.
struct FastqExportSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export FASTQ views and tables with provenance",
        subcommands: [
            FastqExportReadsSubcommand.self,
            FastqExportSampleBarcodesSubcommand.self,
        ]
    )
}

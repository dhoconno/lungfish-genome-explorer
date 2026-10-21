// PrimerExportInvocations.swift - The argv of the primer order and primer selection exports
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

/// The `lungfish-cli primers analysis export-order` command of a primer order export (Phase 2.13 lane 13.43,
/// PRIMER-EXPORT-RUN, ARCH ruling on the export shape 1.1).
///
/// The Inspector's order export and the leaf share this builder, so the row the app records, the argv the leaf records
/// and the command a user pastes in Terminal are one command.
public enum PrimerOrderExport {
    /// The leaf's path under `lungfish-cli`.
    public static let commandPath = ["primers", "analysis", "export-order"]
}

/// The `lungfish-cli primers analysis export-selection` command of a primer FASTA bundle or a reference amplicon
/// export (Phase 2.13 lane 13.43, PRIMER-EXPORT-RUN, ARCH ruling on the export shape 1.1).
public enum PrimerSelectionExport {
    /// The leaf's path under `lungfish-cli`.
    public static let commandPath = ["primers", "analysis", "export-selection"]
}

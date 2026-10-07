// SRADownloadSubcommand+PreferSource.swift - The archive fetch sra download tries first
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import LungfishCore
import LungfishWorkflow

extension SRADownloadSourcePreference: ExpressibleByArgument {}

extension SRADownloadSubcommand {
    /// The archive tried first, `ena` unless `--prefer-source` names one.
    var sourcePreference: SRADownloadSourcePreference {
        preferSource ?? .ena
    }

    /// What the user asked for, as the provenance records it under
    /// `requestedStrategy`, in the names the window records too.
    var requestedStrategy: String {
        SRADownloadStrategy.requested(preference: sourcePreference, toolkitOnly: useToolkit)
    }

    /// The strategy of the route tried first.
    var initialStrategy: String {
        useToolkit || sourcePreference == .ncbi ? "sra-toolkit" : "ena-direct"
    }

    /// The `--prefer-source` arguments the recorded command carries, only
    /// when NCBI was chosen, since ENA is the default.
    var preferSourceArguments: [String] {
        !useToolkit && sourcePreference == .ncbi ? ["--prefer-source", SRADownloadSourcePreference.ncbi.rawValue] : []
    }

    /// The preference the provenance records, or null for `--use-toolkit`,
    /// which fetches with the SRA Toolkit only.
    var preferredSourceParameter: ParameterValue {
        useToolkit ? .null : .string(sourcePreference.rawValue)
    }

    func validate() throws {
        try validateRunAccession()
        if useToolkit, preferSource != nil {
            throw ValidationError("--use-toolkit fetches with the SRA Toolkit only, so it cannot be combined with --prefer-source.")
        }
    }
}

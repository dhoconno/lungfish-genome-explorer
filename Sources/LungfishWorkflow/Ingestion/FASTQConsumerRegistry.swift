// FASTQConsumerRegistry.swift - Every FASTQ-consuming tool's declared read-layout handling
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The owner contract (FASTQInputLayout.swift) asks every tool invocation
// that consumes FASTQ to say what it does with single-end, strictly
// interleaved, mixed (merged reads plus pairs), and R1/R2 input. The
// mappers declare next to their builder (MappingTool+ReadLayout). The rest
// are declared here, with the source that decides the behaviour named in
// the rationale. Every consumer now resolves its layout through
// FASTQInputLayoutResolver (metadata, then a record scan) and either pairs
// mixed input by NAME or runs it as single reads; `mixedHandlingIsGraceful
// == false` is reserved for a consumer that still pairs mixed input by
// position, and FASTQConsumerRegistryTests pins that list (empty) so a new
// unsafe consumer cannot slip in unnoticed.

import Foundation
import LungfishIO

public enum FASTQConsumerRegistry {

    /// Every declaration, mappers first.
    public static var declarations: [FASTQConsumerDeclaration] {
        MappingTool.allCases.map(\.fastqConsumerDeclaration)
            + classifierDeclarations
            + assemblerDeclarations
            + fastqSubcommandDeclarations
            + guiAndRecipeDeclarations
            + genotypingAndWorkflowDeclarations
    }

    /// The declaration for a consumer ID, if registered.
    public static func declaration(for consumerID: String) -> FASTQConsumerDeclaration? {
        declarations.first { $0.consumerID == consumerID }
    }

    /// Consumers whose declared mixed handling is not graceful.
    public static var consumersWithUngracefulMixedHandling: [FASTQConsumerDeclaration] {
        declarations.filter { !$0.mixedHandlingIsGraceful }
    }
}

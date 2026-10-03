// ReadPairingCapabilityRegistry.swift - Every read consumer's declared pairing capability
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each family declares its tools in its own file under Capabilities/, so a
// lane that moves a tool onto ReadSetResolver edits only its family's file.
// ReadPairingCapabilityRegistryTests fails when a consumer in
// FASTQConsumerRegistry has no capability here, or the other way round.

import Foundation

public enum ReadPairingCapabilityRegistry {

    /// Every declaration, by family.
    public static var declarations: [ReadPairingCapabilityDeclaration] {
        mapperCapabilities
            + kraken2Capabilities
            + samplesheetPipelineCapabilities
            + assemblerCapabilities
            + fastqOperationCapabilities
            + twelveSCapabilities
    }

    /// The declaration for a consumer ID, if registered.
    public static func declaration(for consumerID: String) -> ReadPairingCapabilityDeclaration? {
        declarations.first { $0.consumerID == consumerID }
    }

    /// The capability for a consumer ID, if registered.
    public static func capability(for consumerID: String) -> ReadPairingCapability? {
        declaration(for: consumerID)?.capability
    }
}

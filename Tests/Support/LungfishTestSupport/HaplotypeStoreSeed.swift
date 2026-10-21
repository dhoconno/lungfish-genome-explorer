// HaplotypeStoreSeed.swift - Save a haplotype definition set to seed a test fixture
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.27 (R2 of BIO-Q-A2). `HaplotypeDefinitionStore.save` takes the caller's provenance context with
// no default, so a test that only needs a definition on disk calls this instead. The record it writes names the app,
// as the nil-context record did, and its argv is the store's own default argv.

import LungfishCore
import LungfishIO

extension HaplotypeDefinitionStore {
    public func seed(_ set: GenotypeHaplotypeDefinitionSet, changeNote: String? = nil) throws {
        try save(
            set,
            changeNote: changeNote,
            provenanceContext: HaplotypeDefinitionProvenanceContext(
                workflowName: "Haplotype definition save",
                toolName: LungfishAppIdentity.recordedToolName,
                argv: []
            )
        )
    }
}

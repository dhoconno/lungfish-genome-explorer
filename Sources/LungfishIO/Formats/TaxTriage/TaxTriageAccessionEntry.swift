// TaxTriageAccessionEntry.swift - An entry in the accession_map table linking organisms to their
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import SQLite3
import LungfishCore
import os.log

// MARK: - Accession Map Entry

/// An entry in the accession_map table linking organisms to their reference accessions.
public struct TaxTriageAccessionEntry: Sendable {
    public let sample: String
    public let organism: String
    public let accession: String
    public let description: String?

    public init(sample: String, organism: String, accession: String, description: String? = nil) {
        self.sample = sample
        self.organism = organism
        self.accession = accession
        self.description = description
    }
}

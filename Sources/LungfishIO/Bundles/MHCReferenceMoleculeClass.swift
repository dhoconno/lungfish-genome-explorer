// MHCReferenceMoleculeClass.swift - Molecule class of an MHC reference record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import SQLite3

public enum MHCReferenceMoleculeClass: String, Codable, Equatable, Sendable {
    case genomicDNA
    case cDNA
}

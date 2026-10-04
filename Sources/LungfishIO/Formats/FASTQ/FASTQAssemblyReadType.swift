// FASTQAssemblyReadType.swift - Explicit dataset-level read type that sets assembly defaults
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import os.log

// MARK: - Persisted Assembly Read Type

/// Explicit dataset-level read type that sets assembly defaults and warnings.
///
/// Stored in the FASTQ sidecar so the app can remember a user-confirmed assembly
/// class independently of sample metadata CSV fields.
public enum FASTQAssemblyReadType: String, Codable, Sendable, CaseIterable {
    case illuminaShortReads
    case ontReads
    case pacBioHiFi

    public var displayName: String {
        switch self {
        case .illuminaShortReads:
            return "Illumina short reads"
        case .ontReads:
            return "ONT reads"
        case .pacBioHiFi:
            return "PacBio HiFi/CCS"
        }
    }

    public init?(sequencingPlatform: SequencingPlatform) {
        switch sequencingPlatform {
        case .illumina, .element, .mgi:
            self = .illuminaShortReads
        case .oxfordNanopore:
            self = .ontReads
        default:
            return nil
        }
    }
}

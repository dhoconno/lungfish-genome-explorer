// FASTQDerivativeError.swift - Error type for FASTQ derivative operations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

public enum FASTQDerivativeError: Error, LocalizedError {
    case sourceMustBeBundle
    case sourceFASTQMissing
    case derivedManifestMissing
    case parentBundleMissing(String)
    case rootBundleMissing(String)
    case rootFASTQMissing
    case invalidOperation(String)
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .sourceMustBeBundle:
            return "Bundle-backed FASTQ/FASTA operations require a .lungfishfastq bundle."
        case .sourceFASTQMissing:
            return "The source FASTQ file is missing from the bundle."
        case .derivedManifestMissing:
            return "Derived FASTQ manifest is missing."
        case .parentBundleMissing(let path):
            return "Parent FASTQ bundle not found: \(path)"
        case .rootBundleMissing(let path):
            return "Root FASTQ bundle not found: \(path)"
        case .rootFASTQMissing:
            return "Root FASTQ payload is missing."
        case .invalidOperation(let reason):
            return "Invalid FASTQ/FASTA operation: \(reason)"
        case .emptyResult:
            return "Operation produced no reads."
        }
    }
}

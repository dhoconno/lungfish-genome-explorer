// VCFError.swift - Errors that can occur when parsing VCF files
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore

// MARK: - VCFError

/// Errors that can occur when parsing VCF files.
public enum VCFError: Error, LocalizedError, Sendable {

    case missingHeader
    case unsupportedVCFVersion(version: String)
    case invalidLineFormat(line: Int, expected: Int, got: Int)
    case invalidPosition(line: Int, value: String)
    case invalidAllele(line: Int, field: String, value: String)
    case invalidQuality(line: Int, value: String)

    public var errorDescription: String? {
        switch self {
        case .missingHeader:
            return "VCF file missing header line (#CHROM...)"
        case .unsupportedVCFVersion:
            return "VCFv3 is not supported. Convert to VCF 4.x with bcftools convert or vcf-convert (vcftools) before importing. See https://samtools.github.io/bcftools/bcftools.html#convert and https://vcftools.github.io/perl_module.html"
        case .invalidLineFormat(let line, let expected, let got):
            return "VCF line \(line): expected at least \(expected) fields, got \(got)"
        case .invalidPosition(let line, let value):
            return "VCF line \(line): invalid position '\(value)'"
        case .invalidAllele(let line, let field, let value):
            return "VCF line \(line): invalid \(field) allele '\(value)'"
        case .invalidQuality(let line, let value):
            return "VCF line \(line): invalid quality '\(value)'"
        }
    }
}

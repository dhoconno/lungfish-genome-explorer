// VCFReferenceInference.swift - Infers reference genome from VCF chromosome names/contigs
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - VCFReferenceInference

/// Infers the reference genome assembly from VCF file metadata.
///
/// VCF files may provide reference information through:
/// 1. `##contig` header lines with chromosome names and lengths
/// 2. Chromosome names in variant records
/// 3. Max variant positions (crude length estimates)
///
/// This leverages the existing `ReferenceInference` engine, adapting its
/// SAM-focused matching to VCF-specific inputs.
///
/// ## Example
///
/// ```swift
/// let reader = VCFReader()
/// let header = try await reader.readHeader(from: url)
/// let result = VCFReferenceInference.infer(from: header)
/// print(result.assembly)   // "SARS-CoV-2"
/// print(result.confidence) // .high
/// ```
public enum VCFReferenceInference {

    // MARK: - Full Inference

    /// Infers reference genome from a VCF header and optional per-chromosome max positions.
    ///
    /// Uses multiple strategies in priority order:
    /// 1. Contig lines with lengths (most reliable)
    /// 2. Well-known chromosome name patterns
    /// 3. Max variant positions as crude length estimates
    ///
    /// - Parameters:
    ///   - header: Parsed VCF header
    ///   - chromosomeMaxPositions: Optional map of chromosome name to max variant position
    /// - Returns: Inference result with assembly, organism, and confidence
    public static func infer(
        from header: VCFHeader,
        chromosomeMaxPositions: [String: Int]? = nil
    ) -> ReferenceInference.Result {
        // Strategy 1: Use contig lines with lengths → delegate to ReferenceInference
        if !header.contigs.isEmpty {
            let sequences = header.contigs.map { (name, length) in
                SAMParser.ReferenceSequence(
                    name: name,
                    length: Int64(length),
                    md5: nil,
                    assembly: nil,
                    uri: nil,
                    species: nil
                )
            }
            let result = ReferenceInference.infer(from: sequences)
            if result.confidence >= .medium {
                return result
            }
        }

        // Strategy 2: Match well-known chromosome names from sample names in header
        let chromNames: Set<String>
        if !header.contigs.isEmpty {
            chromNames = Set(header.contigs.keys)
        } else if let positions = chromosomeMaxPositions {
            chromNames = Set(positions.keys)
        } else if !header.sampleNames.isEmpty {
            // No chromosome info available at all from header alone
            chromNames = []
        } else {
            chromNames = []
        }

        if !chromNames.isEmpty {
            let nameResult = infer(fromChromosomeNames: chromNames)
            if nameResult.confidence >= .low {
                // If we also have max positions, refine the estimate
                if let positions = chromosomeMaxPositions,
                   nameResult.confidence == .low {
                    return refineWithPositions(
                        baseResult: nameResult,
                        positions: positions
                    )
                }
                return nameResult
            }
        }

        // Strategy 3: Use max variant positions as crude length estimates
        if let positions = chromosomeMaxPositions, !positions.isEmpty {
            let sequences = positions.map { (name, maxPos) in
                SAMParser.ReferenceSequence(
                    name: name,
                    length: Int64(maxPos),
                    md5: nil,
                    assembly: nil,
                    uri: nil,
                    species: nil
                )
            }
            let result = ReferenceInference.infer(from: sequences)
            if result.confidence >= .low {
                return result
            }
        }

        // No match
        return ReferenceInference.Result(
            assembly: nil, organism: nil, accession: nil,
            namingConvention: chromNames.isEmpty ? nil : ReferenceInference.detectNamingConvention(names: chromNames),
            confidence: .none,
            sequenceCount: chromNames.count,
            totalLength: Int64(chromosomeMaxPositions?.values.reduce(0, +) ?? 0)
        )
    }

    // MARK: - Name-Only Inference

    /// Infers reference genome from chromosome names alone (no length information).
    ///
    /// Matches against well-known chromosome naming patterns:
    /// - `NC_045512.2` → SARS-CoV-2
    /// - `chr1`, `chr2`, ... → Human (UCSC)
    /// - `NC_0000XX.XX` → Human (RefSeq)
    /// - etc.
    ///
    /// - Parameter names: Set of chromosome names from VCF records
    /// - Returns: Inference result (typically low-medium confidence without lengths)
    public static func infer(fromChromosomeNames names: Set<String>) -> ReferenceInference.Result {
        guard !names.isEmpty else {
            return ReferenceInference.Result(
                assembly: nil, organism: nil, accession: nil,
                namingConvention: nil, confidence: .none,
                sequenceCount: 0, totalLength: 0
            )
        }

        let naming = ReferenceInference.detectNamingConvention(names: names)

        // Try direct name lookup for each chromosome name
        var matchCounts: [String: (assembly: String, organism: String, accession: String?, count: Int)] = [:]

        for name in names {
            if let match = ReferenceInference.lookupByChromosomeName(name) {
                let key = match.assembly
                if var entry = matchCounts[key] {
                    entry.count += 1
                    matchCounts[key] = entry
                } else {
                    matchCounts[key] = (match.assembly, match.organism, match.accession, 1)
                }
            }
        }

        // Pick the assembly with the most matching chromosome names
        if let best = matchCounts.values.max(by: { $0.count < $1.count }) {
            // Confidence based on how many names matched
            let confidence: ReferenceInference.Confidence
            if best.count >= 3 {
                confidence = .medium
            } else if best.count >= 1 {
                // For single-contig organisms like SARS-CoV-2, 1 match is sufficient
                confidence = names.count <= 2 ? .medium : .low
            } else {
                confidence = .low
            }

            return ReferenceInference.Result(
                assembly: best.assembly,
                organism: best.organism,
                accession: best.accession,
                namingConvention: naming,
                confidence: confidence,
                sequenceCount: names.count,
                totalLength: 0
            )
        }

        return ReferenceInference.Result(
            assembly: nil, organism: nil, accession: nil,
            namingConvention: naming, confidence: .none,
            sequenceCount: names.count, totalLength: 0
        )
    }

    // MARK: - NCBI Accession Extraction

    /// Extracts NCBI accession patterns from chromosome names.
    ///
    /// Recognizes RefSeq accession prefixes:
    /// - `NC_` — Complete genomic molecule (chromosome)
    /// - `NW_` — WGS contig
    /// - `NT_` — Intermediate assembled contig
    /// - `AC_` — Alternate complete genomic molecule
    ///
    /// - Parameter chromosomeNames: Set of chromosome names from VCF records
    /// - Returns: Array of unique NCBI accession strings found
    public static func extractNCBIAccessions(from chromosomeNames: Set<String>) -> [String] {
        // Match patterns like NC_045512.2, NW_025791760.1, NT_187361.1, AC_000158.1
        let pattern = /^(NC|NW|NT|AC)_\d{6,9}\.\d+$/
        return chromosomeNames
            .filter { $0.wholeMatch(of: pattern) != nil }
            .sorted()
    }

    // MARK: - Private Helpers

    /// Refines a name-based result using max variant positions as crude length estimates.
    private static func refineWithPositions(
        baseResult: ReferenceInference.Result,
        positions: [String: Int]
    ) -> ReferenceInference.Result {
        guard let assembly = baseResult.assembly else { return baseResult }

        // Check if the known assembly's chr1 length is compatible with max positions
        let assemblies = ReferenceInference.knownAssemblyList()
        guard let sig = assemblies.first(where: { $0.assembly == assembly }) else {
            return baseResult
        }

        // For single-chromosome organisms, max variant position should be <= total size
        let maxPos = positions.values.max() ?? 0
        if maxPos > 0 && Int64(maxPos) <= sig.totalSize {
            return ReferenceInference.Result(
                assembly: baseResult.assembly,
                organism: baseResult.organism,
                accession: baseResult.accession,
                namingConvention: baseResult.namingConvention,
                confidence: .medium,
                sequenceCount: baseResult.sequenceCount,
                totalLength: Int64(positions.values.reduce(0, +))
            )
        }

        return baseResult
    }
}

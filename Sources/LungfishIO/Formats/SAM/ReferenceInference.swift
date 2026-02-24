// ReferenceInference.swift - Infers reference genome from BAM/SAM header @SQ lines
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ReferenceInference

/// Infers the reference genome assembly from BAM/SAM header @SQ (reference sequence) entries.
///
/// Uses chromosome naming conventions and key chromosome lengths to match against
/// known genome assemblies. This allows automatic detection of the reference genome
/// when importing alignment files.
///
/// ## Matching Strategy
///
/// 1. **Naming convention**: "chr1" vs "1" vs "NC_000001.11" identifies UCSC/Ensembl/RefSeq styles
/// 2. **Key lengths**: chr1 length uniquely identifies assembly version (e.g., GRCh38 vs GRCh37)
/// 3. **Sequence count**: Total reference count helps disambiguate (e.g., with/without patches)
///
/// ## Example
///
/// ```swift
/// let sequences = SAMParser.parseReferenceSequences(from: headerText)
/// let result = ReferenceInference.infer(from: sequences)
/// print(result.assembly) // "GRCh38"
/// print(result.confidence) // .high
/// ```
public enum ReferenceInference {

    // MARK: - Result Types

    /// Confidence level of the inference.
    public enum Confidence: Sendable, Comparable {
        /// No match found.
        case none
        /// Weak match based on heuristics.
        case low
        /// Partial match (e.g., naming matches but lengths not verified).
        case medium
        /// Strong match on multiple criteria.
        case high
    }

    /// Result of reference inference.
    public struct Result: Sendable {
        /// Inferred assembly name (e.g., "GRCh38", "GRCm39", "T2T-CHM13v2.0").
        public let assembly: String?
        /// Common name (e.g., "Human", "Mouse", "SARS-CoV-2").
        public let organism: String?
        /// NCBI assembly accession if known (e.g., "GCF_000001405.40").
        public let accession: String?
        /// Naming convention used ("UCSC", "Ensembl", "RefSeq", "GenBank").
        public let namingConvention: String?
        /// Confidence of the inference.
        public let confidence: Confidence
        /// Number of reference sequences in the header.
        public let sequenceCount: Int
        /// Total genome size in bases.
        public let totalLength: Int64
    }

    // MARK: - Known Assemblies

    /// Key chromosome lengths for known assemblies.
    /// Uses chr1 (or equivalent) length as the primary discriminator.
    private struct AssemblySignature {
        let assembly: String
        let organism: String
        let accession: String?
        /// Expected length of the largest autosome (chr1 or equivalent).
        let chr1Length: Int64
        /// Expected total genome size (approximate, for secondary matching).
        let totalSize: Int64
        /// UCSC-style name patterns.
        let ucscNames: [String]
        /// Ensembl/NCBI numeric names.
        let ensemblNames: [String]
        /// RefSeq accession patterns.
        let refseqPattern: String?
    }

    private static let knownAssemblies: [AssemblySignature] = [
        // Human
        AssemblySignature(
            assembly: "GRCh38", organism: "Human", accession: "GCF_000001405.40",
            chr1Length: 248_956_422, totalSize: 3_088_286_401,
            ucscNames: ["chr1", "chr2", "chr3"], ensemblNames: ["1", "2", "3"],
            refseqPattern: "NC_0000"
        ),
        AssemblySignature(
            assembly: "GRCh37", organism: "Human", accession: "GCF_000001405.25",
            chr1Length: 249_250_621, totalSize: 3_095_693_981,
            ucscNames: ["chr1", "chr2", "chr3"], ensemblNames: ["1", "2", "3"],
            refseqPattern: "NC_0000"
        ),
        AssemblySignature(
            assembly: "T2T-CHM13v2.0", organism: "Human", accession: "GCF_009914755.1",
            chr1Length: 248_387_328, totalSize: 3_117_292_070,
            ucscNames: ["chr1", "chr2", "chr3"], ensemblNames: [],
            refseqPattern: "NC_0600"
        ),
        // Mouse
        AssemblySignature(
            assembly: "GRCm39", organism: "Mouse", accession: "GCF_000001635.27",
            chr1Length: 195_154_279, totalSize: 2_728_222_451,
            ucscNames: ["chr1", "chr2", "chr3"], ensemblNames: ["1", "2", "3"],
            refseqPattern: "NC_0000"
        ),
        AssemblySignature(
            assembly: "GRCm38", organism: "Mouse", accession: "GCF_000001635.26",
            chr1Length: 195_471_971, totalSize: 2_730_871_774,
            ucscNames: ["chr1", "chr2", "chr3"], ensemblNames: ["1", "2", "3"],
            refseqPattern: "NC_0000"
        ),
        // Rat
        AssemblySignature(
            assembly: "mRatBN7.2", organism: "Rat", accession: "GCF_015227675.2",
            chr1Length: 260_522_016, totalSize: 2_647_915_728,
            ucscNames: ["chr1", "chr2", "chr3"], ensemblNames: ["1", "2", "3"],
            refseqPattern: "NC_0510"
        ),
        // Zebrafish
        AssemblySignature(
            assembly: "GRCz11", organism: "Zebrafish", accession: "GCF_000002035.6",
            chr1Length: 59_578_282, totalSize: 1_373_471_384,
            ucscNames: ["chr1", "chr2", "chr3"], ensemblNames: ["1", "2", "3"],
            refseqPattern: "NC_0073"
        ),
        // Drosophila
        AssemblySignature(
            assembly: "dm6", organism: "Drosophila", accession: "GCF_000001215.4",
            chr1Length: 28_110_227, totalSize: 143_726_002,
            ucscNames: ["chr2L", "chr2R", "chr3L", "chr3R", "chrX"],
            ensemblNames: ["2L", "2R", "3L", "3R", "X"],
            refseqPattern: "NT_0337"
        ),
        // C. elegans
        AssemblySignature(
            assembly: "ce11", organism: "C. elegans", accession: "GCF_000002985.6",
            chr1Length: 15_072_434, totalSize: 100_286_401,
            ucscNames: ["chrI", "chrII", "chrIII", "chrIV", "chrV"],
            ensemblNames: ["I", "II", "III", "IV", "V"],
            refseqPattern: nil
        ),
        // SARS-CoV-2
        AssemblySignature(
            assembly: "SARS-CoV-2", organism: "SARS-CoV-2", accession: nil,
            chr1Length: 29_903, totalSize: 29_903,
            ucscNames: ["MN908947.3", "NC_045512.2"],
            ensemblNames: ["MN908947.3", "NC_045512.2"],
            refseqPattern: "NC_0455"
        ),
    ]

    // MARK: - Inference

    /// Infers the reference genome assembly from parsed @SQ header records.
    ///
    /// - Parameter sequences: Parsed reference sequence records from SAMParser
    /// - Returns: Inference result with assembly name, organism, and confidence
    public static func infer(from sequences: [SAMParser.ReferenceSequence]) -> Result {
        guard !sequences.isEmpty else {
            return Result(
                assembly: nil, organism: nil, accession: nil,
                namingConvention: nil, confidence: .none,
                sequenceCount: 0, totalLength: 0
            )
        }

        let totalLength = sequences.reduce(Int64(0)) { $0 + $1.length }
        let seqCount = sequences.count
        let names = Set(sequences.map(\.name))

        // Check for AS (assembly) tag in sequences — direct match
        let assemblyTags = Set(sequences.compactMap(\.assembly))
        if let tag = assemblyTags.first, !tag.isEmpty {
            let organism = knownAssemblies.first { $0.assembly == tag }?.organism
            return Result(
                assembly: tag, organism: organism, accession: nil,
                namingConvention: detectNamingConvention(names: names),
                confidence: .high, sequenceCount: seqCount, totalLength: totalLength
            )
        }

        // Detect naming convention
        let naming = detectNamingConvention(names: names)

        // Find longest sequence (likely chr1 or equivalent)
        let longest = sequences.max(by: { $0.length < $1.length })

        // Try matching against known assemblies
        var bestMatch: (sig: AssemblySignature, confidence: Confidence)?

        for sig in knownAssemblies {
            var score = 0

            // Check if chr1-equivalent length matches
            if let longest, abs(longest.length - sig.chr1Length) < 1000 {
                score += 3  // Strong length match
            }

            // Check naming pattern match
            if let firstName = sig.ucscNames.first, names.contains(firstName) {
                score += 2
            } else if let firstName = sig.ensemblNames.first, names.contains(firstName) {
                score += 2
            }

            // Check RefSeq pattern
            if let pattern = sig.refseqPattern,
               names.contains(where: { $0.hasPrefix(pattern) }) {
                score += 2
            }

            // Check total size is in the right ballpark (within 10%)
            let sizeDiff = abs(totalLength - sig.totalSize)
            if Double(sizeDiff) / Double(sig.totalSize) < 0.10 {
                score += 1
            }

            let confidence: Confidence
            if score >= 5 { confidence = .high }
            else if score >= 3 { confidence = .medium }
            else if score >= 2 { confidence = .low }
            else { continue }

            if bestMatch == nil || confidence > bestMatch!.confidence {
                bestMatch = (sig, confidence)
            }
        }

        if let match = bestMatch {
            return Result(
                assembly: match.sig.assembly,
                organism: match.sig.organism,
                accession: match.sig.accession,
                namingConvention: naming,
                confidence: match.confidence,
                sequenceCount: seqCount,
                totalLength: totalLength
            )
        }

        // No match — return what we can
        return Result(
            assembly: nil, organism: nil, accession: nil,
            namingConvention: naming, confidence: .none,
            sequenceCount: seqCount, totalLength: totalLength
        )
    }

    // MARK: - Name-Based Lookup

    /// Looks up a known assembly by matching a single chromosome name against known patterns.
    ///
    /// Checks UCSC names, Ensembl names, and RefSeq accession patterns from the
    /// built-in assembly database. Useful for VCF files where only chromosome names
    /// are available (no lengths).
    ///
    /// - Parameter name: A chromosome or sequence name (e.g., "NC_045512.2", "chr1")
    /// - Returns: Matching assembly info, or nil if no match found
    public static func lookupByChromosomeName(_ name: String) -> (assembly: String, organism: String, accession: String?)? {
        for sig in knownAssemblies {
            // Direct name match in UCSC or Ensembl name lists
            if sig.ucscNames.contains(name) || sig.ensemblNames.contains(name) {
                return (sig.assembly, sig.organism, sig.accession)
            }
            // RefSeq prefix match
            if let pattern = sig.refseqPattern, name.hasPrefix(pattern) {
                return (sig.assembly, sig.organism, sig.accession)
            }
        }
        return nil
    }

    /// Returns all known assembly signatures for cross-referencing.
    ///
    /// Each tuple contains: assembly name, organism, accession, chr1 length, total size.
    public static func knownAssemblyList() -> [(assembly: String, organism: String, accession: String?, chr1Length: Int64, totalSize: Int64)] {
        knownAssemblies.map { ($0.assembly, $0.organism, $0.accession, $0.chr1Length, $0.totalSize) }
    }

    // MARK: - Naming Convention Detection

    /// Detects the chromosome naming convention from a set of sequence names.
    public static func detectNamingConvention(names: Set<String>) -> String? {
        if names.contains("chr1") || names.contains("chrM") || names.contains("chrX") {
            return "UCSC"
        }
        if names.contains("1") || names.contains("MT") {
            return "Ensembl"
        }
        if names.contains(where: { $0.hasPrefix("NC_") }) {
            return "RefSeq"
        }
        // Roman numerals (C. elegans)
        if names.contains("I") || names.contains("chrI") {
            return names.contains("chrI") ? "UCSC" : "Ensembl"
        }
        // Drosophila arm names
        if names.contains("2L") || names.contains("chr2L") {
            return names.contains("chr2L") ? "UCSC" : "Ensembl"
        }
        return nil
    }
}

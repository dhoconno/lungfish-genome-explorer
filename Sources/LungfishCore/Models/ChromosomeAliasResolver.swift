// ChromosomeAliasResolver.swift - Unified chromosome name aliasing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

// MARK: - ChromosomeAliasResolver

/// Resolves chromosome name mismatches between different data sources.
///
/// Bioinformatics data uses inconsistent chromosome naming conventions:
/// - NCBI: `NC_000001.11`, `NC_041760.1`
/// - UCSC: `chr1`, `chr2`
/// - Ensembl: `1`, `2`
/// - VCF files: `7`, `chr7`, `NC_041760.1`
/// - BAM files: `MN908947.3`
///
/// This resolver builds a bidirectional mapping table between a reference
/// genome's chromosome names and the names used in an external data source
/// (VCF, BAM, CRAM, etc.). It applies a prioritized cascade of matching
/// strategies, from exact match down to length-based fuzzy matching.
///
/// ## Usage
///
/// ```swift
/// let resolver = ChromosomeAliasResolver.build(
///     referenceChromosomes: [("chr1", 248_956_422), ("chr2", 242_193_529)],
///     sourceChromosomes: [("1", 248_956_422), ("2", 242_193_529)]
/// )
/// resolver.resolve("1")       // "chr1"
/// resolver.reverseResolve("chr1")  // "1"
/// ```
public struct ChromosomeAliasResolver: Sendable, Equatable {

    // MARK: - Public Properties

    /// Forward mapping: source chromosome name -> reference chromosome name.
    public let sourceToReference: [String: String]

    /// Reverse mapping: reference chromosome name -> source chromosome name.
    public let referenceToSource: [String: String]

    /// The number of aliases in this resolver.
    public var count: Int { sourceToReference.count }

    /// Whether this resolver has no aliases (all names matched exactly).
    public var isEmpty: Bool { sourceToReference.isEmpty }

    // MARK: - Initialization

    /// Creates a resolver from pre-built mappings.
    ///
    /// - Parameters:
    ///   - sourceToReference: Map from source chromosome names to reference names.
    ///   - referenceToSource: Map from reference chromosome names to source names.
    public init(
        sourceToReference: [String: String],
        referenceToSource: [String: String]
    ) {
        self.sourceToReference = sourceToReference
        self.referenceToSource = referenceToSource
    }

    /// An empty resolver that performs no aliasing.
    public static let empty = ChromosomeAliasResolver(
        sourceToReference: [:],
        referenceToSource: [:]
    )

    // MARK: - Resolution

    /// Resolves a source chromosome name to the corresponding reference name.
    ///
    /// Returns the mapped reference name if an alias exists, or the original
    /// name if no alias is needed (exact match or unknown chromosome).
    ///
    /// - Parameter sourceChromosome: A chromosome name from the source data.
    /// - Returns: The corresponding reference chromosome name.
    public func resolve(_ sourceChromosome: String) -> String {
        sourceToReference[sourceChromosome] ?? sourceChromosome
    }

    /// Resolves a reference chromosome name back to the source name.
    ///
    /// Returns the mapped source name if an alias exists, or the original
    /// name if no alias is needed.
    ///
    /// - Parameter referenceChromosome: A chromosome name from the reference genome.
    /// - Returns: The corresponding source chromosome name.
    public func reverseResolve(_ referenceChromosome: String) -> String {
        referenceToSource[referenceChromosome] ?? referenceChromosome
    }

    // MARK: - Builder

    /// A descriptor for a reference chromosome used during alias resolution.
    public struct ReferenceChromosome: Sendable {
        /// The canonical chromosome name in the reference genome.
        public let name: String

        /// The sequence length in base pairs.
        public let length: Int64

        /// Known aliases for this chromosome (e.g., from assembly reports).
        public let aliases: [String]

        /// The FASTA header description text (after the first space on the `>` line).
        ///
        /// Used for description-based matching, e.g., extracting "chromosome 7"
        /// from "Macaca mulatta chromosome 7, whole genome shotgun sequence".
        public let fastaDescription: String?

        /// Creates a reference chromosome descriptor.
        public init(
            name: String,
            length: Int64,
            aliases: [String] = [],
            fastaDescription: String? = nil
        ) {
            self.name = name
            self.length = length
            self.aliases = aliases
            self.fastaDescription = fastaDescription
        }
    }

    /// A descriptor for a source chromosome used during alias resolution.
    public struct SourceChromosome: Sendable {
        /// The chromosome name as it appears in the source data.
        public let name: String

        /// The sequence length in base pairs, if known.
        ///
        /// For VCF files this comes from `##contig` headers.
        /// For BAM files this comes from `@SQ` headers or `samtools idxstats`.
        public let length: Int64?

        /// Creates a source chromosome descriptor.
        public init(name: String, length: Int64? = nil) {
            self.name = name
            self.length = length
        }
    }

    /// Configuration for length-based matching behavior.
    public struct LengthMatchingConfig: Sendable {
        /// The maximum absolute difference in base pairs for an exact-length match.
        ///
        /// Contig lengths in VCF headers sometimes differ by a few bases from
        /// the reference due to assembly patches. Default is 10 bp.
        public let exactTolerance: Int64

        /// Whether to use proportional tolerance for inexact length matching.
        ///
        /// When enabled, source chromosomes without contig header lengths can
        /// be matched using a proportional tolerance (e.g., MAX(POS) from a VCF
        /// must be within 5-20% of the reference length). Disabled by default.
        public let allowProportionalMatch: Bool

        /// Default configuration: 10 bp tolerance, no proportional matching.
        public static let `default` = LengthMatchingConfig(
            exactTolerance: 10,
            allowProportionalMatch: false
        )

        /// Strict configuration: exact length only (0 bp tolerance).
        public static let strict = LengthMatchingConfig(
            exactTolerance: 0,
            allowProportionalMatch: false
        )

        /// Relaxed configuration: 10 bp tolerance with proportional fallback.
        public static let relaxed = LengthMatchingConfig(
            exactTolerance: 10,
            allowProportionalMatch: true
        )

        /// Creates a length matching configuration.
        public init(exactTolerance: Int64, allowProportionalMatch: Bool) {
            self.exactTolerance = exactTolerance
            self.allowProportionalMatch = allowProportionalMatch
        }
    }

    // MARK: - Well-Known Synonyms

    /// Canonical mitochondrial chromosome names across naming conventions.
    ///
    /// UCSC uses "chrM", Ensembl/NCBI use "MT", some assemblies use "chrMT".
    private static let canonicalMitochondrialNames = ["M", "MT", "chrM", "chrMT"]

    /// Well-known mitochondrial chromosome name synonyms.
    ///
    /// Derived from `canonicalMitochondrialNames` plus their lowercased variants;
    /// this table enables matching across the naming conventions above.
    private static let mitochondrialSynonyms: Set<String> =
        Set(canonicalMitochondrialNames + canonicalMitochondrialNames.map { $0.lowercased() })

    /// Returns well-known synonyms for a chromosome name, if any.
    ///
    /// Currently handles mitochondrial naming conventions. Returns an empty
    /// array if the name has no well-known synonyms.
    static func wellKnownSynonyms(for name: String) -> [String] {
        if mitochondrialSynonyms.contains(name) {
            // Return all synonyms except the input itself
            return canonicalMitochondrialNames.filter { $0 != name }
        }
        return []
    }

    /// Builds a resolver by matching source chromosomes to reference chromosomes.
    ///
    /// Applies matching strategies in priority order:
    /// 1. **Exact match** -- source name equals a reference name (no alias needed)
    /// 2. **Case-insensitive match** -- e.g., "Chr1" matches "chr1"
    /// 3. **Alias match** -- source name appears in a reference chromosome's alias list
    /// 4. **Version stripping** -- "NC_000001.11" matches "NC_000001"
    /// 5. **chr prefix handling** -- "chr1" matches "1" and vice versa
    /// 6. **Well-known synonyms** -- "MT" matches "chrM" via mitochondrial synonym table
    /// 7. **Combined version + chr prefix** -- strip version then toggle chr prefix
    /// 8. **Fuzzy prefix** -- "MN908947.3" matches "MN908947" via prefix check
    /// 9. **FASTA description** -- "7" matches a reference with description containing "chromosome 7"
    /// 10. **Length-based** -- match by sequence length within configured tolerance
    ///
    /// Earlier strategies take priority. Once a source chromosome is matched,
    /// it is not reconsidered by later strategies.
    ///
    /// - Parameters:
    ///   - referenceChromosomes: The reference genome's chromosomes.
    ///   - sourceChromosomes: The external data source's chromosomes.
    ///   - lengthConfig: Configuration for length-based matching.
    /// - Returns: A resolver containing the computed alias mappings.
    public static func build(
        referenceChromosomes: [ReferenceChromosome],
        sourceChromosomes: [SourceChromosome],
        lengthConfig: LengthMatchingConfig = .default
    ) -> ChromosomeAliasResolver {
        let refNames = Set(referenceChromosomes.map(\.name))
        let sourceNameSet = Set(sourceChromosomes.map(\.name))

        // Find source chromosomes that do not exactly match any reference name.
        let unmatched = sourceChromosomes.map(\.name).filter { !refNames.contains($0) }
        if unmatched.isEmpty {
            return .empty
        }

        // Build lookup structures for the reference.
        let refByName = Dictionary(
            referenceChromosomes.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let refByLowercaseName = Dictionary(
            referenceChromosomes.map { ($0.name.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var sourceToRef: [String: String] = [:]
        var refToSource: [String: String] = [:]
        var matchedSources = Set<String>()
        var matchedRefs = Set<String>()

        // Track reference chromosomes that are "claimed" by exact source name matches.
        // These should not be available for length-based matching.
        let exactlyMatchedRefs = refNames.intersection(sourceNameSet)

        /// Records a match, ensuring no duplicate assignments.
        func record(source: String, reference: String) {
            guard matchedSources.insert(source).inserted,
                  matchedRefs.insert(reference).inserted else { return }
            sourceToRef[source] = reference
            refToSource[reference] = source
        }

        // --- Strategy 1: Case-insensitive match ---
        for sourceName in unmatched {
            guard !matchedSources.contains(sourceName) else { continue }
            let lower = sourceName.lowercased()
            if let ref = refByLowercaseName[lower], !matchedRefs.contains(ref.name) {
                record(source: sourceName, reference: ref.name)
            }
        }

        // --- Strategy 2: Alias match ---
        for sourceName in unmatched {
            guard !matchedSources.contains(sourceName) else { continue }
            for ref in referenceChromosomes where !matchedRefs.contains(ref.name) {
                if ref.aliases.contains(sourceName) {
                    record(source: sourceName, reference: ref.name)
                    break
                }
            }
        }

        // --- Strategy 3: Version stripping ---
        // "MN908947.3" -> "MN908947", then check exact, alias, and reverse
        for sourceName in unmatched {
            guard !matchedSources.contains(sourceName) else { continue }
            let stripped = ChromosomeAliasResolver.stripVersionSuffix(sourceName)
            if stripped != sourceName {
                // stripped source name matches a reference name?
                if let ref = refByName[stripped], !matchedRefs.contains(ref.name) {
                    record(source: sourceName, reference: ref.name)
                    continue
                }
                // stripped source name is in a reference's alias list?
                for ref in referenceChromosomes where !matchedRefs.contains(ref.name) {
                    if ref.aliases.contains(stripped) {
                        record(source: sourceName, reference: ref.name)
                        break
                    }
                }
            }
            // Also check: does a reference name, when stripped, match the source?
            if !matchedSources.contains(sourceName) {
                for ref in referenceChromosomes where !matchedRefs.contains(ref.name) {
                    let refStripped = ChromosomeAliasResolver.stripVersionSuffix(ref.name)
                    if refStripped != ref.name && refStripped == sourceName {
                        record(source: sourceName, reference: ref.name)
                        break
                    }
                }
            }
        }

        // --- Strategy 4: chr prefix handling ---
        // "chr1" <-> "1", "chrM" <-> "M"
        for sourceName in unmatched {
            guard !matchedSources.contains(sourceName) else { continue }
            let chrVariant = ChromosomeAliasResolver.toggleChrPrefix(sourceName)
            if let ref = refByName[chrVariant], !matchedRefs.contains(ref.name) {
                record(source: sourceName, reference: ref.name)
                continue
            }
            // Also check aliases
            for ref in referenceChromosomes where !matchedRefs.contains(ref.name) {
                if ref.aliases.contains(chrVariant) {
                    record(source: sourceName, reference: ref.name)
                    break
                }
            }
        }

        // --- Strategy 5: Well-known synonyms ---
        // Handles cases like "MT" <-> "chrM" that simple chr prefix toggling misses,
        // because toggleChrPrefix("MT") = "chrMT", not "chrM".
        for sourceName in unmatched {
            guard !matchedSources.contains(sourceName) else { continue }
            let synonyms = ChromosomeAliasResolver.wellKnownSynonyms(for: sourceName)
            for synonym in synonyms {
                if let ref = refByName[synonym], !matchedRefs.contains(ref.name) {
                    record(source: sourceName, reference: ref.name)
                    break
                }
            }
        }

        // --- Strategy 6: Combined version stripping + chr prefix ---
        for sourceName in unmatched {
            guard !matchedSources.contains(sourceName) else { continue }
            let stripped = ChromosomeAliasResolver.stripVersionSuffix(sourceName)
            guard stripped != sourceName else { continue }
            let chrVariant = ChromosomeAliasResolver.toggleChrPrefix(stripped)
            if let ref = refByName[chrVariant], !matchedRefs.contains(ref.name) {
                record(source: sourceName, reference: ref.name)
            }
        }

        // --- Strategy 7: Fuzzy prefix matching ---
        // "MN908947.3" starts with "MN908947" + "."
        for sourceName in unmatched {
            guard !matchedSources.contains(sourceName) else { continue }
            // Source is a versioned extension of a reference name?
            for ref in referenceChromosomes where !matchedRefs.contains(ref.name) {
                if sourceName.hasPrefix(ref.name + ".") {
                    record(source: sourceName, reference: ref.name)
                    break
                }
            }
            // Reference is a versioned extension of the source name?
            if !matchedSources.contains(sourceName) {
                for ref in referenceChromosomes where !matchedRefs.contains(ref.name) {
                    if ref.name.hasPrefix(sourceName + ".") {
                        record(source: sourceName, reference: ref.name)
                        break
                    }
                }
            }
        }

        // --- Strategy 8: FASTA description matching ---
        // Source "7" matches reference with description "... chromosome 7 ..."
        for sourceName in unmatched {
            guard !matchedSources.contains(sourceName) else { continue }
            let lowerSource = sourceName.lowercased()
            for ref in referenceChromosomes where !matchedRefs.contains(ref.name) {
                guard let desc = ref.fastaDescription?.lowercased() else { continue }
                let needle = "chromosome \(lowerSource)"
                if desc.contains(needle) {
                    // Ensure word boundary: needle must be at end, or followed by
                    // comma/space (not part of a longer number like "chromosome 17"
                    // matching source "1").
                    let isAtEnd = desc.hasSuffix(needle)
                    let hasTrailingBoundary = desc.contains(needle + ",")
                        || desc.contains(needle + " ")
                    if isAtEnd || hasTrailingBoundary {
                        record(source: sourceName, reference: ref.name)
                        break
                    }
                }
            }
        }

        // --- Strategy 9: Length-based matching ---
        let sourceLengths = Dictionary(
            sourceChromosomes.compactMap { chrom -> (String, Int64)? in
                guard let length = chrom.length else { return nil }
                return (chrom.name, length)
            },
            uniquingKeysWith: { first, _ in first }
        )

        if !sourceLengths.isEmpty {
            for ref in referenceChromosomes {
                guard !matchedRefs.contains(ref.name) else { continue }
                // Skip references that are already claimed by an exact source name match.
                // Those references don't need aliasing -- their source uses the same name.
                guard !exactlyMatchedRefs.contains(ref.name) else { continue }

                var bestMatch: String?
                var bestDelta: Int64 = .max

                for sourceName in unmatched where !matchedSources.contains(sourceName) {
                    guard let sourceLength = sourceLengths[sourceName] else { continue }
                    let delta = abs(ref.length - sourceLength)

                    // Exact-tolerance match (e.g., contig header lengths)
                    if delta <= lengthConfig.exactTolerance {
                        if delta < bestDelta {
                            bestDelta = delta
                            bestMatch = sourceName
                        }
                    } else if lengthConfig.allowProportionalMatch {
                        // Proportional tolerance (e.g., MAX(POS) as length proxy)
                        guard sourceLength <= ref.length else { continue }
                        let proportionalTolerance = ref.length > 1_000_000
                            ? ref.length / 20   // 5% for large chromosomes
                            : ref.length / 5    // 20% for small contigs
                        if delta < proportionalTolerance && delta < bestDelta {
                            bestDelta = delta
                            bestMatch = sourceName
                        }
                    }
                }

                if let match = bestMatch {
                    record(source: match, reference: ref.name)
                }
            }
        }

        return ChromosomeAliasResolver(
            sourceToReference: sourceToRef,
            referenceToSource: refToSource
        )
    }

    /// Convenience overload accepting simple name/length tuples.
    ///
    /// - Parameters:
    ///   - referenceChromosomes: Tuples of (name, length) for each reference chromosome.
    ///   - sourceChromosomes: Tuples of (name, length) for each source chromosome.
    ///   - lengthConfig: Configuration for length-based matching.
    /// - Returns: A resolver containing the computed alias mappings.
    public static func build(
        referenceChromosomes: [(String, Int64)],
        sourceChromosomes: [(String, Int64)],
        lengthConfig: LengthMatchingConfig = .default
    ) -> ChromosomeAliasResolver {
        build(
            referenceChromosomes: referenceChromosomes.map {
                ReferenceChromosome(name: $0.0, length: $0.1)
            },
            sourceChromosomes: sourceChromosomes.map {
                SourceChromosome(name: $0.0, length: $0.1)
            },
            lengthConfig: lengthConfig
        )
    }

    /// Convenience overload that builds from ``ChromosomeInfo`` values.
    ///
    /// This bridges directly to the existing bundle manifest model, making
    /// migration from the previous ad-hoc aliasing functions straightforward.
    ///
    /// - Parameters:
    ///   - bundleChromosomes: Reference chromosomes from a ``BundleManifest``.
    ///   - sourceChromosomes: The external data source's chromosomes.
    ///   - lengthConfig: Configuration for length-based matching.
    /// - Returns: A resolver containing the computed alias mappings.
    public static func build(
        bundleChromosomes: [ChromosomeInfo],
        sourceChromosomes: [SourceChromosome],
        lengthConfig: LengthMatchingConfig = .default
    ) -> ChromosomeAliasResolver {
        build(
            referenceChromosomes: bundleChromosomes.map {
                ReferenceChromosome(
                    name: $0.name,
                    length: $0.length,
                    aliases: $0.aliases,
                    fastaDescription: $0.fastaDescription
                )
            },
            sourceChromosomes: sourceChromosomes,
            lengthConfig: lengthConfig
        )
    }

    // MARK: - Internal Helpers

    /// Strips a trailing version suffix from an accession-style name.
    ///
    /// Examples:
    /// - `MN908947.3` -> `MN908947`
    /// - `NC_045512.2` -> `NC_045512`
    /// - `chr1` -> `chr1` (no version suffix)
    static func stripVersionSuffix(_ name: String) -> String {
        guard let dotIndex = name.lastIndex(of: ".") else { return name }
        let suffix = name[name.index(after: dotIndex)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isWholeNumber) else { return name }
        return String(name[..<dotIndex])
    }

    /// Toggles the "chr" prefix on a chromosome name.
    ///
    /// - If the name starts with "chr", removes it: `chr1` -> `1`
    /// - Otherwise, adds it: `1` -> `chr1`
    static func toggleChrPrefix(_ name: String) -> String {
        if name.hasPrefix("chr") {
            return String(name.dropFirst(3))
        } else {
            return "chr" + name
        }
    }
}

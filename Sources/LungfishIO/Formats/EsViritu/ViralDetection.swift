// ViralDetection.swift - Value types for parsed EsViritu viral metagenomics data
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Reference: https://github.com/hurwitzlab/EsViritu

import Foundation

// MARK: - ViralDetection

/// A single viral contig detection from the EsViritu pipeline.
///
/// Each row in the `detected_virus.info.tsv` output file maps to one
/// ``ViralDetection``. The file contains per-contig metrics including
/// read alignment statistics, coverage, diversity, and full NCBI taxonomy.
///
/// ## Thread Safety
///
/// `ViralDetection` is a value type conforming to `Sendable` and `Codable`.
/// It is safe to share across isolation domains.
public struct ViralDetection: Sendable, Codable, Identifiable, Hashable {

    /// Unique identity derived from the GenBank ``accession``.
    public var id: String { accession }

    /// Sample identifier from the pipeline run.
    public let sampleId: String

    /// Virus name (e.g., "Rift Valley fever virus").
    public let name: String

    /// Extended description of the contig or reference.
    public let description: String

    /// Length of the reference contig in base pairs.
    public let length: Int

    /// Genome segment label (e.g., "L", "M", "S"), or `nil` for unsegmented viruses.
    public let segment: String?

    /// GenBank accession of the reference contig.
    public let accession: String

    /// NCBI assembly accession (e.g., "GCF_000856585.1").
    public let assembly: String

    /// Total length of the parent assembly in base pairs.
    public let assemblyLength: Int

    // MARK: Taxonomy

    /// Taxonomic kingdom (e.g., "Viruses").
    public let kingdom: String?

    /// Taxonomic phylum.
    public let phylum: String?

    /// Taxonomic class. Named `tclass` because `class` is a Swift reserved word.
    public let tclass: String?

    /// Taxonomic order (e.g., "Bunyavirales").
    public let order: String?

    /// Taxonomic family (e.g., "Phenuiviridae").
    public let family: String?

    /// Taxonomic genus (e.g., "Phlebovirus").
    public let genus: String?

    /// Taxonomic species (e.g., "Rift Valley fever phlebovirus").
    public let species: String?

    /// Taxonomic subspecies or strain, if applicable.
    public let subspecies: String?

    // MARK: Metrics

    /// Reads per kilobase per million filtered reads.
    public let rpkmf: Double

    /// Number of reads mapped to this contig.
    public let readCount: Int

    /// Number of reference bases covered by at least one read.
    public let coveredBases: Int

    /// Mean read depth across the contig.
    public let meanCoverage: Double

    /// Average percent identity of mapped reads.
    public let avgReadIdentity: Double

    /// Nucleotide diversity (Pi) across the contig.
    public let pi: Double

    /// Total number of quality-filtered reads in the sample.
    public let filteredReadsInSample: Int

    /// Creates a new ``ViralDetection``.
    ///
    /// - Parameters:
    ///   - sampleId: Sample identifier.
    ///   - name: Virus name.
    ///   - description: Extended description.
    ///   - length: Contig length in bp.
    ///   - segment: Genome segment label, or `nil`.
    ///   - accession: GenBank accession.
    ///   - assembly: Assembly accession.
    ///   - assemblyLength: Assembly length in bp.
    ///   - kingdom: Taxonomic kingdom.
    ///   - phylum: Taxonomic phylum.
    ///   - tclass: Taxonomic class.
    ///   - order: Taxonomic order.
    ///   - family: Taxonomic family.
    ///   - genus: Taxonomic genus.
    ///   - species: Taxonomic species.
    ///   - subspecies: Taxonomic subspecies.
    ///   - rpkmf: Reads per kilobase per million filtered reads.
    ///   - readCount: Mapped read count.
    ///   - coveredBases: Number of covered bases.
    ///   - meanCoverage: Mean read depth.
    ///   - avgReadIdentity: Average read identity percent.
    ///   - pi: Nucleotide diversity.
    ///   - filteredReadsInSample: Total filtered reads in the sample.
    public init(
        sampleId: String,
        name: String,
        description: String,
        length: Int,
        segment: String?,
        accession: String,
        assembly: String,
        assemblyLength: Int,
        kingdom: String?,
        phylum: String?,
        tclass: String?,
        order: String?,
        family: String?,
        genus: String?,
        species: String?,
        subspecies: String?,
        rpkmf: Double,
        readCount: Int,
        coveredBases: Int,
        meanCoverage: Double,
        avgReadIdentity: Double,
        pi: Double,
        filteredReadsInSample: Int
    ) {
        self.sampleId = sampleId
        self.name = name
        self.description = description
        self.length = length
        self.segment = segment
        self.accession = accession
        self.assembly = assembly
        self.assemblyLength = assemblyLength
        self.kingdom = kingdom
        self.phylum = phylum
        self.tclass = tclass
        self.order = order
        self.family = family
        self.genus = genus
        self.species = species
        self.subspecies = subspecies
        self.rpkmf = rpkmf
        self.readCount = readCount
        self.coveredBases = coveredBases
        self.meanCoverage = meanCoverage
        self.avgReadIdentity = avgReadIdentity
        self.pi = pi
        self.filteredReadsInSample = filteredReadsInSample
    }
}

// MARK: - ViralAssembly

/// Assembly-level aggregated detection from the EsViritu pipeline.
///
/// Groups multiple ``ViralDetection`` contigs that belong to the same NCBI
/// assembly and provides aggregate metrics (total reads, mean coverage, RPKMF).
///
/// ## Thread Safety
///
/// Value type conforming to `Sendable` and `Codable`.
public struct ViralAssembly: Sendable, Codable, Identifiable, Hashable {

    /// Unique identity derived from the ``assembly`` accession.
    public var id: String { assembly }

    /// NCBI assembly accession (e.g., "GCF_000856585.1").
    public let assembly: String

    /// Total length of the assembly in base pairs.
    public let assemblyLength: Int

    /// Representative virus name.
    public let name: String

    /// Taxonomic family.
    public let family: String?

    /// Taxonomic genus.
    public let genus: String?

    /// Taxonomic species.
    public let species: String?

    /// Total mapped reads across all contigs in this assembly.
    public let totalReads: Int

    /// Reads per kilobase of the whole assembly per million filtered reads, as EsViritu's assembly summary gives it
    /// (``esVirituRPKMF(of:)``).
    public let rpkmf: Double

    /// Mean read depth over the whole assembly, the aligned bases over ``assemblyLength`` (``meanDepth(of:)``).
    public let meanCoverage: Double

    /// Average percent identity of mapped reads across the assembly.
    public let avgReadIdentity: Double

    /// Constituent contigs belonging to this assembly.
    public let contigs: [ViralDetection]

    /// Creates a new ``ViralAssembly``.
    ///
    /// - Parameters:
    ///   - assembly: Assembly accession.
    ///   - assemblyLength: Assembly length in bp.
    ///   - name: Representative virus name.
    ///   - family: Taxonomic family.
    ///   - genus: Taxonomic genus.
    ///   - species: Taxonomic species.
    ///   - totalReads: Total mapped reads.
    ///   - rpkmf: Reads per kilobase per million filtered reads.
    ///   - meanCoverage: Mean read depth.
    ///   - avgReadIdentity: Average read identity percent.
    ///   - contigs: Constituent contig detections.
    public init(
        assembly: String,
        assemblyLength: Int,
        name: String,
        family: String?,
        genus: String?,
        species: String?,
        totalReads: Int,
        rpkmf: Double,
        meanCoverage: Double,
        avgReadIdentity: Double,
        contigs: [ViralDetection]
    ) {
        self.assembly = assembly
        self.assemblyLength = assemblyLength
        self.name = name
        self.family = family
        self.genus = genus
        self.species = species
        self.totalReads = totalReads
        self.rpkmf = rpkmf
        self.meanCoverage = meanCoverage
        self.avgReadIdentity = avgReadIdentity
        self.contigs = contigs
    }

    public static func == (lhs: ViralAssembly, rhs: ViralAssembly) -> Bool {
        lhs.assembly == rhs.assembly
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(assembly)
    }
}

// MARK: - Identity in copies, exports and assembly rows

extension ViralDetection {
    /// The text a copy or an export writes for an identity fraction, the shortest text that reads back as the same
    /// number. The table's Copy Row as TSV and the delimited export both write it, so one cell never reads two ways
    /// (walk WO-2).
    public static func identityText(_ identity: Double) -> String {
        String(identity)
    }
}

extension ViralAssembly {
    /// The mean of `value` over `contigs` weighted by read count, for contigs that hold `totalReads` reads in all.
    ///
    /// Contigs that share one value weigh to that value exactly. Summing value times reads and dividing by the reads
    /// is off by one in the last digit for some read counts. It gave 0.9969929135297526 for the one value
    /// 0.9969929135297527 over 5 reads, so an assembly row of one contig copied a different number than the export
    /// writes for its contig (walk WO-2). Values that differ keep the sum and divide form.
    public static func readWeightedMean(
        of contigs: [ViralDetection],
        totalReads: Int,
        _ value: (ViralDetection) -> Double
    ) -> Double {
        guard let first = contigs.first else { return 0 }
        let shared = value(first)
        if contigs.allSatisfy({ value($0) == shared }) { return shared }
        return contigs.reduce(0.0) { $0 + value($1) * Double($1.readCount) } / Double(totalReads)
    }
}

// MARK: - A virus row measured over its whole genome

extension ViralAssembly {
    /// EsViritu's assembly RPKMF (`esv_funcs.assembly_table_maker`, the RPKMF of
    /// `*.detected_virus.assembly_summary.tsv`): the contigs' reads per kilobase of the whole assembly
    /// (Asm_length, every segment, read or not) per million filtered reads. One unsegmented contig keeps its own
    /// value. A missing length or filtered count (a damaged table) leaves one contig its own value and more 0.
    public static func esVirituRPKMF(of contigs: [ViralDetection]) -> Double {
        let length = contigs.map(\.assemblyLength).max() ?? 0
        if contigs.count == 1, contigs[0].length == length { return contigs[0].rpkmf }
        let filtered = contigs.map(\.filteredReadsInSample).max() ?? 0
        guard length > 0, filtered > 0 else { return contigs.count == 1 ? contigs[0].rpkmf : 0 }
        let reads = contigs.reduce(0) { $0 + $1.readCount }
        return Double(reads) / (Double(length) / 1000) / (Double(filtered) / 1e6)
    }

    /// Mean depth over the whole assembly: the contigs' aligned bases (mean coverage times length) over
    /// Asm_length, the denominator RPKMF and breadth use. One unsegmented contig keeps its own mean coverage,
    /// and so does one contig whose length is missing (a damaged table), since its aligned bases cannot be formed.
    public static func meanDepth(of contigs: [ViralDetection]) -> Double {
        let length = contigs.map(\.assemblyLength).max() ?? 0
        if contigs.count == 1, contigs[0].length == length || contigs[0].length == 0 { return contigs[0].meanCoverage }
        guard length > 0 else { return contigs.count == 1 ? contigs[0].meanCoverage : 0 }
        return contigs.reduce(0.0) { $0 + $1.meanCoverage * Double($1.length) } / Double(length)
    }
}

// MARK: - ViralTaxProfile

/// A taxonomic profile entry from the EsViritu `tax_profile.tsv` output.
///
/// Each row aggregates read counts at a specific taxonomic level,
/// providing RPKMF and identity metrics along with the list of assemblies
/// contributing to that taxon.
///
/// ## Thread Safety
///
/// Value type conforming to `Sendable` and `Codable`.
public struct ViralTaxProfile: Sendable, Codable, Hashable {

    /// Sample identifier.
    public let sampleId: String

    /// Total number of quality-filtered reads in the sample.
    public let filteredReadsInSample: Int

    /// Taxonomic kingdom.
    public let kingdom: String?

    /// Taxonomic phylum.
    public let phylum: String?

    /// Taxonomic class. Named `tclass` because `class` is a Swift reserved word.
    public let tclass: String?

    /// Taxonomic order.
    public let order: String?

    /// Taxonomic family.
    public let family: String?

    /// Taxonomic genus.
    public let genus: String?

    /// Taxonomic species.
    public let species: String?

    /// Taxonomic subspecies or strain.
    public let subspecies: String?

    /// Number of reads classified to this taxon.
    public let readCount: Int

    /// Reads per kilobase per million filtered reads.
    public let rpkmf: Double

    /// Average percent identity of mapped reads.
    public let avgReadIdentity: Double

    /// Comma-separated list of assembly accessions contributing to this taxon.
    public let assemblyList: String

    /// Creates a new ``ViralTaxProfile``.
    ///
    /// - Parameters:
    ///   - sampleId: Sample identifier.
    ///   - filteredReadsInSample: Total filtered reads.
    ///   - kingdom: Taxonomic kingdom.
    ///   - phylum: Taxonomic phylum.
    ///   - tclass: Taxonomic class.
    ///   - order: Taxonomic order.
    ///   - family: Taxonomic family.
    ///   - genus: Taxonomic genus.
    ///   - species: Taxonomic species.
    ///   - subspecies: Taxonomic subspecies.
    ///   - readCount: Classified read count.
    ///   - rpkmf: Reads per kilobase per million filtered reads.
    ///   - avgReadIdentity: Average read identity percent.
    ///   - assemblyList: Comma-separated assembly accessions.
    public init(
        sampleId: String,
        filteredReadsInSample: Int,
        kingdom: String?,
        phylum: String?,
        tclass: String?,
        order: String?,
        family: String?,
        genus: String?,
        species: String?,
        subspecies: String?,
        readCount: Int,
        rpkmf: Double,
        avgReadIdentity: Double,
        assemblyList: String
    ) {
        self.sampleId = sampleId
        self.filteredReadsInSample = filteredReadsInSample
        self.kingdom = kingdom
        self.phylum = phylum
        self.tclass = tclass
        self.order = order
        self.family = family
        self.genus = genus
        self.species = species
        self.subspecies = subspecies
        self.readCount = readCount
        self.rpkmf = rpkmf
        self.avgReadIdentity = avgReadIdentity
        self.assemblyList = assemblyList
    }
}

// MARK: - ViralCoverageWindow

/// A coverage window for a viral contig from the EsViritu `virus_coverage_windows.tsv`.
///
/// Each row describes the average read depth within a fixed-width window
/// along a reference contig. Used for plotting coverage depth across a genome.
///
/// ## Thread Safety
///
/// Value type conforming to `Sendable` and `Codable`.
public struct ViralCoverageWindow: Sendable, Codable, Hashable {

    /// GenBank accession of the reference contig.
    public let accession: String

    /// Zero-based window index along the contig.
    public let windowIndex: Int

    /// Start position of the window (0-based, inclusive).
    public let windowStart: Int

    /// End position of the window (0-based, exclusive).
    public let windowEnd: Int

    /// Average read depth within this window.
    public let averageCoverage: Double

    /// Creates a new ``ViralCoverageWindow``.
    ///
    /// - Parameters:
    ///   - accession: GenBank accession.
    ///   - windowIndex: Zero-based window index.
    ///   - windowStart: Window start position.
    ///   - windowEnd: Window end position.
    ///   - averageCoverage: Average read depth.
    public init(
        accession: String,
        windowIndex: Int,
        windowStart: Int,
        windowEnd: Int,
        averageCoverage: Double
    ) {
        self.accession = accession
        self.windowIndex = windowIndex
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.averageCoverage = averageCoverage
    }
}

// MARK: - EsVirituResult

/// Complete EsViritu result for a single sample.
///
/// Aggregates all parsed output files from an EsViritu pipeline run:
/// detections, assembly-level summaries, taxonomic profile, and coverage
/// windows. Also includes summary statistics and optional pipeline metadata.
///
/// ## Thread Safety
///
/// Value type conforming to `Sendable` and `Codable`.
public struct EsVirituResult: Sendable, Codable {

    /// Sample identifier.
    public let sampleId: String

    /// Per-contig viral detections from `detected_virus.info.tsv`.
    public let detections: [ViralDetection]

    /// Assembly-level aggregated detections.
    public let assemblies: [ViralAssembly]

    /// Taxonomic profile entries from `tax_profile.tsv`.
    public let taxProfile: [ViralTaxProfile]

    /// Coverage windows from `virus_coverage_windows.tsv`.
    public let coverageWindows: [ViralCoverageWindow]

    /// Total number of quality-filtered reads in the sample.
    public let totalFilteredReads: Int

    /// Number of distinct viral families detected.
    public let detectedFamilyCount: Int

    /// Number of distinct viral species detected.
    public let detectedSpeciesCount: Int

    /// Pipeline wall-clock runtime in seconds, if available.
    public let runtime: TimeInterval?

    /// EsViritu tool version string, if available.
    public let toolVersion: String?

    /// Creates a new ``EsVirituResult``.
    ///
    /// - Parameters:
    ///   - sampleId: Sample identifier.
    ///   - detections: Per-contig detections.
    ///   - assemblies: Assembly-level summaries.
    ///   - taxProfile: Taxonomic profile entries.
    ///   - coverageWindows: Coverage window data.
    ///   - totalFilteredReads: Total filtered reads.
    ///   - detectedFamilyCount: Distinct family count.
    ///   - detectedSpeciesCount: Distinct species count.
    ///   - runtime: Pipeline runtime in seconds.
    ///   - toolVersion: Tool version string.
    public init(
        sampleId: String,
        detections: [ViralDetection],
        assemblies: [ViralAssembly],
        taxProfile: [ViralTaxProfile],
        coverageWindows: [ViralCoverageWindow],
        totalFilteredReads: Int,
        detectedFamilyCount: Int,
        detectedSpeciesCount: Int,
        runtime: TimeInterval?,
        toolVersion: String?
    ) {
        self.sampleId = sampleId
        self.detections = detections
        self.assemblies = assemblies
        self.taxProfile = taxProfile
        self.coverageWindows = coverageWindows
        self.totalFilteredReads = totalFilteredReads
        self.detectedFamilyCount = detectedFamilyCount
        self.detectedSpeciesCount = detectedSpeciesCount
        self.runtime = runtime
        self.toolVersion = toolVersion
    }
}

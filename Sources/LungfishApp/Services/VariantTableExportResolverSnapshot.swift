import Foundation
import LungfishCore
import LungfishIO

struct VariantTableExportResolvedFields: Sendable, Equatable {
    let codingFeature: String
    let consequence: String
    let aaChange: String
}

enum VariantTableExportResolverPreparationError: LocalizedError {
    case sequenceReadFailed(feature: String, chromosome: String, start: Int, end: Int)
    case sequenceLengthMismatch(feature: String, expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .sequenceReadFailed(let feature, let chromosome, let start, let end):
            return "Could not read reference sequence for \(feature) at \(chromosome):\(start)-\(end)."
        case .sequenceLengthMismatch(let feature, let expected, let actual):
            return "Reference sequence for \(feature) had \(actual) bases; expected \(expected)."
        }
    }
}

/// Frozen value-only inputs for resolving derived variant-table fields off-main.
struct VariantTableExportResolverSnapshot: Sendable {
    struct CodingFeature: Sendable {
        let chromosome: String
        let intervals: [AnnotationInterval]
        let label: String
        let isReverse: Bool
        let codingBases: [Character]?
        let codingGenomePositions: [Int]?
        let phaseOffset: Int
        let codonTable: CodonTable
    }

    let features: [CodingFeature]
    let variantChromosomeAliasMap: [String: String]
    let referenceChromosomeAliases: [String: String]
    let referenceBundle: ReferenceBundle?
    let cachedSequence: String?
    let cachedSequenceRegion: GenomicRegion?

    static let empty = VariantTableExportResolverSnapshot(
        features: [], variantChromosomeAliasMap: [:], referenceChromosomeAliases: [:], referenceBundle: nil,
        cachedSequence: nil, cachedSequenceRegion: nil
    )

    init(
        features: [CodingFeature],
        variantChromosomeAliasMap: [String: String],
        referenceChromosomeAliases: [String: String] = [:],
        referenceBundle: ReferenceBundle? = nil,
        cachedSequence: String? = nil,
        cachedSequenceRegion: GenomicRegion? = nil
    ) {
        self.features = features
        self.variantChromosomeAliasMap = variantChromosomeAliasMap
        self.referenceChromosomeAliases = referenceChromosomeAliases
        self.referenceBundle = referenceBundle
        self.cachedSequence = cachedSequence
        self.cachedSequenceRegion = cachedSequenceRegion
    }

    /// Materializes missing CDS coding contexts. Call from the export worker,
    /// never from the main actor; bundle-backed sequence reads are synchronous.
    func preparingForBackgroundExport(
        shouldCancel: @Sendable () -> Bool = { false }
    ) throws -> VariantTableExportResolverSnapshot {
        var prepared: [CodingFeature] = []
        prepared.reserveCapacity(features.count)
        for feature in features {
            if shouldCancel() { throw CancellationError() }
            guard feature.codingBases == nil || feature.codingGenomePositions == nil,
                  let context = try codingContext(for: feature, shouldCancel: shouldCancel) else {
                prepared.append(feature)
                continue
            }
            prepared.append(
                CodingFeature(
                    chromosome: feature.chromosome,
                    intervals: feature.intervals,
                    label: feature.label,
                    isReverse: feature.isReverse,
                    codingBases: context.bases,
                    codingGenomePositions: context.positions,
                    phaseOffset: context.phaseOffset,
                    codonTable: feature.codonTable
                )
            )
        }
        return VariantTableExportResolverSnapshot(
            features: prepared,
            variantChromosomeAliasMap: variantChromosomeAliasMap,
            referenceChromosomeAliases: referenceChromosomeAliases,
            referenceBundle: referenceBundle,
            cachedSequence: cachedSequence,
            cachedSequenceRegion: cachedSequenceRegion
        )
    }

    func resolve(_ row: AnnotationSearchIndex.SearchResult) -> VariantTableExportResolvedFields {
        let info = row.infoDict ?? [:]
        let overlapping = overlappingFeatures(for: row)
        let derived = derivedConsequence(for: row, overlapping: overlapping)

        let codingFeature: String = {
            var labels: [String] = []
            for feature in overlapping where !labels.contains(feature.label) {
                labels.append(feature.label)
            }
            if !labels.isEmpty { return labels.joined(separator: "; ") }
            let gene = firstInfoValue(info, keys: ["CSQ_SYMBOL", "ANN_Gene_Name", "GENE", "SYMBOL"])
            let protein = firstInfoValue(info, keys: ["protein_name", "product", "protein_id", "CSQ_ENSP"])
            return [gene, protein].compactMap { $0 }.joined(separator: " • ")
        }()

        let consequence = firstInfoValue(
            info,
            keys: ["CSQ_Consequence", "ANN_Consequence", "Consequence", "consequence", "ANN_Annotation", "EFFECT", "effect"]
        ) ?? derived.consequence ?? ""
        let aaChange = firstInfoValue(
            info,
            keys: ["CSQ_HGVSp", "HGVSp", "ANN_HGVS_p", "AA_CHANGE", "CSQ_Amino_acids", "Amino_acids", "ANN_AA_pos_len"]
        ) ?? derived.aaChange ?? ""

        return VariantTableExportResolvedFields(
            codingFeature: codingFeature,
            consequence: consequence,
            aaChange: aaChange
        )
    }

    private func overlappingFeatures(
        for row: AnnotationSearchIndex.SearchResult
    ) -> [CodingFeature] {
        let chromosome = resolvedReferenceChromosome(row.chromosome)
        let end = row.start + max(1, row.ref?.count ?? 1)
        return features.filter { feature in
            feature.chromosome == chromosome
                && feature.intervals.contains { $0.start < end && $0.end > row.start }
        }
    }

    private func resolvedReferenceChromosome(_ chromosome: String) -> String {
        if let canonical = referenceChromosomeAliases[chromosome] {
            return canonical
        }
        if let reference = variantChromosomeAliasMap.first(where: { $0.value == chromosome })?.key {
            return reference
        }
        return chromosome
    }

    private func codingContext(
        for feature: CodingFeature,
        shouldCancel: @Sendable () -> Bool
    ) throws -> (bases: [Character], positions: [Int], phaseOffset: Int)? {
        let sortedIntervals = feature.intervals.sorted { $0.start < $1.start }
        var exonSequences: [(String, AnnotationInterval)] = []
        for interval in sortedIntervals {
            if shouldCancel() { throw CancellationError() }
            guard interval.start < interval.end else { return nil }
            guard let sequence = try sequence(
                chromosome: feature.chromosome, start: interval.start, end: interval.end,
                featureLabel: feature.label
            ) else { return nil }
            exonSequences.append((sequence, interval))
        }
        guard !exonSequences.isEmpty else { return nil }

        let concatenated = exonSequences.map(\.0).joined()
        let codingSequence = feature.isReverse ? Self.reverseComplement(concatenated) : concatenated
        var positions: [Int] = []
        for (sequence, interval) in exonSequences {
            positions.append(contentsOf: (0..<sequence.count).map { interval.start + $0 })
        }
        if feature.isReverse { positions.reverse() }
        let bases = Array(codingSequence.uppercased())
        guard bases.count == positions.count else { return nil }
        return (bases, positions, exonSequences.first?.1.phase ?? 0)
    }

    private func sequence(
        chromosome: String,
        start: Int,
        end: Int,
        featureLabel: String
    ) throws -> String? {
        let expectedLength = end - start
        if let cachedSequence, let cachedSequenceRegion,
           resolvedReferenceChromosome(cachedSequenceRegion.chromosome) == chromosome,
           start >= cachedSequenceRegion.start, end <= cachedSequenceRegion.end {
            let lower = start - cachedSequenceRegion.start
            let upper = end - cachedSequenceRegion.start
            guard lower >= 0, upper <= cachedSequence.count else {
                throw VariantTableExportResolverPreparationError.sequenceReadFailed(
                    feature: featureLabel, chromosome: chromosome, start: start, end: end
                )
            }
            let lowerIndex = cachedSequence.index(cachedSequence.startIndex, offsetBy: lower)
            let upperIndex = cachedSequence.index(cachedSequence.startIndex, offsetBy: upper)
            let result = String(cachedSequence[lowerIndex..<upperIndex])
            guard result.count == expectedLength else {
                throw VariantTableExportResolverPreparationError.sequenceLengthMismatch(
                    feature: featureLabel, expected: expectedLength, actual: result.count
                )
            }
            return result
        }
        guard let referenceBundle else { return nil }
        do {
            let result = try referenceBundle.fetchSequenceSync(
                region: GenomicRegion(chromosome: chromosome, start: start, end: end)
            )
            guard result.count == expectedLength else {
                throw VariantTableExportResolverPreparationError.sequenceLengthMismatch(
                    feature: featureLabel, expected: expectedLength, actual: result.count
                )
            }
            return result
        } catch let error as VariantTableExportResolverPreparationError {
            throw error
        } catch {
            throw VariantTableExportResolverPreparationError.sequenceReadFailed(
                feature: featureLabel, chromosome: chromosome, start: start, end: end
            )
        }
    }

    private func derivedConsequence(
        for row: AnnotationSearchIndex.SearchResult,
        overlapping: [CodingFeature]
    ) -> (consequence: String?, aaChange: String?) {
        guard let ref = row.ref, !ref.isEmpty,
              let rawAlt = row.alt, !rawAlt.isEmpty else { return (nil, nil) }
        let alt = rawAlt.split(separator: ",").first.map(String.init) ?? rawAlt
        guard !alt.isEmpty else { return (nil, nil) }
        let siteStart = row.start
        let siteEnd = siteStart + max(1, ref.count)
        let altChars = Array(alt.uppercased())
        var consequences: [String] = []
        var aaChanges: [String] = []

        for feature in overlapping {
            guard let codingBases = feature.codingBases,
                  let codingPositions = feature.codingGenomePositions,
                  codingBases.count == codingPositions.count,
                  let firstCodingIndex = codingPositions.firstIndex(where: {
                      $0 >= siteStart && $0 < siteEnd
                  }) else { continue }

            if ref.count != alt.count {
                let effect = abs(alt.count - ref.count) % 3 == 0
                    ? "inframe_indel" : "frameshift_variant"
                appendUnique("\(feature.label): \(effect)", to: &consequences)
                continue
            }

            guard firstCodingIndex >= feature.phaseOffset else { continue }
            let codonStart = feature.phaseOffset
                + ((firstCodingIndex - feature.phaseOffset) / 3) * 3
            guard codonStart + 2 < codingBases.count,
                  codonStart + 2 < codingPositions.count else { continue }

            let refCodonChars = Array(codingBases[codonStart...(codonStart + 2)])
            let codonPositions = Array(codingPositions[codonStart...(codonStart + 2)])
            var altCodonChars = refCodonChars
            for (offset, position) in codonPositions.enumerated() {
                let altIndex = position - siteStart
                guard altIndex >= 0, altIndex < altChars.count else { continue }
                altCodonChars[offset] = feature.isReverse
                    ? Self.complement(altChars[altIndex]) : altChars[altIndex]
            }

            let refAA = feature.codonTable.translate(String(refCodonChars).uppercased())
            let altAA = feature.codonTable.translate(String(altCodonChars).uppercased())
            let aaIndex = ((codonStart - feature.phaseOffset) / 3) + 1
            let effect: String
            if refAA == altAA { effect = "synonymous_variant" }
            else if altAA == "*" { effect = "stop_gained" }
            else if refAA == "*" { effect = "stop_lost" }
            else { effect = "missense_variant" }

            let aa = "\(refAA)\(aaIndex)\(altAA)"
            appendUnique("\(feature.label): \(effect) \(aa)", to: &consequences)
            appendUnique(overlapping.count > 1 ? "\(feature.label): \(aa)" : aa, to: &aaChanges)
        }

        return (
            consequences.isEmpty ? nil : consequences.joined(separator: "; "),
            aaChanges.isEmpty ? nil : aaChanges.joined(separator: ", ")
        )
    }

    private func firstInfoValue(_ info: [String: String], keys: [String]) -> String? {
        keys.lazy.compactMap { key -> String? in
            guard let value = info[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  ![".", "na", "n/a", "null", "none"].contains(value.lowercased()) else { return nil }
            return value
        }.first
    }

    private func appendUnique(_ value: String, to values: inout [String]) {
        if !values.contains(value) { values.append(value) }
    }

    private static func complement(_ base: Character) -> Character {
        switch Character(String(base).uppercased()) {
        case "A": return "T"
        case "T": return "A"
        case "C": return "G"
        case "G": return "C"
        default: return Character(String(base).uppercased())
        }
    }

    private static func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map(complement))
    }
}

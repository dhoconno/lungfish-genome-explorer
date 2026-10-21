import Foundation
import LungfishCore
import LungfishIO

package struct VariantTableExportResolvedFields: Sendable, Equatable {
    package let codingFeature: String
    package let consequence: String
    package let aaChange: String
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
package struct VariantTableExportResolverSnapshot: Sendable {
    package struct CodingFeature: Sendable {
        let chromosome: String
        let intervals: [AnnotationInterval]
        let label: String
        let isReverse: Bool
        let codingBases: [Character]?
        let codingGenomePositions: [Int]?
        let phaseOffset: Int
        let codonTable: CodonTable

        /// Whole codons of the full CDS before the first whole codon that was read. The first codon read is
        /// residue `codonsBeforeFirstRead + 1` of the protein.
        var codonsBeforeFirstRead: Int = 0

        package init(
            chromosome: String,
            intervals: [AnnotationInterval],
            label: String,
            isReverse: Bool,
            codingBases: [Character]?,
            codingGenomePositions: [Int]?,
            phaseOffset: Int,
            codonTable: CodonTable,
            codonsBeforeFirstRead: Int = 0
        ) {
            self.chromosome = chromosome
            self.intervals = intervals
            self.label = label
            self.isReverse = isReverse
            self.codingBases = codingBases
            self.codingGenomePositions = codingGenomePositions
            self.phaseOffset = phaseOffset
            self.codonTable = codonTable
            self.codonsBeforeFirstRead = codonsBeforeFirstRead
        }
    }

    package let features: [CodingFeature]
    let variantChromosomeAliasMap: [String: String]
    let referenceChromosomeAliases: [String: String]
    /// The bundle the viewer shows, which the drawer's bundle-wide CDS read reads (lane 13.38, BIO item 7).
    package let referenceBundle: ReferenceBundle?
    let cachedSequence: String?
    let cachedSequenceRegion: GenomicRegion?
    /// The annotation tracks of the annotations the viewer cached for its region, sorted, which the table export
    /// names as the derived columns' inputs (Phase 2.12 lane 12.39, ARCH ruling on 12.39 R1 item 4).
    package var codingFeatureTrackIDs: [String] = []
    /// The viewer's cached annotation region with those track ids, which the table export's selection file names so
    /// the leaf reads the same coding features (ARCH ruling on 12.39 R1 item 4). Nil when the viewer cached none.
    package var codingFeatureRegion: AnnotationTableFeatureRegion?

    package static let empty = VariantTableExportResolverSnapshot(
        features: [], variantChromosomeAliasMap: [:], referenceChromosomeAliases: [:], referenceBundle: nil,
        cachedSequence: nil, cachedSequenceRegion: nil
    )

    package init(
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
    package func preparingForBackgroundExport(
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
                    codonTable: feature.codonTable,
                    codonsBeforeFirstRead: context.codonsBeforeFirstRead
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

    package func resolve(_ row: AnnotationSearchResult) -> VariantTableExportResolvedFields {
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
        for row: AnnotationSearchResult
    ) -> [CodingFeature] {
        let chromosome = resolvedReferenceChromosome(row.chromosome)
        let end = row.start + max(1, row.ref?.count ?? 1)
        return features.filter { feature in
            feature.chromosome == chromosome
                && feature.intervals.contains { $0.start < end && $0.end > row.start }
        }
    }

    /// The reference's name for a variant chromosome, which `VariantTableBundleCodingFeatures` also reads by.
    package func resolvedReferenceChromosome(_ chromosome: String) -> String {
        if let canonical = referenceChromosomeAliases[chromosome] {
            return canonical
        }
        if let reference = variantChromosomeAliasMap.first(where: { $0.value == chromosome })?.key {
            return reference
        }
        return chromosome
    }

    /// Reads the segments of `feature` and finds its frame with the rule the viewer uses
    /// (`TranslationEngine.codingLayout`), so a CDS the viewer has not cached exports the consequence the screen
    /// would show. A segment comes from the cached window when it covers the segment and from the bundle otherwise.
    /// The end of the chromosome clips a range instead of failing it, so a CDS that runs past the end keeps the
    /// bases that exist and the frame that its missing 5' bases leave. A segment that is missing for any other
    /// reason gives no context, and a read that fails still ends the export.
    private func codingContext(
        for feature: CodingFeature,
        shouldCancel: @Sendable () -> Bool
    ) throws -> (bases: [Character], positions: [Int], phaseOffset: Int, codonsBeforeFirstRead: Int)? {
        guard !feature.intervals.isEmpty, feature.intervals.allSatisfy({ $0.start < $0.end }) else { return nil }
        let annotation = SequenceAnnotation(
            type: .cds,
            name: feature.label,
            chromosome: feature.chromosome,
            intervals: feature.intervals,
            strand: feature.isReverse ? .reverse : .forward
        )

        // The bases the chromosome holds inside the intervals. A layout with fewer lacks a segment it should have.
        let chromosomeLength = referenceBundle?.chromosome(named: feature.chromosome).map { Int($0.length) }
        let expectedBases = feature.intervals.reduce(0) { total, interval in
            total + max(0, min(interval.end, chromosomeLength ?? interval.end) - interval.start)
        }

        var readFailure: Error?
        let reader = ClampedSequenceProvider(
            extent: { _ in chromosomeLength.map { 0..<$0 } },
            fetch: { chromosome, start, end in
                do {
                    return try self.sequence(
                        chromosome: chromosome, start: start, end: end, featureLabel: feature.label
                    )
                } catch {
                    readFailure = readFailure ?? error
                    return nil
                }
            }
        )
        var cancelled = false
        let layout = TranslationEngine.codingLayout(
            annotation: annotation,
            segmentProvider: { start, end in
                if cancelled || readFailure != nil { return nil }
                if shouldCancel() {
                    cancelled = true
                    return nil
                }
                return reader.segment(chromosome: feature.chromosome, start: start, end: end)
            }
        )
        if cancelled { throw CancellationError() }
        if let readFailure { throw readFailure }

        guard let layout, layout.codingSequence.count == expectedBases else { return nil }
        return (
            Array(layout.codingSequence.uppercased()),
            layout.genomicPositions,
            layout.phaseOffset,
            layout.codonsBeforeFirstRead
        )
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
        for row: AnnotationSearchResult,
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
            let aaIndex = feature.codonsBeforeFirstRead + ((codonStart - feature.phaseOffset) / 3) + 1
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
}

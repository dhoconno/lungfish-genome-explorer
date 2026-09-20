import AppKit
import LungfishCore
import LungfishIO

extension SequenceViewerView {
    func invalidateVariantFormatHoverCache() {
        variantSummaryHoverCache = nil
    }

    /// One representation for variant-bar hover text and the copy action.
    func variantDetailsText(for row: AnnotationSearchIndex.SearchResult, sampleName: String? = nil) -> String {
        let row = cachedVariantAnnotations.first(where: {
            $0.qualifier("variant_track_id") == row.trackId
                && $0.qualifier("variant_row_id").flatMap(Int64.init) == row.variantRowId
                && row.variantRowId != nil
        }).flatMap { variantSearchResult(for: $0) } ?? row
        let index = viewController?.annotationSearchIndex
        let database = index?.variantDatabaseHandles.first { $0.trackId == row.trackId }?.db
        let info = row.variantRowId.flatMap { database?.infoValues(variantId: $0) } ?? row.infoDict ?? [:]
        let genotypes = row.variantRowId.flatMap { database?.genotypes(forVariantId: $0) } ?? []
        let overlaySampleFields: [String: [String: String]] = {
            guard let ref = row.ref, let alt = row.alt else { return [:] }
            let record = VariantDatabaseRecord(
                id: row.variantRowId, chromosome: row.chromosome, position: row.start, end: row.end,
                variantID: row.name, ref: ref, alt: alt, variantType: row.type,
                quality: row.quality, filter: row.filter, info: nil, sampleCount: row.sampleCount ?? 0
            )
            let overlay = index?.variantFormatOverlaySnapshot ?? VariantFormatOverlaySnapshot()
            return Dictionary(uniqueKeysWithValues: genotypes.map { genotype in
                (genotype.sampleName, overlay.sampleFields(
                    trackID: row.trackId, record: record, sample: genotype.sampleName
                ))
            })
        }()
        let trackName = index?.variantTrackName(for: row.trackId) ?? row.trackName
            ?? currentReferenceBundle?.variantTrack(id: row.trackId)?.name ?? row.trackId
        let fallback = fallbackConsequenceForTableVariant(
            chromosome: row.chromosome, position: row.start, ref: row.ref ?? "", alt: row.alt ?? ""
        )
        return Self.formatVariantDetails(row: row, trackName: trackName, info: info,
            genotypes: genotypes, sampleName: sampleName, sampleFields: overlaySampleFields,
            consequence: fallback.consequence, aaChange: fallback.aaChange,
            codingFeature: codingFeatureText(chromosome: row.chromosome, position: row.start, referenceLength: row.ref?.count ?? 1))
    }

    static func formatVariantDetails(
        row: AnnotationSearchIndex.SearchResult, trackName: String, info: [String: String],
        genotypes: [GenotypeRecord] = [], sampleName: String? = nil,
        sampleFields: [String: [String: String]] = [:],
        consequence: String? = nil, aaChange: String? = nil, codingFeature: String? = nil
    ) -> String {
        func value(_ keys: [String]) -> String? {
            keys.compactMap { info[$0] }.first { !$0.isEmpty && $0 != "." }
        }
        let effect = value(["CSQ_Consequence", "ANN_Consequence", "Consequence", "consequence", "ANN_Annotation", "EFFECT", "effect"]) ?? consequence
        let aa = value(["CSQ_HGVSp", "HGVSp", "ANN_HGVS_p", "AA_CHANGE", "CSQ_Amino_acids", "Amino_acids"]) ?? aaChange
        var lines = [
            "\(row.chromosome):\(row.start + 1)  \(row.ref ?? "?") → \(row.alt ?? "?")",
            "Track: \(trackName.isEmpty ? "Not recorded" : trackName)",
            "Track ID: \(row.trackId.isEmpty ? "Not recorded" : row.trackId)",
            "Variant type: \(row.type)",
            "Depth (INFO/DP): \(value(["DP"]) ?? "Not recorded")",
            "Allele frequency (INFO/AF): \(value(["AF"]) ?? "Not recorded")",
            "Quality: \(row.quality.flatMap { $0 >= 0 ? String($0) : nil } ?? "Not recorded")",
            "Filter: \(row.filter ?? "Not recorded")",
            "Consequence: \(effect?.isEmpty == false ? effect! : "Not available")",
            "Amino acid change: \(aa?.isEmpty == false ? aa! : "Not available")"
        ]
        if let codingFeature, !codingFeature.isEmpty { lines.insert("Gene / Protein: \(codingFeature)", at: 3) }
        if !row.name.isEmpty, row.name != "." { lines.insert("ID: \(row.name)", at: 1) }
        if let gene = value(["CSQ_SYMBOL", "ANN_Gene_Name", "GENE", "SYMBOL"]) { lines.append("Gene: \(gene)") }
        if let codons = value(["CSQ_Codons", "Codons"]) { lines.append("Codons: \(codons)") }
        for gt in genotypes where sampleName == nil || gt.sampleName == sampleName {
            var fields = AnnotationDatabase.parseAttributes(gt.rawFields ?? "")
            for (key, value) in sampleFields[gt.sampleName] ?? [:] {
                fields[key] = value
            }
            lines.append("Sample: \(gt.sampleName)")
            lines.append("  Genotype: \(gt.genotype ?? ".")")
            lines.append("  Depth (FORMAT/DP): \(gt.depth.map(String.init) ?? "Not recorded")")
            let frequency = [fields["AF"], fields["FREQ"], fields["ALT_FREQ"]]
                .compactMap { $0 }.first { !$0.isEmpty && $0 != "." }
            if let frequency, frequency != "." {
                let origin = fields["ALT_FREQ"] == frequency ? "FORMAT/ALT_FREQ" : "FORMAT"
                lines.append("  Allele frequency (\(origin)): \(frequency)")
            } else if let depths = gt.alleleDepths {
                let counts = depths.split(separator: ",").compactMap { Double($0) }
                if counts.count >= 2, counts.count == depths.split(separator: ",").count,
                   counts.allSatisfy({ $0.isFinite && $0 >= 0 }), counts.reduce(0, +) > 0 {
                    let total = counts.reduce(0, +)
                    let frequencies = counts.dropFirst().map { String(format: "%.6g", $0 / total) }.joined(separator: ", ")
                    lines.append("  Allele frequency (from AD): \(frequencies)")
                }
            }
            if let ad = gt.alleleDepths { lines.append("  Allele depths (AD): \(ad)") }
            let callerLabels: [(String, String)] = [
                ("REF_DP", "Reference depth"), ("REF_RV", "Reference reverse reads"),
                ("REF_QUAL", "Reference quality"), ("ALT_DP", "Alternate depth"),
                ("ALT_RV", "Alternate reverse reads"), ("ALT_QUAL", "Alternate quality"),
                ("MERGED_AF", "Merged frequencies"), ("MERGED_DP", "Merged depths"),
            ]
            for (key, label) in callerLabels {
                if let callerValue = fields[key], !callerValue.isEmpty, callerValue != "." {
                    lines.append("  \(label) (FORMAT/\(key)): \(callerValue)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    func variantSummaryDetails(at point: NSPoint) -> String? {
        guard sampleDisplayState.showSummaryBar,
              point.y >= variantTrackY, point.y < variantTrackY + effectiveSummaryBarHeight else { return nil }
        let annotations = variantAnnotationsAtPoint(point)
        let ids = annotations.map(\.id)
        if let cache = variantSummaryHoverCache, cache.ids == ids { return cache.text }
        let rows = annotations.compactMap { variantSearchResult(for: $0) }
        guard !rows.isEmpty else { return nil }
        let text = rows.map { variantDetailsText(for: $0) }.joined(separator: "\n\n")
        variantSummaryHoverCache = (ids, text)
        return text
    }

    @objc func copyVariantDetailsAction(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        Self.copyVariantDetails(text, to: .general)
    }

    static func copyVariantDetails(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

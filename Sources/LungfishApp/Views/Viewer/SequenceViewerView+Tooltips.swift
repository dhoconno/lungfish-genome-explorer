// SequenceViewerView+Tooltips.swift - Extracted from SequenceViewerView.swift (pure mechanical split, no behavior change)
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import LungfishCore
import LungfishIO
import UniformTypeIdentifiers
import Quartz
import PDFKit
import os.log

extension SequenceViewerView {


    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = viewerTrackingArea {
            removeTrackingArea(existing)
        }
        viewerTrackingArea = NSTrackingArea(
            rect: .zero,
            options: [.inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: [NotificationUserInfoKey.inspectorTab: "selection"]
        )
        if let area = viewerTrackingArea {
            addTrackingArea(area)
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updateTrackingAreas()
    }

    public override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    public override func mouseMoved(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // --- Gutter edge cursor ---
        if isNearGutterEdge(at: location) {
            NSCursor.resizeLeftRight.set()
            hoverTooltip.hide()
            return
        }

        // --- Sample name gutter hover tooltip ---
        if let sampleName = sampleNameAtGutterPoint(location) {
            let displayName = cachedGenotypeSampleDisplayNames[sampleName] ?? sampleName
            hoverTooltip.show(text: displayName, near: location, in: self)
            NSCursor.arrow.set()
            return
        }

        // --- Genotype cell hit-testing ---
        if let genotypeTooltip = genotypeTooltipAtPoint(location) {
            hoveredAnnotation = nil
            hoverTooltip.show(text: genotypeTooltip.tooltip, near: location, in: self)
            if let controller = viewController {
                controller.statusBar.update(
                    position: controller.statusBar.positionLabel.stringValue,
                    selection: genotypeTooltip.statusText,
                    scale: controller.referenceFrame?.scale ?? 1.0
                )
            }
            NSCursor.crosshair.set()
            return
        }
        lastHoveredGenotypeCell = nil
        lastHoveredGenotypeTooltipText = nil
        lastHoveredGenotypeStatusText = nil

        // --- Read hit-testing ---
        if let read = readAtPoint(location) {
            if hoveredRead?.id != read.id {
                hoveredRead = read
                hoveredAnnotation = nil
                let tooltip = readTooltipText(for: read)
                hoverTooltip.show(text: tooltip, near: location, in: self)

                if let controller = viewController {
                    let strandStr = read.isReverse ? "(-)" : "(+)"
                    let hoverSummary = "Read: \(read.name) \(strandStr) • MAPQ \(read.mapq) • \(read.referenceLength) bp"
                    controller.statusBar.update(
                        position: controller.statusBar.positionLabel.stringValue,
                        selection: hoverSummary,
                        scale: controller.referenceFrame?.scale ?? 1.0
                    )
                }
            }
            NSCursor.pointingHand.set()
            return
        }
        hoveredRead = nil

        // --- Coverage hit-testing (coverage tier) ---
        if let coverageHit = coverageDepthAtPoint(location) {
            hoveredAnnotation = nil
            let tooltip = "Depth\n\(coverageHit.chromosome):\(coverageHit.position + 1)\nDepth: \(coverageHit.depth)x"
            hoverTooltip.show(text: tooltip, near: location, in: self)

            if let controller = viewController {
                controller.statusBar.update(
                    position: controller.statusBar.positionLabel.stringValue,
                    selection: "Depth: \(coverageHit.depth)x at \(coverageHit.chromosome):\(coverageHit.position + 1)",
                    scale: controller.referenceFrame?.scale ?? 1.0
                )
            }
            NSCursor.crosshair.set()
            return
        }

        // --- Annotation hit-testing ---
        let annotation: SequenceAnnotation?
        if currentReferenceBundle != nil {
            annotation = bundleAnnotationAtPoint(location)
        } else {
            annotation = annotationAtPoint(location)
        }

        if let annot = annotation {
            if hoveredAnnotation?.id != annot.id {
                hoveredAnnotation = annot
                // Build tooltip with annotation details
                let strandStr: String
                switch annot.strand {
                case .forward: strandStr = "(+)"
                case .reverse: strandStr = "(-)"
                case .unknown: strandStr = ""
                }
                let size = annot.end - annot.start
                let sizeStr = size >= 1_000_000 ? String(format: "%.1f Mb", Double(size) / 1_000_000.0)
                    : size >= 1_000 ? String(format: "%.1f Kb", Double(size) / 1_000.0)
                    : "\(size) bp"
                let chromosome = annot.chromosome ?? (viewController?.referenceFrame?.chromosome ?? "unknown")
                let label = displayLabel(for: annot)
                let coords = "\(chromosome):\(annot.start.formatted())-\(annot.end.formatted())"
                var tooltip = "\(label)\n\(annot.type.rawValue) \(strandStr)\n\(coords) (\(sizeStr))"

                // Enrich tooltip with annotation note
                if let note = annot.note, !note.isEmpty {
                    tooltip += "\n\(note)"
                }

                // Enrich from qualifiers["extra"] (raw BED column 13+ data)
                if let extraStr = annot.qualifier("extra") {
                    let parsed = LungfishIO.AnnotationDatabase.parseAttributes(extraStr)
                    if let desc = parsed["description"] {
                        tooltip += "\n\(desc)"
                    }
                    if let biotype = parsed["gene_biotype"] {
                        tooltip += "\nBiotype: \(biotype)"
                    }
                }

                // Enrich from SQLite annotation database (if available)
                if let db = viewController?.annotationSearchIndex?.annotationDatabase {
                    let record = db.lookupAnnotation(name: annot.name, chromosome: chromosome, start: annot.start, end: annot.end)
                    if let attrs = record?.attributes {
                        let parsed = LungfishIO.AnnotationDatabase.parseAttributes(attrs)
                        if annot.qualifier("extra") == nil {
                            if let desc = parsed["description"] {
                                tooltip += "\n\(desc)"
                            }
                            if let biotype = parsed["gene_biotype"] {
                                tooltip += "\nBiotype: \(biotype)"
                            }
                        }
                        if let gene = parsed["gene"] {
                            tooltip += "\nGene: \(gene)"
                        }
                        if let product = parsed["product"] {
                            tooltip += "\nProduct: \(product)"
                        }
                        let dbxref = parsed["Dbxref"] ?? parsed["db_xref"]
                        if let dbxref {
                            tooltip += "\nRef: \(dbxref)"
                        }
                    }
                }

                hoverTooltip.show(text: tooltip, near: location, in: self)

                if let controller = viewController {
                    let hoverSummary = "Hover: \(label) • \(annot.type.rawValue) \(strandStr) • \(coords)"
                    controller.statusBar.update(
                        position: controller.statusBar.positionLabel.stringValue,
                        selection: hoverSummary,
                        scale: controller.referenceFrame?.scale ?? 1.0
                    )
                }
            }
            NSCursor.pointingHand.set()
        } else {
            if hoveredAnnotation != nil {
                hoveredAnnotation = nil
                hoverTooltip.hide()
                updateSelectionStatus()
            } else {
                hoverTooltip.hide()
            }
            NSCursor.arrow.set()
        }
    }

    // MARK: - Genotype Tooltip

    /// Result of genotype cell hit-testing.
    struct GenotypeTooltipResult {
        let tooltip: String
        let statusText: String
        let variantSearchResult: AnnotationSearchIndex.SearchResult?
    }

    /// Hit-tests the genotype row area and returns a tooltip if the mouse is over a genotype cell.
    func genotypeTooltipAtPoint(_ point: NSPoint) -> GenotypeTooltipResult? {
        guard showVariants,
              cachedSampleCount > 0,
              let genotypeData = filteredVisibleGenotypeData(),
              !genotypeData.sampleNames.isEmpty,
              !genotypeData.sites.isEmpty,
              let frame = viewController?.referenceFrame else { return nil }

        let genotypeTopY = variantTrackY + effectiveSummaryBarHeight + effectiveSummaryToRowGap
        guard point.y >= genotypeTopY else { return nil }

        let rowH = sampleDisplayState.rowHeight
        guard rowH > 0 else { return nil }

        // Determine which sample row the mouse is over
        let relativeY = point.y - genotypeTopY + genotypeScrollOffset
        let sampleIdx = Int(relativeY / rowH)
        guard sampleIdx >= 0, sampleIdx < genotypeData.sampleNames.count else { return nil }
        let sampleName = genotypeData.sampleNames[sampleIdx]

        // Determine which variant site the mouse is over
        var bestSiteIdx: Int?
        var sampleMatchedSiteIdx: Int?
        for (idx, site) in genotypeData.sites.enumerated() {
            let siteEnd = site.position + max(1, site.ref.count)
            let startPx = frame.screenPosition(for: Double(site.position))
            let endPx = frame.screenPosition(for: Double(siteEnd))
            let cellWidth = max(1, endPx - startPx)
            if point.x >= startPx && point.x < startPx + cellWidth {
                if site.genotypes[sampleName] != nil {
                    sampleMatchedSiteIdx = idx
                    break
                }
                bestSiteIdx = bestSiteIdx ?? idx
                continue
            }
            // For very zoomed out views where variants are sub-pixel, find closest
            if cellWidth <= 1 && abs(Double(site.position) - frame.genomicPosition(for: point.x)) < frame.scale {
                if site.genotypes[sampleName] != nil {
                    sampleMatchedSiteIdx = idx
                    break
                }
                bestSiteIdx = bestSiteIdx ?? idx
                continue
            }
        }
        if sampleMatchedSiteIdx != nil {
            bestSiteIdx = sampleMatchedSiteIdx
        }

        guard let siteIdx = bestSiteIdx else {
            lastHoveredGenotypeCell = nil
            lastHoveredGenotypeTooltipText = nil
            return nil
        }

        // Avoid recomputing tooltip if we're still on the same cell
        if let last = lastHoveredGenotypeCell, last.sampleIdx == sampleIdx, last.siteIdx == siteIdx {
            if let tooltipText = lastHoveredGenotypeTooltipText {
                return GenotypeTooltipResult(
                    tooltip: tooltipText,
                    statusText: lastHoveredGenotypeStatusText ?? "",
                    variantSearchResult: genotypeVariantSearchResult(for: genotypeData.sites[siteIdx], frame: frame)
                )
            }
        }
        lastHoveredGenotypeCell = (sampleIdx, siteIdx)

        let site = genotypeData.sites[siteIdx]

        // No tooltip for samples without data at this site
        guard let call = site.genotypes[sampleName] else {
            lastHoveredGenotypeTooltipText = nil
            lastHoveredGenotypeStatusText = nil
            return nil
        }

        // Build tooltip
        let callLabel: String
        switch call {
        case .homRef:  callLabel = "0/0 (Hom Ref)"
        case .het:     callLabel = "0/1 (Het)"
        case .homAlt:  callLabel = "1/1 (Hom Alt)"
        case .noCall:  callLabel = "./. (No Call)"
        }

        // Position display (1-based for user)
        let displayPos = site.position + 1
        let chrom = viewController?.referenceFrame?.chromosome ?? "?"
        var tooltip = "\(sampleName)\n\(callLabel)\n\(chrom):\(displayPos.formatted()) \(site.ref) \u{2192} \(site.alt) (\(site.variantType))"

        if let vid = site.variantID, !vid.isEmpty, vid != "." {
            tooltip += "\nID: \(vid)"
        }

        // Show pre-computed impact data from VariantSite (enriched during fetch)
        if let shortAA = site.shortAAChange {
            tooltip += "\nAA: \(shortAA)"
        }
        if let impact = site.impact, impact != .unknown {
            tooltip += "\nImpact: \(impact.rawValue.lowercased())"
        }
        if let gene = site.geneSymbol {
            tooltip += "\nGene: \(gene)"
        }
        if let sampleAF = site.sampleAlleleFractions[sampleName] {
            tooltip += String(format: "\nSample AF: %.3f", sampleAF)
        }
        if let aaChange = site.aminoAcidChange, site.shortAAChange == nil {
            // Only show long form if shortAAChange wasn't populated
            tooltip += "\nAA Change: \(aaChange)"
        }

        var hasExplicitConsequence = false

        // Enrich with additional CSQ/INFO fields from variant database
        if let rowId = site.databaseRowId,
           let handles = viewController?.annotationSearchIndex?.variantDatabaseHandles {
            let db = site.sourceTrackId.flatMap { trackId in
                handles.first(where: { $0.trackId == trackId })?.db
            } ?? handles.first?.db
            let infoDict = db?.infoValues(variantId: rowId) ?? [:]
            if !infoDict.isEmpty {
                // Show CSQ consequence string (more detailed than the impact classification)
                if let consequence = infoDict["CSQ_Consequence"] {
                    tooltip += "\nConsequence: \(consequence)"
                    hasExplicitConsequence = true
                }
                if let codons = infoDict["CSQ_Codons"] {
                    tooltip += "\nCodons: \(codons)"
                }
                if let af = infoDict["AF"] {
                    tooltip += "\nAF: \(af)"
                }
            }
        }

        // Fallback codon-level consequence prediction from CDS annotations when CSQ/ANN
        // annotations are missing or incomplete.
        let predictedImpacts = predictedCDSConsequences(
            for: site,
            sampleName: sampleName,
            genotypeData: genotypeData
        )
        if !predictedImpacts.isEmpty {
            if !hasExplicitConsequence {
                tooltip += "\nConsequence: \(predictedImpacts.joined(separator: "; "))"
            } else {
                tooltip += "\nCDS impact(s): \(predictedImpacts.joined(separator: "; "))"
            }
        }

        let aaStatus = site.shortAAChange.map { " \u{2022} \($0)" } ?? ""
        let statusText = "Genotype: \(sampleName) \u{2022} \(callLabel) \u{2022} \(chrom):\(displayPos.formatted()) \(site.ref)\u{2192}\(site.alt)\(aaStatus)"
        lastHoveredGenotypeTooltipText = tooltip
        lastHoveredGenotypeStatusText = statusText
        return GenotypeTooltipResult(
            tooltip: tooltip,
            statusText: statusText,
            variantSearchResult: genotypeVariantSearchResult(for: site, frame: frame)
        )
    }

    func genotypeVariantSearchResult(
        for site: VariantSite,
        frame: ReferenceFrame
    ) -> AnnotationSearchIndex.SearchResult? {
        let fallbackName = "\(frame.chromosome)_\(site.position + 1)"
        return AnnotationSearchIndex.SearchResult(
            name: site.variantID?.isEmpty == false ? site.variantID! : fallbackName,
            chromosome: frame.chromosome,
            start: site.position,
            end: site.position + max(1, site.ref.count),
            trackId: site.sourceTrackId ?? "",
            type: site.variantType,
            strand: ".",
            ref: site.ref,
            alt: site.alt,
            quality: nil,
            filter: nil,
            sampleCount: nil,
            variantRowId: site.databaseRowId
        )
    }

    /// Predicts coding consequences from overlapping CDS annotations for a site/sample.
    ///
    /// Used as a fallback when CSQ/ANN consequence fields are unavailable or incomplete.
    /// Includes same-codon compound substitutions by applying all alt-carrying calls from
    /// the current sample within the codon before translating.
    func predictedCDSConsequences(
        for site: VariantSite,
        sampleName: String,
        genotypeData: GenotypeDisplayData
    ) -> [String] {
        guard let frame = viewController?.referenceFrame else { return [] }
        let chrom = frame.chromosome
        let siteStart = site.position
        let siteEnd = site.position + max(1, site.ref.count)

        let overlappingCDS = cachedBundleAnnotations.filter { annotation in
            annotation.type == .cds
                && (annotation.chromosome ?? chrom) == chrom
                && annotation.overlaps(start: siteStart, end: siteEnd)
        }
        guard !overlappingCDS.isEmpty else { return [] }

        var rendered = Set<String>()
        var details: [String] = []

        for cds in overlappingCDS {
            guard let context = cdsCodingContext(for: cds) else { continue }
            let impactedCodingIndices = context.codingGenomePositions.enumerated().compactMap { pair -> Int? in
                let genomicPos = pair.element
                return (genomicPos >= siteStart && genomicPos < siteEnd) ? pair.offset : nil
            }
            guard let firstCodingIndex = impactedCodingIndices.first else { continue }

            // Indels are classified directly by frame-preservation.
            if site.ref.count != site.alt.count {
                let delta = site.alt.count - site.ref.count
                let effect = (abs(delta) % 3 == 0) ? "inframe_indel" : "frameshift_variant"
                let label = "\(cds.name): \(effect)"
                if rendered.insert(label).inserted {
                    details.append(label)
                }
                continue
            }

            guard firstCodingIndex >= context.phaseOffset else { continue }
            let codonStart = context.phaseOffset + ((firstCodingIndex - context.phaseOffset) / 3) * 3
            guard codonStart + 2 < context.codingBases.count,
                  codonStart + 2 < context.codingGenomePositions.count else { continue }

            let refCodonChars = Array(context.codingBases[codonStart...(codonStart + 2)])
            let codonGenomePositions = Array(context.codingGenomePositions[codonStart...(codonStart + 2)])
            var altCodonChars = refCodonChars

            for (codonOffset, genomicPos) in codonGenomePositions.enumerated() {
                guard let codonVariant = genotypeData.sites.first(where: {
                    $0.position == genomicPos &&
                    ($0.genotypes[sampleName] == .het || $0.genotypes[sampleName] == .homAlt)
                }) else { continue }
                guard codonVariant.ref.count == 1,
                      let firstAltBase = codonVariant.alt.split(separator: ",").first?.first else { continue }
                let orientedBase: Character
                if context.annotation.strand == .reverse {
                    orientedBase = complementDNA(firstAltBase)
                } else {
                    orientedBase = Character(String(firstAltBase).uppercased())
                }
                altCodonChars[codonOffset] = orientedBase
            }

            let refCodon = String(refCodonChars).uppercased()
            let altCodon = String(altCodonChars).uppercased()
            guard refCodon.count == 3, altCodon.count == 3 else { continue }

            let refAA = context.codonTable.translate(refCodon)
            let altAA = context.codonTable.translate(altCodon)
            let aminoIndex = ((codonStart - context.phaseOffset) / 3) + 1

            let effect: String
            if refAA == altAA {
                effect = "synonymous_variant"
            } else if altAA == "*" {
                effect = "stop_gained"
            } else if refAA == "*" {
                effect = "stop_lost"
            } else {
                effect = "missense_variant"
            }

            let label = "\(cds.name): \(effect) \(refAA)\(aminoIndex)\(altAA)"
            if rendered.insert(label).inserted {
                details.append(label)
            }
        }

        return details
    }

    /// Predicts variant consequence/AA-change for table rows when CSQ/ANN INFO is absent.
    ///
    /// This variant-only fallback does not require per-sample genotype context.
    func fallbackConsequenceForTableVariant(
        chromosome: String,
        position: Int,
        ref: String,
        alt: String
    ) -> (consequence: String?, aaChange: String?) {
        let refChromosome = referenceChromosomeName(forVariantDBChromosome: chromosome)
        let siteStart = position
        let siteEnd = position + max(1, ref.count)
        let firstAlt = alt.split(separator: ",").first.map(String.init) ?? alt
        guard !firstAlt.isEmpty else { return (nil, nil) }

        let overlappingCDS = cachedBundleAnnotations.filter { annotation in
            annotation.type == .cds
                && (annotation.chromosome ?? refChromosome) == refChromosome
                && annotation.overlaps(start: siteStart, end: siteEnd)
        }
        guard !overlappingCDS.isEmpty else { return (nil, nil) }

        var consequences: [String] = []
        var aaChanges: [String] = []
        var seenConsequence = Set<String>()
        var seenAA = Set<String>()

        let altChars = Array(firstAlt.uppercased())
        for cds in overlappingCDS {
            guard let context = cdsCodingContext(for: cds) else { continue }
            let impactedCodingIndices = context.codingGenomePositions.enumerated().compactMap { pair -> Int? in
                let genomicPos = pair.element
                return (genomicPos >= siteStart && genomicPos < siteEnd) ? pair.offset : nil
            }
            guard let firstCodingIndex = impactedCodingIndices.first else { continue }

            if ref.count != firstAlt.count {
                let delta = firstAlt.count - ref.count
                let effect = (abs(delta) % 3 == 0) ? "inframe_indel" : "frameshift_variant"
                let label = "\(cds.name): \(effect)"
                if seenConsequence.insert(label).inserted {
                    consequences.append(label)
                }
                continue
            }

            guard firstCodingIndex >= context.phaseOffset else { continue }
            let codonStart = context.phaseOffset + ((firstCodingIndex - context.phaseOffset) / 3) * 3
            guard codonStart + 2 < context.codingBases.count,
                  codonStart + 2 < context.codingGenomePositions.count else { continue }

            let refCodonChars = Array(context.codingBases[codonStart...(codonStart + 2)])
            let codonGenomePositions = Array(context.codingGenomePositions[codonStart...(codonStart + 2)])
            var altCodonChars = refCodonChars

            for (codonOffset, genomicPos) in codonGenomePositions.enumerated() {
                let altIndex = genomicPos - siteStart
                guard altIndex >= 0, altIndex < altChars.count else { continue }
                var replacement = altChars[altIndex]
                if context.annotation.strand == .reverse {
                    replacement = complementDNA(replacement)
                }
                altCodonChars[codonOffset] = replacement
            }

            let refCodon = String(refCodonChars).uppercased()
            let altCodon = String(altCodonChars).uppercased()
            guard refCodon.count == 3, altCodon.count == 3 else { continue }

            let refAA = context.codonTable.translate(refCodon)
            let altAA = context.codonTable.translate(altCodon)
            let aaIndex = ((codonStart - context.phaseOffset) / 3) + 1

            let effect: String
            if refAA == altAA {
                effect = "synonymous_variant"
            } else if altAA == "*" {
                effect = "stop_gained"
            } else if refAA == "*" {
                effect = "stop_lost"
            } else {
                effect = "missense_variant"
            }

            let aaChange = "\(refAA)\(aaIndex)\(altAA)"
            let consequence = "\(cds.name): \(effect) \(aaChange)"
            if seenConsequence.insert(consequence).inserted {
                consequences.append(consequence)
            }
            if seenAA.insert(aaChange).inserted {
                aaChanges.append(aaChange)
            }
        }

        let consequenceText = consequences.isEmpty ? nil : consequences.joined(separator: "; ")
        let aaText = aaChanges.isEmpty ? nil : aaChanges.joined(separator: ", ")
        return (consequenceText, aaText)
    }

    /// Returns a cached CDS coding context, building one from the local sequence cache when needed.
    func cdsCodingContext(for annotation: SequenceAnnotation) -> CDSCodingContext? {
        if let cached = cachedCDSCodingContexts[annotation.id] {
            return cached
        }
        guard annotation.type == .cds else { return nil }
        let sequenceProvider: (Int, Int) -> String? = { [weak self] start, end in
            guard let self else { return nil }
            guard start < end else { return nil }

            // Fast path: use cached sequence window if it fully covers the request.
            if let sequence = self.cachedBundleSequence, let region = self.cachedSequenceRegion,
               start >= region.start, end <= region.end {
                let offsetStart = start - region.start
                let offsetEnd = end - region.start
                guard offsetStart >= 0, offsetEnd <= sequence.count else { return nil }
                let startIdx = sequence.index(sequence.startIndex, offsetBy: offsetStart)
                let endIdx = sequence.index(sequence.startIndex, offsetBy: offsetEnd)
                return String(sequence[startIdx..<endIdx])
            }

            // Fallback path: pull the exact interval directly from bundle-backed FASTA.
            guard let bundle = self.currentReferenceBundle,
                  let frame = self.viewController?.referenceFrame else { return nil }
            let fetchRegion = GenomicRegion(chromosome: frame.chromosome, start: start, end: end)
            return try? bundle.fetchSequenceSync(region: fetchRegion)
        }

        let sortedIntervals = annotation.intervals.sorted { $0.start < $1.start }
        var exonSequences: [(sequence: String, interval: AnnotationInterval)] = []
        for interval in sortedIntervals {
            guard let seq = sequenceProvider(interval.start, interval.end), !seq.isEmpty else { continue }
            exonSequences.append((seq, interval))
        }
        guard !exonSequences.isEmpty else { return nil }

        let concatenated = exonSequences.map(\.sequence).joined()
        let codingSequence: String
        if annotation.strand == .reverse {
            codingSequence = reverseComplementString(concatenated)
        } else {
            codingSequence = concatenated
        }

        var codingPositions: [Int] = []
        codingPositions.reserveCapacity(codingSequence.count)
        for (seq, interval) in exonSequences {
            for idx in 0..<seq.count {
                codingPositions.append(interval.start + idx)
            }
        }
        if annotation.strand == .reverse {
            codingPositions.reverse()
        }

        let codingBases = Array(codingSequence.uppercased())
        guard codingBases.count == codingPositions.count else { return nil }

        let context = CDSCodingContext(
            annotation: annotation,
            codingBases: codingBases,
            codingGenomePositions: codingPositions,
            phaseOffset: exonSequences.first?.interval.phase ?? 0,
            codonTable: .standard
        )
        cachedCDSCodingContexts[annotation.id] = context
        return context
    }

    /// DNA complement for a nucleotide base.
    func complementDNA(_ base: Character) -> Character {
        switch Character(String(base).uppercased()) {
        case "A": return "T"
        case "T": return "A"
        case "C": return "G"
        case "G": return "C"
        default: return Character(String(base).uppercased())
        }
    }

    public override func mouseExited(with event: NSEvent) {
        hoveredAnnotation = nil
        lastHoveredGenotypeCell = nil
        lastHoveredGenotypeTooltipText = nil
        lastHoveredGenotypeStatusText = nil
        hoverTooltip.hide()
        NSCursor.arrow.set()
        updateSelectionStatus()
    }

    /// Hit-tests cached bundle annotations at the given point.
    ///
    /// Uses the same coordinate system as `drawBundleAnnotations` — screen positions
    /// computed via `frame.screenPosition(for:)` and pixel-based row packing.
    func bundleAnnotationAtPoint(_ point: NSPoint) -> SequenceAnnotation? {
        guard let frame = viewController?.referenceFrame else { return nil }
        let scale = frame.scale
        guard point.y >= annotationTrackY else { return nil }

        // Don't hit-test annotations in the variant track area below them
        if showVariants && point.y >= variantTrackY { return nil }

        // Only hit-test in squished and expanded modes (not density histogram)
        guard scale <= annotationDensityThreshold else { return nil }

        // Use the same annotation pool rendered in drawBundleContent (variants are separate track).
        let bundlePool = cachedBundleAnnotations

        // Match visible region filtering used by render path.
        let visibleStart = Int(frame.start)
        let visibleEnd = Int(frame.end)
        let visibleAnnotations = bundlePool.filter { annot in
            annot.end > visibleStart && annot.start < visibleEnd
        }

        // Match inspector type/text filters used by rendering.
        let typeFiltered: [SequenceAnnotation]
        if let typeFilter = visibleAnnotationTypes {
            typeFiltered = visibleAnnotations.filter { typeFilter.contains($0.type) }
        } else {
            typeFiltered = visibleAnnotations
        }

        let textFiltered: [SequenceAnnotation]
        if annotationFilterText.isEmpty {
            textFiltered = typeFiltered
        } else {
            let needle = annotationFilterText.lowercased()
            textFiltered = typeFiltered.filter { annot in
                annot.name.lowercased().contains(needle)
            }
        }

        let trackFiltered: [SequenceAnnotation]
        if annotationTrackDisplayState.hiddenTrackIDs.isEmpty {
            trackFiltered = textFiltered
        } else {
            trackFiltered = textFiltered.filter { annotation in
                !annotationTrackDisplayState.hiddenTrackIDs.contains(annotationTrackID(for: annotation))
            }
        }

        let visibleSpan = max(1, visibleEnd - visibleStart)
        let regionThresholdSpan = max(visibleSpan, frame.sequenceLength)
        let displayAnnotations: [SequenceAnnotation]
        if scale > annotationDensityThreshold {
            displayAnnotations = trackFiltered.filter { annot in
                let span = annot.end - annot.start
                return annot.type != .region || span < Int(Double(regionThresholdSpan) * 0.98)
            }
        } else {
            displayAnnotations = trackFiltered.filter { annot in
                let span = annot.end - annot.start
                return annot.type != .region || span < Int(Double(regionThresholdSpan) * 0.98)
            }
        }

        // Use the same layered packing used by rendering.
        let (rows, _) = packAnnotationsLayered(displayAnnotations, frame: frame)

        let rowHeight: CGFloat = scale > annotationSquishedThreshold ? 7 : (annotationHeight + annotationRowSpacing)

        for (rowIndex, row) in rows.enumerated() {
            let rowY = annotationTrackY + CGFloat(rowIndex) * rowHeight

            for annot in row {
                let startX = frame.screenPosition(for: Double(annot.start))
                let endX = frame.screenPosition(for: Double(annot.end))
                let width = max(scale > annotationSquishedThreshold ? 1 : 3, endX - startX)
                let height: CGFloat = scale > annotationSquishedThreshold ? 6 : annotationHeight
                let annotRect = CGRect(x: startX, y: rowY, width: width, height: height)

                if annotRect.contains(point) {
                    return annot
                }
            }
        }

        return nil
    }

    /// Hit-tests a variant glyph in the variant summary/rows area.
    /// Returns the closest visible variant within a small horizontal tolerance.
    func variantAtPoint(_ point: NSPoint) -> SequenceAnnotation? {
        guard showVariants,
              let frame = viewController?.referenceFrame,
              !filteredVisibleVariantAnnotations.isEmpty else { return nil }

        let hitTop = variantTrackY
        let hitBottom = max(
            variantTrackY + max(effectiveSummaryBarHeight, sampleDisplayState.rowHeight),
            variantTrackY + effectiveSummaryBarHeight + effectiveSummaryToRowGap + sampleDisplayState.rowHeight
        )
        guard point.y >= hitTop, point.y <= hitBottom else { return nil }

        let tolerance: CGFloat = 6
        var best: (annotation: SequenceAnnotation, distance: CGFloat)?
        for annotation in filteredVisibleVariantAnnotations {
            let startX = frame.screenPosition(for: Double(annotation.start))
            let endX = frame.screenPosition(for: Double(max(annotation.start + 1, annotation.end)))
            let minX = min(startX, endX)
            let maxX = max(startX, endX)
            let dx: CGFloat
            if point.x < minX {
                dx = minX - point.x
            } else if point.x > maxX {
                dx = point.x - maxX
            } else {
                dx = 0
            }
            guard dx <= tolerance else { continue }
            if best == nil || dx < best!.distance {
                best = (annotation, dx)
            }
        }
        return best?.annotation
    }

    // MARK: - Read Hit-Testing

    /// Returns the aligned read at the given point, if any, using the cached packed layout.
    ///
    /// Hit-tests against the packed read rows from the most recent draw pass.
    /// Returns nil in coverage tier (individual reads not visible).
    func readAtPoint(_ point: NSPoint) -> AlignedRead? {
        guard !cachedPackedReads.isEmpty,
              let frame = viewController?.referenceFrame else { return nil }

        let tier = lastRenderedReadTier
        guard tier != .coverage else { return nil }

        let metrics = ReadTrackRenderer.layoutMetrics(verticalCompress: verticallyCompressContigSetting)
        let rowHeight: CGFloat
        switch tier {
        case .coverage: return nil
        case .packed: rowHeight = metrics.packedReadHeight + metrics.rowGap
        case .base: rowHeight = metrics.baseReadHeight + metrics.rowGap
        }

        let rY = lastRenderedReadY

        // Check if point is in the visible read track area
        let availableHeight = bounds.height - rY
        let visibleHeight = min(readContentHeight, max(availableHeight, maxReadTrackHeight))
        guard point.y >= rY && point.y < rY + visibleHeight else { return nil }

        // Account for scroll offset: convert screen Y to content Y
        let contentY = (point.y - rY) + readScrollOffset
        let rowIndex = Int(contentY / rowHeight)

        // Find reads in this row and check horizontal position
        for (row, read) in cachedPackedReads where row == rowIndex {
            let startPx = frame.genomicToPixel(Double(read.position))
            let endPx = frame.genomicToPixel(Double(read.alignmentEnd))
            let readWidth = max(ReadTrackRenderer.minReadPixels, endPx - startPx)

            if point.x >= startPx && point.x <= startPx + readWidth {
                return read
            }
        }

        return nil
    }

    /// Builds a tooltip string for an aligned read.
    func readTooltipText(for read: AlignedRead) -> String {
        let strandStr = read.isReverse ? "(-)" : "(+)"
        let cigarStr = read.cigarString
        let mapqStr = "MAPQ: \(read.mapq)"
        let posStr = "\(read.chromosome):\(read.position + 1)-\(read.alignmentEnd)"
        let lenStr = "\(read.referenceLength) bp"

        var lines = [
            read.name,
            "\(strandStr) \(posStr) (\(lenStr))",
            "\(mapqStr) • CIGAR: \(cigarStr.prefix(40))\(cigarStr.count > 40 ? "..." : "")",
        ]

        if read.isPaired {
            let pairStatus = read.isProperPair ? "Proper pair" : "Improper pair"
            let mateStr: String
            if let mateChr = read.mateChromosome, let matePos = read.matePosition {
                mateStr = "\(mateChr):\(matePos + 1)"
            } else {
                mateStr = "unmapped"
            }
            lines.append("\(pairStatus) • Mate: \(mateStr)")
            if read.insertSize != 0 {
                lines.append("Insert size: \(read.insertSize)")
            }
        }

        if let rg = read.readGroup {
            lines.append("Read group: \(rg)")
        }

        if read.isSecondary { lines.append("Secondary alignment") }
        if read.isSupplementary { lines.append("Supplementary alignment") }
        if read.isDuplicate { lines.append("PCR/optical duplicate") }

        return lines.joined(separator: "\n")
    }

    /// Returns coverage depth at a point for coverage-tier hover interactions.
    func coverageDepthAtPoint(_ point: NSPoint) -> (chromosome: String, position: Int, depth: Int)? {
        guard let frame = viewController?.referenceFrame else { return nil }
        guard !cachedDepthPoints.isEmpty else { return nil }

        let rY = lastRenderedCoverageY
        let h = coverageStripHeight
        guard point.y >= rY, point.y <= rY + h else { return nil }

        let pos = Int(frame.genomicPosition(for: point.x))
        let depth = ReadTrackRenderer.depthAt(position: pos, in: cachedDepthPoints)
        return (frame.chromosome, pos, depth)
    }
}

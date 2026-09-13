import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

/// Captures scientific authority once. No workbook participates in this operation.
public enum GenotypeExcelSnapshotBuilder {
    public static let filteredEvidenceRowPolicy = "positive-displayed-count-in-visible-samples"

    private struct CaptureContext: Codable {
        let authority: CapturedAuthority
        let filter: GenotypeMatrixBaseProjection.Filter
        let filteredEvidenceRowPolicy: String
    }

    /// Rebuild from retained scientific inputs, never from the matrices being
    /// validated or from source files that may have changed since capture.
    public static func validate(_ snapshot: GenotypeWorkbookPresentation.Snapshot) throws {
        guard let inputs = snapshot.capturedScientificInputs,
              let resultData = inputs["result.json"], let sidecarData = inputs["annotations.json"],
              let contextData = inputs["capture-context.json"] else {
            throw CaptureError.incoherent("retained scientific inputs are required")
        }
        for (name, data) in inputs where snapshot.sourceRevision[name] != digest(data) {
            throw CaptureError.incoherent("retained input witness changed: \(name)")
        }
        let decoder = JSONDecoder()
        let context = try decoder.decode(CaptureContext.self, from: contextData)
        guard context.filteredEvidenceRowPolicy == filteredEvidenceRowPolicy else {
            throw CaptureError.incoherent("unsupported filtered evidence row policy")
        }
        let expected = try capture(result: decoder.decode(ONTGenotypeResultBundleData.self, from: resultData),
            sidecar: decoder.decode(GenotypeAnnotationSidecar.self, from: sidecarData),
            allProjection: inputs["all-projection.json"].map { try decoder.decode(GenotypeViewProjection.self, from: $0) },
            filteredProjection: inputs["filtered-projection.json"].map { try decoder.decode(GenotypeViewProjection.self, from: $0) },
            generatedAt: snapshot.generatedAt, authority: context.authority, filter: context.filter)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(snapshot) == encoder.encode(expected) else {
            throw CaptureError.incoherent("rendered snapshot does not match its retained scientific capture")
        }
    }
    public enum CaptureError: Error, LocalizedError {
        case incoherent(String)
        public var errorDescription: String? {
            switch self { case .incoherent(let message): return "Incoherent Excel capture: " + message }
        }
    }

    public struct CapturedAuthority: Codable, Sendable {
        public let analysis: GenotypeHaplotypeAnalysis?
        public let definitionSet: GenotypeHaplotypeDefinitionSet?
        public let locusDisplayOrder: [String]?
        public let colors: [GenotypeWorkbookPresentation.Color]
        public init(analysis: GenotypeHaplotypeAnalysis?, definitionSet: GenotypeHaplotypeDefinitionSet? = nil,
                    locusDisplayOrder: [String]? = nil, colors: [GenotypeWorkbookPresentation.Color] = []) {
            self.analysis = analysis; self.definitionSet = definitionSet
            self.locusDisplayOrder = locusDisplayOrder; self.colors = colors
        }
    }

    public static func capture(result: ONTGenotypeResultBundleData, sidecar: GenotypeAnnotationSidecar,
                               allProjection: GenotypeViewProjection?, filteredProjection: GenotypeViewProjection?,
                               generatedAt: String) throws -> GenotypeWorkbookPresentation.Snapshot {
        // Resolve mutable definitions/order only at capture; compare a second
        // read so a concurrent definition publication cannot mix values.
        let definition = GenotypeHaplotypeAnalysisResolver.activeDefinitionSet(for: result, sidecar: sidecar)
        let analysis = GenotypeHaplotypeAnalysisResolver.activeAnalysis(for: result, sidecar: sidecar, definitionSet: definition)
        let order = sidecar.settings.genotypeLocusDisplayOrder ?? result.genotypeLocusDisplayOrder
        guard definition == GenotypeHaplotypeAnalysisResolver.activeDefinitionSet(for: result, sidecar: sidecar),
              order == (sidecar.settings.genotypeLocusDisplayOrder ?? result.genotypeLocusDisplayOrder) else {
            throw CaptureError.incoherent("definition or ordering changed during capture")
        }
        return try capture(result: result, sidecar: sidecar, allProjection: allProjection,
            filteredProjection: filteredProjection, generatedAt: generatedAt,
            authority: .init(analysis: analysis, definitionSet: definition, locusDisplayOrder: order))
    }

    public static func capture(result: ONTGenotypeResultBundleData, sidecar: GenotypeAnnotationSidecar,
                               allProjection: GenotypeViewProjection?, filteredProjection: GenotypeViewProjection?,
                               generatedAt: String, authority: CapturedAuthority,
                               filter: GenotypeMatrixBaseProjection.Filter = .unfiltered) throws -> GenotypeWorkbookPresentation.Snapshot {
        typealias P = GenotypeWorkbookPresentation
        typealias T = GenotypeAnnotationSidecar.MatrixTarget
        if let analysis = authority.analysis, let definition = authority.definitionSet,
           analysis.definitionSetID != definition.id || analysis.assayID != definition.assayID {
            throw CaptureError.incoherent("analysis and frozen definition identity disagree")
        }
        _ = try result.reviewableRowCatalog?.validated()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var captured = ["result.json": try encoder.encode(result), "annotations.json": try encoder.encode(sidecar)]
        captured["capture-context.json"] = try encoder.encode(CaptureContext(authority: authority, filter: filter, filteredEvidenceRowPolicy: filteredEvidenceRowPolicy))
        if let analysis = authority.analysis { captured["analysis.json"] = try encoder.encode(analysis) }
        if let definition = authority.definitionSet { captured["definition.json"] = try encoder.encode(definition) }
        if let allProjection { captured["all-projection.json"] = try encoder.encode(allProjection) }
        if let filteredProjection { captured["filtered-projection.json"] = try encoder.encode(filteredProjection) }
        let sampleNames = unique(result.samples.map(\.sample) + result.calls.map(\.sample)
            + (result.reviewableRowCatalog?.samples ?? []) + (result.mhcCandidates?.observations.map(\.sampleID) ?? [])
            + (result.mhcUnnameableClusters?.observations.map(\.sampleID) ?? [])
            + (authority.analysis?.samples.map(\.sample) ?? []))
        let base = GenotypeMatrixBaseProjection(calls: result.calls, samples: result.samples,
            candidateDocument: result.mhcCandidates, unnameableDocument: result.mhcUnnameableClusters,
            logicalSampleNames: sampleNames, candidateSettings: .default,
            usesBiologicalAlleleOrder: authority.locusDisplayOrder != nil,
            locusDisplayOrder: authority.locusDisplayOrder)
        let allRows = base.derive(.unfiltered).rows
        let filteredRows = base.derive(filter).rows
        var raw = GenotypeMatrixReviewEligibility.rawSupport(in: result)
        var evidenceRows: [(locus: String, genotype: String, stable: String?, label: String)] =
            allRows.map { row in
                // Match native known-reference display semantics. This affects
                // fallback labels only, never raw identity or captured viewport labels.
                let label: String
                if row.population == .known,
                   let field = result.referenceMetadata?.alleleFieldKey,
                   let value = result.referenceMetadata?.recordsBySequenceName[row.genotype]?[field],
                   !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    label = value
                } else {
                    label = row.alleleName
                }
                return (row.locus, row.genotype, row.stableClusterID, label)
            }
        // Catalog call IDs are transport identities; annotations and the native
        // projection use the displayed candidate identity. Map explicitly.
        for row in result.reviewableRowCatalog?.rows ?? [] {
            let matches = evidenceRows.indices.filter {
                let native = evidenceRows[$0]
                return GenotypeHaplotypeLocusResolver.canonicalLocusName(native.locus) == row.locus && native.stable == row.stableID
                    && (native.genotype == row.callID || native.genotype == row.displayName
                        || MHCReferenceGenotypeDisplay.alleleName(for: native.genotype) == row.displayName)
            }
            guard matches.count <= 1 else { throw CaptureError.incoherent("ambiguous catalog to native row identity") }
            let existing = matches.first
            let genotype = existing.map { evidenceRows[$0].genotype } ?? row.displayName
            let nativeLocus = existing.map { evidenceRows[$0].locus } ?? row.locus
            if existing == nil { evidenceRows.append((row.locus, genotype, row.stableID, row.displayName)) }
            for (sample, reads) in row.supportBySample {
                let target = T.cell(locus: nativeLocus, genotype: genotype, sample: sample, stableClusterID: row.stableID)
                if let observed = raw[target], observed != reads {
                    throw CaptureError.incoherent("catalog support disagrees with captured observations")
                }
                raw[target] = reads
            }
        }
        guard raw.values.allSatisfy({ $0 >= 0 }) else { throw CaptureError.incoherent("negative support") }
        let reviews = GenotypeMatrixReviewEligibility.eligibleReviews(sidecar.matrixReviews, rawSupport: { raw[$0] })
        let comments = sidecar.resolvedMatrixComments
        let styles = Dictionary(sidecar.matrixStyles.map { ($0.target, $0.style) }, uniquingKeysWith: { _, last in last })
        let callCapture = try calls(result: result, sidecar: sidecar, authority: authority, samples: sampleNames)
        let loci = unique(callCapture.calls.map(\.locus))
        let rowKey: (String, String, String?) -> String = { locus, genotype, stable in
            // JSON tuple encoding prevents delimiter collisions.
            String(data: try! encoder.encode([locus, genotype, stable ?? ""]), encoding: .utf8)!
        }
        let evidence = Dictionary(evidenceRows.map { (rowKey($0.locus, $0.genotype, $0.stable), $0) }, uniquingKeysWith: { first, _ in first })
        let allNativeValues = Dictionary(allRows.map { (rowKey($0.locus, $0.genotype, $0.stableClusterID), $0) }, uniquingKeysWith: { first, _ in first })
        let nativeValues = Dictionary(filteredRows.map { (rowKey($0.locus, $0.genotype, $0.stableClusterID), $0) }, uniquingKeysWith: { first, _ in first })
        let lookupByName = Dictionary(grouping: evidenceRows, by: { rowKey("", $0.genotype, $0.stable) })

        func catalogCandidatePassesSupplementalPercent(
            locus: String,
            genotype: String,
            stableClusterID: String
        ) -> Bool {
            let positiveSamples = Set(sampleNames.filter { sample in
                (raw[.cell(
                    locus: locus,
                    genotype: genotype,
                    sample: sample,
                    stableClusterID: stableClusterID
                )] ?? 0) > 0
            })
            let fraction = GenotypeMatrixBaseProjection.candidatePopulationFraction(
                supportingSamples: positiveSamples,
                logicalSamples: Set(sampleNames)
            ) ?? 0
            return fraction >= filter.globalMinimumPercent / 100
                && fraction >= filter.matrixMinimumPercent / 100
        }

        func matrix(_ projection: GenotypeViewProjection?, full: Bool) throws -> P.Matrix {
            let bandLoci = full ? loci : (projection?.haplotypeLocusScope ?? loci)
            guard Set(bandLoci).count == bandLoci.count, Set(bandLoci).isSubset(of: Set(loci)) else {
                throw CaptureError.incoherent("haplotype locus scope")
            }
            let names = projection?.sampleColumns ?? sampleNames
            guard Set(names).count == names.count, Set(names).isSubset(of: Set(sampleNames)),
                  !full || Set(names) == Set(sampleNames) else { throw CaptureError.incoherent("sample scope") }
            if let revision = projection?.sourceRevision {
                guard revision.assayID == authority.analysis?.assayID,
                      revision.definitionSetID == authority.analysis?.definitionSetID,
                      revision.analysisRevisionID == authority.analysis?.analysisRevisionID else {
                    throw CaptureError.incoherent("projection analysis revision")
                }
            }
            var projectedCallKeys = Set<String>()
            for projected in projection?.haplotypeCalls ?? [] {
                guard names.contains(projected.sample), projectedCallKeys.insert(projected.sample + "\u{0}" + projected.locus).inserted,
                      let actual = callCapture.calls.first(where: { $0.sampleID == projected.sample && $0.locus == projected.locus }),
                      projected.haplotype1 == actual.h1.effective, projected.haplotype2 == actual.h2.effective,
                      projected.haplotype1Status == actual.h1.status, projected.haplotype2Status == actual.h2.status,
                      projected.haplotype1Source == actual.h1.source, projected.haplotype2Source == actual.h2.source,
                      projected.baselineHaplotype1 == (actual.h1.pipeline ?? ""), projected.baselineHaplotype2 == (actual.h2.pipeline ?? "") else {
                    throw CaptureError.incoherent("projection calls disagree with full native authority")
                }
            }
            let requested: [GenotypeViewProjectionRow]
            if let projection { requested = projection.rows }
            else {
                requested = try evidenceRows.compactMap { row in
                    let key = rowKey(row.locus, row.genotype, row.stable)
                    let native = nativeValues[key]
                    let hasCatalogOnlyEvidence = allNativeValues[key] == nil
                    if !full && native == nil && !hasCatalogOnlyEvidence { return nil }
                    var passesSupplementalPercent = true
                    if !full && hasCatalogOnlyEvidence && (filter.globalMinimumPercent > 0 || filter.matrixMinimumPercent > 0) {
                        if let stableClusterID = row.stable {
                            passesSupplementalPercent = catalogCandidatePassesSupplementalPercent(
                                locus: row.locus,
                                genotype: row.genotype,
                                stableClusterID: stableClusterID
                            )
                        } else {
                            let positiveSamples = Set(sampleNames.filter { sample in
                                (raw[.cell(locus: row.locus, genotype: row.genotype, sample: sample, stableClusterID: nil)] ?? 0) > 0
                            })
                            guard positiveSamples.isEmpty else {
                                throw CaptureError.incoherent("positive catalog-only reference evidence lacks native per-occurrence percent denominators")
                            }
                            passesSupplementalPercent = false
                        }
                    }
                    let cells = names.map { sample in
                            let target = T.cell(locus: row.locus, genotype: row.genotype, sample: sample, stableClusterID: row.stable)
                            if full { return (allNativeValues[rowKey(row.locus, row.genotype, row.stable)]?.support(for: sample)?.passedUniqueReads ?? raw[target]).map(String.init) ?? "" }
                            if hasCatalogOnlyEvidence { return passesSupplementalPercent ? (raw[target].flatMap { $0 >= filter.matrixMinimumReads ? String($0) : nil } ?? "") : "" }
                            return native?.support(for: sample).map { String($0.passedUniqueReads) }
                                ?? (filter == .unfiltered ? raw[target].map(String.init) : nil) ?? ""
                    }
                    return .init(label: row.label, rawGenotype: row.genotype, locus: row.locus, stableClusterID: row.stable, cells: cells)
                }
            }
            var seen = Set<String>()
            let rows = try requested.map { row -> P.Row in
                let genotype = row.rawGenotype ?? row.label
                let matching = (lookupByName[rowKey("", genotype, row.stableClusterID)] ?? []).filter { row.locus == nil || $0.locus == row.locus }
                guard matching.count == 1, let scientific = matching.first, row.cells.count == names.count else {
                    throw CaptureError.incoherent("unknown or ambiguous projected row: \(row.label)")
                }
                let key = rowKey(scientific.locus, scientific.genotype, scientific.stable)
                guard seen.insert(key).inserted else { throw CaptureError.incoherent("duplicate projected row") }
                let target = T.row(locus: scientific.locus, genotype: scientific.genotype, stableClusterID: scientific.stable)
                let rowStyle = row.rowStyle ?? GenotypeMatrixStyleResolver.resolve([.init(fillColor: row.rowColorHex)],
                    initial: resolvedStyle(target, styles: styles))
                let cells = try names.enumerated().map { index, sample -> P.Cell in
                    let cellTarget = T.cell(locus: scientific.locus, genotype: scientific.genotype, sample: sample, stableClusterID: scientific.stable)
                    let support = raw[cellTarget]
                    let text = row.cells[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    let projectedValue: Int?
                    if text.isEmpty || text == "-" { projectedValue = nil }
                    else { guard let number = Int(text), number >= 0 else { throw CaptureError.incoherent("nonnumeric evidence") }; projectedValue = number }
                    let occurrences = allNativeValues[key]?.sampleSupport.filter { $0.sample == sample }.map(\.passedUniqueReads) ?? []
                    let allValue = occurrences.first ?? support
                    guard projectedValue == nil || projectedValue == support
                            || projectedValue.map(occurrences.contains) == true,
                          !full || projectedValue == allValue else {
                        throw CaptureError.incoherent(
                            "projected value does not match authoritative evidence"
                        )
                    }
                    let value: Int?
                    if !full, projection != nil, filter.hasActiveNumericThresholds,
                       let projectedValue, projectedValue > 0 {
                        if allNativeValues[key] != nil {
                            let admittedOccurrences = nativeValues[key]?.sampleSupport
                                .filter { $0.sample == sample }
                                .map(\.passedUniqueReads) ?? []
                            value = admittedOccurrences.contains(projectedValue)
                                ? projectedValue
                                : nil
                        } else {
                            let passesReads = projectedValue >= filter.matrixMinimumReads
                            // A stable ID identifies candidate evidence, whose
                            // percent basis is supporting samples over the full
                            // logical roster. A catalog-only reference row has
                            // no per-occurrence denominator; keep its captured
                            // value rather than inventing one.
                            let passesPercent = scientific.stable.map {
                                catalogCandidatePassesSupplementalPercent(
                                    locus: scientific.locus,
                                    genotype: scientific.genotype,
                                    stableClusterID: $0
                                )
                            } ?? true
                            value = passesReads && passesPercent
                                ? projectedValue
                                : nil
                        }
                    } else {
                        // An attested zero is evidence, not an empty cell. The
                        // row policy decides retention from positive visible
                        // cells after every projected value is validated.
                        value = projectedValue
                    }
                    let capturedFill = row.cellColorsHex.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                    let style = row.cellStyles.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                        ?? GenotypeMatrixStyleResolver.resolve([.init(fillColor: capturedFill ?? row.rowColorHex)], initial: resolvedStyle(cellTarget, styles: styles))
                    return .init(sampleID: sample, displayValue: value, rawSupport: support, reviewEligible: support != nil,
                        fillHex: row.cellColorsHex.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? style.fillHex,
                        comment: comments[cellTarget]?.body, review: reviews[cellTarget].map { $0.disposition == .falsePositive ? "false-positive" : "false-negative" }, style: style)
                }
                return .init(id: digest(Data(key.utf8)), target: .init(kind: "row", locus: scientific.locus,
                    genotype: scientific.genotype, stableClusterID: scientific.stable), displayName: row.label,
                    comment: comments[target]?.body, fillHex: row.rowColorHex ?? rowStyle.fillHex, cells: cells, style: rowStyle)
            }
            if full && seen != Set(evidence.keys) { throw CaptureError.incoherent("All projection omits authoritative rows") }
            let retainedRows = full ? rows : rows.filter { row in row.cells.contains { ($0.displayValue ?? 0) > 0 } }
            return .init(samples: names.map { .init(id: $0, name: $0, comment: comments[.column(sample: $0)]?.body) }, loci: bandLoci, rows: retainedRows)
        }
        let all = try matrix(allProjection, full: true)
        let filtered = try matrix(filteredProjection, full: false)
        var revision = captured.mapValues(digest)
        revision["bundle"] = result.bundleURL.path
        revision["analysisRevisionID"] = authority.analysis?.analysisRevisionID ?? ""
        revision["definitionSetID"] = authority.analysis?.definitionSetID ?? ""
        let metadata = [["Scope", "All authoritative evidence and captured filtered view"],
            ["Filtering", "Filtering does not redact Genotype Matrix - All"],
            ["Editing", "Point-in-time report; make edits in LGE"],
            ["Minimum reads", String(filter.matrixMinimumReads)], ["Minimum percent", String(filter.matrixMinimumPercent)],
            ["Percent denominator", filter.matrixDenominator.rawValue], ["Global minimum percent", String(filter.globalMinimumPercent)],
            ["Global percent denominator", filter.globalDenominator.rawValue], ["Filtered evidence row policy", filteredEvidenceRowPolicy],
            ["Candidate percent basis", "Positive supporting samples / full logical sample roster"]]
            + (filteredProjection?.filterContext ?? [:]).sorted(by: { $0.key < $1.key }).map { [$0.key, $0.value] }
        return .init(generatedAt: generatedAt, sourceRevision: revision, allMatrix: all, filteredMatrix: filtered,
            calls: callCapture.calls, colors: callCapture.colors, hasHaplotypeContent: !callCapture.calls.isEmpty,
            metadata: metadata, capturedScientificInputs: captured)
    }

    private static func resolvedStyle(_ target: GenotypeAnnotationSidecar.MatrixTarget,
        styles: [GenotypeAnnotationSidecar.MatrixTarget: GenotypeAnnotationSidecar.MatrixStyle]) -> GenotypeWorkbookPresentation.Style {
        typealias T = GenotypeAnnotationSidecar.MatrixTarget
        var layers: [T] = []
        switch target {
        case .column: layers = [target]
        case let .row(locus, genotype, stable):
            layers = [.row(locus: locus, genotype: genotype)]
            if stable != nil { layers.append(target) }
        case let .cell(locus, genotype, sample, stable):
            layers = [.row(locus: locus, genotype: genotype)]
            if let stable { layers.append(.row(locus: locus, genotype: genotype, stableClusterID: stable)) }
            layers += [.column(sample: sample), .cell(locus: locus, genotype: genotype, sample: sample)]
            if stable != nil { layers.append(target) }
        }
        return GenotypeMatrixStyleResolver.resolve(layers.map { styles[$0] })
    }

    private static func calls(result: ONTGenotypeResultBundleData, sidecar: GenotypeAnnotationSidecar,
        authority: CapturedAuthority, samples: [String]) throws -> (calls: [GenotypeWorkbookPresentation.Call], colors: [GenotypeWorkbookPresentation.Color]) {
        typealias P = GenotypeWorkbookPresentation
        var calls: [P.Call] = []; var colors = authority.colors
        if let analysis = authority.analysis {
            let resolution = GenotypeEffectiveCallAuthority.resolve(analysis: analysis, sidecar: sidecar)
            let usesIdentityBoundOverrides = GenotypeEffectiveCallAuthority.usesIdentityBoundOverrides(in: result.manifest, analysis: analysis)
            let rawCalls = Dictionary(analysis.samples.flatMap { sample in
                sample.calls.map { ([sample.sample, $0.locus], $0) }
            }, uniquingKeysWith: { _, last in last })
            for sample in resolution.orderedSamples {
                for locus in resolution.orderedLoci {
                    guard let resolved = resolution.locusValue(sample: sample, locus: locus),
                          let rawCall = rawCalls[[sample, locus]] else { continue }
                    let value = usesIdentityBoundOverrides ? resolved
                        : GenotypeEffectiveCallAuthority.resolveLegacy(sample: sample, call: rawCall, sidecar: sidecar)
                    func slot(_ value: GenotypeEffectiveCallAuthority.SlotValue) -> P.Slot {
                        let source: String
                        switch value.source { case .pipeline: source = "pipeline"; case .analystOverride: source = "analystOverride"; case .staleOverride: source = "staleOverride" }
                        return .init(effective: value.effective, pipeline: value.baseline, baselineAvailable: true,
                            status: value.status.rawValue, source: source)
                    }
                    calls.append(.init(id: digest(Data((sample + "\u{0}" + locus).utf8)), sampleID: sample,
                        locus: locus, h1: slot(value.h1), h2: slot(value.h2),
                        comment: analysis.samples.first { $0.sample == sample }?.calls.last { $0.locus == locus }?.notes))
                }
            }
        } else if case .eligible = GenotypeManualHaplotypeAuthority.evaluate(result.manifest) {
            let index = GenotypeManualHaplotypeAssignmentIndex(assignments: sidecar.manualHaplotypeAssignments)
            for sample in samples {
                for locus in GenotypeManualHaplotypeLocus.allCases {
                    let assignments = index.assignments(sample: sample, locus: locus)
                    func slot(_ assignment: ManualHaplotypeAssignment?) -> P.Slot {
                        let label = assignment.flatMap { try? GenotypeManualHaplotypeAssignmentInputValidator.validatedLabel($0.label) }
                        return .init(effective: label ?? "", pipeline: nil, baselineAvailable: false,
                            status: label == nil ? "unassigned" : "called", source: label == nil ? "unassigned" : "manualAssignment")
                    }
                    let h1 = slot(assignments.h1), h2 = slot(assignments.h2)
                    guard !h1.effective.isEmpty || !h2.effective.isEmpty else { continue }
                    calls.append(.init(id: digest(Data((sample + "\u{0}" + locus.rawValue).utf8)), sampleID: sample,
                        locus: locus.rawValue, h1: h1, h2: h2, comment: [assignments.h1?.notes, assignments.h2?.notes].compactMap { $0 }.joined(separator: "\n")))
                    for value in [h1.effective, h2.effective] where !value.isEmpty {
                        let token = HaplotypeColorToken.canonicalPalette.first { $0.canonicalIndex == index.catalogEntry(for: value)?.colorTokenIndex } ?? HaplotypeColorToken.assigned(forName: value)
                        colors.append(.init(locus: locus.rawValue, call: value, fillHex: token.fillColor.hexString, fontHex: token.fontColor.hexString))
                    }
                }
            }
        }
        for call in calls {
            for value in [call.h1.effective, call.h2.effective] where !value.isEmpty && value != "-" {
                if colors.contains(where: { $0.locus == call.locus && $0.call == value }) { continue }
                let definition = authority.definitionSet?.locusDefinitions.first { $0.locus == call.locus }?.haplotypes.first { $0.name == value }
                let token = HaplotypeColorToken.assigned(forName: value)
                colors.append(.init(locus: call.locus, call: value, fillHex: (definition?.effectiveFillColor ?? token.fillColor).hexString, fontHex: token.fontColor.hexString))
            }
        }
        var seen = Set<String>()
        colors = colors.filter { seen.insert($0.locus + "\u{0}" + $0.call).inserted }
        return (calls, colors)
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>(); return values.filter { seen.insert($0).inserted }
    }
}

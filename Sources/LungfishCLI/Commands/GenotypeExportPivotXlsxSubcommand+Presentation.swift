import CryptoKit
import Foundation
import LungfishIO
import LungfishWorkflow

extension GenotypeExportPivotXlsxSubcommand {
    func filteredPresentation(result: ONTGenotypeResultBundleData, sidecar: GenotypeAnnotationSidecar?, thresholds: PivotWorkbookBuilder.Thresholds, projection: GenotypeViewProjection?) throws -> GenotypeWorkbookPresentation.Payload {
        typealias P = GenotypeWorkbookPresentation
        let workbook = PivotWorkbookBuilder.build(from: result, sidecar: sidecar, thresholds: thresholds)
        let samples = projection?.sampleColumns ?? workbook.samples
        let comments = sidecar?.resolvedMatrixComments ?? [:]
        func identity<T: Encodable>(_ target: T) throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return SHA256.hash(data: try encoder.encode(target)).map { String(format: "%02x", $0) }.joined()
        }
        let sourceRows = projection?.rows ?? workbook.groups.flatMap { group in
            group.alleles.map { row in
                GenotypeViewProjectionRow(label: row.name, rawGenotype: row.name,
                    locus: result.calls.first(where: { $0.genotype == row.name })?.locusGroup ?? group.label,
                    cells: row.counts.map { $0.map(String.init) ?? "" })
            }
        }
        let rows = try sourceRows.map { row -> P.Row in
            let genotype = row.rawGenotype ?? row.label
            let locus = row.locus ?? ""
            let target = P.Target(kind: "row", locus: locus, genotype: genotype, stableClusterID: row.stableClusterID)
            let annotationTarget = GenotypeAnnotationSidecar.MatrixTarget.row(locus: locus, genotype: genotype, stableClusterID: row.stableClusterID)
            let catalogRow = result.reviewableRowCatalog?.rows.first { $0.callID == genotype && $0.locus == locus && $0.stableID == row.stableClusterID }
            let cells = samples.enumerated().map { index, sample -> P.Cell in
                let cellTarget = GenotypeAnnotationSidecar.MatrixTarget.cell(locus: locus, genotype: genotype, sample: sample, stableClusterID: row.stableClusterID)
                let raw = catalogRow?.supportBySample[sample]
                let captured = index < row.cells.count ? row.cells[index] : ""
                let review = sidecar?.matrixReviews.last(where: { $0.target == cellTarget })?.disposition
                let token = review.map { $0 == .falsePositive ? "false-positive" : "false-negative" }
                let color = row.cellColorsHex.flatMap { index < $0.count ? $0[index] : nil }
                return .init(sampleID: sample, displayValue: Int(captured), rawSupport: raw, reviewEligible: raw != nil,
                    fillHex: color, comment: comments[cellTarget]?.body, review: token)
            }
            return .init(id: try identity(target), target: target, displayName: row.label,
                comment: comments[annotationTarget]?.body, fillHex: row.rowColorHex, cells: cells)
        }
        var projectedCalls = projection?.haplotypeCalls ?? []
        if projection == nil, case .eligible = GenotypeManualHaplotypeAuthority.evaluate(result.manifest) {
            let index = GenotypeManualHaplotypeAssignmentIndex(assignments: sidecar?.manualHaplotypeAssignments ?? [])
            projectedCalls = samples.flatMap { sample in
                GenotypeManualHaplotypeLocus.allCases.map { locus in
                    let slots = index.assignments(sample: sample, locus: locus)
                    return .init(sample: sample, locus: locus.rawValue, haplotype1: slots.h1?.label ?? "", haplotype2: slots.h2?.label ?? "",
                        haplotype1Status: "called", haplotype2Status: "called",
                        haplotype1Source: slots.h1 == nil ? "unassigned" : "manualAssignment", haplotype2Source: slots.h2 == nil ? "unassigned" : "manualAssignment",
                        baselineHaplotype1: "", baselineHaplotype2: "", comment: [slots.h1?.notes, slots.h2?.notes].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "; "),
                        baselineHaplotype1Available: false, baselineHaplotype2Available: false)
                }
            }
        }
        if projection == nil,
           let analysis = GenotypeActiveHaplotypeAnalysisResolver.activeAnalysis(for: result, sidecar: sidecar) {
            let authority = GenotypeEffectiveCallAuthority.resolve(analysis: analysis, sidecar: sidecar ?? .empty(generatedAt: analysis.generatedAt ?? "1970-01-01T00:00:00Z"))
            projectedCalls = analysis.samples.filter { samples.contains($0.sample) }.flatMap { sample in
                sample.calls.compactMap { call in
                    guard let value = authority.locusValue(sample: sample.sample, locus: call.locus) else { return nil }
                    return .init(sample: sample.sample, locus: call.locus, haplotype1: value.h1.effective, haplotype2: value.h2.effective,
                        haplotype1Status: value.h1.status.rawValue, haplotype2Status: value.h2.status.rawValue,
                        haplotype1Source: String(describing: value.h1.source), haplotype2Source: String(describing: value.h2.source),
                        baselineHaplotype1: call.haplotype1, baselineHaplotype2: call.haplotype2, comment: call.notes,
                        baselineHaplotype1Available: true, baselineHaplotype2Available: true)
                }
            }
        }
        let calls = try projectedCalls.filter { samples.contains($0.sample) }.map { call -> P.Call in
            let available1 = call.baselineHaplotype1Available == true
            let available2 = call.baselineHaplotype2Available == true
            return .init(id: try identity(["sampleID": call.sample, "locus": call.locus]), sampleID: call.sample, locus: call.locus,
                h1: .init(effective: call.haplotype1, pipeline: available1 ? call.baselineHaplotype1 : nil, baselineAvailable: available1, status: call.haplotype1Status, source: call.haplotype1Source),
                h2: .init(effective: call.haplotype2, pipeline: available2 ? call.baselineHaplotype2 : nil, baselineAvailable: available2, status: call.haplotype2Status, source: call.haplotype2Source), comment: call.comment)
        }
        var loci: [String] = []
        for call in calls where !loci.contains(call.locus) { loci.append(call.locus) }
        var revision: [String: String] = [:]
        if let source = projection?.sourceRevision {
            revision = ["assayID": source.assayID, "definitionSetID": source.definitionSetID]
            revision["analysisRevisionID"] = source.analysisRevisionID
        }
        let metadata = [["Scope", "Filtered snapshot"], ["Minimum reads", String(thresholds.minimumReads)], ["Minimum percent", String(thresholds.minimumPercent)]]
            + (projection?.filterContext ?? [:]).sorted { $0.key < $1.key }.map { [$0.key, $0.value] }
        let colors = projection?.presentationColors ?? GenotypeActiveHaplotypeAnalysisResolver.activeDefinitionSet(for: result, sidecar: sidecar)?.locusDefinitions.flatMap { locus in
            locus.haplotypes.map { haplotype -> P.Color in
                let color = haplotype.effectiveFillColor
                func channel(_ value: Double) -> Double { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
                let luminance = 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
                return .init(locus: locus.locus, call: haplotype.name, fillHex: color.hexString, fontHex: luminance > 0.45 ? "#000000" : "#FFFFFF")
            }
        } ?? []
        return .init(schemaVersion: 2, role: "filtered-snapshot", sourceRevision: revision,
            samples: samples.map { .init(id: $0, name: $0, comment: comments[.column(sample: $0)]?.body) },
            loci: loci, rows: rows, calls: calls, colors: colors, metadata: metadata, callEditingSupported: false)
    }

    static var filteredPresentationScript: String {
        GenotypeWorkbookPresentation.pythonScript + #"""

import sys, platform, openpyxl
with open(sys.argv[3]) as handle:
    payload = json.load(handle)
render_three_sheet_workbook(payload, sys.argv[2])
print(json.dumps(dict(sheet='Genotype Matrix', matchedAlleleRows=len(payload['rows']),
    blankedValues=sum(c.get('displayValue') is None for r in payload['rows'] for c in r['cells']), removedAlleleRows=0,
    pythonExecutable=sys.executable, pythonVersion=platform.python_version(), openpyxlVersion=openpyxl.__version__)))
"""#
    }
}

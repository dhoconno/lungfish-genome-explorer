import AppKit
import Combine
import SwiftUI
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

/// Owns the genotype viewport export path of one GenotypeResultViewController.
/// It settles the view, freezes the Excel capture, presents the save panel,
/// runs the export task and publishes the export events. The controller
/// creates the coordinator once and holds it for its own lifetime, so the
/// coordinator never outlives the controller it reads. It reads controller
/// state only through the forwarders at the end of this file. New export
/// logic belongs here and not in the controller (REVIEW.md R6).
@MainActor
final class GenotypeViewportExportCoordinator {
    private unowned let host: GenotypeResultViewController

    init(host: GenotypeResultViewController) {
        self.host = host
    }

    /// Settles native drafts and filters, then freezes both worksheets before
    /// the ordinary save panel can delay publication.
    func presentExcelExportPanel(
        expectedDisplayState: GenotypeResultDisplayState,
        settleDisplayState: (() throws -> GenotypeResultDisplayState)? = nil,
        originStillCurrent: @escaping () -> Bool = { true }
    ) {
        guard originStillCurrent(), result != nil else { return }
        let authority = desiredResultConfigurationAuthority
        let origin = representedBundleURL
        // End native editing before consulting the draft coordinator so its
        // Save/Discard/Cancel decision includes the final field-editor value.
        guard view.window?.makeFirstResponder(nil) != false else { return }
        let capture: @MainActor () -> Void = { [weak self] in
            guard let self, originStillCurrent(), self.representedBundleURL == origin,
                  self.ownsDesiredResultConfiguration(authority) else { return }
            do {
                let settled = try settleDisplayState?() ?? expectedDisplayState
                guard self.displayState == settled, originStillCurrent(), self.ownsDesiredResultConfiguration(authority) else { return }
                let snapshot = try self.captureExcelExportSnapshot()
                self.presentViewExportPanel(format: .excel, filenameSuffix: "genotype", capturedSnapshot: snapshot,
                    excelWorkflow: true, originStillCurrent: originStillCurrent)
            } catch {
                self.publishExcelExportEvent(.failed(error.localizedDescription), excelWorkflow: true)
            }
        }
        if !deferManualHaplotypeTransition(.export, mutation: capture) { capture() }
    }

    /// The retained scientific model and native annotations are authoritative.
    /// Source paths are historical context, never later substitutes for these bytes.
    func captureExcelExportSnapshot() throws -> GenotypeViewportExportSnapshot {
        guard let result else { throw GenotypeExcelSnapshotBuilder.CaptureError.incoherent("no selected result") }
        guard deferredMatrixAnnotationMutationCount == 0 else {
            throw GenotypeExcelSnapshotBuilder.CaptureError.incoherent(
                "Native annotations are still saving. Wait for the save to finish, then export again.")
        }
        quickFilterBar.settleSearchForExport(committedState: quickFilterState)
        ensureComparisonMatrixConfigured()
        comparisonMatrix.settlePendingFilterForExport()
        let sidecar = annotationStore?.sidecar ?? .empty(generatedAt: "1970-01-01T00:00:00Z")
        let analysis = activeHaplotypeAnalysis()
        let definition = definitionSetForResult(result)
        let colors = resolvedWorkbookPresentationColors()
        let filtered = attachFilterContext(to: comparisonMatrix.exportSnapshot(
            bundleURL: result.bundleURL, analysisName: result.manifest.analysisName, lens: selectedLens.identifier))
        let all = comparisonMatrix.exportSnapshot(bundleURL: result.bundleURL,
            analysisName: result.manifest.analysisName, lens: selectedLens.identifier, unfiltered: true)
        let authority = GenotypeExcelSnapshotBuilder.CapturedAuthority(analysis: analysis,
            definitionSet: definition,
            locusDisplayOrder: sidecar.settings.genotypeLocusDisplayOrder ?? result.genotypeLocusDisplayOrder,
            colors: colors)
        let generatedAt = ISO8601DateFormatter().string(from: Date())
        let allProjection = GenotypeViewProjectionSerializer.makeProjection(from: all)
        // The native matrix may omit catalog-only evidence. The shared builder
        // owns its identity, attested zeros and annotations, so supplement from
        // that same frozen authority before the final capture.
        let complete = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: sidecar,
            allProjection: nil, filteredProjection: nil, generatedAt: generatedAt, authority: authority)
        let completeRowsByIdentity = Dictionary(uniqueKeysWithValues: complete.allMatrix.rows.map {
            ([$0.target.locus, $0.target.genotype, $0.target.stableClusterID ?? ""], $0)
        })
        let known = Set(allProjection.rows.map { [$0.locus ?? "", $0.rawGenotype ?? $0.label, $0.stableClusterID ?? ""] })
        let supplemental = complete.allMatrix.rows.filter { !known.contains([$0.target.locus, $0.target.genotype, $0.target.stableClusterID ?? ""]) }
        let completeSamples = complete.allMatrix.samples.map(\.name)
        let allSamples = allProjection.sampleColumns + completeSamples.filter { !allProjection.sampleColumns.contains($0) }
        let nativeRows = allProjection.rows.map { row in
            let indices = allSamples.map { allProjection.sampleColumns.firstIndex(of: $0) }
            let identity = [row.locus ?? "", row.rawGenotype ?? row.label, row.stableClusterID ?? ""]
            let authoritativeCells = Dictionary(uniqueKeysWithValues:
                (completeRowsByIdentity[identity]?.cells ?? []).map { ($0.sampleID, $0) })
            return GenotypeViewProjectionRow(label: row.label, rawGenotype: row.rawGenotype, locus: row.locus,
                stableClusterID: row.stableClusterID,
                cells: allSamples.enumerated().map { index, sample in
                    let nativeValue = indices[index].map { row.cells[$0] } ?? ""
                    // Preserve native occurrence values; fill only absent cells
                    // from attested evidence, never by converting unknown to zero.
                    return nativeValue.isEmpty
                        ? (authoritativeCells[sample]?.displayValue.map(String.init) ?? "")
                        : nativeValue
                },
                cellColorsHex: row.cellColorsHex.map { colors in indices.map { $0.flatMap { colors[$0] } } },
                rowColorHex: row.rowColorHex, rowStyle: row.rowStyle,
                cellStyles: row.cellStyles.map { styles in indices.map { $0.flatMap { styles[$0] } } },
                matrixColumnValues: row.matrixColumnValues)
        }
        let projection = GenotypeViewProjection(lens: allProjection.lens,
            sampleColumns: allSamples,
            rows: nativeRows + supplemental.map { row in
                let cells = allSamples.compactMap { sample in row.cells.first { $0.sampleID == sample } }
                return .init(label: row.displayName, rawGenotype: row.target.genotype, locus: row.target.locus,
                    stableClusterID: row.target.stableClusterID,
                    cells: cells.map { $0.displayValue.map(String.init) ?? "" },
                    rowStyle: row.style, cellStyles: cells.map(\.style))
            }, matrixColumns: allProjection.matrixColumns,
            filterContext: allProjection.filterContext, presentationColors: colors)
        let capture = try GenotypeExcelSnapshotBuilder.capture(result: result, sidecar: sidecar,
            allProjection: projection,
            filteredProjection: GenotypeViewProjectionSerializer.makeProjection(from: filtered),
            generatedAt: generatedAt, authority: authority,
            filter: .init(globalMinimumPercent: displayState.activeMinimumSupportPercent,
                globalDenominator: displayState.supportDenominator,
                matrixMinimumReads: displayState.matrixMinimumReads,
                matrixMinimumPercent: displayState.matrixMinimumPercent,
                matrixDenominator: displayState.matrixPercentDenominator,
                minimumPrevalencePercent: displayState.matrixMinimumPrevalencePercent))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return GenotypeViewportExportSnapshot(bundleURL: filtered.bundleURL, analysisName: filtered.analysisName,
            lens: filtered.lens, filters: filtered.filters, sampleNames: filtered.sampleNames, rows: filtered.rows,
            annotationSidecarData: try sidecar.encoded(), presentationColors: colors,
            matrixColumns: filtered.matrixColumns,
            excelSnapshotData: try encoder.encode(capture))
    }

    private func presentViewExportPanel(
        format: GenotypeViewportExportFormat,
        filenameSuffix: String,
        capturedSnapshot: GenotypeViewportExportSnapshot? = nil,
        excelWorkflow: Bool = false,
        originStillCurrent: @escaping () -> Bool = { true }
    ) {
        guard let result else { return }
        let authority = desiredResultConfigurationAuthority
        let origin = representedBundleURL
        let panel = NSSavePanel()
        panel.title = "Export Genotype View"
        panel.message = "Export Genotype View"
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(result.manifest.outputName)-\(filenameSuffix)-\(timestamp).\(format.fileExtension)"
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        excelSavePanelPresenter(panel, view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] url in
            guard let url else { return }
            guard let self, originStillCurrent(), self.representedBundleURL == origin,
                  self.ownsDesiredResultConfiguration(authority) else { return }
            // Excel always carries its pre-panel immutable scientific capture.
            // Delimiter formats retain their existing viewport snapshot boundary.
            guard let snapshot = capturedSnapshot ?? self.currentExportSnapshot() else { return }
            let outputURL = url
            self.publishExcelExportEvent(.started, excelWorkflow: excelWorkflow)
            let export = self.viewportExportRunner
            Task { [weak self] in
                do {
                    try await export(snapshot, format, outputURL)
                    await MainActor.run {
                        guard let self, originStillCurrent(), self.representedBundleURL == origin,
                              self.ownsDesiredResultConfiguration(authority) else { return }
                        self.publishExcelExportEvent(.succeeded(outputURL), excelWorkflow: excelWorkflow)
                    }
                } catch {
                    await MainActor.run {
                        guard let self, originStillCurrent(), self.representedBundleURL == origin,
                              self.ownsDesiredResultConfiguration(authority) else { return }
                        self.publishExcelExportEvent(.failed(error.localizedDescription), excelWorkflow: excelWorkflow)
                        if let window = self.view.window ?? NSApp.keyWindow {
                            NSAlert(error: error).beginSheetModal(for: window, completionHandler: { _ in })
                        } else {
                            NSApp.presentError(error)
                        }
                    }
                }
            }
        }
    }

    func publishExcelExportEvent(
        _ event: GenotypeExcelExportEvent,
        excelWorkflow: Bool
    ) {
        guard excelWorkflow else { return }
        onExcelExportEvent?(event)
    }

    func currentExportSnapshot() -> GenotypeViewportExportSnapshot? {
        guard let result else { return nil }
        let capturedAnalysis = activeHaplotypeAnalysis()
        let capturedSidecar = annotationStore?.sidecar
        let baseSnapshot: GenotypeViewportExportSnapshot
        if selectedLens == .summary,
           displayState.summaryViewMode == .matrix,
           presentationPolicy?.appliesToHaplotypedMiSeq != true,
           definitionSetForResult(result) != nil,
           !displayState.showsAncillaryLoci {
            let haplotypeScope = haplotypeMatrixView.exportSnapshot(
                bundleURL: result.bundleURL,
                analysisName: result.manifest.analysisName,
                lens: "summary.matrix.haplotypeDefinitions"
            )
            ensureComparisonMatrixConfigured()
            let matrix = comparisonMatrix.exportSnapshot(
                bundleURL: result.bundleURL,
                analysisName: result.manifest.analysisName,
                lens: selectedLens.identifier
            )
            baseSnapshot = GenotypeViewportExportSnapshot(
                bundleURL: matrix.bundleURL,
                analysisName: matrix.analysisName,
                lens: matrix.lens,
                filters: matrix.filters.merging([
                    "haplotypeScopeView": haplotypeScope.lens,
                ]) { _, new in new },
                sampleNames: matrix.sampleNames,
                rows: matrix.rows,
                provenanceInputURLs: matrix.provenanceInputURLs,
                annotationSidecarURL: matrix.annotationSidecarURL,
                annotationSidecarData: matrix.annotationSidecarData,
                sidecar: matrix.sidecar,
                haplotypeCalls: matrix.haplotypeCalls,
                sourceRevision: matrix.sourceRevision,
                haplotypeSampleScope: haplotypeScope.haplotypeSampleScope,
                haplotypeLocusScope: haplotypeScope.haplotypeLocusScope,
                matrixColumns: matrix.matrixColumns
            )
        } else {
            ensureComparisonMatrixConfigured()
            baseSnapshot = comparisonMatrix.exportSnapshot(
                bundleURL: result.bundleURL,
                analysisName: result.manifest.analysisName,
                lens: selectedLens.identifier
            )
        }
        return attachSidecarSnapshot(
            to: attachEffectiveHaplotypeCalls(
                to: attachHaplotypeDefinitionProvenanceContext(
                    to: attachFilterContext(to: baseSnapshot),
                    capturedAnalysis: capturedAnalysis
                ),
                capturedAnalysis: capturedAnalysis,
                capturedSidecar: capturedSidecar
            ),
            capturedSidecar: capturedSidecar
        )
    }

    /// Empty annotation state is authoritative too. Failure to encode must
    /// prevent export rather than falling back to the live bundle sidecar.
    private func attachSidecarSnapshot(
        to base: GenotypeViewportExportSnapshot,
        capturedSidecar sidecar: GenotypeAnnotationSidecar?
    ) -> GenotypeViewportExportSnapshot? {
        let sidecar = sidecar ?? .empty(generatedAt: "1970-01-01T00:00:00Z")
        guard let annotationData = try? sidecar.encoded() else { return nil }
        let overrides = sidecar.callOverrides.map { o in
            GenotypeAnnotationOverrideEntry(
                sample: o.sample, locus: o.locus, slot: o.slot.rawValue,
                originalCall: o.originalCall, overrideCall: o.overrideCall,
                reasonTag: o.reasonTag.rawValue, rationale: o.rationale,
                author: o.author, timestamp: o.timestamp
            )
        }
        let auditEntries = sidecar.auditLog.map { e in
            GenotypeAnnotationAuditEntry(
                action: e.action,
                sample: e.sample,
                locus: e.locus ?? "",
                slot: e.slot?.rawValue ?? "",
                before: e.before ?? "",
                after: e.after ?? "",
                author: e.author,
                timestamp: e.timestamp
            )
        }
        let annotationSidecarURL = ONTGenotypeResultBundleData.annotationSidecarURL(forBundleAt: base.bundleURL)
        var provenanceInputURLs = base.provenanceInputURLs
        if FileManager.default.fileExists(atPath: annotationSidecarURL.path),
           !provenanceInputURLs.contains(annotationSidecarURL) {
            provenanceInputURLs.append(annotationSidecarURL)
        }
        return GenotypeViewportExportSnapshot(
            bundleURL: base.bundleURL,
            analysisName: base.analysisName,
            lens: base.lens,
            filters: base.filters,
            sampleNames: base.sampleNames,
            rows: base.rows,
            provenanceInputURLs: provenanceInputURLs,
            annotationSidecarURL: FileManager.default.fileExists(atPath: annotationSidecarURL.path)
                ? annotationSidecarURL
                : nil,
            annotationSidecarData: annotationData,
            sidecar: GenotypeAnnotationSidecarSnapshot(
                overrides: overrides,
                auditEntries: auditEntries
            ),
            haplotypeCalls: base.haplotypeCalls,
            sourceRevision: base.sourceRevision,
            haplotypeSampleScope: base.haplotypeSampleScope,
            haplotypeLocusScope: base.haplotypeLocusScope,
            presentationColors: base.presentationColors,
            matrixColumns: base.matrixColumns
        )
    }

    private func attachFilterContext(
        to base: GenotypeViewportExportSnapshot
    ) -> GenotypeViewportExportSnapshot {
        let context = exportFilterContext()
        guard !context.isEmpty else { return base }
        return GenotypeViewportExportSnapshot(
            bundleURL: base.bundleURL,
            analysisName: base.analysisName,
            lens: base.lens,
            filters: base.filters.merging(context) { _, contextValue in contextValue },
            sampleNames: base.sampleNames,
            rows: base.rows,
            provenanceInputURLs: base.provenanceInputURLs,
            annotationSidecarURL: base.annotationSidecarURL,
            annotationSidecarData: base.annotationSidecarData,
            sidecar: base.sidecar,
            haplotypeCalls: base.haplotypeCalls,
            sourceRevision: base.sourceRevision,
            haplotypeSampleScope: base.haplotypeSampleScope,
            haplotypeLocusScope: base.haplotypeLocusScope,
            presentationColors: base.presentationColors,
            matrixColumns: base.matrixColumns
        )
    }

    private func attachHaplotypeDefinitionProvenanceContext(
        to base: GenotypeViewportExportSnapshot,
        capturedAnalysis analysis: GenotypeHaplotypeAnalysis?
    ) -> GenotypeViewportExportSnapshot {
        guard let result,
              let definitionID = analysis?.definitionSetID
                ?? activeHaplotypeDefinitionSetID() else {
            return base
        }
        var filters = base.filters
        filters["activeHaplotypeDefinitionSetID"] = definitionID
        if let definition = definitionSetForResult(result) {
            filters["activeHaplotypeAssayID"] = definition.assayID
            filters["activeHaplotypeDefinitionName"] = definition.displayName
            if let schemaVersion = definition.schemaVersion {
                filters["activeHaplotypeDefinitionSchemaVersion"] = "\(schemaVersion)"
            }
            if let lastModified = definition.lastModified {
                filters["activeHaplotypeDefinitionLastModified"] = lastModified
            }
        }
        var provenanceInputURLs = base.provenanceInputURLs
        if let url = GenotypeHaplotypeAnalysisResolver.activeDefinitionFileURL(
            for: result, sidecar: annotationStore?.sidecar
        ),
           FileManager.default.fileExists(atPath: url.path),
           !provenanceInputURLs.contains(url) {
            provenanceInputURLs.append(url)
            filters["activeHaplotypeDefinitionPath"] = url.path
        }
        return GenotypeViewportExportSnapshot(
            bundleURL: base.bundleURL,
            analysisName: base.analysisName,
            lens: base.lens,
            filters: filters,
            sampleNames: base.sampleNames,
            rows: base.rows,
            provenanceInputURLs: provenanceInputURLs,
            annotationSidecarURL: base.annotationSidecarURL,
            annotationSidecarData: base.annotationSidecarData,
            sidecar: base.sidecar,
            haplotypeCalls: base.haplotypeCalls,
            sourceRevision: base.sourceRevision,
            haplotypeSampleScope: base.haplotypeSampleScope,
            haplotypeLocusScope: base.haplotypeLocusScope,
            presentationColors: resolvedWorkbookPresentationColors(),
            matrixColumns: base.matrixColumns
        )
    }

    private func attachEffectiveHaplotypeCalls(
        to base: GenotypeViewportExportSnapshot,
        capturedAnalysis analysis: GenotypeHaplotypeAnalysis?,
        capturedSidecar: GenotypeAnnotationSidecar?
    ) -> GenotypeViewportExportSnapshot {
        func replacingCalls(
            _ calls: [GenotypeViewProjectionHaplotypeCall],
            sourceRevision: GenotypeViewProjectionSourceRevision? = nil
        ) -> GenotypeViewportExportSnapshot {
            GenotypeViewportExportSnapshot(
                bundleURL: base.bundleURL,
                analysisName: base.analysisName,
                lens: base.lens,
                filters: base.filters,
                sampleNames: base.sampleNames,
                rows: base.rows,
                provenanceInputURLs: base.provenanceInputURLs,
                annotationSidecarURL: base.annotationSidecarURL,
                annotationSidecarData: base.annotationSidecarData,
                sidecar: base.sidecar,
                haplotypeCalls: calls,
                sourceRevision: sourceRevision,
                haplotypeSampleScope: base.haplotypeSampleScope,
                haplotypeLocusScope: base.haplotypeLocusScope,
                presentationColors: base.presentationColors,
                matrixColumns: base.matrixColumns
            )
        }
        guard let analysis else {
            if case .eligible = manualHaplotypeEligibility {
                let visibleSamples = base.haplotypeSampleScope ?? base.sampleNames
                let selectedLocus = base.filters["locus"].flatMap { $0 == "All Loci" || $0.isEmpty ? nil : $0 }
                let visibleLoci = base.haplotypeLocusScope
                    ?? selectedLocus.map { [$0] }
                    ?? GenotypeManualHaplotypeLocus.allCases.map(\.rawValue)
                let index = GenotypeManualHaplotypeAssignmentIndex(
                    assignments: capturedSidecar?.manualHaplotypeAssignments ?? []
                )
                return replacingCalls(visibleSamples.flatMap { sample in
                    visibleLoci.compactMap { locus -> GenotypeViewProjectionHaplotypeCall? in
                        guard let manualLocus = GenotypeManualHaplotypeLocus(rawValue: locus) else { return nil }
                        let slots = index.assignments(sample: sample, locus: manualLocus)
                        let notes = [slots.h1?.notes, slots.h2?.notes].compactMap { $0 }.filter { !$0.isEmpty }
                        return .init(
                            sample: sample, locus: locus,
                            haplotype1: slots.h1?.label ?? "", haplotype2: slots.h2?.label ?? "",
                            haplotype1Status: "called", haplotype2Status: "called",
                            haplotype1Source: slots.h1 == nil ? "unassigned" : "manualAssignment",
                            haplotype2Source: slots.h2 == nil ? "unassigned" : "manualAssignment",
                            baselineHaplotype1: "", baselineHaplotype2: "",
                            comment: notes.joined(separator: "; "),
                            baselineHaplotype1Available: false,
                            baselineHaplotype2Available: false
                        )
                    }
                })
            }
            // GUI projections always opt in to the typed, clean workbook
            // contract. `nil` remains reserved for decoded legacy projections.
            return replacingCalls([])
        }
        let sidecar = capturedSidecar
            ?? GenotypeAnnotationSidecar.empty(
                generatedAt: analysis.generatedAt ?? "1970-01-01T00:00:00Z"
            )
        let resolution = GenotypeEffectiveCallAuthority.resolve(
            analysis: analysis,
            sidecar: sidecar
        )
        let visibleSamples = base.haplotypeSampleScope ?? base.sampleNames
        let selectedLocus = base.filters["locus"].flatMap {
            $0 == "All Loci" || $0.isEmpty ? nil : $0
        }
        let visibleLoci = base.haplotypeLocusScope
            ?? selectedLocus.map { [$0] }
            ?? resolution.orderedLoci
        let commentsBySampleLocus = Dictionary(
            uniqueKeysWithValues: analysis.samples.flatMap { sample in
                sample.calls.map { ((sample.sample + "\u{1f}" + $0.locus), $0.notes) }
            }
        )
        func sourceName(_ source: GenotypeEffectiveHaplotypeValue.Source) -> String {
            switch source {
            case .pipeline: return "pipeline"
            case .analystOverride: return "analystOverride"
            case .staleOverride: return "staleOverride"
            }
        }
        var calls: [GenotypeViewProjectionHaplotypeCall] = []
        for sample in visibleSamples {
            for locus in visibleLoci {
                guard resolution.locusValue(sample: sample, locus: locus) != nil else { continue }
                guard let rawCall = analysis.samples.first(where: { $0.sample == sample })?.calls.first(where: { $0.locus == locus }) else { continue }
                let effective = effectiveHaplotypeCall(sample: sample, call: rawCall)
                calls.append(.init(
                    sample: sample,
                    locus: locus,
                    haplotype1: effective.h1,
                    haplotype2: effective.h2,
                    haplotype1Status: effective.h1Status.rawValue,
                    haplotype2Status: effective.h2Status.rawValue,
                    haplotype1Source: sourceName(effective.h1Source),
                    haplotype2Source: sourceName(effective.h2Source),
                    baselineHaplotype1: rawCall.haplotype1,
                    baselineHaplotype2: rawCall.haplotype2,
                    comment: commentsBySampleLocus[sample + "\u{1f}" + locus],
                    baselineHaplotype1Available: true,
                    baselineHaplotype2Available: true
                ))
            }
        }
        return replacingCalls(
            calls,
            sourceRevision: .init(
                assayID: resolution.identity.assayID,
                analysisRevisionID: resolution.identity.analysisRevisionID,
                definitionSetID: resolution.identity.definitionSetID
            )
        )
    }

    private func exportFilterContext() -> [String: String] {
        var context: [String: String] = [:]
        if let activeSmartCohort {
            context["activeSmartCohortName"] = activeSmartCohort.name
            context["activeSmartCohortScope"] = activeSmartCohort.scope
            context["activeSmartCohortPredicate"] = encodedPredicate(activeSmartCohort.predicate)
        }
        let summary = quickFilterState.displaySummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            context["quickFilter"] = summary
        }
        let search = quickFilterSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            context["quickFilterSearchText"] = search
        }
        if let predicate = quickFilterState.saveablePredicate {
            context["quickFilterPredicate"] = encodedPredicate(predicate)
        }
        return context
    }

    private func encodedPredicate(_ predicate: SmartCohortPredicate) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(predicate),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: predicate)
        }
        return text
    }

    private func resolvedWorkbookPresentationColors() -> [GenotypeWorkbookPresentation.Color] {
        guard let result, let definition = definitionSetForResult(result) else { return [] }
        return definition.locusDefinitions.flatMap { locus in
            locus.haplotypes.map { haplotype in
                let color = haplotype.effectiveFillColor
                func channel(_ value: Double) -> Double {
                    value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
                }
                let luminance = 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
                return .init(locus: locus.locus, call: haplotype.name, fillHex: color.hexString, fontHex: luminance > 0.45 ? "#000000" : "#FFFFFF")
            }
        }
    }

    func fileViewerSelectionURLs(for export: GenotypeViewportExportResult) -> [URL] {
        [export.outputURL]
    }
}

// The controller state the export reads. Each line forwards one member to the
// controller under the member's own name, so every moved line above stays
// byte-identical and a new controller dependency shows up as a new line here.
private extension GenotypeViewportExportCoordinator {
    var result: ONTGenotypeResultBundleData? { host.result }
    var annotationStore: GenotypeAnnotationStore? { host.annotationStore }
    var selectedLens: GenotypeResultViewportLens { host.selectedLens }
    var displayState: GenotypeResultDisplayState { host.displayState }
    var presentationPolicy: GenotypeResultPresentationPolicy? { host.presentationPolicy }
    var manualHaplotypeEligibility: GenotypeManualHaplotypeEligibility { host.manualHaplotypeEligibility }
    var activeSmartCohort: GenotypeCohortSmartFilter? { host.activeSmartCohort }
    var quickFilterState: GenotypeQuickFilterBarView.FilterState { host.quickFilterState }
    var quickFilterSearchText: String { host.quickFilterSearchText }
    var deferredMatrixAnnotationMutationCount: Int { host.deferredMatrixAnnotationMutationCount }
    var comparisonMatrix: GenotypeComparisonMatrixView { host.comparisonMatrix }
    var haplotypeMatrixView: GenotypeHaplotypeDefinitionMatrixView { host.haplotypeMatrixView }
    var quickFilterBar: GenotypeQuickFilterBarView { host.quickFilterBar }
    var view: NSView { host.view }
    var representedBundleURL: URL? { host.representedBundleURL }
    var desiredResultConfigurationAuthority: GenotypeResultDesiredConfigurationAuthority { host.desiredResultConfigurationAuthority }
    var excelSavePanelPresenter: (NSSavePanel, NSWindow, @escaping (URL?) -> Void) -> Void { host.excelSavePanelPresenter }
    var viewportExportRunner: (GenotypeViewportExportSnapshot, GenotypeViewportExportFormat, URL) async throws -> Void { host.viewportExportRunner }
    var onExcelExportEvent: ((GenotypeExcelExportEvent) -> Void)? { host.onExcelExportEvent }

    func activeHaplotypeAnalysis() -> GenotypeHaplotypeAnalysis? { host.activeHaplotypeAnalysis() }
    func definitionSetForResult(_ result: ONTGenotypeResultBundleData) -> GenotypeHaplotypeDefinitionSet? { host.definitionSetForResult(result) }
    func activeHaplotypeDefinitionSetID() -> String? { host.activeHaplotypeDefinitionSetID() }
    func effectiveHaplotypeCall(sample: String, call: GenotypeHaplotypeLocusCall) -> GenotypeResultViewController.EffectiveHaplotypeCall { host.effectiveHaplotypeCall(sample: sample, call: call) }
    func ensureComparisonMatrixConfigured() { host.ensureComparisonMatrixConfigured() }
    func ownsDesiredResultConfiguration(_ authority: GenotypeResultDesiredConfigurationAuthority) -> Bool { host.ownsDesiredResultConfiguration(authority) }
    func deferManualHaplotypeTransition(_ transition: GenotypeManualHaplotypeDraftCoordinator.Transition, mutation: @escaping @MainActor () -> Void) -> Bool { host.deferManualHaplotypeTransition(transition, mutation: mutation) }
}

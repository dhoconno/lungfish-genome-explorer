import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

/// Owns the Excel export path of one GenotypeResultViewController, the one
/// GUI export since 24fe49f05. It settles the view, freezes the Excel
/// capture, presents the save panel, runs the export task and publishes the
/// export events. The controller creates the coordinator once and holds it
/// for its own lifetime, so the coordinator never outlives the controller it
/// reads. It reads controller state only through the forwarders at the end of
/// this file. New export logic belongs here and not in the controller
/// (REVIEW.md R6). CSV and TSV come from `lungfish-cli genotype export`,
/// which takes its calls from the same builder as the workbook.
@MainActor
final class GenotypeViewportExportCoordinator {
    /// The controller this coordinator reads, held without a retain because
    /// the controller is the coordinator's only owner. Two invariants keep
    /// that safe. The three `[weak self]` captures in presentExcelExportPanel
    /// and presentViewExportPanel must stay weak, so a closure that runs after
    /// the controller is gone finds a nil coordinator and returns before any
    /// forwarder reads the controller. And no callback the export path calls,
    /// which are originStillCurrent, settleDisplayState, onExcelExportEvent
    /// and excelSavePanelPresenter, may release the controller synchronously,
    /// because the forwarder read that follows the call would reach a freed
    /// controller. GenotypeViewportExportCoordinatorLifetimeTests pins the
    /// first invariant.
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
                self.presentViewExportPanel(filenameSuffix: "genotype", capturedSnapshot: snapshot,
                    originStillCurrent: originStillCurrent)
            } catch {
                self.publishExcelExportEvent(.failed(GenotypeExcelExportRefusal.message(for: error)))
            }
        }
        if !deferManualHaplotypeTransition(.export, mutation: capture) { capture() }
    }

    /// The retained scientific model and native annotations are authoritative.
    /// Source paths are historical context, never later substitutes for these bytes.
    func captureExcelExportSnapshot() throws -> GenotypeViewportExportSnapshot {
        guard let result else { throw GenotypeExcelSnapshotBuilder.CaptureError.incoherent("no selected result") }
        guard deferredMatrixAnnotationMutationCount == 0 else {
            throw GenotypeExcelExportRefusal.annotationsStillSaving
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

    /// Presents the save panel for a capture frozen before the panel opened
    /// and runs the export task with that capture, so a view change while the
    /// panel is up never reaches the workbook.
    private func presentViewExportPanel(
        filenameSuffix: String,
        capturedSnapshot snapshot: GenotypeViewportExportSnapshot,
        originStillCurrent: @escaping () -> Bool = { true }
    ) {
        guard let result else { return }
        let authority = desiredResultConfigurationAuthority
        let origin = representedBundleURL
        let panel = NSSavePanel()
        panel.title = "Export Genotype View"
        panel.message = "Export Genotype View"
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(result.manifest.outputName)-\(filenameSuffix)-\(timestamp).xlsx"
        panel.allowedContentTypes = [UTType(filenameExtension: "xlsx") ?? .data]
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        excelSavePanelPresenter(panel, view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] url in
            guard let url else { return }
            guard let self, originStillCurrent(), self.representedBundleURL == origin,
                  self.ownsDesiredResultConfiguration(authority) else { return }
            let outputURL = url
            self.publishExcelExportEvent(.started)
            let export = self.viewportExportRunner
            Task { [weak self] in
                do {
                    try await export(snapshot, outputURL)
                    await MainActor.run {
                        guard let self, originStillCurrent(), self.representedBundleURL == origin,
                              self.ownsDesiredResultConfiguration(authority) else { return }
                        self.publishExcelExportEvent(.succeeded(outputURL))
                    }
                } catch {
                    await MainActor.run {
                        guard let self, originStillCurrent(), self.representedBundleURL == origin,
                              self.ownsDesiredResultConfiguration(authority) else { return }
                        self.publishExcelExportEvent(.failed(error.localizedDescription))
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

    func publishExcelExportEvent(_ event: GenotypeExcelExportEvent) {
        onExcelExportEvent?(event)
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
}

// The controller state the export reads. Each line forwards one member to the
// controller under the member's own name, so every line above reads as it did
// in the controller and a new controller dependency shows up as a new line here.
private extension GenotypeViewportExportCoordinator {
    var result: ONTGenotypeResultBundleData? { host.result }
    var annotationStore: GenotypeAnnotationStore? { host.annotationStore }
    var selectedLens: GenotypeResultViewportLens { host.selectedLens }
    var displayState: GenotypeResultDisplayState { host.displayState }
    var activeSmartCohort: GenotypeCohortSmartFilter? { host.activeSmartCohort }
    var quickFilterState: GenotypeQuickFilterBarView.FilterState { host.quickFilterState }
    var quickFilterSearchText: String { host.quickFilterSearchText }
    var deferredMatrixAnnotationMutationCount: Int { host.deferredMatrixAnnotationMutationCount }
    var comparisonMatrix: GenotypeComparisonMatrixView { host.comparisonMatrix }
    var quickFilterBar: GenotypeQuickFilterBarView { host.quickFilterBar }
    var view: NSView { host.view }
    var representedBundleURL: URL? { host.representedBundleURL }
    var desiredResultConfigurationAuthority: GenotypeResultDesiredConfigurationAuthority { host.desiredResultConfigurationAuthority }
    var excelSavePanelPresenter: (NSSavePanel, NSWindow, @escaping (URL?) -> Void) -> Void { host.excelSavePanelPresenter }
    var viewportExportRunner: (GenotypeViewportExportSnapshot, URL) async throws -> Void { host.viewportExportRunner }
    var onExcelExportEvent: ((GenotypeExcelExportEvent) -> Void)? { host.onExcelExportEvent }

    func activeHaplotypeAnalysis() -> GenotypeHaplotypeAnalysis? { host.activeHaplotypeAnalysis() }
    func definitionSetForResult(_ result: ONTGenotypeResultBundleData) -> GenotypeHaplotypeDefinitionSet? { host.definitionSetForResult(result) }
    func ensureComparisonMatrixConfigured() { host.ensureComparisonMatrixConfigured() }
    func ownsDesiredResultConfiguration(_ authority: GenotypeResultDesiredConfigurationAuthority) -> Bool { host.ownsDesiredResultConfiguration(authority) }
    func deferManualHaplotypeTransition(_ transition: GenotypeManualHaplotypeDraftCoordinator.Transition, mutation: @escaping @MainActor () -> Void) -> Bool { host.deferManualHaplotypeTransition(transition, mutation: mutation) }
}

import AppKit
import SwiftUI

struct PrimerBindingInspectionView: View {
    let contexts: [PrimerBindingInspectionContext]
    var selectedReviewPrimerID: String? = nil
    var visibility = PrimerAnalysisVisibility()
    var reviewTargets: [PrimerTargetDesignReview] = []
    var identityDots: Binding<Bool>? = nil
    @State private var selectedContextID: String?
    @State private var selectedPrimerID: String?
    @State private var localIdentityDots = true
    private var dots: Binding<Bool> { identityDots ?? $localIdentityDots }
    private var showIdentityDots: Bool { dots.wrappedValue }
    private var displayedContexts: [PrimerBindingInspectionContext] {
        reviewTargets.isEmpty ? contexts : contexts.map { visibility.filtering($0, targets: reviewTargets) }
    }

    private var context: PrimerBindingInspectionContext? {
        displayedContexts.first { $0.id == selectedContextID } ?? displayedContexts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Alignment & primer sites").font(.title2.weight(.semibold))
                .help("Stored primer footprints are mapped from the design reference. The consensus summarizes the supplied alignment rows.")
            if let context {
                Picker("Target alignment", selection: Binding(get: { context.id }, set: { selectedContextID = $0; selectedPrimerID = nil })) {
                    ForEach(displayedContexts) { Text($0.title).tag($0.id) }
                }
                if let reason = context.unavailableReason {
                    Text(reason).foregroundStyle(.secondary)
                }
                let primer = Self.resolvePrimer(in: context, selectedID: selectedPrimerID)
                let track = primer.flatMap { try? context.displayTrack(for: $0, showIdentityDots: showIdentityDots) }
                if !context.primers.isEmpty {
                    Picker("Compare primer", selection: Binding(get: { primer?.id ?? "" }, set: { selectedPrimerID = $0 })) {
                        Text("Choose a visible primer").tag("")
                        ForEach(context.primers) { Text($0.name).tag($0.id) }
                    }
                }
                if primer != nil {
                    if identityDots == nil {
                        Toggle("Show matching observed bases as dots", isOn: dots).disabled(track == nil)
                    }
                    Text(track?.label ?? "Primer sequence track unavailable: sequence length and mapped columns do not agree.")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                PrimerBindingAlignmentCanvas(context: context, selectedPrimerID: primer?.id, track: track)
                    .frame(minHeight: 200, idealHeight: 320, maxHeight: 400)
                    .border(Color.secondary.opacity(0.25))
                    .help(Self.legend(hasTrack: track != nil, showIdentityDots: showIdentityDots))
                    .accessibilityIdentifier("primerAnalysisViewer.bindingAlignment")
                if let primer {
                    Text("5′ \(primer.sequence) 3′ · strand \(primer.strand) · alignment columns \(primer.alignedStart + 1)–\(primer.alignedEnd)")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    PrimerBindingComparisonTable(context: context, primer: primer)
                        .frame(minHeight: 100, idealHeight: 180, maxHeight: .infinity, alignment: .topLeading)
                } else if context.unavailableReason == nil {
                    Text(!context.primers.isEmpty ? "The selected primer is hidden or unavailable. Choose a visible primer above or adjust Inspector → View."
                         : contexts.first(where: { $0.id == context.id })?.primers.isEmpty == false
                         ? "All primer sites for this alignment are hidden. Use Show all in Inspector → View to restore them."
                         : "No primer sites were returned for this alignment.").foregroundStyle(.secondary)
                }
            } else {
                Text("Alignment binding inspection is available for stored PrimalScheme results with a verified input alignment and reference mapping.")
                    .foregroundStyle(.secondary)
            }
        }.onAppear {
            adoptReviewSelection()
            if selectedPrimerID == nil { selectedPrimerID = context?.primers.first?.id }
        }
        .onChange(of: selectedReviewPrimerID) { _, _ in adoptReviewSelection() }
    }

    nonisolated static func resolvePrimer(in context: PrimerBindingInspectionContext,
                                          selectedID: String?) -> PrimerBindingInspectionPrimer? {
        guard let selectedID else { return context.primers.first }
        return context.primers.first { $0.id == selectedID }
    }

    nonisolated static func legend(hasTrack: Bool, showIdentityDots: Bool) -> String {
        let comparison: String
        if !hasTrack {
            comparison = "No primer comparison track is available. The alignment retains its standard display."
        } else if showIdentityDots {
            comparison = "Dots: compatible observed bases within the primer site. Letters in the site: differences or unknowns; outside: original bases."
        } else {
            comparison = "Letters: original bases, including matches, differences and unknowns."
        }
        return comparison + " –: alignment gap. Purple ruler marks: variable MSA columns. Orange overview: gap-bearing columns. Underline: saved primer footprint."
            + (hasTrack ? " Zoomed-out difference colors show known primer mismatches only." : "")
    }

    private func adoptReviewSelection() {
        guard let selectedReviewPrimerID else { return }
        guard let requested = Self.bindingSelection(for: selectedReviewPrimerID, contexts: contexts) else {
            selectedPrimerID = "" // Explicit unavailable request; never substitute the first visible oligo.
            return
        }
        selectedContextID = requested.contextID
        selectedPrimerID = requested.primerID
    }

    nonisolated static func bindingSelection(for reviewID: String, contexts: [PrimerBindingInspectionContext])
      -> (contextID: String, primerID: String)? {
        // Adopt identity from the saved records, including hidden members. Rendering resolves
        // that exact identity against the displayed set and shows an unavailable state if hidden.
        for context in contexts {
            if let primer = context.primers.first(where: { $0.reviewPrimerID == reviewID }) {
                return (context.id, primer.id)
            }
        }
        return nil
    }
}

private struct PrimerBindingAlignmentCanvas: NSViewControllerRepresentable {
    let context: PrimerBindingInspectionContext
    let selectedPrimerID: String?
    let track: MSAReadOnlyPrimerTrack?

    final class Coordinator {
        var loadedID: String?
        var loadedAnnotationIDs: [String] = []
        var focusedPrimerID: String?
        var loadedTrack: MSAReadOnlyPrimerTrack?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSViewController(context: Context) -> MultipleSequenceAlignmentViewController {
        MultipleSequenceAlignmentViewController()
    }

    func updateNSViewController(_ controller: MultipleSequenceAlignmentViewController, context: Context) {
        do {
            let annotationIDs = self.context.annotations.map(\.id)
            if context.coordinator.loadedID != self.context.id || context.coordinator.loadedAnnotationIDs != annotationIDs {
                try controller.displayReadOnlyAlignment(fasta: self.context.alignedFASTA, annotations: self.context.annotations)
                context.coordinator.loadedID = self.context.id
                context.coordinator.loadedAnnotationIDs = annotationIDs
                context.coordinator.focusedPrimerID = nil
                context.coordinator.loadedTrack = nil
            }
            if context.coordinator.loadedTrack != track {
                controller.applyReadOnlyPrimerTrack(track)
                context.coordinator.loadedTrack = track
            }
            if let selectedPrimerID, selectedPrimerID != context.coordinator.focusedPrimerID {
                controller.focusReadOnlyAnnotation(id: selectedPrimerID)
                context.coordinator.focusedPrimerID = selectedPrimerID
            }
        } catch {
            // Validated snapshot parsing normally prevents this; surface failures in the viewport.
            let message = NSTextField(wrappingLabelWithString: "Alignment could not be displayed: \(error.localizedDescription)")
            controller.view = message
        }
    }
}

private struct PrimerBindingComparisonTable: View {
    let context: PrimerBindingInspectionContext
    let primer: PrimerBindingInspectionPrimer
    @State private var comparisons: [PrimerBindingRowComparison] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var compatibility: PrimerMSACompatibilitySummary {
        PrimerMSACompatibilitySummary(
            matchingRows: comparisons.filter { $0.mismatchCount == 0 }.count,
            assessableRows: comparisons.filter { $0.mismatchCount != nil }.count,
            totalRows: comparisons.count)
    }

    private func highlightedSite(_ row: PrimerBindingRowComparison) -> Text {
        let mismatches = Set(row.mismatchPositions)
        return row.alignedSite.enumerated().reduce(Text("")) { text, entry in
            let base = Text(String(entry.element))
            return text + (mismatches.contains(entry.offset) ? base.foregroundColor(.orange).bold().underline() : base)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isLoading {
                ProgressView("Comparing selected primer…").controlSize(.small)
            } else if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(compatibility.label)
                    .font(.subheadline.weight(.medium)).monospacedDigit()
                    .help(compatibility.help)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 14) {
                            Text("Alignment row").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Reference-oriented site").frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.caption.weight(.semibold))
                        ForEach(comparisons) { row in
                            HStack(alignment: .top, spacing: 14) {
                                Text(row.rowName).frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(row.status).foregroundStyle(row.mismatchCount.map { $0 > 0 } == true ? Color.orange : Color.secondary)
                                    highlightedSite(row).font(.system(.caption, design: .monospaced))
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.caption).padding(.vertical, 4).textSelection(.enabled)
                        }
                    }
                }.accessibilityIdentifier("primerAnalysisViewer.bindingRows")
            }
        }.task(id: primer.id) {
            comparisons = []
            isLoading = true
            errorMessage = nil
            let inspectionContext = context
            let selectedPrimer = primer
            let worker = Task.detached(priority: .userInitiated) {
                try inspectionContext.comparisons(for: selectedPrimer)
            }
            do {
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                comparisons = result
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                isLoading = false
                errorMessage = "Sequence comparison could not be loaded: " + error.localizedDescription
            }
        }
    }
}

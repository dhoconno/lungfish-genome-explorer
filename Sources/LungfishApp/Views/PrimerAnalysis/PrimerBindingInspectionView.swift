import AppKit
import SwiftUI

struct PrimerBindingInspectionView: View {
    let contexts: [PrimerBindingInspectionContext]
    var selectedReviewPrimerID: String? = nil
    @State private var selectedContextID: String?
    @State private var selectedPrimerID: String?

    private var context: PrimerBindingInspectionContext? {
        contexts.first { $0.id == selectedContextID } ?? contexts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Alignment & primer sites").font(.title2.weight(.semibold))
            Text("Inspect stored primer footprints beside the alignment consensus. Footprints are mapped from the design reference; the consensus is a visual summary of the supplied rows.")
                .font(.caption).foregroundStyle(.secondary)
            if let context {
                Picker("Target alignment", selection: Binding(get: { context.id }, set: { selectedContextID = $0; selectedPrimerID = nil })) {
                    ForEach(contexts) { Text($0.title).tag($0.id) }
                }
                if let reason = context.unavailableReason {
                    Text(reason).foregroundStyle(.secondary)
                }
                PrimerBindingAlignmentCanvas(context: context, selectedPrimerID: selectedPrimerID)
                    .frame(minHeight: 200, idealHeight: 320, maxHeight: 400)
                    .border(Color.secondary.opacity(0.25))
                    .accessibilityIdentifier("primerAnalysisViewer.bindingAlignment")
                if let primer = context.primers.first(where: { $0.id == selectedPrimerID }) ?? context.primers.first {
                    Picker("Compare primer", selection: Binding(get: { primer.id }, set: { selectedPrimerID = $0 })) {
                        ForEach(context.primers) { Text($0.name).tag($0.id) }
                    }
                    Text("5′ \(primer.sequence) 3′ · strand \(primer.strand) · alignment columns \(primer.alignedStart + 1)–\(primer.alignedEnd)")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("Sequence comparison at the mapped site. Reverse primers are compared in reverse-complement orientation. Zero mismatches means sequence compatibility, not measured amplification. Gaps and ambiguous target bases remain unresolved.")
                        .font(.caption).foregroundStyle(.secondary)
                    PrimerBindingComparisonTable(context: context, primer: primer)
                        .frame(minHeight: 100, idealHeight: 180, maxHeight: .infinity, alignment: .topLeading)
                } else if context.unavailableReason == nil {
                    Text("No primer sites were returned for this alignment.").foregroundStyle(.secondary)
                }
            } else {
                Text("Alignment binding inspection is available for stored PrimalScheme results with a verified input alignment and reference mapping.")
                    .foregroundStyle(.secondary)
            }
        }.onAppear { adoptReviewSelection() }
        .onChange(of: selectedReviewPrimerID) { _, _ in adoptReviewSelection() }
    }

    private func adoptReviewSelection() {
        guard let selectedReviewPrimerID,
          let context = contexts.first(where: { $0.primers.contains { $0.reviewPrimerID == selectedReviewPrimerID } }),
          let primer = context.primers.first(where: { $0.reviewPrimerID == selectedReviewPrimerID }) else { return }
        selectedContextID = context.id
        selectedPrimerID = primer.id
    }
}

private struct PrimerBindingAlignmentCanvas: NSViewControllerRepresentable {
    let context: PrimerBindingInspectionContext
    let selectedPrimerID: String?

    final class Coordinator {
        var loadedID: String?
        var focusedPrimerID: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSViewController(context: Context) -> MultipleSequenceAlignmentViewController {
        MultipleSequenceAlignmentViewController()
    }

    func updateNSViewController(_ controller: MultipleSequenceAlignmentViewController, context: Context) {
        do {
            if context.coordinator.loadedID != self.context.id {
                try controller.displayReadOnlyAlignment(fasta: self.context.alignedFASTA, annotations: self.context.annotations)
                context.coordinator.loadedID = self.context.id
                context.coordinator.focusedPrimerID = nil
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

    private func highlightedSite(_ row: PrimerBindingRowComparison) -> Text {
        let mismatches = Set(row.mismatchPositions)
        return row.alignedSite.enumerated().reduce(Text("")) { text, entry in
            let base = Text(String(entry.element))
            return text + (mismatches.contains(entry.offset) ? base.foregroundColor(.orange).bold().underline() : base)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(context.rows.count) alignment rows · sites shown in reference orientation")
                .font(.caption).foregroundStyle(.secondary)
            if isLoading {
                ProgressView("Comparing selected primer…").controlSize(.small)
            } else if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.secondary)
            } else {
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

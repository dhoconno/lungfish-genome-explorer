import AppKit
import Foundation
import SwiftUI

struct PrimalSchemeResultsView: View {
  @Environment(\.primerAnalysisVisibility) private var visibility
  let results: [PrimalSchemeDisplayResult]
  var engineDescription: String = "PrimalScheme3"
  var reviewTargets: [PrimerTargetDesignReview] = []
  var selection: Binding<PrimerReviewSelection?> = .constant(nil)
  var onInspectSelection: () -> Void = {}
  @State private var selectedResultID: String?
  @State private var localSelection: PrimerReviewSelection?

  private var activeSelection: Binding<PrimerReviewSelection?> {
    Binding(get: { selection.wrappedValue ?? localSelection }, set: { selection.wrappedValue = $0; localSelection = $0 })
  }

  private var selectedTarget: PrimerTargetDesignReview? {
    reviewTargets.first { $0.id == activeSelection.wrappedValue?.targetID }
  }

  private var result: PrimalSchemeDisplayResult? {
    results.first { $0.id == selectedTarget?.sourceResultID }
      ?? results.first { $0.id == selectedResultID } ?? results.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Selected scheme oligos").font(.title2.weight(.semibold))
      Picker("Selected scheme", selection: Binding(get: { result?.id }, set: { id in
        selectedResultID = id
        if let chosen = results.first(where: { $0.id == id }), let primer = chosen.primers.first {
          select(primer, in: chosen)
        } else { activeSelection.wrappedValue = nil }
      })) {
        ForEach(results) { Text($0.title).tag(Optional($0.id)) }
      }
      if let result { schemeResults(result) }
    }
  }

  private func schemeResults(_ result: PrimalSchemeDisplayResult) -> some View {
    let pools = Set(result.primers.map(\.pool)).sorted()
    let visible = result.primers.filter { primer in
      let review = target(for: primer, in: result)
      guard let record = review.primers.first(where: { $0.id == "\(result.id)-primer-\(primer.id)" }) else { return false }
      return visibility.isVisible(record, in: review)
    }
    let selected = result.primers.first { "\(result.id)-primer-\($0.id)" == activeSelection.wrappedValue?.primerID }
      ?? result.primers.first { $0.reference == selectedTarget?.referenceID } ?? visible.first
    return VStack(alignment: .leading, spacing: 16) {
      Text("\(result.primers.count) selected oligos · \(pools.count) pools · \(Set(result.primers.map(\.reference)).count) references")
        .font(.caption).foregroundStyle(.secondary)
      if let orderSheetURL = result.orderSheetURL {
        Button("Show saved order sheet…") { NSWorkspace.shared.activateFileViewerSelecting([orderSheetURL]) }
          .help("Opens the complete saved scheme, including oligos hidden from this viewport. Use the displayed-order action in Inspector for the currently shown set.")
          .accessibilityIdentifier("primerAnalysisViewer.orderSheet")
      } else {
        Text("This saved analysis has no ordering worksheet. Its native primer records remain available in the Inspector’s Files tab.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Group {
        if let selectedTarget, selectedTarget.sourceResultID == result.id {
          PrimerTargetReviewCard(target: selectedTarget, selection: activeSelection)
        } else if let selected {
          let target = target(for: selected, in: result)
          PrimerTargetReviewCard(target: target, selection: activeSelection)
        }
      }.id(PrimerReviewSelection.selectedDesignAnchor)
      Text("\(visible.count) of \(result.primers.count) selected oligos displayed")
        .font(.caption).foregroundStyle(.secondary)
        .help("Inspector → View controls visible pools and variants. Select a primer to inspect its saved amplicon, reference span, pool and sequence.")
      if visible.isEmpty { Text(result.primers.isEmpty ? "No primer records were returned." : "All oligos are hidden by display filters. Use Show all in Inspector → View to restore them.").foregroundStyle(.secondary) }
      ForEach(pools.filter { pool in visible.contains { $0.pool == pool } }, id: \.self) { pool in
        let members = visible.filter { $0.pool == pool }
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Text("Pool \(pool)").font(.headline)
            Spacer()
            Text("\(members.count) oligos · \(members.reduce(0) { $0 + $1.sequence.count }) nt total")
              .font(.caption).foregroundStyle(.secondary)
          }
          ForEach(members) { primer in
            Button { select(primer, in: result); onInspectSelection() } label: {
              VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 14) {
                  Text(primer.name).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
                  Text("\(primer.sequence.count) nt · \(primer.gcLabel)").font(.caption)
                }
                Text(primer.sequence.uppercased()).font(.system(.caption, design: .monospaced))
                Text("\(primer.referenceLabel) · \(primer.start + 1)–\(primer.end) (\(primer.strand))")
                  .font(.caption).foregroundStyle(.secondary)
                compatibility(for: "\(result.id)-primer-\(primer.id)")
                if primer.ambiguousBaseCount > 0 {
                  Text("\(primer.ambiguousBaseCount) ambiguous bases — review synthesis representation")
                    .font(.caption).foregroundStyle(.orange)
                }
              }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                .background(activeSelection.wrappedValue?.primerID == "\(result.id)-primer-\(primer.id)" ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain)
              .contextMenu {
                let review = target(for: primer, in: result)
                if let record = review.primers.first(where: { $0.id == "\(result.id)-primer-\(primer.id)" }) {
                  PrimerReviewContextMenu(target: review, item: .primer(record), selection: activeSelection)
                }
              }
              .accessibilityIdentifier("primerResults.primer.\(result.id)-\(primer.id)")
          }
        }
      }
    }
  }

  @ViewBuilder private func compatibility(for primerID: String) -> some View {
    if let summary = visibility.summaries[primerID] {
      Text(summary.label).help(summary.help)
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
    } else if visibility.isComputingCompatibility {
      Text("Calculating MSA matches…").font(.caption).foregroundStyle(.secondary)
    } else {
      Text("MSA matches: unavailable").font(.caption).foregroundStyle(.secondary)
        .help("This saved primer has no assessable MSA comparison.")
    }
  }

  private func select(_ primer: PrimalSchemeDisplayPrimer, in result: PrimalSchemeDisplayResult) {
    let target = target(for: primer, in: result)
    guard let reviewPrimer = target.primers.first(where: { $0.id == "\(result.id)-primer-\(primer.id)" }) else { return }
    activeSelection.wrappedValue = .selecting(primer: reviewPrimer, in: target)
  }

  private func target(for primer: PrimalSchemeDisplayPrimer, in result: PrimalSchemeDisplayResult) -> PrimerTargetDesignReview {
    reviewTargets.first { $0.sourceResultID == result.id && $0.referenceID == primer.reference }
      ?? PrimerTargetDesignReview(id: "\(result.id)-\(primer.reference)", label: "\(result.title) · \(primer.referenceLabel)",
        referenceLength: primer.referenceLength, coverageLabel: "Reference spanned by amplicons", coveredBases: nil, intervals: [],
        primers: result.primers.filter { $0.reference == primer.reference }.map {
          PrimerReviewPrimer(id: "\(result.id)-primer-\($0.id)", name: $0.name, start: $0.start, end: $0.end, strand: $0.strand, pool: $0.pool, sequence: $0.sequence)
        }, notes: [], sourceResultID: result.id, referenceID: primer.reference)
  }
}

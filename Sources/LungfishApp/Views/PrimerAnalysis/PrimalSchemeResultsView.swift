import AppKit
import Foundation
import SwiftUI

struct PrimalSchemeResultsView: View {
  let results: [PrimalSchemeDisplayResult]
  var engineDescription: String = "PrimalScheme3"
  var reviewTargets: [PrimerTargetDesignReview] = []
  var selection: Binding<PrimerReviewSelection?> = .constant(nil)
  var onInspectSelection: () -> Void = {}
  @State private var selectedResultID: String?
  @State private var selectedPool: Int?
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
      Text("\(engineDescription) results").font(.title2.weight(.semibold))
      Picker("Stored scheme", selection: Binding(get: { result?.id }, set: { id in
        selectedResultID = id
        selectedPool = nil
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
    let visible = result.primers.filter { selectedPool == nil || $0.pool == selectedPool }
    let selected = result.primers.first { "\(result.id)-primer-\($0.id)" == activeSelection.wrappedValue?.primerID }
      ?? result.primers.first { $0.reference == selectedTarget?.referenceID } ?? visible.first
    return VStack(alignment: .leading, spacing: 16) {
      Text("\(result.primers.count) primer records · \(pools.count) pools · \(Set(result.primers.map(\.reference)).count) references")
        .font(.caption).foregroundStyle(.secondary)
      if let orderSheetURL = result.orderSheetURL {
        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 5) {
            Text("Prepare primer pools for ordering").font(.headline)
            Text("The stored CSV includes every oligo, grouped by pool, with 5′–3′ sequences. Alternatives remain separate. Copy the sheet before filling in your synthesis scale, purification or modifications.")
              .font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Button("Show order sheet…") { NSWorkspace.shared.activateFileViewerSelecting([orderSheetURL]) }
            .accessibilityIdentifier("primerAnalysisViewer.orderSheet")
        }.padding(12).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
      } else {
        Text("This saved analysis has no ordering worksheet. Its native primer records remain available in the Inspector’s Files tab.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Text("Pool numbers apply within this stored scheme. Review alternative and ambiguous oligos individually; no synthesis quantities are inferred.")
        .font(.caption).foregroundStyle(.secondary)
      Group {
        if let selectedTarget, selectedTarget.sourceResultID == result.id {
          PrimerTargetReviewCard(target: selectedTarget, selection: activeSelection)
        } else if let selected {
          let target = target(for: selected, in: result)
          PrimerTargetReviewCard(target: target, selection: activeSelection)
        }
      }.id(PrimerReviewSelection.selectedDesignAnchor)
      Picker("Pool", selection: $selectedPool) {
        Text("All pools").tag(nil as Int?)
        ForEach(pools, id: \.self) { Text("Pool \($0)").tag(Optional($0)) }
      }.onChange(of: selectedPool) {
        if let first = result.primers.first(where: { selectedPool == nil || $0.pool == selectedPool }) {
          select(first, in: result)
        }
      }
      Text("Select a primer to inspect its amplicon, reference span and pool. Native coordinates and identifiers are preserved in the Inspector’s Files tab.")
        .font(.caption).foregroundStyle(.secondary)
      if visible.isEmpty { Text("No primer records were returned.").foregroundStyle(.secondary) }
      ForEach(pools.filter { selectedPool == nil || $0 == selectedPool }, id: \.self) { pool in
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

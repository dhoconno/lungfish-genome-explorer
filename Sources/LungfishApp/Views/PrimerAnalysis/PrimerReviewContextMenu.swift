import AppKit
import SwiftUI

struct PrimerReviewContextActions {
  var targets: [PrimerTargetDesignReview] = []
  var bindingPrimerIDs: Set<String> = []
  var onInspectDetails: (() -> Void)?
  var onInspectBinding: ((PrimerReviewSelection) -> Void)?
  var onExportRequested: ((PrimerAnalysisExportSelection, PrimerAnalysisExportKind) -> Void)?
}

private struct PrimerReviewContextActionsKey: EnvironmentKey {
  static var defaultValue: PrimerReviewContextActions { .init() }
}

extension EnvironmentValues {
  var primerReviewActions: PrimerReviewContextActions {
    get { self[PrimerReviewContextActionsKey.self] }
    set { self[PrimerReviewContextActionsKey.self] = newValue }
  }
}

/// Menu commands capture the clicked record, never the previously selected record.
/// Saved-file actions are provided by the originating project controller.
struct PrimerReviewContextMenu: View {
  enum Item {
    case primer(PrimerReviewPrimer)
    case amplicon(PrimerReviewInterval)
  }

  let target: PrimerTargetDesignReview
  let item: Item
  let selection: Binding<PrimerReviewSelection?>
  @Environment(\.primerReviewActions) private var actions

  var body: some View {
    switch item {
    case .primer(let primer): primerMenu(primer)
    case .amplicon(let interval): ampliconMenu(interval)
    }
  }

  private func primerMenu(_ primer: PrimerReviewPrimer) -> some View {
    let clicked = PrimerReviewSelection.selecting(primer: primer, in: target)
    let fasta = PrimerReviewClipboard.primerFASTA(primer, in: target)
    let associated = target.intervals.first { $0.id == clicked.ampliconID }
    return Group {
      summary(primer.name)
      summary("\(primer.sequence.count) nt · \(primer.name == "Internal probe" ? "Probe" : primer.strand == "+" ? "Forward (+)" : "Reverse (−)") · \(poolLabel(primer.pool))")
      summary("Binding site \(primer.start + 1)–\(primer.end) · 1-based inclusive")
      Divider()
      Button("Inspect Primer") { inspect(clicked) }
      Button("Inspect in Alignment") { inspectBinding(clicked) }
        .disabled(!actions.bindingPrimerIDs.contains(primer.id) || actions.onInspectBinding == nil)
      Menu("Copy") {
        Button("Copy Name") { copy(primer.name, clicked: clicked) }
        Button("Copy Coordinates") { copy(PrimerReviewClipboard.coordinates(primer, in: target), clicked: clicked) }
        Divider()
        Button("Copy Sequence (5′–3′)") { copy(PrimerReviewClipboard.sequence(primer), clicked: clicked) }
          .disabled(PrimerReviewClipboard.sequence(primer) == nil)
        Button("Copy as FASTA") { copy(fasta, clicked: clicked) }.disabled(fasta == nil)
        if let associated {
          Button("Copy Associated Oligos as FASTA") {
            copy(PrimerReviewClipboard.ampliconFASTA(associated, in: target), clicked: clicked)
          }.disabled(PrimerReviewClipboard.ampliconFASTA(associated, in: target) == nil)
        }
        poolCopy(primer.pool, clicked: clicked)
      }
      Divider()
      Button("Save Primer FASTA Bundle in Project") {
        export(.primer(targetID: target.id, primerID: primer.id), kind: .primerFASTA, clicked: clicked)
      }.disabled(actions.onExportRequested == nil || fasta == nil)
      poolSave(primer.pool, clicked: clicked)
      if let associated {
        Button("Extract Reference Amplicon Bundle in Project") {
          export(.amplicon(targetID: target.id, ampliconID: associated.id), kind: .referenceAmplicon, clicked: clicked)
        }.disabled(actions.onExportRequested == nil)
      }
    }
  }

  private func ampliconMenu(_ interval: PrimerReviewInterval) -> some View {
    let clicked = PrimerReviewSelection(targetID: target.id, primerID: nil, ampliconID: interval.id)
    let members = PrimerReviewClipboard.ampliconPrimers(interval, in: target)
    let fasta = PrimerReviewClipboard.ampliconFASTA(interval, in: target)
    return Group {
      summary(interval.name)
      summary("\(interval.length) bp · \(poolLabel(interval.pool))")
      summary("\(interval.sizeLabel) · \(interval.start + 1)–\(interval.end)")
      summary(members.map { "\($0.count) associated oligos; alternatives retained" } ?? "Primer correspondence unavailable")
      Divider()
      Button("Inspect Amplicon") { inspect(clicked) }
      if let members {
        let inspectable = members.filter { actions.bindingPrimerIDs.contains($0.id) }
        if !inspectable.isEmpty {
          Menu("Inspect Primer in Alignment") {
            ForEach(inspectable) { primer in
              Button(primer.name) { inspectBinding(.selecting(primer: primer, in: target)) }
            }
          }.disabled(actions.onInspectBinding == nil)
        }
      }
      Menu("Copy") {
        Button("Copy Name") { copy(interval.name, clicked: clicked) }
        Button("Copy Coordinates") { copy(PrimerReviewClipboard.coordinates(interval, in: target), clicked: clicked) }
        Divider()
        Button("Copy Associated Oligos as FASTA") { copy(fasta, clicked: clicked) }.disabled(fasta == nil)
        poolCopy(interval.pool, clicked: clicked)
      }
      Divider()
      Button("Save Associated Primer FASTA Bundle in Project") {
        export(.amplicon(targetID: target.id, ampliconID: interval.id), kind: .primerFASTA, clicked: clicked)
      }.disabled(actions.onExportRequested == nil || fasta == nil)
      poolSave(interval.pool, clicked: clicked)
      Button("Extract Reference Amplicon Bundle in Project") {
        export(.amplicon(targetID: target.id, ampliconID: interval.id), kind: .referenceAmplicon, clicked: clicked)
      }.disabled(actions.onExportRequested == nil)
    }
  }

  @ViewBuilder
  private func poolSave(_ pool: Int?, clicked: PrimerReviewSelection) -> some View {
    if let pool {
      let fasta = PrimerReviewClipboard.poolFASTA(sourceResultID: target.sourceResultID, pool: pool, targets: actions.targets)
      Button("Save Pool \(pool) Primer FASTA Bundle in Project") {
        export(.pool(sourceResultID: target.sourceResultID, pool: pool), kind: .primerFASTA, clicked: clicked)
      }.disabled(actions.onExportRequested == nil || fasta == nil)
    }
  }

  @ViewBuilder
  private func poolCopy(_ pool: Int?, clicked: PrimerReviewSelection) -> some View {
    if let pool {
      let fasta = PrimerReviewClipboard.poolFASTA(sourceResultID: target.sourceResultID, pool: pool, targets: actions.targets)
      Button("Copy All Pool \(pool) Oligos as FASTA") { copy(fasta, clicked: clicked) }.disabled(fasta == nil)
    }
  }

  private func summary(_ title: String) -> some View { Button(title) {}.disabled(true) }
  private func poolLabel(_ pool: Int?) -> String { pool.map { "Pool \($0)" } ?? "Not pooled" }

  private func inspect(_ clicked: PrimerReviewSelection) {
    selection.wrappedValue = clicked
    actions.onInspectDetails?()
  }

  private func inspectBinding(_ clicked: PrimerReviewSelection) {
    selection.wrappedValue = clicked
    actions.onInspectBinding?(clicked)
  }

  private func copy(_ text: String?, clicked: PrimerReviewSelection) {
    guard let text else { return }
    selection.wrappedValue = clicked
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func export(_ exportSelection: PrimerAnalysisExportSelection, kind: PrimerAnalysisExportKind,
                      clicked: PrimerReviewSelection) {
    selection.wrappedValue = clicked
    actions.onExportRequested?(exportSelection, kind)
  }
}

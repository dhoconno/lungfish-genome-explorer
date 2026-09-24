import AppKit
import LungfishWorkflow
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
      summary("\(primer.sequence.count) nt · \(primer.role == .probe ? "Probe" : primer.strand == "+" ? "Forward (+)" : "Reverse (−)") · \(primer.poolLabel ?? poolLabel(primer.pool))")
      summary("Binding site \(primer.start + 1)–\(primer.end) · 1-based inclusive")
      if target.presentation == .schemeReference {
        summary(candidateLabel(primer.candidateStatus, rank: primer.rank, noun: "assay oligo"))
      }
      Divider()
      Button("Inspect Primer") { inspect(clicked) }
      if target.presentation != .primer3Template {
        Button("Inspect in Alignment") { inspectBinding(clicked) }
          .disabled(!actions.bindingPrimerIDs.contains(primer.id) || actions.onInspectBinding == nil)
      }
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
        if let pool = primer.nativePool { poolCopy(pool, clicked: clicked) }
      }
      Divider()
      Button("Save Primer FASTA Bundle in Project") {
        export(.primer(targetID: target.id, primerID: primer.id), kind: .primerFASTA, clicked: clicked)
      }.disabled(actions.onExportRequested == nil || fasta == nil)
      if let pool = primer.nativePool { poolSave(pool, clicked: clicked) }
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
      summary("\(interval.length) bp · \(interval.poolLabel ?? poolLabel(interval.pool))")
      summary("\(interval.sizeLabel) · \(interval.start + 1)–\(interval.end)")
      summary(members.map { target.presentation == .schemeReference
        ? candidateMembershipLabel(count: $0.count, status: interval.candidateStatus, rank: interval.rank)
        : "\($0.count) associated oligos" } ?? "Primer correspondence unavailable")
      Divider()
      Button("Inspect Amplicon") { inspect(clicked) }
      if target.presentation != .primer3Template, let members {
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
        if let pool = interval.nativePool { poolCopy(pool, clicked: clicked) }
      }
      Divider()
      Button("Save Associated Primer FASTA Bundle in Project") {
        export(.amplicon(targetID: target.id, ampliconID: interval.id), kind: .primerFASTA, clicked: clicked)
      }.disabled(actions.onExportRequested == nil || fasta == nil)
      if let pool = interval.nativePool { poolSave(pool, clicked: clicked) }
      Button("Extract Reference Amplicon Bundle in Project") {
        export(.amplicon(targetID: target.id, ampliconID: interval.id), kind: .referenceAmplicon, clicked: clicked)
      }.disabled(actions.onExportRequested == nil)
    }
  }

  @ViewBuilder
  private func poolSave(_ pool: String, clicked: PrimerReviewSelection) -> some View {
    let fasta = PrimerReviewClipboard.poolFASTA(sourceResultID: target.sourceResultID, nativePool: pool, targets: actions.targets)
    Button("Save Pool \(pool) Primer FASTA Bundle in Project") {
      export(.nativePool(sourceResultID: target.sourceResultID, pool: pool), kind: .primerFASTA, clicked: clicked)
    }.disabled(actions.onExportRequested == nil || fasta == nil)
  }

  @ViewBuilder
  private func poolCopy(_ pool: String, clicked: PrimerReviewSelection) -> some View {
    let fasta = PrimerReviewClipboard.poolFASTA(sourceResultID: target.sourceResultID, nativePool: pool, targets: actions.targets)
    Button("Copy All Pool \(pool) Oligos as FASTA") { copy(fasta, clicked: clicked) }.disabled(fasta == nil)
  }

  private func candidateLabel(_ status: PrimerAssayStatus, rank: Int?, noun: String) -> String {
    let label = status == .selected ? "Selected \(noun)" : "Alternative \(noun)"
    return label + (status == .alternative ? rank.map { " · rank \($0)" } ?? "" : "")
  }

  private func candidateMembershipLabel(count: Int, status: PrimerAssayStatus, rank: Int?) -> String {
    let assay = status == .selected ? "selected assay" : "alternative assay"
    let suffix = status == .alternative ? rank.map { " · rank \($0)" } ?? "" : ""
    return "\(count) \(count == 1 ? "oligo" : "oligos") in \(assay)\(suffix)"
  }

  private func summary(_ title: String) -> some View { Button(title) {}.disabled(true) }
  private func poolLabel(_ pool: Int?) -> String {
    pool.map { "Pool \($0)" } ?? (target.presentation == .primer3Template ? "Candidate pair" : "Not pooled")
  }

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

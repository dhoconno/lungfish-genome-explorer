import AppKit
import LungfishWorkflow
import SwiftUI

struct PrimerReviewContextActions {
  var targets: [PrimerTargetDesignReview] = []
  var bindingPrimerIDs: Set<String> = []
  var onInspectDetails: (() -> Void)?
  var onInspectBinding: ((PrimerReviewSelection) -> Void)?
  var onExportRequested: ((PrimerAnalysisExportSelection, PrimerAnalysisExportKind) -> Void)?
  /// The pasteboard the copy commands write. Tests substitute a private one.
  var pasteboard: NSPasteboard = .general
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
///
/// The menu is built as a list of ``ContextAction``s, so the same commands that
/// the secondary-click menu shows are also published as accessibility actions
/// on the row (see ``SwiftUI/View/primerReviewContextActions(target:item:selection:)``).
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
    ContextActionMenuContent(actions: Self.contextActions(target: target, item: item, selection: selection, context: actions))
  }

  @MainActor
  static func contextActions(
    target: PrimerTargetDesignReview,
    item: Item,
    selection: Binding<PrimerReviewSelection?>,
    context: PrimerReviewContextActions
  ) -> [ContextAction] {
    let builder = Builder(target: target, selection: selection, actions: context)
    switch item {
    case .primer(let primer): return builder.primerActions(primer)
    case .amplicon(let interval): return builder.ampliconActions(interval)
    }
  }

  /// The header lines under the item's name, for an accessibility value.
  @MainActor
  static func summaryLines(
    target: PrimerTargetDesignReview,
    item: Item,
    context: PrimerReviewContextActions = .init()
  ) -> [String] {
    let builder = Builder(target: target, selection: .constant(nil), actions: context)
    switch item {
    case .primer(let primer): return builder.primerSummaryLines(primer)
    case .amplicon(let interval): return builder.ampliconSummaryLines(interval)
    }
  }

  @MainActor
  private struct Builder {
    let target: PrimerTargetDesignReview
    let selection: Binding<PrimerReviewSelection?>
    let actions: PrimerReviewContextActions

    func primerActions(_ primer: PrimerReviewPrimer) -> [ContextAction] {
      let clicked = PrimerReviewSelection.selecting(primer: primer, in: target)
      let fasta = PrimerReviewClipboard.primerFASTA(primer, in: target)
      let associated = target.intervals.first { $0.id == clicked.ampliconID }
      var result: [ContextAction] = [.header(primer.name)] + primerSummaryLines(primer).map { .header($0) }
      result.append(.divider("summary"))
      result.append(.command("Inspect Primer") { inspect(clicked) })
      // Primer3 candidates designed from an alignment carry binding contexts too.
      result.append(.command("Inspect in Alignment", isEnabled: actions.bindingPrimerIDs.contains(primer.id) && actions.onInspectBinding != nil) {
        inspectBinding(clicked)
      })
      var copy: [ContextAction] = [
        .command("Copy Name") { self.copy(primer.name, clicked: clicked) },
        .command("Copy Coordinates") { self.copy(PrimerReviewClipboard.coordinates(primer, in: target), clicked: clicked) },
        .divider("copy-coordinates"),
        .command("Copy Sequence (5′–3′)", isEnabled: PrimerReviewClipboard.sequence(primer) != nil) {
          self.copy(PrimerReviewClipboard.sequence(primer), clicked: clicked)
        },
        .command("Copy as FASTA", isEnabled: fasta != nil) { self.copy(fasta, clicked: clicked) },
      ]
      if let associated {
        let associatedFASTA = PrimerReviewClipboard.ampliconFASTA(associated, in: target)
        copy.append(.command("Copy Associated Oligos as FASTA", isEnabled: associatedFASTA != nil) {
          self.copy(associatedFASTA, clicked: clicked)
        })
      }
      if let pool = primer.nativePool { copy.append(poolCopy(pool, clicked: clicked)) }
      result.append(.submenu("Copy", copy))
      result.append(.divider("export"))
      result.append(.command("Save Primer FASTA Bundle in Project", isEnabled: actions.onExportRequested != nil && fasta != nil) {
        export(.primer(targetID: target.id, primerID: primer.id), kind: .primerFASTA, clicked: clicked)
      })
      if let pool = primer.nativePool { result.append(poolSave(pool, clicked: clicked)) }
      if let associated {
        result.append(.command("Extract Reference Amplicon Bundle in Project", isEnabled: actions.onExportRequested != nil) {
          export(.amplicon(targetID: target.id, ampliconID: associated.id), kind: .referenceAmplicon, clicked: clicked)
        })
      }
      return result
    }

    func ampliconActions(_ interval: PrimerReviewInterval) -> [ContextAction] {
      let clicked = PrimerReviewSelection(targetID: target.id, primerID: nil, ampliconID: interval.id)
      let members = PrimerReviewClipboard.ampliconPrimers(interval, in: target)
      let fasta = PrimerReviewClipboard.ampliconFASTA(interval, in: target)
      var result: [ContextAction] = [.header(interval.name)] + ampliconSummaryLines(interval).map { .header($0) } + [
        .divider("summary"),
        .command("Inspect Amplicon") { inspect(clicked) },
      ]
      if let members {
        let inspectable = members.filter { actions.bindingPrimerIDs.contains($0.id) }
        if !inspectable.isEmpty {
          let enabled = actions.onInspectBinding != nil
          result.append(.submenu("Inspect Primer in Alignment", inspectable.map { primer in
            // The menu lists the bare primer name under its submenu. The
            // accessibility action lists commands flat, so it carries the full
            // phrase on purpose. The id includes the primer id because two
            // primers can share a name.
            .command(primer.name, isEnabled: enabled, accessibilityTitle: "Inspect \(primer.name) in Alignment", id: "inspect-binding-\(primer.id)") {
              inspectBinding(.selecting(primer: primer, in: target))
            }
          }))
        }
      }
      var copy: [ContextAction] = [
        .command("Copy Name") { self.copy(interval.name, clicked: clicked) },
        .command("Copy Coordinates") { self.copy(PrimerReviewClipboard.coordinates(interval, in: target), clicked: clicked) },
        .divider("copy-coordinates"),
        .command("Copy Associated Oligos as FASTA", isEnabled: fasta != nil) { self.copy(fasta, clicked: clicked) },
      ]
      if let pool = interval.nativePool { copy.append(poolCopy(pool, clicked: clicked)) }
      result.append(.submenu("Copy", copy))
      result.append(.divider("export"))
      result.append(.command("Save Associated Primer FASTA Bundle in Project", isEnabled: actions.onExportRequested != nil && fasta != nil) {
        export(.amplicon(targetID: target.id, ampliconID: interval.id), kind: .primerFASTA, clicked: clicked)
      })
      if let pool = interval.nativePool { result.append(poolSave(pool, clicked: clicked)) }
      result.append(.command("Extract Reference Amplicon Bundle in Project", isEnabled: actions.onExportRequested != nil) {
        export(.amplicon(targetID: target.id, ampliconID: interval.id), kind: .referenceAmplicon, clicked: clicked)
      })
      return result
    }

    /// The facts the menu header shows under a primer's name. The marks that
    /// draw primers without text publish the same lines as their accessibility
    /// value, so they do not rest on hover or the menu.
    func primerSummaryLines(_ primer: PrimerReviewPrimer) -> [String] {
      var lines = [
        "\(primer.sequence.count) nt · \(primer.role == .probe ? "Probe" : primer.strand == "+" ? "Forward (+)" : "Reverse (−)") · \(primer.poolLabel ?? poolLabel(primer.pool))",
        "Binding site \(primer.start + 1)–\(primer.end) · 1-based inclusive",
      ]
      if target.presentation == .schemeReference {
        lines.append(candidateLabel(primer.candidateStatus, rank: primer.rank, noun: "assay oligo"))
      }
      return lines
    }

    func ampliconSummaryLines(_ interval: PrimerReviewInterval) -> [String] {
      let members = PrimerReviewClipboard.ampliconPrimers(interval, in: target)
      return [
        "\(interval.length) bp · \(interval.poolLabel ?? poolLabel(interval.pool))",
        "\(interval.sizeLabel) · \(interval.start + 1)–\(interval.end)",
        members.map { target.presentation == .schemeReference
          ? candidateMembershipLabel(count: $0.count, status: interval.candidateStatus, rank: interval.rank)
          : "\($0.count) associated oligos" } ?? "Primer correspondence unavailable",
      ]
    }

    private func poolSave(_ pool: String, clicked: PrimerReviewSelection) -> ContextAction {
      let fasta = PrimerReviewClipboard.poolFASTA(sourceResultID: target.sourceResultID, nativePool: pool, targets: actions.targets)
      return .command("Save Pool \(pool) Primer FASTA Bundle in Project", isEnabled: actions.onExportRequested != nil && fasta != nil) {
        export(.nativePool(sourceResultID: target.sourceResultID, pool: pool), kind: .primerFASTA, clicked: clicked)
      }
    }

    private func poolCopy(_ pool: String, clicked: PrimerReviewSelection) -> ContextAction {
      let fasta = PrimerReviewClipboard.poolFASTA(sourceResultID: target.sourceResultID, nativePool: pool, targets: actions.targets)
      return .command("Copy All Pool \(pool) Oligos as FASTA", isEnabled: fasta != nil) { copy(fasta, clicked: clicked) }
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
      actions.pasteboard.clearContents()
      actions.pasteboard.setString(text, forType: .string)
    }

    private func export(_ exportSelection: PrimerAnalysisExportSelection, kind: PrimerAnalysisExportKind,
                        clicked: PrimerReviewSelection) {
      selection.wrappedValue = clicked
      actions.onExportRequested?(exportSelection, kind)
    }
  }
}

extension View {
  /// Attaches the primer review menu to a row as a context menu and as
  /// accessibility actions, so every command is reachable without a
  /// secondary click.
  func primerReviewContextActions(
    target: PrimerTargetDesignReview,
    item: PrimerReviewContextMenu.Item,
    selection: Binding<PrimerReviewSelection?>
  ) -> some View {
    modifier(PrimerReviewContextActionsModifier(target: target, item: item, selection: selection))
  }
}

extension View {
  /// The same, for rows whose record is resolved when the menu is built. A
  /// row that resolves to nothing gets no menu and no actions.
  func primerReviewContextActions(
    selection: Binding<PrimerReviewSelection?>,
    resolve: @escaping () -> (PrimerTargetDesignReview, PrimerReviewContextMenu.Item)?
  ) -> some View {
    modifier(PrimerReviewContextActionsModifier(selection: selection, resolve: resolve))
  }
}

private struct PrimerReviewContextActionsModifier: ViewModifier {
  let selection: Binding<PrimerReviewSelection?>
  let resolve: () -> (PrimerTargetDesignReview, PrimerReviewContextMenu.Item)?
  @Environment(\.primerReviewActions) private var actions

  init(target: PrimerTargetDesignReview, item: PrimerReviewContextMenu.Item, selection: Binding<PrimerReviewSelection?>) {
    self.selection = selection
    self.resolve = { (target, item) }
  }

  init(selection: Binding<PrimerReviewSelection?>, resolve: @escaping () -> (PrimerTargetDesignReview, PrimerReviewContextMenu.Item)?) {
    self.selection = selection
    self.resolve = resolve
  }

  func body(content: Content) -> some View {
    let resolved = resolve()
    return content.contextActions(resolved.map {
      PrimerReviewContextMenu.contextActions(target: $0.0, item: $0.1, selection: selection, context: actions)
    } ?? [])
  }
}

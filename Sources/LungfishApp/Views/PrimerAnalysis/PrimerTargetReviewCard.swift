import SwiftUI

/// Saved-coordinate summary; the model defines coverage semantics and never infers assay success.
struct PrimerTargetReviewCard: View {
  @Environment(\.primerAnalysisVisibility) private var visibility
  let target: PrimerTargetDesignReview
  var selection: Binding<PrimerReviewSelection?> = .constant(nil)

  var body: some View {
    Group {
      if target.presentation == .primer3Template {
        Primer3TemplateReviewCard(target: target, selection: selection)
      } else {
        schemeContent
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.15)))
    .accessibilityElement(children: .contain)
  }

  private var schemeContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(target.label).font(.headline).textSelection(.enabled)
        Spacer(minLength: 12)
        VStack(alignment: .trailing, spacing: 3) {
          Text(target.coveragePercent.map { String(format: "%.1f%%", $0) } ?? "Unavailable")
            .font(.title2.weight(.semibold)).monospacedDigit()
          Text(target.coverageLabel).font(.caption).foregroundStyle(.secondary)
        }
      }
      if let covered = target.coveredBases {
        Text("\(covered.formatted()) of \(target.referenceLength.formatted()) bp · \((target.referenceLength - covered).formatted()) bp outside saved amplicon spans")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Text("\(target.referenceLength.formatted()) bp reference · amplicon spans are not available in this saved result")
          .font(.caption).foregroundStyle(.secondary)
      }
      if visibility.visiblePrimers(in: target).count != target.primers.count {
        Text("\(visibility.visiblePrimers(in: target).count) of \(target.primers.count) oligos displayed. Coverage above describes the complete saved scheme.")
          .font(.caption).foregroundStyle(.secondary)
      }
      PrimerReferenceCoverageTrack(target: target, selection: selection)
      HStack(spacing: 16) {
        legend("Amplicon", color: .accentColor.opacity(0.45))
        legend("Forward primer", color: .blue)
        legend("Reverse primer", color: .orange)
        if target.primers.contains(where: { $0.name == "Internal probe" }) {
          legend("Probe", color: .purple)
        }
      }.font(.caption2)
        .help("Select a saved amplicon or primer to inspect its span, pool and sequence. Control-click for copy, alignment and extraction actions.")
      if selection.wrappedValue?.targetID == target.id {
        PrimerAmpliconDetailView(target: target, selection: selection)
      }
      if !target.notes.isEmpty {
        ForEach(Array(target.notes.enumerated()), id: \.offset) { _, note in
          Text(note).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private func legend(_ text: String, color: Color) -> some View {
    HStack(spacing: 4) {
      Capsule().fill(color).frame(width: 12, height: 5)
      Text(text).foregroundStyle(.secondary)
    }
  }
}

struct PrimerReferenceCoverageTrack: View {
  @Environment(\.primerAnalysisVisibility) private var visibility
  let target: PrimerTargetDesignReview
  var selection: Binding<PrimerReviewSelection?> = .constant(nil)

  private var pools: [Int?] {
    let values = Set(target.intervals.compactMap(\.pool) + target.primers.compactMap(\.pool)).sorted()
    return (values.isEmpty ? [nil] : values.map(Optional.some)).filter {
      visibility.isPoolVisible($0, resultID: target.sourceResultID)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(pools.enumerated()), id: \.offset) { _, pool in
        HStack(spacing: 8) {
          Text(pool.map { "Pool \($0)" } ?? "Not pooled")
            .font(.caption2).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
          lane(pool: pool)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Reference coordinate track, 1 to \(target.referenceLength); \(target.intervals.count) saved amplicons and \(target.primers.count) primer sites")
  }

  private func lane(pool: Int?) -> some View {
    GeometryReader { geometry in
      let width = max(1, geometry.size.width)
      let scale = width / CGFloat(max(1, target.referenceLength))
      ZStack(alignment: .topLeading) {
        Text("1").font(.caption2).foregroundStyle(.secondary)
        Text(target.referenceLength.formatted()).font(.caption2).foregroundStyle(.secondary)
          .frame(width: width, alignment: .trailing)
        Capsule().fill(.secondary.opacity(0.15)).frame(width: width, height: 12).offset(y: 24)
        ForEach(target.intervals.filter { visibility.settings.showAmplicons && $0.pool == pool }) { interval in
          intervalMark(interval, width: width, scale: scale)
        }
        ForEach(target.primers.filter { $0.pool == pool && visibility.isVisible($0, in: target) }) { primer in
          primerMark(primer, width: width, scale: scale)
        }
      }
    }.frame(height: target.primers.contains(where: { $0.name == "Internal probe" }) ? 102 : 82)
  }

  private func intervalMark(_ interval: PrimerReviewInterval, width: CGFloat, scale: CGFloat) -> some View {
    let markWidth = max(3, CGFloat(interval.end - interval.start) * scale)
    let position = min(max(0, width - markWidth), CGFloat(interval.start) * scale)
    let isSelected = selection.wrappedValue?.targetID == target.id && selection.wrappedValue?.ampliconID == interval.id
    let poolLabel = interval.pool.map { " · Pool \($0)" } ?? ""
    let label = "Amplicon \(interval.start + 1)–\(interval.end) · \(interval.end - interval.start) bp" + poolLabel
    return Button {
      selection.wrappedValue = .init(targetID: target.id, primerID: nil, ampliconID: interval.id)
    } label: {
      RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(isSelected ? 0.8 : 0.4))
        .frame(width: markWidth, height: 12)
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(isSelected ? Color.primary : .clear, lineWidth: 1))
        .frame(height: 20).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu { PrimerReviewContextMenu(target: target, item: .amplicon(interval), selection: selection) }
    .offset(x: position, y: 20)
    .help(label).accessibilityLabel(label)
    .accessibilityIdentifier("primerReview.amplicon.\(interval.id)")
  }

  private func primerMark(_ primer: PrimerReviewPrimer, width: CGFloat, scale: CGFloat) -> some View {
    let isForward = primer.strand == "+"
    let isProbe = primer.name == "Internal probe"
    let color: Color = isProbe ? .purple : (isForward ? .blue : .orange)
    let markWidth = max(3, CGFloat(primer.end - primer.start) * scale)
    let hitWidth = max(12, markWidth)
    let x = min(max(0, width - hitWidth), max(0, CGFloat(primer.start) * scale - (hitWidth - markWidth) / 2))
    let y: CGFloat = isProbe ? 80 : (isForward ? 40 : 60)
    let isSelected = selection.wrappedValue?.targetID == target.id && selection.wrappedValue?.primerID == primer.id
    return Button {
      selection.wrappedValue = PrimerReviewSelection.selecting(primer: primer, in: target)
    } label: {
      Capsule().fill(color).frame(width: markWidth, height: isSelected ? 9 : 6)
        .overlay(Capsule().strokeBorder(isSelected ? Color.primary : .clear, lineWidth: 1))
        .frame(width: hitWidth, height: 20).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .contextMenu { PrimerReviewContextMenu(target: target, item: .primer(primer), selection: selection) }
    .offset(x: x, y: y)
    .help(primerHelp(primer))
    .accessibilityLabel("\(primer.name), binding site \(primer.start + 1)–\(primer.end), \(primer.pool.map { "pool \($0)" } ?? "candidate pair")")
    .accessibilityIdentifier("primerReview.primer.\(primer.id)")
  }

  private func primerHelp(_ primer: PrimerReviewPrimer) -> String {
    let site = "\(primer.name): \(primer.start + 1)–\(primer.end) (\(primer.strand))"
    guard let summary = visibility.summaries[primer.id] else {
      return site + (visibility.isComputingCompatibility ? "\nCalculating MSA matches…" : "\nMSA matches: unavailable")
    }
    return site + "\n" + summary.label + "\n" + summary.help
  }
}

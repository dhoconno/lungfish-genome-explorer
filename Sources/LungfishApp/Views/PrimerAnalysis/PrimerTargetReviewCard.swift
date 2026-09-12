import SwiftUI

/// Saved-coordinate summary; the model defines coverage semantics and never infers assay success.
struct PrimerTargetReviewCard: View {
  let target: PrimerTargetDesignReview

  var body: some View {
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
      PrimerReferenceCoverageTrack(target: target)
      HStack(spacing: 16) {
        legend("Amplicon span", color: .accentColor.opacity(0.45))
        legend("Forward primer", color: .blue)
        legend("Reverse primer", color: .orange)
        if target.primers.contains(where: { $0.name == "Internal probe" }) {
          legend("Probe", color: .purple)
        }
      }.font(.caption2)
      if !target.notes.isEmpty {
        ForEach(Array(target.notes.enumerated()), id: \.offset) { _, note in
          Text(note).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.secondary.opacity(0.15)))
    .accessibilityElement(children: .contain)
  }

  private func legend(_ text: String, color: Color) -> some View {
    HStack(spacing: 4) {
      Capsule().fill(color).frame(width: 12, height: 5)
      Text(text).foregroundStyle(.secondary)
    }
  }
}

struct PrimerReferenceCoverageTrack: View {
  let target: PrimerTargetDesignReview

  var body: some View {
    GeometryReader { geometry in
      let width = max(1, geometry.size.width)
      let scale = width / CGFloat(max(1, target.referenceLength))
      ZStack(alignment: .topLeading) {
        Text("1").font(.caption2).foregroundStyle(.secondary)
        Text(target.referenceLength.formatted()).font(.caption2).foregroundStyle(.secondary)
          .frame(width: width, alignment: .trailing)
        Capsule().fill(.secondary.opacity(0.15)).frame(width: width, height: 12).offset(y: 22)
        ForEach(target.intervals) { interval in
          intervalMark(interval, scale: scale)
        }
        ForEach(target.primers) { primer in
          primerMark(primer, width: width, scale: scale)
        }
      }
    }.frame(height: target.primers.contains(where: { $0.name == "Internal probe" }) ? 80 : 66)
      .accessibilityLabel("Reference coordinate track, 1 to \(target.referenceLength); \(target.intervals.count) saved amplicons and \(target.primers.count) primer sites")
  }

  private func intervalMark(_ interval: PrimerReviewInterval, scale: CGFloat) -> some View {
    let markWidth: CGFloat = max(1, CGFloat(interval.end - interval.start) * scale)
    let position: CGFloat = CGFloat(interval.start) * scale
    let poolLabel = interval.pool.map { " · Pool \($0)" } ?? ""
    return RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.45))
      .frame(width: markWidth, height: 12)
      .offset(x: position, y: 22)
      .help("Amplicon \(interval.start + 1)–\(interval.end)" + poolLabel)
  }

  private func primerMark(_ primer: PrimerReviewPrimer, width: CGFloat, scale: CGFloat) -> some View {
    let isForward = primer.strand == "+"
    let isProbe = primer.name == "Internal probe"
    let color: Color = isProbe ? .purple : (isForward ? .blue : .orange)
    let markWidth: CGFloat = max(2, CGFloat(primer.end - primer.start) * scale)
    let x: CGFloat = min(max(0, width - 2), CGFloat(primer.start) * scale)
    let y: CGFloat = isProbe ? 66 : (isForward ? 42 : 54)
    return Capsule().fill(color)
      .frame(width: markWidth, height: 6)
      .offset(x: x, y: y)
      .help("\(primer.name): \(primer.start + 1)–\(primer.end) (\(primer.strand))")
  }

}

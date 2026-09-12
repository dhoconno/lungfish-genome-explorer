import SwiftUI

/// Uses verified saved membership only. Selected variant sets are not paired by their suffixes.
struct PrimerAmpliconDetailView: View {
  let target: PrimerTargetDesignReview
  let selection: Binding<PrimerReviewSelection?>

  private var selectedPrimer: PrimerReviewPrimer? {
    target.primers.first { $0.id == selection.wrappedValue?.primerID }
  }

  private var selectedAmplicon: PrimerReviewInterval? {
    target.intervals.first { $0.id == selection.wrappedValue?.ampliconID }
  }

  private enum VariantSide: String, CaseIterable {
    case forward = "LEFT"
    case reverse = "RIGHT"
    case probe = "PROBE"
    case other = ""

    var title: String {
      switch self {
      case .forward: return "Forward variants (LEFT)"
      case .reverse: return "Reverse variants (RIGHT)"
      case .probe: return "Probe variants (PROBE)"
      case .other: return "Other saved oligos"
      }
    }
  }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        if let interval = selectedAmplicon {
          HStack(alignment: .firstTextBaseline) {
            Text(interval.name).font(.headline).textSelection(.enabled)
            Spacer()
            Text(interval.pool.map { "Pool \($0)" } ?? (target.presentation == .primer3Template ? "Candidate pair" : "Not pooled"))
              .font(.subheadline.weight(.medium))
          }
          .contextMenu { PrimerReviewContextMenu(target: target, item: .amplicon(interval), selection: selection) }
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(interval.length.formatted()) bp").font(.title2.weight(.semibold)).monospacedDigit()
            Text(interval.sizeLabel).font(.caption).foregroundStyle(.secondary)
          }
          Text("\(target.presentation == .primer3Template ? "Template" : "Reference") coordinates \(interval.start + 1)–\(interval.end) · 1-based inclusive")
            .font(.caption).foregroundStyle(.secondary)
          if target.presentation == .schemeReference {
            Text("This saved reference span encloses the selected primer set. Individual products and alignment rows may differ in length.")
              .font(.caption).foregroundStyle(.secondary)
          }
          let members = target.primers.filter { interval.primerIDs.contains($0.id) }
          if members.isEmpty {
            Text("Amplicon correspondence unavailable. The saved span is available, but primer membership cannot be established from these records.")
              .font(.caption).foregroundStyle(.secondary)
          } else if target.presentation == .schemeReference,
            let verifiedMembers = PrimerReviewClipboard.ampliconPrimers(interval, in: target) {
            selectedVariantSet(verifiedMembers)
          } else {
            ForEach(members) { primer in oligo(primer) }
          }
        } else if let primer = selectedPrimer {
          Text("Amplicon correspondence unavailable")
            .font(.headline)
          Text("Inspect this primer independently. Its pool and position do not establish a primer pair.")
            .font(.caption).foregroundStyle(.secondary)
          oligo(primer)
        } else {
          Text("Select an amplicon or primer on the reference track.").foregroundStyle(.secondary)
        }
      }
      .padding(6)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("primerReview.selectedAmplicon")
  }

  private func selectedVariantSet(_ members: [PrimerReviewPrimer]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Selected primer set").font(.headline)
      Text("All listed variants are selected components, not backup candidates. Suffix numbers enumerate oligos; they do not indicate quality rank or matched forward/reverse pairs.")
        .font(.caption).foregroundStyle(.secondary)
      ForEach(VariantSide.allCases, id: \.rawValue) { side in
        let group = members.filter { variantSide($0) == side }
        if !group.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text("\(side.title) · \(group.count)").font(.subheadline.weight(.semibold))
            ForEach(group) { primer in oligo(primer) }
          }
        }
      }
    }
  }

  private func variantSide(_ primer: PrimerReviewPrimer) -> VariantSide {
    let components = primer.name.split(separator: "_")
    guard components.count >= 2, let suffix = components.last, Int(suffix) != nil else { return .other }
    return VariantSide(rawValue: String(components[components.count - 2])) ?? .other
  }

  private func oligo(_ primer: PrimerReviewPrimer) -> some View {
    let selected = primer.id == selectedPrimer?.id
    let isProbe = primer.name == "Internal probe" || (target.presentation == .schemeReference && variantSide(primer) == .probe)
    let color: Color = isProbe ? .purple : (primer.strand == "+" ? .blue : .orange)
    return VStack(alignment: .leading, spacing: 4) {
      Button {
        selection.wrappedValue = PrimerReviewSelection.selecting(primer: primer, in: target)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: primer.strand == "+" ? "arrow.right" : "arrow.left").foregroundStyle(color)
          Text(primer.name).fontWeight(selected ? .semibold : .regular)
          Spacer()
          Text(primer.pool.map { "Pool \($0)" } ?? (target.presentation == .primer3Template ? "Candidate pair" : "Not pooled")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3).contentShape(Rectangle())
      }.buttonStyle(.plain)
      Text("Binding site \(primer.start + 1)–\(primer.end) (\(primer.strand)) · \(primer.sequence.count) nt oligo")
        .font(.caption).foregroundStyle(.secondary)
      if !primer.sequence.isEmpty {
        Text("5′ \(primer.sequence) 3′").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(selected ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 4))
    .contextMenu { PrimerReviewContextMenu(target: target, item: .primer(primer), selection: selection) }
  }
}

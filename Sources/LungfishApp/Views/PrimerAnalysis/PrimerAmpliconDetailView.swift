import SwiftUI

/// Uses verified saved membership only. Alternative primer clouds are not paired by their suffixes.
struct PrimerAmpliconDetailView: View {
  let target: PrimerTargetDesignReview
  let selection: Binding<PrimerReviewSelection?>

  private var selectedPrimer: PrimerReviewPrimer? {
    target.primers.first { $0.id == selection.wrappedValue?.primerID }
  }

  private var selectedAmplicon: PrimerReviewInterval? {
    target.intervals.first { $0.id == selection.wrappedValue?.ampliconID }
  }

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        if let interval = selectedAmplicon {
          HStack(alignment: .firstTextBaseline) {
            Text(interval.name).font(.headline).textSelection(.enabled)
            Spacer()
            Text(interval.pool.map { "Pool \($0)" } ?? "Not pooled")
              .font(.subheadline.weight(.medium))
          }
          .contextMenu { PrimerReviewContextMenu(target: target, item: .amplicon(interval), selection: selection) }
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(interval.length.formatted()) bp").font(.title2.weight(.semibold)).monospacedDigit()
            Text(interval.sizeLabel).font(.caption).foregroundStyle(.secondary)
          }
          Text("Reference coordinates \(interval.start + 1)–\(interval.end) · 1-based inclusive")
            .font(.caption).foregroundStyle(.secondary)
          if interval.pool != nil {
            Text("This saved span encloses the primer alternatives. Individual products and alignment rows may differ in length.")
              .font(.caption).foregroundStyle(.secondary)
          }
          let members = target.primers.filter { interval.primerIDs.contains($0.id) }
          if members.isEmpty {
            Text("Amplicon correspondence unavailable. The saved span is available, but primer membership cannot be established from these records.")
              .font(.caption).foregroundStyle(.secondary)
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

  private func oligo(_ primer: PrimerReviewPrimer) -> some View {
    let selected = primer.id == selectedPrimer?.id
    let color: Color = primer.name == "Internal probe" ? .purple : (primer.strand == "+" ? .blue : .orange)
    return VStack(alignment: .leading, spacing: 4) {
      Button {
        selection.wrappedValue = PrimerReviewSelection.selecting(primer: primer, in: target)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: primer.strand == "+" ? "arrow.right" : "arrow.left").foregroundStyle(color)
          Text(primer.name).fontWeight(selected ? .semibold : .regular)
          Spacer()
          Text(primer.pool.map { "Pool \($0)" } ?? "Not pooled").font(.caption).foregroundStyle(.secondary)
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

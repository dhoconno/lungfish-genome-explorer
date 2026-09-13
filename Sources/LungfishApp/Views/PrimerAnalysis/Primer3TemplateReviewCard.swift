import SwiftUI

/// Each candidate retains its own saved template coordinates and exact oligo membership.
struct Primer3TemplateReviewCard: View {
  let target: PrimerTargetDesignReview
  var selection: Binding<PrimerReviewSelection?> = .constant(nil)
  private let labelWidth: CGFloat = 126
  private let coordinateWidth: CGFloat = 82

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(target.label).font(.headline).textSelection(.enabled)
      HStack(alignment: .firstTextBaseline) {
        Text("Saved design template").font(.subheadline.weight(.medium))
        Spacer(minLength: 8)
        Text("\(target.referenceLength.formatted()) bp").font(.caption).foregroundStyle(.secondary)
      }
      if let interval = target.intervals.first {
        Text("Positions are 1-based inclusive on the saved template.")
          .font(.caption).foregroundStyle(.secondary)
        templateAxis
        productRow(interval)
        ForEach(target.primers) { primer in primerRow(primer) }
        Text("Select a product or binding site for details. Control-click for copy and extraction actions.")
          .font(.caption).foregroundStyle(.secondary)
        if selection.wrappedValue?.targetID == target.id {
          PrimerAmpliconDetailView(target: target, selection: selection)
        }
      } else {
        Text("No candidate pairs").font(.subheadline.weight(.medium))
        ForEach(Array(target.notes.enumerated()), id: \.offset) { _, note in
          Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("primer3.templateMap.\(target.id)")
  }

  private var templateAxis: some View {
    HStack(spacing: 8) {
      Text("Template").font(.caption).foregroundStyle(.secondary)
        .frame(width: labelWidth, alignment: .leading)
      VStack(spacing: 4) {
        HStack {
          Text("1")
          Spacer(minLength: 0)
          Text(target.referenceLength.formatted())
        }.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        Capsule().fill(.secondary.opacity(0.3)).frame(height: 3)
      }
      Color.clear.frame(width: coordinateWidth, height: 1)
    }
  }

  private func productRow(_ interval: PrimerReviewInterval) -> some View {
    let selected = selection.wrappedValue?.targetID == target.id
      && selection.wrappedValue?.ampliconID == interval.id
    return Button {
      selection.wrappedValue = .init(targetID: target.id, primerID: nil, ampliconID: interval.id)
    } label: {
      mapRow(title: "Product · \(interval.length.formatted()) bp", start: interval.start, end: interval.end,
        color: .accentColor.opacity(0.6), selected: selected)
    }
    .buttonStyle(.plain)
    .help("Product \(interval.start + 1)–\(interval.end), including both primer sites")
    .accessibilityLabel("Product, \(interval.length) bp, template coordinates \(interval.start + 1)–\(interval.end)")
    .accessibilityIdentifier("primerReview.amplicon.\(interval.id)")
    .contextMenu { PrimerReviewContextMenu(target: target, item: .amplicon(interval), selection: selection) }
  }

  private func primerRow(_ primer: PrimerReviewPrimer) -> some View {
    let color: Color = primer.name == "Internal probe" ? .purple : primer.strand == "+" ? .blue : .orange
    let selected = selection.wrappedValue?.targetID == target.id
      && selection.wrappedValue?.primerID == primer.id
    let title = primer.name + (primer.strand == "+" ? " →" : " ←")
    return Button {
      selection.wrappedValue = .selecting(primer: primer, in: target)
    } label: {
      mapRow(title: title, start: primer.start, end: primer.end, color: color, selected: selected)
    }
    .buttonStyle(.plain)
    .help("\(primer.name): \(primer.start + 1)–\(primer.end) (\(primer.strand)); stored oligo is 5′–3′")
    .accessibilityLabel("\(primer.name), binding site \(primer.start + 1)–\(primer.end), strand \(primer.strand)")
    .accessibilityIdentifier("primerReview.primer.\(primer.id)")
    .contextMenu { PrimerReviewContextMenu(target: target, item: .primer(primer), selection: selection) }
  }

  private func mapRow(title: String, start: Int, end: Int, color: Color, selected: Bool) -> some View {
    HStack(spacing: 8) {
      Text(title).font(.caption.weight(selected ? .semibold : .medium)).foregroundStyle(color)
        .frame(width: labelWidth, alignment: .leading)
      GeometryReader { geometry in
        let width = max(1, geometry.size.width)
        let scale = width / CGFloat(max(1, target.referenceLength))
        let markWidth = min(width, max(3, CGFloat(end - start) * scale))
        let position = min(max(0, width - markWidth), CGFloat(start) * scale)
        ZStack(alignment: .leading) {
          Capsule().fill(.secondary.opacity(0.12)).frame(height: 2)
          Capsule().fill(color)
            .frame(width: markWidth, height: selected ? 10 : 7)
            .overlay(Capsule().strokeBorder(selected ? Color.primary : .clear, lineWidth: 1))
            .offset(x: position)
        }.frame(height: 24)
      }.frame(height: 24)
      Text("\(start + 1)–\(end)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
        .frame(width: coordinateWidth, alignment: .trailing)
    }
    .contentShape(Rectangle())
  }
}

import AppKit
import Foundation
import SwiftUI

struct PrimalSchemeResultsView: View {
  let results: [PrimalSchemeDisplayResult]
  var engineDescription: String = "PrimalScheme3"
  @State private var selectedResultID: String?
  @State private var selectedPrimerID: Int?
  @State private var selectedPool: Int?

  private var result: PrimalSchemeDisplayResult? {
    results.first { $0.id == selectedResultID } ?? results.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("\(engineDescription) results").font(.title2.weight(.semibold))
      Picker("Stored scheme", selection: Binding(get: { result?.id }, set: { selectedResultID = $0 })) {
        ForEach(results) { Text($0.title).tag(Optional($0.id)) }
      }.onChange(of: selectedResultID) { selectedPrimerID = nil; selectedPool = nil }
      if let result {
        let pools = Set(result.primers.map(\.pool)).sorted()
        let visible = result.primers.filter { selectedPool == nil || $0.pool == selectedPool }
        let selected = visible.first { $0.id == selectedPrimerID } ?? visible.first
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
          Text("This saved analysis has no ordering worksheet. Its native primer records remain available in Files.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Text("Pool numbers apply within this stored scheme. Review alternative and ambiguous oligos individually; no synthesis quantities are inferred.")
          .font(.caption).foregroundStyle(.secondary)
        Picker("Pool", selection: $selectedPool) {
          Text("All pools").tag(nil as Int?)
          ForEach(pools, id: \.self) { Text("Pool \($0)").tag(Optional($0)) }
        }
        if let selected {
          VStack(alignment: .leading, spacing: 8) {
            Text(selected.name).font(.headline).textSelection(.enabled)
            Text("\(selected.referenceLabel) · \(selected.referenceLength) bp reference · pool \(selected.pool)")
              .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            GeometryReader { geometry in
              let width = max(1, geometry.size.width)
              let scale = width / CGFloat(max(1, selected.referenceLength))
              ZStack(alignment: .topLeading) {
                Text("1").font(.caption2).foregroundStyle(.secondary)
                Text(selected.referenceLength.formatted()).font(.caption2).foregroundStyle(.secondary)
                  .frame(width: width, alignment: .trailing)
                Rectangle().fill(.secondary.opacity(0.25)).frame(height: 2).offset(y: 22)
                ForEach(visible.filter { $0.reference == selected.reference }) { primer in
                  RoundedRectangle(cornerRadius: 2)
                    .fill(primer.strand == "+" ? Color.blue : Color.orange)
                    .opacity(primer.id == selected.id ? 1 : 0.35)
                    .frame(width: max(3, CGFloat(primer.end - primer.start) * scale), height: primer.id == selected.id ? 10 : 6)
                    .offset(x: min(width - 3, CGFloat(primer.start) * scale), y: primer.strand == "+" ? 32 : 48)
                    .help("\(primer.name) · Pool \(primer.pool) · \(primer.start + 1)–\(primer.end)")
                }
              }
            }.frame(height: 64)
            Text("All visible primer sites on this reference; the selected primer is emphasized. Blue: forward strand. Orange: reverse strand.")
              .font(.caption2).foregroundStyle(.secondary)
            Text("Binding site: \(selected.start + 1)–\(selected.end) · strand \(selected.strand) · \(selected.sequence.count) nt")
              .font(.caption)
            Text("5′ \(selected.sequence) 3′").font(.system(.body, design: .monospaced)).textSelection(.enabled)
          }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        }
        Text("Select a primer to see its binding site. Displayed coordinates are 1-based inclusive; native files retain their original coordinates and identifiers.")
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
              Button { selectedPrimerID = primer.id } label: {
                VStack(alignment: .leading, spacing: 5) {
                  HStack(spacing: 14) {
                    Text(primer.name).fontWeight(.medium).frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(primer.sequence.count) nt · \(primer.gcLabel)").font(.caption)
                  }
                  Text(primer.sequence.uppercased()).font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                  Text("\(primer.referenceLabel) · \(primer.start + 1)–\(primer.end) (\(primer.strand))")
                    .font(.caption).foregroundStyle(.secondary)
                  if primer.ambiguousBaseCount > 0 {
                    Text("\(primer.ambiguousBaseCount) ambiguous bases — review synthesis representation")
                      .font(.caption).foregroundStyle(.orange)
                  }
                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                  .background(selected?.id == primer.id ? Color.accentColor.opacity(0.12) : .clear,
                              in: RoundedRectangle(cornerRadius: 5))
              }.buttonStyle(.plain)
            }
          }
        }
      }
    }
  }
}

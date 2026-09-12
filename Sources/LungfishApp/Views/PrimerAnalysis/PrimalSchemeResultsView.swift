import AppKit
import Foundation
import SwiftUI

struct PrimalSchemeDisplayPrimer: Identifiable, Sendable {
  let id: Int
  let reference: String
  let referenceLabel: String
  let start: Int
  let end: Int
  let name: String
  let pool: Int
  let strand: String
  let sequence: String
  let referenceLength: Int

  var ambiguousBaseCount: Int { sequence.uppercased().filter { !"ACGT".contains($0) }.count }
  var gcLabel: String {
    guard ambiguousBaseCount == 0 else { return "GC varies" }
    let gc = sequence.uppercased().filter { "GC".contains($0) }.count
    return String(format: "%.1f%% GC", Double(gc) * 100 / Double(sequence.count))
  }
}

struct PrimalSchemeDisplayResult: Identifiable, Sendable {
  let id: String
  let title: String
  let primers: [PrimalSchemeDisplayPrimer]
  let orderSheetURL: URL?

  /// PrimalScheme3's ARTIC BED v3 coordinates are zero-based, half-open.
  /// Column five is a pool identifier, not a BED score.
  static func parse(id: String, title: String, bed: Data, reference: Data, referenceLabels: [String: String] = [:], orderSheetURL: URL? = nil) throws -> Self {
    func invalid(_ detail: String) -> NSError {
      NSError(domain: "PrimalSchemeDisplay", code: 1,
              userInfo: [NSLocalizedDescriptionKey: "Invalid stored scheme: " + detail])
    }
    guard let fasta = String(data: reference, encoding: .utf8), let text = String(data: bed, encoding: .utf8) else {
      throw invalid("native files must be UTF-8")
    }
    var lengths: [String: Int] = [:]
    var current: String?
    for line in fasta.split(whereSeparator: \.isNewline) {
      if line.hasPrefix(">") {
        guard let name = line.dropFirst().split(whereSeparator: \.isWhitespace).first,
          lengths[String(name)] == nil else { throw invalid("missing or duplicate reference identifier") }
        current = String(name)
        lengths[String(name)] = 0
      } else if let current {
        let bases = line.filter { !$0.isWhitespace }
        guard bases.utf8.allSatisfy({ "ACGTRYSWKMBDHVNacgtryswkmbdhvn".utf8.contains($0) }) else {
          throw invalid("reference contains unsupported bases")
        }
        lengths[current, default: 0] += bases.utf8.count
      } else if !line.trimmingCharacters(in: .whitespaces).isEmpty { throw invalid("reference lacks a FASTA header") }
    }
    guard !lengths.isEmpty, lengths.values.allSatisfy({ $0 > 0 }) else { throw invalid("empty reference sequence") }
    var primers: [PrimalSchemeDisplayPrimer] = []
    for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
      if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count >= 7, let start = Int(fields[1]), let end = Int(fields[2]),
        let pool = Int(fields[4]), pool > 0, start >= 0, end > start,
        let length = lengths[fields[0]], end <= length,
        ["+", "-"].contains(fields[5]), !fields[3].isEmpty,
        !fields[6].isEmpty,
        fields[6].utf8.allSatisfy({ "ACGTRYSWKMBDHVNacgtryswkmbdhvn".utf8.contains($0) }) else { throw invalid("primer BED coordinates, pool or reference do not agree") }
      primers.append(.init(id: primers.count, reference: fields[0], referenceLabel: referenceLabels[fields[0]] ?? fields[0], start: start, end: end,
        name: fields[3], pool: pool, strand: fields[5], sequence: fields[6], referenceLength: length))
    }
    return .init(id: id, title: title, primers: primers, orderSheetURL: orderSheetURL)
  }
}

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
              let width = geometry.size.width
              let x = width * Double(selected.start) / Double(selected.referenceLength)
              let length = max(3, width * Double(selected.end - selected.start) / Double(selected.referenceLength))
              ZStack(alignment: .leading) {
                Rectangle().fill(.secondary.opacity(0.25)).frame(height: 2)
                RoundedRectangle(cornerRadius: 3).fill(selected.strand == "+" ? Color.blue : Color.orange)
                  .frame(width: length, height: 10).offset(x: x)
              }.frame(height: 28)
            }.frame(height: 28)
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

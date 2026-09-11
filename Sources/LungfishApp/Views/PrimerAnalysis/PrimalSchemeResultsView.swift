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
}

struct PrimalSchemeDisplayResult: Identifiable, Sendable {
  let id: String
  let title: String
  let primers: [PrimalSchemeDisplayPrimer]

  /// PrimalScheme3's ARTIC BED v3 coordinates are zero-based, half-open.
  /// Column five is a pool identifier, not a BED score.
  static func parse(id: String, title: String, bed: Data, reference: Data, referenceLabels: [String: String] = [:]) throws -> Self {
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
        fields[6].utf8.count == end - start,
        fields[6].utf8.allSatisfy({ "ACGTRYSWKMBDHVNacgtryswkmbdhvn".utf8.contains($0) }) else { throw invalid("primer BED coordinates, pool or reference do not agree") }
      primers.append(.init(id: primers.count, reference: fields[0], referenceLabel: referenceLabels[fields[0]] ?? fields[0], start: start, end: end,
        name: fields[3], pool: pool, strand: fields[5], sequence: fields[6], referenceLength: length))
    }
    return .init(id: id, title: title, primers: primers)
  }
}

struct PrimalSchemeResultsView: View {
  let results: [PrimalSchemeDisplayResult]
  @State private var selectedResultID: String?
  @State private var selectedPrimerID: Int?
  @State private var selectedPool: Int?

  private var result: PrimalSchemeDisplayResult? {
    results.first { $0.id == selectedResultID } ?? results.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("PrimalScheme3 results").font(.title2.weight(.semibold))
      Picker("Stored scheme", selection: Binding(get: { result?.id }, set: { selectedResultID = $0 })) {
        ForEach(results) { Text($0.title).tag(Optional($0.id)) }
      }.onChange(of: selectedResultID) { selectedPrimerID = nil; selectedPool = nil }
      if let result {
        let pools = Set(result.primers.map(\.pool)).sorted()
        let visible = result.primers.filter { selectedPool == nil || $0.pool == selectedPool }
        let selected = visible.first { $0.id == selectedPrimerID } ?? visible.first
        Text("\(result.primers.count) primer records · \(pools.count) pools · \(Set(result.primers.map(\.reference)).count) references")
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
        ForEach(visible) { primer in
          Button { selectedPrimerID = primer.id } label: {
            HStack(spacing: 14) {
              Text("Pool \(primer.pool)").frame(width: 65, alignment: .leading)
              Text(primer.name).frame(maxWidth: .infinity, alignment: .leading)
              Text("\(primer.start + 1)–\(primer.end) (\(primer.strand))").monospacedDigit()
            }.padding(8).contentShape(Rectangle())
              .background(selected?.id == primer.id ? Color.accentColor.opacity(0.12) : .clear,
                          in: RoundedRectangle(cornerRadius: 5))
          }.buttonStyle(.plain)
        }
      }
    }
  }
}

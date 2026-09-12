import Foundation

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


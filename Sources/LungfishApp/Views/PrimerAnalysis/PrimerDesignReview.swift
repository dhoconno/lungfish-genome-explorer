import Foundation
import LungfishWorkflow

struct PrimerReviewInterval: Identifiable, Sendable {
  let id: String
  let start: Int
  let end: Int
  let pool: Int?
}

struct PrimerReviewPrimer: Identifiable, Sendable {
  let id: String
  let name: String
  let start: Int
  let end: Int
  let strand: String
  let pool: Int?
}

struct PrimerTargetDesignReview: Identifiable, Sendable {
  let id: String
  let label: String
  let referenceLength: Int
  let coverageLabel: String
  let coveredBases: Int?
  var coveragePercent: Double? { coveredBases.map { Double($0) * 100 / Double(referenceLength) } }
  let intervals: [PrimerReviewInterval]
  let primers: [PrimerReviewPrimer]
  let notes: [String]
}

enum PrimerDesignReview {
  static func coveredBases(_ intervals: [PrimerReviewInterval]) -> Int {
    var total = 0
    var end = 0
    for interval in intervals.sorted(by: { $0.start < $1.start }) {
      if interval.end > end { total += interval.end - max(end, interval.start); end = interval.end }
    }
    return total
  }

  static func primalScheme(id: String, label: String, reference: Data, amplicons: Data?,
                          primers: [PrimalSchemeDisplayPrimer], labels: [String: String]) throws -> [PrimerTargetDesignReview] {
    func invalid() -> NSError { NSError(domain: "PrimerDesignReview", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Stored amplicon coordinates or reference sequence are invalid."]) }
    guard let fasta = String(data: reference, encoding: .utf8) else { throw invalid() }
    var names: [String] = []
    var lengths: [String: Int] = [:]
    var current: String?
    for line in fasta.split(whereSeparator: \.isNewline) {
      try Task.checkCancellation()
      if line.hasPrefix(">") {
        guard let name = line.dropFirst().split(whereSeparator: \.isWhitespace).first,
          lengths[String(name)] == nil else { throw invalid() }
        current = String(name); names.append(String(name)); lengths[String(name)] = 0
      } else if let current {
        let sequence = line.filter { !$0.isWhitespace }
        guard sequence.utf8.allSatisfy({ "ACGTRYSWKMBDHVNacgtryswkmbdhvn".utf8.contains($0) }) else { throw invalid() }
        lengths[current, default: 0] += sequence.utf8.count
      } else if !line.trimmingCharacters(in: .whitespaces).isEmpty { throw invalid() }
    }
    guard !names.isEmpty, lengths.values.allSatisfy({ $0 > 0 }) else { throw invalid() }
    var spans: [String: [PrimerReviewInterval]] = [:]
    if let amplicons {
      guard let bed = String(data: amplicons, encoding: .utf8) else { throw invalid() }
      for (index, line) in bed.split(whereSeparator: \.isNewline).enumerated() where !line.hasPrefix("#") {
        try Task.checkCancellation()
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5, let length = lengths[fields[0]],
          let start = Int(fields[1]), let end = Int(fields[2]), start >= 0, end > start, end <= length,
          let pool = Int(fields[4]), pool > 0 else { throw invalid() }
        spans[fields[0], default: []].append(.init(id: "\(id)-span-\(index)", start: start, end: end, pool: pool))
      }
    }
    return names.map { name in
      let intervals = spans[name] ?? []
      return PrimerTargetDesignReview(id: "\(id)-\(name)", label: "\(label) · \(labels[name] ?? name)",
        referenceLength: lengths[name]!, coverageLabel: "Reference spanned by amplicons",
        coveredBases: amplicons == nil ? nil : coveredBases(intervals), intervals: intervals,
        primers: primers.filter { $0.reference == name }.map {
          .init(id: "\(id)-primer-\($0.id)", name: $0.name, start: $0.start, end: $0.end, strand: $0.strand, pool: $0.pool)
        }, notes: ["Denominator: the full saved mapping reference. Overlapping amplicon spans count once; primer sequences are included.",
          amplicons == nil ? "No saved amplicon BED is available; coverage is unknown." : "Positional reference coverage does not establish coverage of every alignment row or successful amplification."])
    }
  }

  static func primer3(_ normalized: Primer3NormalizedResults) -> [PrimerTargetDesignReview] {
    normalized.results.flatMap { result -> [PrimerTargetDesignReview] in
      if result.pairs.isEmpty {
        return [.init(id: result.resultID.uuidString, label: result.title, referenceLength: result.templateSequence.utf8.count,
          coverageLabel: "Template spanned by candidate", coveredBases: 0, intervals: [], primers: [],
          notes: [result.error ?? result.explanation ?? "No candidate primer pairs were returned."])]
      }
      return result.pairs.enumerated().map { index, pair in
        let interval = PrimerReviewInterval(id: pair.id.uuidString, start: pair.left.start, end: pair.right.end, pool: nil)
        return .init(id: pair.id.uuidString, label: "\(result.title) · Candidate \(index + 1)",
          referenceLength: result.templateSequence.utf8.count, coverageLabel: "Template spanned by this candidate",
          coveredBases: interval.end - interval.start, intervals: [interval],
          primers: ([pair.left, pair.right] + (pair.internalOligo.map { [$0] } ?? [])).map {
            .init(id: $0.id.uuidString, name: $0.id == pair.internalOligo?.id ? "Internal probe" : ($0.orientation == .forward ? "Forward primer" : "Reverse primer"),
              start: $0.start, end: $0.end, strand: $0.orientation == .forward ? "+" : "-", pool: nil)
          }, notes: ["Alternative candidates are shown separately, not combined into a scheme.",
            "Denominator: the full saved template, not a selected subregion. Positional span is not an assay-success estimate."])
      }
    }
  }
}

import Foundation

public struct PrimerReviewInterval: Identifiable, Sendable {
  public let id: String
  public let start: Int
  public let end: Int
  public let pool: Int?
  /// Native scientific pool identity. `pool` is only a visual lane group.
  public var nativePool: String? = nil
  public var poolLabel: String? = nil
  public var candidateStatus: PrimerAssayStatus = .selected
  public var rank: Int? = nil
  public var name: String = "Amplicon"
  public var primerIDs: [String] = []
  public var sizeLabel: String = "Reference span, including primers"

  public init(
    id: String,
    start: Int,
    end: Int,
    pool: Int?,
    nativePool: String? = nil,
    poolLabel: String? = nil,
    candidateStatus: PrimerAssayStatus = .selected,
    rank: Int? = nil,
    name: String = "Amplicon",
    primerIDs: [String] = [],
    sizeLabel: String = "Reference span, including primers"
  ) {
    self.id = id
    self.start = start
    self.end = end
    self.pool = pool
    self.nativePool = nativePool
    self.poolLabel = poolLabel
    self.candidateStatus = candidateStatus
    self.rank = rank
    self.name = name
    self.primerIDs = primerIDs
    self.sizeLabel = sizeLabel
  }
  public var length: Int { end - start }
}

public struct PrimerReviewPrimer: Identifiable, Sendable {
  public let id: String
  public let name: String
  public let start: Int
  public let end: Int
  public let strand: String
  public let pool: Int?
  public var poolLabel: String? = nil
  public var role: PrimerOligoRole = .forward
  public var candidateStatus: PrimerAssayStatus = .selected
  public var rank: Int? = nil
  public var nativePool: String? = nil
  public var sequence: String = ""
  public var ampliconIDs: [String] = []

  public init(
    id: String,
    name: String,
    start: Int,
    end: Int,
    strand: String,
    pool: Int?,
    poolLabel: String? = nil,
    role: PrimerOligoRole = .forward,
    candidateStatus: PrimerAssayStatus = .selected,
    rank: Int? = nil,
    nativePool: String? = nil,
    sequence: String = "",
    ampliconIDs: [String] = []
  ) {
    self.id = id
    self.name = name
    self.start = start
    self.end = end
    self.strand = strand
    self.pool = pool
    self.poolLabel = poolLabel
    self.role = role
    self.candidateStatus = candidateStatus
    self.rank = rank
    self.nativePool = nativePool
    self.sequence = sequence
    self.ampliconIDs = ampliconIDs
  }
}

public struct PrimerTargetDesignReview: Identifiable, Sendable {
  public enum Presentation: Equatable, Sendable {
    case schemeReference
    case primer3Template
  }
  public let id: String
  public let label: String
  public let referenceLength: Int
  public let coverageLabel: String
  public let coveredBases: Int?
  /// qPCR reports independent alternative assays, so a spanned-bases percentage
  /// would read as a quality score for candidates the user chooses among. When
  /// this is set the card shows the assay count instead of a percentage.
  public var assayCountHeadline: Int?
  public var coveragePercent: Double? {
    // A count headline replaces the percentage rather than sitting beside it.
    guard assayCountHeadline == nil else { return nil }
    return coveredBases.map { Double($0) * 100 / Double(referenceLength) }
  }
  public let intervals: [PrimerReviewInterval]
  public let primers: [PrimerReviewPrimer]
  public let notes: [String]
  /// Visible explanations of how the engine reached this coverage.
  public var advisories: [PrimerSchemeCoverageAdvisory] = []
  public var sourceResultID: String = ""
  public var referenceID: String = ""
  public var presentation: Presentation = .schemeReference

  public init(
    id: String,
    label: String,
    referenceLength: Int,
    coverageLabel: String,
    coveredBases: Int?,
    assayCountHeadline: Int? = nil,
    intervals: [PrimerReviewInterval],
    primers: [PrimerReviewPrimer],
    notes: [String],
    advisories: [PrimerSchemeCoverageAdvisory] = [],
    sourceResultID: String = "",
    referenceID: String = "",
    presentation: Presentation = .schemeReference
  ) {
    self.id = id
    self.label = label
    self.referenceLength = referenceLength
    self.coverageLabel = coverageLabel
    self.coveredBases = coveredBases
    self.assayCountHeadline = assayCountHeadline
    self.intervals = intervals
    self.primers = primers
    self.notes = notes
    self.advisories = advisories
    self.sourceResultID = sourceResultID
    self.referenceID = referenceID
    self.presentation = presentation
  }
}

public enum PrimerDesignReview {
  public static func coveredBases(_ intervals: [PrimerReviewInterval]) -> Int {
    var total = 0
    var end = 0
    for interval in intervals.sorted(by: { $0.start < $1.start }) {
      if interval.end > end { total += interval.end - max(end, interval.start); end = interval.end }
    }
    return total
  }

  public static func primalScheme(id: String, label: String, reference: Data, amplicons: Data?,
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
        spans[fields[0], default: []].append(.init(id: "\(id)-span-\(index)", start: start, end: end, pool: pool,
          nativePool: String(pool), name: fields[3]))
      }
    }
    return names.map { name in
      var intervals = spans[name] ?? []
      var targetPrimers: [PrimerReviewPrimer] = primers.filter { $0.reference == name }.map {
        .init(id: "\(id)-primer-\($0.id)", name: $0.name, start: $0.start, end: $0.end, strand: $0.strand,
          pool: $0.pool, nativePool: String($0.pool), sequence: $0.sequence)
      }
      associateNativeAmplicons(intervals: &intervals, primers: &targetPrimers)
      return PrimerTargetDesignReview(id: "\(id)-\(name)", label: "\(label) · \(labels[name] ?? name)",
        referenceLength: lengths[name]!, coverageLabel: "Reference spanned by amplicons",
        coveredBases: amplicons == nil ? nil : coveredBases(intervals), intervals: intervals,
        primers: targetPrimers, notes: ["Denominator: the full saved mapping reference. Overlapping amplicon spans count once; primer sequences are included.",
          amplicons == nil ? "No saved amplicon BED is available; coverage is unknown." : "Positional reference coverage does not establish coverage of every alignment row or successful amplification."],
        sourceResultID: id, referenceID: name)
    }
  }

  public static func primer3(_ normalized: Primer3NormalizedResults) -> [PrimerTargetDesignReview] {
    normalized.results.flatMap { result -> [PrimerTargetDesignReview] in
      if result.pairs.isEmpty {
        return [.init(id: result.resultID.uuidString, label: result.title, referenceLength: result.templateSequence.utf8.count,
          coverageLabel: "Template spanned by candidate", coveredBases: 0, intervals: [], primers: [],
          notes: [result.error ?? result.explanation ?? "No candidate primer pairs were returned."],
          sourceResultID: result.resultID.uuidString, referenceID: result.sourceRecordID,
          presentation: .primer3Template)]
      }
      return result.pairs.enumerated().map { index, pair in
        let oligos = [pair.left, pair.right] + (pair.internalOligo.map { [$0] } ?? [])
        let interval = PrimerReviewInterval(id: pair.id.uuidString, start: pair.left.start, end: pair.right.end, pool: nil,
          name: "Candidate \(index + 1)", primerIDs: oligos.map { $0.id.uuidString }, sizeLabel: "Product size on saved template")
        return .init(id: pair.id.uuidString, label: "\(result.title) · Candidate \(index + 1)",
          referenceLength: result.templateSequence.utf8.count, coverageLabel: "Template spanned by this candidate",
          coveredBases: interval.end - interval.start, intervals: [interval],
          primers: oligos.map {
            .init(id: $0.id.uuidString, name: $0.id == pair.internalOligo?.id ? "Internal probe" : ($0.orientation == .forward ? "Forward primer" : "Reverse primer"),
              start: $0.start, end: $0.end, strand: $0.orientation == .forward ? "+" : "-", pool: nil,
              role: $0.id == pair.internalOligo?.id ? .probe : ($0.orientation == .forward ? .forward : .reverse),
              sequence: $0.sequence, ampliconIDs: [interval.id])
          }, notes: ["Alternative candidates are shown separately, not combined into a scheme.",
            "Denominator: the full saved template, not a selected subregion. Positional span is not an assay-success estimate."],
          sourceResultID: result.resultID.uuidString, referenceID: result.sourceRecordID,
          presentation: .primer3Template)
      }
    }
  }

  /// Selected native variants form forward/reverse clouds. Their shared amplicon
  /// name identifies membership; numbered suffixes do not establish ranks or pairs.
  /// Called separately for each saved native result and reference to prevent cross-target joins.
  private static func associateNativeAmplicons(intervals: inout [PrimerReviewInterval], primers: inout [PrimerReviewPrimer]) {
    struct Membership { let index: Int; let side: String }
    let pattern = try! NSRegularExpression(pattern: "^([A-Za-z0-9-]+_[0-9]+)_(LEFT|RIGHT|PROBE)_([0-9]+)$")
    var groups: [String: [Membership]] = [:]
    for (index, primer) in primers.enumerated() {
      let name = primer.name as NSString
      guard let match = pattern.firstMatch(in: primer.name, range: NSRange(location: 0, length: name.length)) else { continue }
      groups[name.substring(with: match.range(at: 1)), default: []].append(
        .init(index: index, side: name.substring(with: match.range(at: 2))))
    }
    let spanCounts = Dictionary(grouping: intervals, by: \.name).mapValues(\.count)
    for index in intervals.indices {
      let span = intervals[index]
      guard spanCounts[span.name] == 1, let members = groups[span.name],
        Set(members.map { primers[$0.index].name }).count == members.count,
        members.allSatisfy({ member in
          let primer = primers[member.index]
          return primer.pool == span.pool && primer.start >= span.start && primer.end <= span.end &&
            (member.side == "PROBE" || primer.strand == (member.side == "LEFT" ? "+" : "-"))
        }) else { continue }
      let left = members.filter { $0.side == "LEFT" }.map { primers[$0.index] }
      let right = members.filter { $0.side == "RIGHT" }.map { primers[$0.index] }
      // Verify the native writer's full envelope; partial or inconsistent groups remain unlinked.
      guard !left.isEmpty, !right.isEmpty, left.map(\.start).min() == span.start,
        right.map(\.end).max() == span.end else { continue }
      intervals[index].primerIDs = members.map { primers[$0.index].id }
      for member in members { primers[member.index].ampliconIDs.append(span.id) }
    }
  }
}

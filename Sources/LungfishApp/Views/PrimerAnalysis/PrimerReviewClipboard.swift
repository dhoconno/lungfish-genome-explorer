import Foundation

/// Read-only clipboard representations of saved oligos. Reverse primers are already
/// stored in synthesis orientation; copying never reverse-complements them.
enum PrimerReviewClipboard {
  static func sequence(_ primer: PrimerReviewPrimer) -> String? {
    let sequence = primer.sequence.uppercased()
    guard !sequence.isEmpty,
      sequence.utf8.allSatisfy({ "ACGTRYSWKMBDHVN".utf8.contains($0) }) else { return nil }
    return sequence
  }

  static func coordinates(_ primer: PrimerReviewPrimer, in target: PrimerTargetDesignReview) -> String {
    "\(target.referenceID):\(primer.start + 1)-\(primer.end) (\(primer.strand)); 1-based inclusive"
  }

  static func coordinates(_ interval: PrimerReviewInterval, in target: PrimerTargetDesignReview) -> String {
    "\(target.referenceID):\(interval.start + 1)-\(interval.end); 1-based inclusive; \(interval.sizeLabel)"
  }

  static func primerFASTA(_ primer: PrimerReviewPrimer, in target: PrimerTargetDesignReview) -> String? {
    recordFASTA(primer, in: target, identifier: headerToken(primer.name))
  }

  private static func recordFASTA(_ primer: PrimerReviewPrimer, in target: PrimerTargetDesignReview, identifier: String) -> String? {
    guard let sequence = sequence(primer) else { return nil }
    let pool = primer.pool.map { " pool=\($0)" } ?? ""
    let header = "\(identifier) name=\(metadataValue(primer.name)) target=\(metadataValue(target.referenceID)) source_result=\(metadataValue(target.sourceResultID)) oligo_id=\(metadataValue(primer.id)) coordinates=\(primer.start + 1)-\(primer.end) strand=\(primer.strand)\(pool) orientation=5prime-to-3prime"
    return ">\(header)\n\(sequence)\n"
  }

  static func ampliconPrimers(_ interval: PrimerReviewInterval, in target: PrimerTargetDesignReview) -> [PrimerReviewPrimer]? {
    guard !interval.primerIDs.isEmpty, Set(interval.primerIDs).count == interval.primerIDs.count else { return nil }
    let members = target.primers.filter { interval.primerIDs.contains($0.id) }
    guard members.count == interval.primerIDs.count, Set(members.map(\.id)).count == members.count,
      members.allSatisfy({ $0.ampliconIDs.contains(interval.id) && $0.pool == interval.pool }) else { return nil }
    return members
  }

  static func ampliconFASTA(_ interval: PrimerReviewInterval, in target: PrimerTargetDesignReview) -> String? {
    guard let primers = ampliconPrimers(interval, in: target) else { return nil }
    return multipleFASTA(primers.map { (target, $0) })
  }

  static func poolFASTA(sourceResultID: String, pool: Int, targets: [PrimerTargetDesignReview]) -> String? {
    let members = targets.filter { $0.sourceResultID == sourceResultID }.flatMap { target in
      target.primers.filter { $0.pool == pool }.map { (target, $0) }
    }
    guard !members.isEmpty else { return nil }
    return multipleFASTA(members)
  }

  private static func multipleFASTA(_ members: [(PrimerTargetDesignReview, PrimerReviewPrimer)]) -> String? {
    let records = members.enumerated().compactMap { index, member in
      recordFASTA(member.1, in: member.0, identifier: "oligo_\(index + 1)|\(headerToken(member.1.name))")
    }
    return records.count == members.count ? records.joined() : nil
  }

  private static func metadataValue(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:*"))
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? headerToken(value)
  }

  private static func headerToken(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:|*"))
    let token = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    return token.isEmpty ? "unnamed" : token
  }
}

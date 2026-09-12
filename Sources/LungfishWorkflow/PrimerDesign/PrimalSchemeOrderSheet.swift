import Foundation

/// Vendor-neutral, version-one ordering worksheet derived from ARTIC BED v3.
/// Every native record remains separate, including alternative oligos. The native
/// sequence is already the oligo's 5′–3′ sequence, even on the reverse strand.
public enum PrimalSchemeOrderSheet {
  public static let filename = "ordering-v1.csv"
  public static let schemaVersion = 1

  public static func csv(fromBED bed: Data) throws -> Data {
    func invalid() -> NSError {
      NSError(domain: "PrimalSchemeOrderSheet", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Cannot prepare an order sheet from invalid primer BED records."])
    }
    guard let text = String(data: bed, encoding: .utf8) else { throw invalid() }
    var rows: [(pool: Int, index: Int, fields: [String])] = []
    for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
      if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count >= 7, !fields[0].isEmpty, !fields[3].isEmpty,
        let start = Int(fields[1]), let end = Int(fields[2]), start >= 0, end > start,
        let pool = Int(fields[4]), pool > 0, ["+", "-"].contains(fields[5]),
        !fields[6].isEmpty,
        fields[6].utf8.allSatisfy({ "ACGTRYSWKMBDHVNacgtryswkmbdhvn".utf8.contains($0) }) else { throw invalid() }
      let sequence = fields[6].uppercased()
      let ambiguous = sequence.filter { !"ACGT".contains($0) }.count
      rows.append((pool, rows.count, [String(pool), fields[3], sequence, String(sequence.count),
        fields[0], String(start + 1), String(end), fields[5], String(ambiguous), "", "", "", ""]))
    }
    let header = ["Pool", "Oligo name", "Sequence (5′–3′)", "Length (nt)", "Native reference",
      "Start (1-based inclusive)", "End (1-based inclusive)", "Strand", "Ambiguous bases",
      "Synthesis scale", "Purification", "Modifications", "Order notes"]
    let ordered = rows.sorted { $0.pool == $1.pool ? $0.index < $1.index : $0.pool < $1.pool }
    let lines = [header] + ordered.map(\.fields)
    return Data((lines.map { $0.map(escapedCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n").utf8)
  }

  /// Quoting alone does not stop spreadsheet formula evaluation. Prefix cells
  /// whose first non-whitespace character is a formula trigger with an apostrophe.
  private static func escapedCell(_ value: String) -> String {
    let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first
    let safe = first.map { "=+-@".contains($0) } == true ? "'" + value : value
    return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}

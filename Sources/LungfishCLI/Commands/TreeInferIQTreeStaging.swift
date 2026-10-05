import ArgumentParser
import Foundation
import LungfishIO

/// One in-scope MSA row as IQ-TREE sees it. IQ-TREE rewrites or truncates names with spaces,
/// `|`, `:`, parentheses or commas, so every row is staged under a safe tip ID (`t0001`, ...)
/// and mapped back to its display name after the run (ruling C3).
struct IQTreeStagedRow {
    let tipID: String
    let rowID: String
    let displayName: String
    let header: String
    let sequence: String
}

/// Resolves comma-separated row selectors against MSA rows. A selector matches a row ID first,
/// then a display name, then a source header. A name shared by several rows is an error that
/// names the candidate row IDs. Returns the matched rows in selector order without repeats.
func resolveTreeRowSelectors(
    _ text: String,
    among rows: [MultipleSequenceAlignmentBundle.Row],
    option: String
) throws -> [MultipleSequenceAlignmentBundle.Row] {
    let selectors = text.split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.isEmpty == false }
    var matched: [MultipleSequenceAlignmentBundle.Row] = []
    for selector in selectors {
        let row: MultipleSequenceAlignmentBundle.Row
        if let byID = rows.first(where: { $0.id == selector }) {
            row = byID
        } else {
            let byName = rows.filter { $0.displayName == selector }
            let candidates = byName.isEmpty ? rows.filter { $0.sourceName == selector } : byName
            guard candidates.isEmpty == false else {
                throw ValidationError("No in-scope MSA row matches '\(selector)' in \(option).")
            }
            guard candidates.count == 1 else {
                let ids = candidates.map(\.id).joined(separator: ", ")
                throw ValidationError("'\(selector)' in \(option) is ambiguous. It names rows \(ids). Use a row ID instead.")
            }
            row = candidates[0]
        }
        if matched.contains(where: { $0.id == row.id }) == false {
            matched.append(row)
        }
    }
    return matched
}

/// Picks the in-scope rows and columns, in MSA row order, and assigns safe tip IDs.
func stageIQTreeRows(
    records: [TreeAlignedFASTARecord],
    bundle: MultipleSequenceAlignmentBundle,
    rows: String?,
    columns: String?
) throws -> [IQTreeStagedRow] {
    let orderedRows = bundle.rows.sorted { $0.order < $1.order }
    guard orderedRows.count == records.count else {
        throw ValidationError("MSA bundle lists \(orderedRows.count) rows but its aligned FASTA has \(records.count) records.")
    }
    var inScope = Array(zip(orderedRows, records))
    if let rows, rows.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
        let selectedIDs = Set(try resolveTreeRowSelectors(rows, among: orderedRows, option: "--rows").map(\.id))
        inScope = inScope.filter { selectedIDs.contains($0.0.id) }
    }
    guard inScope.isEmpty == false else {
        throw ValidationError("No MSA rows matched --rows selection.")
    }
    let rowsByDisplayName = Dictionary(grouping: inScope.map(\.0), by: \.displayName)
    if let duplicate = rowsByDisplayName.filter({ $0.value.count > 1 }).min(by: { $0.key < $1.key }) {
        let ids = duplicate.value.map(\.id).joined(separator: ", ")
        throw ValidationError(
            "In-scope rows \(ids) share the display name '\(duplicate.key)'. Tree tips need distinct names, so rename one or leave it out with --rows."
        )
    }
    let columnRanges = try parseTreeColumnRanges(columns, alignedLength: bundle.manifest.alignedLength)
    return inScope.enumerated().map { index, pair in
        let (row, record) = pair
        var sequence = record.sequence
        if columnRanges.isEmpty == false {
            let characters = Array(record.sequence)
            sequence = String(columnRanges.flatMap { range in range.map { characters[$0] } })
        }
        return IQTreeStagedRow(
            tipID: String(format: "t%04d", index + 1),
            rowID: row.id,
            displayName: row.displayName,
            header: record.name,
            sequence: sequence
        )
    }
}

/// Writes artifacts/iqtree/tip-map.tsv so the raw IQ-TREE treefile stays interpretable.
func writeIQTreeTipMap(_ rows: [IQTreeStagedRow], to url: URL) throws {
    func field(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
    let lines = ["tip_id\trow_id\tdisplay_name\theader"] + rows.map { row in
        [row.tipID, row.rowID, row.displayName, row.header].map(field).joined(separator: "\t")
    }
    try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
}

/// Replaces safe tip IDs in a Newick string with quoted display names. Tip labels follow `(` or
/// `,`, and the IDs never need quoting, so a token match is exact.
func relabelIQTreeTips(in newick: String, labels: [String: String]) throws -> String {
    let regex = try NSRegularExpression(pattern: #"(?<=[(,])t[0-9]{4,}(?=[:,);\[])"#)
    let source = newick as NSString
    var result = ""
    var cursor = 0
    for match in regex.matches(in: newick, range: NSRange(location: 0, length: source.length)) {
        let tipID = source.substring(with: match.range)
        guard let label = labels[tipID] else {
            throw TreeCommandRuntimeError("IQ-TREE wrote an unknown tip \(tipID).")
        }
        result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
        result += newickQuotedLabel(label)
        cursor = match.range.location + match.range.length
    }
    result += source.substring(from: cursor)
    return result
}

/// Quotes a Newick label unless it is plain letters, digits, `_`, `.` or `-`.
func newickQuotedLabel(_ label: String) -> String {
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
    if label.isEmpty == false, label.unicodeScalars.allSatisfy({ safe.contains($0) }) {
        return label
    }
    return "'" + label.replacingOccurrences(of: "'", with: "''") + "'"
}

/// The node to root on so the outgroup tips form one side of the root (ruling C4), or nil when
/// the outgroup is not a clade of the unrooted tree. The drawn root of an IQ-TREE tree is
/// arbitrary, so a clade whose complement is a drawn subtree counts too.
func iqtreeOutgroupRootNodeID(tipIDs: Set<String>, in tree: PhylogeneticTreeNormalizedTree) -> String? {
    let nodesByID = Dictionary(uniqueKeysWithValues: tree.nodes.map { ($0.id, $0) })
    var tipsBelow: [String: Set<String>] = [:]
    func tips(_ id: String) -> Set<String> {
        if let cached = tipsBelow[id] { return cached }
        guard let node = nodesByID[id] else { return [] }
        let result = node.isTip ? [node.displayLabel] : node.childIDs.reduce(into: Set<String>()) { $0.formUnion(tips($1)) }
        tipsBelow[id] = result
        return result
    }
    let allTips = Set(tree.nodes.filter(\.isTip).map(\.displayLabel))
    let ingroup = allTips.subtracting(tipIDs)
    let candidates = tree.nodes.filter { $0.parentID != nil }
    if let node = candidates.first(where: { tips($0.id) == tipIDs }) {
        return node.id
    }
    return candidates.first(where: { tips($0.id) == ingroup })?.id
}

/// The `Seed:` value IQ-TREE logged, which is the seed it drew when none was given (ruling C1).
func parseIQTreeSeed(log: String) -> String? {
    guard let range = log.range(of: #"(?m)^Seed:\s+([0-9]+)"#, options: .regularExpression) else {
        return nil
    }
    return log[range].split(whereSeparator: \.isWhitespace).last.map(String.init)
}

import Foundation
import LungfishCore

public enum TwelveSAmpliconResultBundle {
    public static let directoryExtension = "lungfish12s"

    public static func isBundleURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == directoryExtension
    }

    public static func manifestURL(in bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent(TwelveSAmpliconResultBundleManifest.filename)
    }

    public static func loadManifest(from bundleURL: URL) throws -> TwelveSAmpliconResultBundleManifest {
        let data = try Data(contentsOf: manifestURL(in: bundleURL))
        return try JSONDecoder().decode(TwelveSAmpliconResultBundleManifest.self, from: data)
    }

    public static func writeManifest(
        _ manifest: TwelveSAmpliconResultBundleManifest,
        to bundleURL: URL
    ) throws {
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL(in: bundleURL), options: .atomic)
    }

    public static func loadResult(from bundleURL: URL) throws -> TwelveSAmpliconResultBundleData {
        try loadResult(from: bundleURL, loadUnresolvedSequences: true)
    }

    public static func loadResult(
        from bundleURL: URL,
        loadUnresolvedSequences: Bool
    ) throws -> TwelveSAmpliconResultBundleData {
        let manifest = try loadManifest(from: bundleURL)
        return try loadResult(
            from: bundleURL,
            manifest: manifest,
            loadUnresolvedSequences: loadUnresolvedSequences
        )
    }

    public static func loadSamples(from bundleURL: URL) throws -> [TwelveSAmpliconSampleResult] {
        let manifest = try loadManifest(from: bundleURL)
        return try loadSampleTable(from: resolvedURL(for: manifest.sampleTablePath, in: bundleURL))
    }

    public static func sampleIDs(in bundleURL: URL) throws -> Set<String> {
        Set(try loadSamples(from: bundleURL).map(\.sampleID))
    }

    public static func loadResult(
        from bundleURL: URL,
        manifest: TwelveSAmpliconResultBundleManifest,
        loadUnresolvedSequences: Bool = true
    ) throws -> TwelveSAmpliconResultBundleData {
        let artifacts = TwelveSAmpliconResultArtifacts(
            referenceURL: resolvedURL(for: manifest.referencePath, in: bundleURL),
            targetTableURL: resolvedURL(for: manifest.targetTablePath, in: bundleURL),
            countMatrixURL: resolvedURL(for: manifest.countMatrixPath, in: bundleURL),
            sampleTableURL: resolvedURL(for: manifest.sampleTablePath, in: bundleURL),
            readFateURL: resolvedURL(for: manifest.readFatePath, in: bundleURL),
            alternateMatchesTableURL: manifest.alternateMatchesTablePath.map { resolvedURL(for: $0, in: bundleURL) },
            unresolvedTableURL: manifest.unresolvedTablePath.map { resolvedURL(for: $0, in: bundleURL) },
            unresolvedFastaURL: manifest.unresolvedFastaPath.map { resolvedURL(for: $0, in: bundleURL) },
            reassignmentsURL: manifest.reassignmentsTablePath.map { resolvedURL(for: $0, in: bundleURL) },
            resolvedSampleMetadataURL: manifest.resolvedSampleMetadataPath.map { resolvedURL(for: $0, in: bundleURL) },
            sampleMetadataManifestURL: manifest.sampleMetadataManifestPath.map { resolvedURL(for: $0, in: bundleURL) },
            analysisSampleMetadataOriginalURL: manifest.analysisSampleMetadataOriginalPath.map { resolvedURL(for: $0, in: bundleURL) },
            provenanceURL: resolvedURL(for: manifest.provenancePath, in: bundleURL)
        )
        let samples = try loadSampleTable(from: artifacts.sampleTableURL)
        let readFate = try JSONDecoder().decode(
            TwelveSAmpliconReadFate.self,
            from: Data(contentsOf: artifacts.readFateURL)
        )
        let unresolvedSequences = loadUnresolvedSequences
            ? try artifacts.unresolvedTableURL.map(loadUnresolvedSequenceTable(from:)) ?? []
            : []
        let reassignments: [TwelveSReassignmentRecord]
        if let reassignmentsURL = artifacts.reassignmentsURL,
           FileManager.default.fileExists(atPath: reassignmentsURL.path) {
            reassignments = loadReassignments(from: reassignmentsURL)
        } else {
            reassignments = []
        }
        let targets: [TwelveSAmpliconTarget]
        let countRows: [String: [String: Int]]
        if loadUnresolvedSequences {
            var loadedTargets = try loadTargets(from: artifacts.targetTableURL)
            let targetIDs = Set(loadedTargets.map(\.targetID))
            countRows = try loadCountRows(from: artifacts.countMatrixURL, validTargetIDs: targetIDs)
            loadedTargets = try attachAlternateMatches(
                to: loadedTargets,
                from: artifacts.alternateMatchesTableURL
            )
            targets = loadedTargets
        } else {
            countRows = try loadCountRows(from: artifacts.countMatrixURL, validTargetIDs: nil)
            var includedTargetIDs = Set(countRows.keys)
            includedTargetIDs.formUnion(reassignments.map(\.toTargetID))
            var loadedTargets = try loadTargets(
                from: artifacts.targetTableURL,
                includedTargetIDs: includedTargetIDs
            )
            let loadedTargetIDs = Set(loadedTargets.map(\.targetID))
            if let unknownTargetID = includedTargetIDs.sorted().first(where: { !loadedTargetIDs.contains($0) }) {
                throw TwelveSAmpliconResultBundleError.unknownTarget(targetID: unknownTargetID)
            }
            loadedTargets = try attachAlternateMatches(
                to: loadedTargets,
                from: artifacts.alternateMatchesTableURL
            )
            targets = loadedTargets
        }
        let sampleMetadata = try artifacts.resolvedSampleMetadataURL.flatMap { url in
            FileManager.default.fileExists(atPath: url.path) ? try ResolvedSampleMetadata.loadTSV(from: url) : nil
        }
        let sampleMetadataManifest = try artifacts.sampleMetadataManifestURL.flatMap { url in
            FileManager.default.fileExists(atPath: url.path)
                ? try JSONDecoder().decode(TwelveSSampleMetadataSnapshotManifest.self, from: Data(contentsOf: url))
                : nil
        }
        let scientificNameRows = TwelveSAmpliconResultBundleData.buildScientificNameRows(
            targets: targets,
            samples: samples,
            countRows: countRows
        )

        return TwelveSAmpliconResultBundleData(
            bundleURL: bundleURL,
            manifest: manifest,
            artifacts: artifacts,
            samples: samples,
            targets: targets,
            countRows: countRows,
            readFate: readFate,
            unresolvedSequences: unresolvedSequences,
            reassignments: reassignments,
            sampleMetadata: sampleMetadata,
            sampleMetadataManifest: sampleMetadataManifest,
            scientificNameRows: scientificNameRows
        )
    }

    public static func loadUnresolvedSequences(fromBundle bundleURL: URL) throws -> [TwelveSUnresolvedSequence] {
        let manifest = try loadManifest(from: bundleURL)
        return try loadUnresolvedSequences(fromBundle: bundleURL, manifest: manifest)
    }

    public static func loadUnresolvedSequences(
        fromBundle bundleURL: URL,
        manifest: TwelveSAmpliconResultBundleManifest
    ) throws -> [TwelveSUnresolvedSequence] {
        guard let unresolvedTablePath = manifest.unresolvedTablePath else { return [] }
        let url = resolvedURL(for: unresolvedTablePath, in: bundleURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try loadUnresolvedSequenceTable(from: url)
    }

    public static func resolvedURL(for path: String, in bundleURL: URL) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed).standardizedFileURL
        }
        return bundleURL.appendingPathComponent(trimmed).standardizedFileURL
    }

    private static func loadTargets(
        from url: URL,
        includedTargetIDs: Set<String>? = nil
    ) throws -> [TwelveSAmpliconTarget] {
        let content = try normalizedTSVContent(from: url)
        let lines = nonEmptyTSVLines(in: content)
        guard let headerLine = lines.first else { return [] }
        let headers = splitTSVLine(headerLine).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let columnIndexes = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($0.element, $0.offset) })
        let knownColumns: Set<String> = [
            "target_id", "display_name", "scientific_name", "common_name",
            "taxid", "taxon_group", "taxonomy", "name_source",
            "locus", "length", "source_header"
        ]
        func value(named column: String, in fields: [Substring]) -> String? {
            guard let index = columnIndexes[column], index < fields.count else { return nil }
            return String(fields[index])
        }

        var targets: [TwelveSAmpliconTarget] = []
        targets.reserveCapacity(includedTargetIDs?.count ?? max(0, lines.count - 1))
        for line in lines.dropFirst() {
            let fields: [Substring]
            let targetID: String
            if let includedTargetIDs {
                targetID = try required(
                    String(firstTSVField(in: line)),
                    column: "target_id",
                    file: url.lastPathComponent
                )
                guard includedTargetIDs.contains(targetID) else { continue }
                fields = splitTSVLine(line)
            } else {
                fields = splitTSVLine(line)
                targetID = try required(
                    value(named: "target_id", in: fields),
                    column: "target_id",
                    file: url.lastPathComponent
                )
            }
            let displayName = nonEmpty(value(named: "display_name", in: fields)) ?? targetID
            let sourceHeader = nonEmpty(value(named: "source_header", in: fields))
            var metadata: [String: String] = [:]
            for (index, header) in headers.enumerated() {
                guard !header.isEmpty, !knownColumns.contains(header), index < fields.count else { continue }
                let field = fields[index]
                guard !field.isEmpty else { continue }
                metadata[header] = String(field)
            }
            if let header = sourceHeader {
                for field in header.split(separator: "|").dropFirst() {
                    let pieces = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard pieces.count == 2 else { continue }
                    let value = pieces[1]
                    guard !value.isEmpty else { continue }
                    metadata[String(pieces[0])] = String(value)
                }
            }
            targets.append(TwelveSAmpliconTarget(
                targetID: targetID,
                displayName: displayName,
                scientificName: nonEmpty(value(named: "scientific_name", in: fields)),
                commonName: nonEmpty(value(named: "common_name", in: fields)),
                taxid: nonEmpty(value(named: "taxid", in: fields)),
                taxonGroup: nonEmpty(value(named: "taxon_group", in: fields)),
                taxonomy: nonEmpty(value(named: "taxonomy", in: fields)),
                nameSource: nonEmpty(value(named: "name_source", in: fields)),
                locus: nonEmpty(value(named: "locus", in: fields)),
                length: try optionalInt(value(named: "length", in: fields), column: "length", file: url.lastPathComponent),
                sourceHeader: sourceHeader,
                metadata: metadata
            ))
        }
        return targets
    }

    private static func attachAlternateMatches(
        to targets: [TwelveSAmpliconTarget],
        from url: URL?
    ) throws -> [TwelveSAmpliconTarget] {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return targets
        }
        let alternateMatches = try loadAlternateMatches(from: url)
        guard !alternateMatches.isEmpty else { return targets }
        return targets.map { target in
            target.withAlternateMatches(alternateMatches[target.targetID, default: []])
        }
    }

    private static func loadAlternateMatches(from url: URL) throws -> [String: [TwelveSAlternateMatch]] {
        var matchesByTarget: [String: [TwelveSAlternateMatch]] = [:]
        for row in try loadTSVRows(from: url) {
            let targetID = try required(row["target_id"], column: "target_id", file: url.lastPathComponent)
            let displayName = nonEmpty(row["display_name"])
                ?? nonEmpty(row["scientific_name"])
                ?? targetID
            matchesByTarget[targetID, default: []].append(
                TwelveSAlternateMatch(
                    displayName: displayName,
                    scientificName: nonEmpty(row["scientific_name"]),
                    commonName: nonEmpty(row["common_name"]),
                    taxid: nonEmpty(row["taxid"]),
                    taxonGroup: nonEmpty(row["taxon_group"]),
                    taxonomy: nonEmpty(row["taxonomy"]),
                    nameSource: nonEmpty(row["name_source"]),
                    reason: nonEmpty(row["reason"])
                )
            )
        }
        return matchesByTarget
    }

    private static func loadReassignments(from url: URL) -> [TwelveSReassignmentRecord] {
        guard let table = try? loadTSVRows(from: url) else { return [] }
        var records: [TwelveSReassignmentRecord] = []
        for row in table {
            guard let sequenceID = nonEmpty(row["sequence_id"]),
                  let sampleID = nonEmpty(row["sample_id"]),
                  let toSpecies = nonEmpty(row["to_species"]),
                  let toTargetID = nonEmpty(row["to_target_id"]),
                  let readsText = nonEmpty(row["reads"]),
                  let reads = Int(readsText) else {
                continue
            }
            let decidedBy = nonEmpty(row["decided_by"]) ?? "pooled"
            let candidateSpecies = (nonEmpty(row["candidate_species"]) ?? "")
                .split(separator: ";", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            records.append(
                TwelveSReassignmentRecord(
                    sequenceID: sequenceID,
                    sampleID: sampleID,
                    toSpecies: toSpecies,
                    toTargetID: toTargetID,
                    reads: reads,
                    decidedBy: decidedBy,
                    candidateSpecies: candidateSpecies
                )
            )
        }
        return records
    }

    private static func loadSampleTable(from url: URL) throws -> [TwelveSAmpliconSampleResult] {
        try loadTSVRows(from: url).map { row in
            let sampleID = try required(
                row["sample_id"] ?? row["sample"],
                column: "sample_id",
                file: url.lastPathComponent
            )
            let inputReads = try requiredInt(row["input_reads"], column: "input_reads", file: url.lastPathComponent)
            let exactMatchReads = try requiredInt(
                row["exact_match_reads"],
                column: "exact_match_reads",
                file: url.lastPathComponent
            )
            let unresolvedReads = try requiredInt(
                row["unresolved_reads"],
                column: "unresolved_reads",
                file: url.lastPathComponent
            )
            let ambiguousExactReads = try optionalInt(
                row["ambiguous_exact_reads"],
                column: "ambiguous_exact_reads",
                file: url.lastPathComponent
            ) ?? 0
            let chimeraCandidateReads = try optionalInt(
                row["chimera_candidate_reads"],
                column: "chimera_candidate_reads",
                file: url.lastPathComponent
            ) ?? 0
            let reassignedReads = try optionalInt(
                row["reassigned_reads"],
                column: "reassigned_reads",
                file: url.lastPathComponent
            ) ?? 0
            return TwelveSAmpliconSampleResult(
                sampleID: sampleID,
                displayName: nonEmpty(row["display_name"]) ?? nonEmpty(row["sample_name"]) ?? sampleID,
                inputReads: inputReads,
                exactMatchReads: exactMatchReads,
                unresolvedReads: unresolvedReads,
                ambiguousExactReads: ambiguousExactReads,
                chimeraCandidateReads: chimeraCandidateReads,
                reassignedReads: reassignedReads,
                exactMatchPercent: optionalDouble(row["exact_match_percent"]) ?? percent(exactMatchReads, inputReads),
                unresolvedPercent: optionalDouble(row["unresolved_percent"]) ?? percent(unresolvedReads, inputReads)
            )
        }
    }

    private static func loadCountRows(
        from url: URL,
        validTargetIDs: Set<String>?
    ) throws -> [String: [String: Int]] {
        let content = try normalizedTSVContent(from: url)
        let lines = nonEmptyTSVLines(in: content)
        guard let headerLine = lines.first else {
            return [:]
        }
        let headers = splitTSVLine(headerLine).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let targetIndex = headers.firstIndex(of: "target_id") else {
            throw TwelveSAmpliconResultBundleError.missingColumn(
                file: url.lastPathComponent,
                column: "target_id"
            )
        }
        let sampleColumns = headers.enumerated()
            .filter { index, header in index != targetIndex && !header.isEmpty }
            .map { index, header in (index: index, sampleID: header) }
        var rowsByTarget: [String: [String: Int]] = [:]
        rowsByTarget.reserveCapacity(max(0, lines.count - 1))
        for line in lines.dropFirst() {
            let fields = splitTSVLine(line)
            guard targetIndex < fields.count, !fields[targetIndex].isEmpty else {
                throw TwelveSAmpliconResultBundleError.missingColumn(
                    file: url.lastPathComponent,
                    column: "target_id"
                )
            }
            let targetID = String(fields[targetIndex])
            if let validTargetIDs, !validTargetIDs.contains(targetID) {
                throw TwelveSAmpliconResultBundleError.unknownTarget(targetID: targetID)
            }
            var counts: [String: Int] = [:]
            counts.reserveCapacity(min(sampleColumns.count, 4))
            for sampleColumn in sampleColumns {
                guard sampleColumn.index < fields.count, !fields[sampleColumn.index].isEmpty else {
                    throw TwelveSAmpliconResultBundleError.missingColumn(
                        file: url.lastPathComponent,
                        column: sampleColumn.sampleID
                    )
                }
                let field = fields[sampleColumn.index]
                if field == "0" {
                    continue
                }
                guard let count = Int(field) else {
                    throw TwelveSAmpliconResultBundleError.invalidInteger(
                        file: url.lastPathComponent,
                        column: sampleColumn.sampleID,
                        value: String(field)
                    )
                }
                if count > 0 {
                    counts[sampleColumn.sampleID] = count
                }
            }
            if !counts.isEmpty {
                rowsByTarget[targetID] = counts
            }
        }
        return rowsByTarget
    }

    private static func loadUnresolvedSequenceTable(from url: URL) throws -> [TwelveSUnresolvedSequence] {
        try loadTSVRows(from: url).map { row in
            let statusText = nonEmpty(row["chimera_status"]) ?? TwelveSChimeraStatus.notReviewed.rawValue
            return TwelveSUnresolvedSequence(
                sequenceID: try required(row["sequence_id"], column: "sequence_id", file: url.lastPathComponent),
                sequence: try required(row["sequence"], column: "sequence", file: url.lastPathComponent),
                readCount: try requiredInt(row["read_count"], column: "read_count", file: url.lastPathComponent),
                sampleCounts: try parseSampleCounts(row["sample_counts"], file: url.lastPathComponent),
                chimeraStatus: TwelveSChimeraStatus(rawValue: statusText) ?? .notReviewed,
                note: nonEmpty(row["note"])
            )
        }
    }

    private struct TSVTable {
        let headers: [String]
        let rows: [[String: String]]
    }

    private static func loadTSVRows(from url: URL) throws -> [[String: String]] {
        try loadTSVTable(from: url).rows
    }

    private static func loadTSVTable(from url: URL) throws -> TSVTable {
        let content = try normalizedTSVContent(from: url)
        let lines = nonEmptyTSVLines(in: content)
        guard let headerLine = lines.first else {
            return TSVTable(headers: [], rows: [])
        }
        let headers = splitTSVLine(headerLine).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let rows = lines.dropFirst().map { line in
            let fields = splitTSVLine(line)
            var row: [String: String] = [:]
            for index in headers.indices {
                guard !headers[index].isEmpty else { continue }
                row[headers[index]] = index < fields.count ? String(fields[index]) : ""
            }
            return row
        }
        return TSVTable(headers: headers, rows: rows)
    }

    private static func splitTSVLine(_ line: String) -> [String] {
        line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    }

    private static func splitTSVLine(_ line: Substring) -> [Substring] {
        line.split(separator: "\t", omittingEmptySubsequences: false)
    }

    private static func firstTSVField(in line: Substring) -> Substring {
        guard let tabIndex = line.firstIndex(of: "\t") else { return line }
        return line[..<tabIndex]
    }

    private static func normalizedTSVContent(from url: URL) throws -> String {
        let content = try String(contentsOf: url, encoding: .utf8)
        guard content.contains("\r") else { return content }
        return content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func nonEmptyTSVLines(in content: String) -> [Substring] {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isBlankTSVLine($0) }
    }

    private static func isBlankTSVLine(_ line: Substring) -> Bool {
        line.allSatisfy { character in
            character == " " || character == "\t"
        }
    }

    private static func parseSampleCounts(_ value: String?, file: String) throws -> [String: Int] {
        guard let value = nonEmpty(value) else { return [:] }
        var counts: [String: Int] = [:]
        for token in value.split(separator: ",", omittingEmptySubsequences: true) {
            let pieces = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let sampleID = String(pieces[0])
            let countText = String(pieces[1])
            guard let count = Int(countText) else {
                throw TwelveSAmpliconResultBundleError.invalidInteger(
                    file: file,
                    column: "sample_counts",
                    value: countText
                )
            }
            counts[sampleID] = count
        }
        return counts
    }

    private static func required(_ value: String?, column: String, file: String) throws -> String {
        guard let value = nonEmpty(value) else {
            throw TwelveSAmpliconResultBundleError.missingColumn(file: file, column: column)
        }
        return value
    }

    private static func requiredInt(_ value: String?, column: String, file: String) throws -> Int {
        guard let value = nonEmpty(value) else {
            throw TwelveSAmpliconResultBundleError.missingColumn(file: file, column: column)
        }
        guard let intValue = Int(value) else {
            throw TwelveSAmpliconResultBundleError.invalidInteger(file: file, column: column, value: value)
        }
        return intValue
    }

    private static func optionalInt(_ value: String?, column: String, file: String) throws -> Int? {
        guard let value = nonEmpty(value) else { return nil }
        guard let intValue = Int(value) else {
            throw TwelveSAmpliconResultBundleError.invalidInteger(file: file, column: column, value: value)
        }
        return intValue
    }

    private static func optionalDouble(_ value: String?) -> Double? {
        guard var text = nonEmpty(value) else { return nil }
        if text.hasSuffix("%") {
            text.removeLast()
        }
        return Double(text.replacingOccurrences(of: ",", with: ""))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func percent(_ numerator: Int, _ denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return Double(numerator) / Double(denominator) * 100
    }
}

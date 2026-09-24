import Foundation

extension NCBIService {
    /// Resolves an explicit list without search filters or pagination. EFetch is
    /// used because ESummary can silently replace a requested historical version.
    /// Results are all-or-nothing and retain the first occurrence of each version.
    public func lookupNucleotideAccessions(_ accessions: [String]) async throws -> SearchResults {
        try Task.checkCancellation()
        for accession in accessions where !GenBankAccessionParser.isNucleotideAccession(accession) {
            throw DatabaseServiceError.invalidQuery(reason: "Invalid GenBank nucleotide accession: \(accession)")
        }
        var requested = Set<String>()
        var resolved = Set<String>()
        var records: [SearchResultRecord] = []
        for rawAccession in accessions {
            try Task.checkCancellation()
            let accession = rawAccession.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard requested.insert(accession).inserted else { continue }
            do {
                let data = try await efetch(database: .nucleotide, ids: [accession], format: .genbank)
                try Task.checkCancellation()
                let record = try Self.nucleotideLookupRecord(data: data, requested: accession)
                if resolved.insert(record.accession).inserted {
                    records.append(record)
                }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw error
                }
                if let serviceError = error as? DatabaseServiceError, case .cancelled = serviceError {
                    throw error
                }
                throw DatabaseServiceError.serverError(
                    message: "Could not resolve GenBank accession \(accession): \(error.localizedDescription)"
                )
            }
        }
        try Task.checkCancellation()
        return SearchResults(totalCount: records.count, records: records, hasMore: false, nextCursor: nil)
    }

    private static func nucleotideLookupRecord(data: Data, requested: String) throws -> SearchResultRecord {
        guard let text = String(data: data, encoding: .utf8) else {
            throw DatabaseServiceError.parseError(message: "Invalid GenBank text encoding")
        }
        let lines = text.components(separatedBy: .newlines)
        guard lines.filter({ $0.hasPrefix("LOCUS ") }).count == 1,
              let versionLine = lines.first(where: { $0.hasPrefix("VERSION ") }),
              let version = versionLine.split(whereSeparator: { $0.isWhitespace }).dropFirst().first.map(String.init),
              version.range(of: #"\.[1-9][0-9]*$"#, options: .regularExpression) != nil else {
            throw DatabaseServiceError.notFound(accession: requested)
        }
        let requestedBase = requested.split(separator: ".").first.map(String.init)
        let resolvedBase = version.split(separator: ".").first.map(String.init)
        guard requestedBase == resolvedBase, !requested.contains(".") || requested == version else {
            throw DatabaseServiceError.parseError(
                message: "NCBI returned \(version) for \(requested); the requested accession/version was not substituted."
            )
        }
        var title = ""
        var organism: String?
        var length: Int?
        var inDefinition = false
        for line in lines {
            if line.hasPrefix("LOCUS ") {
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                if fields.count > 2 { length = Int(fields[2]) }
            }
            if line.hasPrefix("DEFINITION ") {
                title = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
                inDefinition = true
            } else if inDefinition && line.hasPrefix("            ") {
                title += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                inDefinition = false
            }
            if line.hasPrefix("  ORGANISM ") {
                organism = String(line.dropFirst(12)).trimmingCharacters(in: .whitespaces)
            }
            if line.hasPrefix("FEATURES") || line.hasPrefix("ORIGIN") { break }
        }
        return SearchResultRecord(
            id: version, accession: version, title: title.isEmpty ? version : title,
            organism: organism, length: length, source: .ncbi
        )
    }
}

import CryptoKit
import Foundation
import LungfishIO

public enum AmpliconGenotypeScientificArtifactPublisherError: Error, Equatable, LocalizedError, Sendable {
    case malformedGenotypeCSV(String)
    case invalidReadCount(sample: String, genotype: String)
    case duplicateReferenceRecord(String)
    case missingReferenceRecord(String)
    case conflictingLoci(String)
    case outputOutsideBundle(String)

    public var errorDescription: String? {
        switch self {
        case .malformedGenotypeCSV(let detail):
            return "The genotype summary CSV is malformed: \(detail)"
        case .invalidReadCount(let sample, let genotype):
            return "The genotype summary has an invalid read count for \(sample), \(genotype)."
        case .duplicateReferenceRecord(let identifier):
            return "The run reference FASTA contains duplicate record '\(identifier)'."
        case .missingReferenceRecord(let identifier):
            return "The observed provisional genotype is absent from the exact run reference FASTA: \(identifier)."
        case .conflictingLoci(let genotype):
            return "The observed provisional genotype maps to conflicting loci: \(genotype)."
        case .outputOutsideBundle(let path):
            return "A scientific artifact output is outside the result bundle: \(path)."
        }
    }
}

public struct AmpliconGenotypeScientificArtifactPublication: Equatable, Sendable {
    public let alignmentArtifacts: ONTGenotypeAlignmentArtifactManifest
    public let provisionalExon2Artifacts: ONTGenotypeProvisionalExon2ArtifactManifest?
    public let provisionalExon2Document: ONTGenotypeProvisionalExon2Document?
    public let catalogJSONURL: URL?
    public let sequencesFASTAURL: URL?
    public let argv: [String]
    public let startedAt: Date
    public let completedAt: Date

    public var outputURLs: [URL] {
        [catalogJSONURL, sequencesFASTAURL].compactMap { $0 }
    }

    public var reviewableRowCandidates: [GenotypeReviewableRowCandidate] {
        provisionalExon2Document?.records.map(
            GenotypeReviewableRowCandidate.init(provisionalExon2:)
        ) ?? []
    }
}

public struct AmpliconGenotypeScientificArtifactPublisher: Sendable {
    private struct MutableSupport {
        var passedAlignments: Int
        var passedUniqueReads: Int
        var loci: Set<String>
    }

    private let dateProvider: @Sendable () -> Date

    public init(dateProvider: @escaping @Sendable () -> Date = Date.init) {
        self.dateProvider = dateProvider
    }

    public func publish(
        reportCSVURL: URL,
        referenceFASTAURL: URL,
        retainedBAMURL: URL,
        retainedBAIURL: URL,
        outputDirectoryURL: URL
    ) throws -> AmpliconGenotypeScientificArtifactPublication {
        let startedAt = dateProvider()
        let calls = try loadCalls(from: reportCSVURL)
            .filter { isAssignedSample($0.sample) }
        let provisionalCalls = calls.filter {
            $0.genotype.localizedCaseInsensitiveContains("_nov")
        }
        let identifiers = Set(provisionalCalls.map(\.genotype))
        let sequenceDirectory = outputDirectoryURL
            .appendingPathComponent("artifacts/sequences", isDirectory: true)
        let catalogURL = sequenceDirectory.appendingPathComponent("observed-provisional-exon2.json")
        let fastaURL = sequenceDirectory.appendingPathComponent("observed-provisional-exon2.fasta")
        let argv = [
            "lungfish-internal",
            "publish-provisional-exon2",
            "--genotypes-csv", reportCSVURL.standardizedFileURL.path,
            "--reference-fasta", referenceFASTAURL.standardizedFileURL.path,
            "--retained-bam", retainedBAMURL.standardizedFileURL.path,
            "--retained-bai", retainedBAIURL.standardizedFileURL.path,
            "--output-json", catalogURL.standardizedFileURL.path,
            "--output-fasta", fastaURL.standardizedFileURL.path,
            "--identifier-rule", "case-insensitive-_nov",
            "--sample-scope", "assigned-only",
            "--fasta-wrap", "80",
        ]

        let alignmentArtifacts = ONTGenotypeAlignmentArtifactManifest(
            genotypingEvidence: ONTMHCBAMArtifactPair(
                bam: try artifactReference(
                    for: retainedBAMURL,
                    in: outputDirectoryURL
                ),
                bai: try artifactReference(
                    for: retainedBAIURL,
                    in: outputDirectoryURL
                )
            ),
            reciprocalEvidence: nil
        )

        guard !identifiers.isEmpty else {
            try removeStaleArtifactIfPresent(catalogURL)
            try removeStaleArtifactIfPresent(fastaURL)
            return AmpliconGenotypeScientificArtifactPublication(
                alignmentArtifacts: alignmentArtifacts,
                provisionalExon2Artifacts: nil,
                provisionalExon2Document: nil,
                catalogJSONURL: nil,
                sequencesFASTAURL: nil,
                argv: argv,
                startedAt: startedAt,
                completedAt: dateProvider()
            )
        }

        var sequencesByID: [String: String] = [:]
        try FASTAReader(url: referenceFASTAURL).forEachSequenceSync(alphabet: .dna) { sequence in
            guard identifiers.contains(sequence.name) else { return }
            guard sequencesByID[sequence.name] == nil else {
                throw AmpliconGenotypeScientificArtifactPublisherError
                    .duplicateReferenceRecord(sequence.name)
            }
            sequencesByID[sequence.name] = sequence.asString().uppercased()
        }
        if let missing = identifiers.sorted().first(where: { sequencesByID[$0] == nil }) {
            throw AmpliconGenotypeScientificArtifactPublisherError.missingReferenceRecord(missing)
        }

        var supportByGenotypeAndSample:
            [String: [String: MutableSupport]] = [:]
        for call in provisionalCalls {
            var support = supportByGenotypeAndSample[call.genotype]?[call.sample]
                ?? MutableSupport(
                passedAlignments: 0,
                passedUniqueReads: 0,
                loci: []
            )
            support.passedAlignments += call.passedAlignments
            support.passedUniqueReads += call.passedUniqueReads
            support.loci.insert(call.locusGroup)
            supportByGenotypeAndSample[call.genotype, default: [:]][call.sample] =
                support
        }

        let records = try identifiers.sorted().map { genotype in
            let matchingSupport = (supportByGenotypeAndSample[genotype] ?? [:])
                .sorted {
                    $0.key.localizedStandardCompare($1.key) == .orderedAscending
                }
            let loci = matchingSupport.reduce(into: Set<String>()) {
                $0.formUnion($1.value.loci)
            }
            guard loci.count == 1, let locus = loci.first else {
                throw AmpliconGenotypeScientificArtifactPublisherError.conflictingLoci(genotype)
            }
            let sequence = sequencesByID[genotype] ?? ""
            return ONTGenotypeProvisionalExon2Record(
                genotype: genotype,
                locus: locus,
                fastaRecordID: genotype,
                sequenceLength: sequence.utf8.count,
                sequenceSHA256: sha256(Data(sequence.utf8)),
                sampleSupport: matchingSupport.map {
                    ONTGenotypeProvisionalExon2SampleSupport(
                        sample: $0.key,
                        passedAlignments: $0.value.passedAlignments,
                        passedUniqueReads: $0.value.passedUniqueReads
                    )
                }
            )
        }
        let document = ONTGenotypeProvisionalExon2Document(records: records)
        try FileManager.default.createDirectory(
            at: sequenceDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var jsonData = try encoder.encode(document)
        jsonData.append(0x0a)
        try jsonData.write(to: catalogURL, options: .atomic)
        let fastaText = records.map { record in
            let sequence = sequencesByID[record.genotype] ?? ""
            return ">\(record.genotype) provisional_exon_2\n\(wrapped(sequence, width: 80))"
        }.joined(separator: "\n") + "\n"
        try Data(fastaText.utf8).write(to: fastaURL, options: .atomic)

        let provisionalArtifacts = ONTGenotypeProvisionalExon2ArtifactManifest(
            schemaVersion: ONTGenotypeProvisionalExon2Document.supportedSchemaVersion,
            catalogJSON: try artifactReference(for: catalogURL, in: outputDirectoryURL),
            sequencesFASTA: try artifactReference(for: fastaURL, in: outputDirectoryURL)
        )
        return AmpliconGenotypeScientificArtifactPublication(
            alignmentArtifacts: alignmentArtifacts,
            provisionalExon2Artifacts: provisionalArtifacts,
            provisionalExon2Document: document,
            catalogJSONURL: catalogURL.standardizedFileURL,
            sequencesFASTAURL: fastaURL.standardizedFileURL,
            argv: argv,
            startedAt: startedAt,
            completedAt: dateProvider()
        )
    }

    private func loadCalls(from url: URL) throws -> [ONTGenotypeCall] {
        let content = try String(contentsOf: url, encoding: .utf8)
        let rows = parseCSV(content)
        guard let headers = rows.first else { return [] }
        let indexes = Dictionary(uniqueKeysWithValues: headers.enumerated().map {
            ($0.element.trimmingCharacters(in: .whitespacesAndNewlines), $0.offset)
        })
        for required in ["sample", "genotype", "passed_alignments", "passed_unique_reads"]
        where indexes[required] == nil {
            throw AmpliconGenotypeScientificArtifactPublisherError
                .malformedGenotypeCSV("Missing required column '\(required)'.")
        }
        return try rows.dropFirst().compactMap { row in
            func value(_ name: String) -> String {
                guard let index = indexes[name], index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let sample = value("sample")
            let genotype = value("genotype")
            guard !sample.isEmpty, !genotype.isEmpty else { return nil }
            guard let passedAlignments = Int(value("passed_alignments")),
                  let passedUniqueReads = Int(value("passed_unique_reads")),
                  passedAlignments >= 0,
                  passedUniqueReads >= 0 else {
                throw AmpliconGenotypeScientificArtifactPublisherError.invalidReadCount(
                    sample: sample,
                    genotype: genotype
                )
            }
            return ONTGenotypeCall(
                sample: sample,
                genotype: genotype,
                passedAlignments: passedAlignments,
                passedUniqueReads: passedUniqueReads,
                sampleTotalReads: nil,
                sampleUniqueRetainedReads: nil,
                sampleUniqueRetainedPercent: nil,
                overallInputReads: nil,
                overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            )
        }
    }

    private func parseCSV(_ content: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = content.makeIterator()
        while let character = iterator.next() {
            switch character {
            case "\"":
                if inQuotes {
                    var peek = iterator
                    if peek.next() == "\"" {
                        field.append("\"")
                        iterator = peek
                    } else {
                        inQuotes = false
                    }
                } else {
                    inQuotes = true
                }
            case "," where !inQuotes:
                row.append(field)
                field = ""
            case "\n" where !inQuotes:
                row.append(field)
                if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    rows.append(row)
                }
                row = []
                field = ""
            case "\r" where !inQuotes:
                continue
            default:
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    private func artifactReference(
        for url: URL,
        in outputDirectoryURL: URL
    ) throws -> ONTMHCArtifactReference {
        let relative = try relativePath(from: outputDirectoryURL, to: url)
        return ONTMHCArtifactReference(
            path: relative,
            sha256: try ProvenanceFileHasher.sha256(of: url),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: url))
        )
    }

    private func relativePath(from directoryURL: URL, to fileURL: URL) throws -> String {
        let directory = directoryURL.standardizedFileURL.path
        let file = fileURL.standardizedFileURL.path
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        guard file.hasPrefix(prefix) else {
            throw AmpliconGenotypeScientificArtifactPublisherError.outputOutsideBundle(file)
        }
        return String(file.dropFirst(prefix.count))
    }

    private func removeStaleArtifactIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func wrapped(_ sequence: String, width: Int) -> String {
        stride(from: 0, to: sequence.count, by: width).map { start in
            let lower = sequence.index(sequence.startIndex, offsetBy: start)
            let upper = sequence.index(
                lower,
                offsetBy: min(width, sequence.count - start)
            )
            return String(sequence[lower..<upper])
        }.joined(separator: "\n")
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isAssignedSample(_ sample: String) -> Bool {
        let normalized = sample.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !normalized.isEmpty && normalized != "unassigned"
    }
}

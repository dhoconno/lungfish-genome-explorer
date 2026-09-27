import CryptoKit
import Foundation
import LungfishIO

/// One user-chosen source of sequences to screen candidate oligos against.
///
/// The user picks project documents, never a BLAST database. LGE builds the
/// database, so the recorded provenance names the sequences that were screened
/// rather than an opaque database prefix.
public struct PrimerScreeningSource: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case alignmentBundle
        case referenceBundle
        case fasta
    }

    public let url: URL
    public let kind: Kind

    public init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }

    /// Classifies a chosen document. Returns nil when the document is not a
    /// sequence source LGE can screen against.
    public static func classify(_ url: URL) -> Self? {
        if Primer3InputLoader.isAlignmentBundle(url) { return .init(url: url, kind: .alignmentBundle) }
        if Primer3InputLoader.isReferenceBundle(url) { return .init(url: url, kind: .referenceBundle) }
        let ext = url.pathExtension.lowercased()
        if PrimalScheme3DesignPipeline.supportedRawFASTAExtensions.contains(ext) {
            return .init(url: url, kind: .fasta)
        }
        return nil
    }

    /// The name shown in the dialog's list, without the bundle extension.
    public var displayName: String { url.deletingPathExtension().lastPathComponent }
}

/// One sequence that entered the screening database, recorded for provenance.
public struct PrimerScreeningRecord: Codable, Sendable, Equatable {
    public let sourcePath: String
    public let sourceKind: String
    public let title: String
    public let length: Int
    public let sha256: String

    public init(sourcePath: String, sourceKind: String, title: String, length: Int, sha256: String) {
        self.sourcePath = sourcePath
        self.sourceKind = sourceKind
        self.title = title
        self.length = length
        self.sha256 = sha256
    }
}

/// The built database plus everything provenance needs to describe it.
public struct PrimerScreeningDatabase: Sendable {
    /// Absolute prefix of the built nucleotide database, suitable for `-db`.
    public let prefix: String
    /// The FASTA the database was built from, inside the same staging root.
    public let fastaURL: URL
    public let records: [PrimerScreeningRecord]
    /// The exact `makeblastdb` argv, with argv[0] the resolved executable.
    public let makeblastdbArgv: [String]
    public let makeblastdbVersion: String
    public let sources: [PrimerScreeningSource]

    public var provenanceOptions: [String: ParameterValue] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let recordsJSON = (try? encoder.encode(records)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        return [
            "screeningSourcePaths": .array(sources.map { .string($0.url.path) }),
            "screeningSourceKinds": .array(sources.map { .string($0.kind.rawValue) }),
            "screeningSequenceCount": .integer(records.count),
            "screeningSequencesJSON": .string(recordsJSON),
            "screeningDatabaseArgv": .array(makeblastdbArgv.map(ParameterValue.string)),
            "screeningDatabaseToolVersion": .string(makeblastdbVersion),
            "screeningDatabaseBuiltByLGE": .boolean(true),
        ]
    }
}

public enum PrimerScreeningDatabaseError: Error, LocalizedError, Equatable {
    case noSources
    case unsupportedSource(String)
    case emptySource(String)
    case duplicateTitle(String)
    case toolUnavailable(String)
    case buildFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noSources:
            return "Choose at least one sequence source to screen against."
        case .unsupportedSource(let name):
            return "\(name) is not an alignment bundle, reference bundle, or nucleotide FASTA."
        case .emptySource(let name):
            return "\(name) contains no usable nucleotide sequences."
        case .duplicateTitle(let title):
            return "Two screening sequences share the name \(title). Rename one so BLAST hits stay identifiable."
        case .toolUnavailable(let reason):
            return "BLAST is not available to build a screening database: \(reason)"
        case .buildFailed(let reason):
            return "The screening database could not be built: \(reason)"
        }
    }
}

/// Builds a nucleotide BLAST database from project sequences with `makeblastdb`.
///
/// `makeblastdb` and `blastn` reject any path containing whitespace, and project
/// folders routinely contain spaces. Every path handed to the tool therefore
/// lives under a whitespace-free staging root that the caller supplies.
public struct PrimerScreeningDatabaseBuilder: Sendable {
    /// Resolves `makeblastdb`. The default resolver looks inside the engine's own
    /// managed environment, which ships the same BLAST build the engine will query
    /// with, so the database format cannot disagree with the reader.
    public typealias ExecutableResolver = @Sendable () async throws -> URL
    public typealias Runner = @Sendable (URL, [String], URL) async throws -> (exitStatus: Int32, stderr: String, argv: [String])
    public typealias VersionReader = @Sendable (URL) async throws -> String

    private let resolveExecutable: ExecutableResolver
    private let run: Runner
    private let readVersion: VersionReader

    /// Resolves `makeblastdb` from an engine environment prefix (the same prefix
    /// whose `bin/python` runs the adapter).
    public static func executable(inEnvironmentPrefix prefix: URL) throws -> URL {
        let candidate = prefix.appendingPathComponent("bin/makeblastdb")
        guard FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw PrimerScreeningDatabaseError.toolUnavailable(
                "makeblastdb is not present in \(prefix.lastPathComponent). Reinstall the PCR Primer Design plugin pack.")
        }
        return candidate
    }

    public init(
        resolveExecutable: ExecutableResolver? = nil,
        run: Runner? = nil,
        readVersion: VersionReader? = nil
    ) {
        self.resolveExecutable = resolveExecutable ?? {
            throw PrimerScreeningDatabaseError.toolUnavailable(
                "No managed primer-design environment was supplied to locate makeblastdb.")
        }
        self.run = run ?? { executable, arguments, workingDirectory in
            let result = try await NativeToolRunner.shared.runProcess(
                executableURL: executable, arguments: arguments,
                workingDirectory: workingDirectory, timeout: 3_600,
                toolName: "makeblastdb (LGE off-target screening)")
            return (result.exitCode, result.stderr,
                    result.arguments.isEmpty ? [executable.path] + arguments : result.arguments)
        }
        self.readVersion = readVersion ?? { executable in
            let result = try await NativeToolRunner.shared.runProcess(
                executableURL: executable, arguments: ["-version"], timeout: 60,
                toolName: "makeblastdb")
            return result.stdout.split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? "unknown"
        }
    }

    /// Reads every source, writes one combined FASTA, and runs `makeblastdb`.
    ///
    /// - Parameter stagingRoot: a directory whose path contains no whitespace.
    ///   The caller owns its lifetime; the database is written inside it.
    public func build(
        sources: [PrimerScreeningSource], stagingRoot: URL,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> PrimerScreeningDatabase {
        guard !sources.isEmpty else { throw PrimerScreeningDatabaseError.noSources }
        guard !stagingRoot.path.contains(where: \.isWhitespace) else {
            throw PrimerScreeningDatabaseError.buildFailed(
                "The screening staging directory path must not contain whitespace.")
        }
        progress?(0.1, "Reading screening sequences…")
        let (fastaText, records) = try Self.combinedFASTA(sources: sources)

        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let fastaURL = stagingRoot.appendingPathComponent("screening-sources.fasta")
        try Data(fastaText.utf8).write(to: fastaURL, options: .withoutOverwriting)

        let executable: URL
        do { executable = try await resolveExecutable() }
        catch { throw PrimerScreeningDatabaseError.toolUnavailable(error.localizedDescription) }
        let version = (try? await readVersion(executable)) ?? "unknown"

        let prefix = stagingRoot.appendingPathComponent("screening-db").path
        let arguments = ["-in", fastaURL.path, "-dbtype", "nucl", "-out", prefix,
                         "-title", "LGE-off-target-screening", "-parse_seqids"]
        progress?(0.5, "Building the nucleotide BLAST database…")
        let outcome: (exitStatus: Int32, stderr: String, argv: [String])
        do { outcome = try await run(executable, arguments, stagingRoot) }
        catch { throw PrimerScreeningDatabaseError.buildFailed(error.localizedDescription) }
        guard outcome.exitStatus == 0 else {
            let detail = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw PrimerScreeningDatabaseError.buildFailed(
                detail.isEmpty ? "makeblastdb exited with status \(outcome.exitStatus)." : detail)
        }
        // The engine adapters require .nhr, .nin and .nsq for a usable database.
        for suffix in ["nhr", "nin", "nsq"] {
            guard FileManager.default.fileExists(atPath: prefix + "." + suffix) else {
                throw PrimerScreeningDatabaseError.buildFailed(
                    "makeblastdb reported success but wrote no .\(suffix) component.")
            }
        }
        progress?(0.9, "Screening database ready")
        return .init(prefix: prefix, fastaURL: fastaURL, records: records,
                     makeblastdbArgv: outcome.argv, makeblastdbVersion: version, sources: sources)
    }

    /// Reads each source into ungapped uppercase records with unique titles.
    ///
    /// Alignment rows lose their gap characters: a screening database holds real
    /// sequences, not alignment rows.
    static func combinedFASTA(
        sources: [PrimerScreeningSource]
    ) throws -> (text: String, records: [PrimerScreeningRecord]) {
        var records: [PrimerScreeningRecord] = []
        var lines: [String] = []
        var seenTitles: Set<String> = []
        for source in sources {
            let rows = try readRows(source)
            guard !rows.isEmpty else {
                throw PrimerScreeningDatabaseError.emptySource(source.displayName)
            }
            for row in rows {
                // BLAST truncates a defline at the first space, so the identifier
                // must be whitespace-free while staying recognizable.
                let title = Self.sanitizedTitle(row.title, source: source)
                guard seenTitles.insert(title).inserted else {
                    throw PrimerScreeningDatabaseError.duplicateTitle(title)
                }
                let sequence = row.sequence
                records.append(.init(
                    sourcePath: source.url.path, sourceKind: source.kind.rawValue,
                    title: title, length: sequence.count,
                    sha256: Self.sha256(of: sequence)))
                lines.append(">" + title)
                lines.append(sequence)
            }
        }
        guard !records.isEmpty else {
            throw PrimerScreeningDatabaseError.emptySource(sources[0].displayName)
        }
        return (lines.joined(separator: "\n") + "\n", records)
    }

    private struct ScreeningRow {
        let title: String
        let sequence: String
    }

    private static func readRows(_ source: PrimerScreeningSource) throws -> [ScreeningRow] {
        switch source.kind {
        case .alignmentBundle:
            let fasta = source.url.appendingPathComponent("alignment/primary.aligned.fasta")
            return try Primer3InputLoader.readAlignedRows(at: fasta, allowingRNAU: true).map {
                .init(title: $0.title, sequence: Self.ungapped($0.sequence))
            }
        case .referenceBundle:
            guard let fasta = Primer3InputLoader.fastaURL(for: source.url) else {
                throw PrimerScreeningDatabaseError.unsupportedSource(source.displayName)
            }
            return try Self.readUnalignedFASTA(at: fasta)
        case .fasta:
            return try Self.readUnalignedFASTA(at: source.url)
        }
    }

    /// A screening FASTA need not be an alignment, so rows may differ in length.
    ///
    /// Reference bundles store their genome bgzipped, so gzip is read transparently.
    private static func readUnalignedFASTA(at url: URL) throws -> [ScreeningRow] {
        let text: String
        if url.pathExtension.lowercased() == "gz" {
            text = try GzipInputStream(url: url).readAllSync()
        } else if let decoded = String(data: try Data(contentsOf: url), encoding: .utf8) {
            text = decoded
        } else {
            throw PrimerScreeningDatabaseError.unsupportedSource(url.lastPathComponent)
        }
        var rows: [ScreeningRow] = []
        var title: String?
        var chunks: [String] = []
        func finish() {
            guard let current = title else { return }
            let sequence = Self.ungapped(chunks.joined())
            if !sequence.isEmpty { rows.append(.init(title: current, sequence: sequence)) }
        }
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if line.hasPrefix(">") {
                finish()
                title = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                chunks = []
            } else if title != nil {
                chunks.append(line)
            }
        }
        finish()
        return rows
    }

    static func sha256(of string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Uppercases, drops alignment gaps, and turns RNA uracil into thymidine.
    static func ungapped(_ sequence: String) -> String {
        String(sequence.uppercased().compactMap { character -> Character? in
            switch character {
            case "-", ".", " ", "\t": return nil
            case "U": return "T"
            default: return character
            }
        })
    }

    /// Makes one whitespace-free, file-safe identifier from a FASTA header.
    ///
    /// The whole record ID matters here, so nothing is truncated mid-token: only
    /// characters BLAST cannot carry in a defline identifier are replaced.
    static func sanitizedTitle(_ header: String, source: PrimerScreeningSource) -> String {
        let firstToken = header.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let base = firstToken.isEmpty ? source.displayName : firstToken
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.|:"))
        let cleaned = String(base.unicodeScalars.map { permitted.contains($0) ? Character($0) : "_" })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return trimmed.isEmpty ? "sequence" : trimmed
    }
}

import Foundation
import CryptoKit
import LungfishCore
import LungfishIO

public enum TwelveSResultExportFormat: String, CaseIterable, Sendable {
    case csv
    case tsv
    case xlsx

    var delimiter: String? {
        switch self {
        case .csv: return ","
        case .tsv: return "\t"
        case .xlsx: return nil
        }
    }

    var provenanceFormat: FileFormat {
        switch self {
        case .csv, .tsv:
            return .text
        case .xlsx:
            return .unknown
        }
    }
}

public enum TwelveSExportChimeraFilter: String, CaseIterable, Sendable {
    case all
    case notReviewed
    case notDetected
    case candidate
    case confirmed

    func includes(_ status: TwelveSChimeraStatus) -> Bool {
        switch self {
        case .all:
            return true
        case .notReviewed:
            return status == .notReviewed
        case .notDetected:
            return status == .notDetected
        case .candidate:
            return status == .candidate
        case .confirmed:
            return status == .confirmed
        }
    }
}

public struct TwelveSResultExportConfiguration: Equatable, Sendable {
    public let bundleURL: URL
    public let outputURL: URL
    public let format: TwelveSResultExportFormat
    public let minimumExactReads: Int
    public let filterText: String
    public let taxonGroups: [String]
    public let excludedTaxonGroups: [String]
    public let excludeHuman: Bool
    public let requireAlternateMatches: Bool
    public let minimumUnresolvedReads: Int
    public let chimeraFilter: TwelveSExportChimeraFilter
    public let forceOverwrite: Bool
    public let argv: [String]

    public init(
        bundleURL: URL,
        outputURL: URL,
        format: TwelveSResultExportFormat,
        minimumExactReads: Int = 0,
        filterText: String = "",
        taxonGroups: [String] = [],
        excludedTaxonGroups: [String] = [],
        excludeHuman: Bool = false,
        requireAlternateMatches: Bool = false,
        minimumUnresolvedReads: Int = 0,
        chimeraFilter: TwelveSExportChimeraFilter = .all,
        forceOverwrite: Bool = false,
        argv: [String] = []
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.outputURL = outputURL.standardizedFileURL
        self.format = format
        self.minimumExactReads = max(0, minimumExactReads)
        self.filterText = filterText
        self.taxonGroups = taxonGroups
        self.excludedTaxonGroups = excludedTaxonGroups
        self.excludeHuman = excludeHuman
        self.requireAlternateMatches = requireAlternateMatches
        self.minimumUnresolvedReads = max(0, minimumUnresolvedReads)
        self.chimeraFilter = chimeraFilter
        self.forceOverwrite = forceOverwrite
        self.argv = argv
    }
}

public struct TwelveSResultExportResult: Equatable, Sendable {
    public let outputURL: URL
    public let provenanceURL: URL
}

public struct TwelveSUnresolvedFastaExportConfiguration: Equatable, Sendable {
    public let bundleURL: URL
    public let outputURL: URL
    public let metadataURL: URL?
    public let minimumReads: Int
    public let includeChimeraCandidates: Bool
    public let sequenceIDs: [String]
    public let forceOverwrite: Bool
    public let argv: [String]

    public init(
        bundleURL: URL,
        outputURL: URL,
        metadataURL: URL? = nil,
        minimumReads: Int = 5,
        includeChimeraCandidates: Bool = false,
        sequenceIDs: [String] = [],
        forceOverwrite: Bool = false,
        argv: [String] = []
    ) {
        self.bundleURL = bundleURL.standardizedFileURL
        self.outputURL = outputURL.standardizedFileURL
        self.metadataURL = metadataURL?.standardizedFileURL
        self.minimumReads = max(0, minimumReads)
        self.includeChimeraCandidates = includeChimeraCandidates
        self.sequenceIDs = sequenceIDs
        self.forceOverwrite = forceOverwrite
        self.argv = argv
    }
}

public struct TwelveSUnresolvedFastaExportResult: Equatable, Sendable {
    public let outputURL: URL
    public let metadataURL: URL
    public let provenanceURL: URL
}

public enum TwelveSResultExportError: Error, LocalizedError, Equatable {
    case missingBundle(String)
    case outputExists(String)
    case zipFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingBundle(let path):
            return "12S result bundle does not exist: \(path)"
        case .outputExists(let path):
            return "12S export output already exists: \(path)"
        case .zipFailed(let stderr):
            return "12S Excel export zip failed: \(stderr)"
        }
    }
}

public struct TwelveSResultExportWorkflow: Sendable {
    public init() {}

    public func export(_ config: TwelveSResultExportConfiguration) async throws -> TwelveSResultExportResult {
        let startedAt = Date()
        try validate(bundleURL: config.bundleURL, outputURL: config.outputURL, force: config.forceOverwrite)
        let result = try TwelveSAmpliconResultBundle.loadResult(from: config.bundleURL)
        let rows = filteredRows(from: result, config: config)
        let table = targetTable(rows: rows, sampleNames: result.sampleNames)
        try FileManager.default.createDirectory(
            at: config.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            switch config.format {
            case .csv:
                try writeDelimited(table, delimiter: ",", to: config.outputURL)
            case .tsv:
                try writeDelimited(table, delimiter: "\t", to: config.outputURL)
            case .xlsx:
                try writeWorkbook(
                    sheets: [
                        ("Species", table),
                        ("Unresolved", unresolvedTable(filteredUnresolvedSequences(from: result, config: config))),
                    ],
                    to: config.outputURL
                )
            }
            let provenanceURL = try writeExportProvenance(
                config: config,
                visibleRowCount: rows.count,
                startedAt: startedAt,
                completedAt: Date()
            )
            return TwelveSResultExportResult(
                outputURL: config.outputURL.standardizedFileURL,
                provenanceURL: provenanceURL.standardizedFileURL
            )
        } catch {
            try? FileManager.default.removeItem(at: config.outputURL)
            try? FileManager.default.removeItem(
                at: config.outputURL.appendingPathExtension("lungfish-provenance.json")
            )
            throw error
        }
    }

    private func filteredRows(
        from result: TwelveSAmpliconResultBundleData,
        config: TwelveSResultExportConfiguration
    ) -> [TwelveSScientificNameCountRow] {
        let filter = config.filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        let groups = Set(config.taxonGroups.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        let excludedGroups = Set(config.excludedTaxonGroups.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        return result.scientificNameRows.filter { row in
            guard row.totalExactReads >= config.minimumExactReads else { return false }
            if config.excludeHuman && (row.scientificName == "Homo sapiens" || row.taxids.contains("9606")) {
                return false
            }
            if config.requireAlternateMatches && row.alternateMatches.isEmpty && row.potentialMatches.isEmpty {
                return false
            }
            let displayTaxonGroups = row.displayTaxonGroups
            let rowGroups = Set(displayTaxonGroups.map { $0.lowercased() })
            if !groups.isEmpty {
                guard !rowGroups.isDisjoint(with: groups) else { return false }
            }
            if !excludedGroups.isEmpty, !rowGroups.isDisjoint(with: excludedGroups) {
                return false
            }
            guard !filter.isEmpty else { return true }
            return row.scientificName.localizedCaseInsensitiveContains(filter)
                || row.commonNamesText.localizedCaseInsensitiveContains(filter)
                || row.potentialMatchesText.localizedCaseInsensitiveContains(filter)
                || displayTaxonGroups.joined(separator: " ").localizedCaseInsensitiveContains(filter)
                || row.taxids.joined(separator: " ").localizedCaseInsensitiveContains(filter)
        }
    }

    private func filteredUnresolvedSequences(
        from result: TwelveSAmpliconResultBundleData,
        config: TwelveSResultExportConfiguration
    ) -> [TwelveSUnresolvedSequence] {
        result.unresolvedSequences.filter { sequence in
            guard sequence.readCount >= config.minimumUnresolvedReads else { return false }
            return config.chimeraFilter.includes(sequence.chimeraStatus)
        }.sorted {
            if $0.readCount != $1.readCount { return $0.readCount > $1.readCount }
            return $0.sequenceID.localizedStandardCompare($1.sequenceID) == .orderedAscending
        }
    }

    private func targetTable(rows: [TwelveSScientificNameCountRow], sampleNames: [String]) -> [[String]] {
        let header = [
            "Scientific Name",
            "Common Names",
            "Taxon Groups",
            "Taxids",
            "Exact Reads",
            "Reference Targets",
            "Other Potential Matches",
            "Max Sample %",
        ] + sampleNames
        let body = rows.map { row in
            [
                row.scientificName,
                row.commonNamesText,
                row.displayTaxonGroups.joined(separator: "; "),
                row.taxids.joined(separator: "; "),
                String(row.totalExactReads),
                String(row.referenceTargetCount),
                row.potentialMatchesText,
                Self.formatDouble(row.maxSamplePercent),
            ] + sampleNames.map { String(row.count(forSample: $0)) }
        }
        return [header] + body
    }
}

public struct TwelveSUnresolvedFastaExportWorkflow: Sendable {
    public init() {}

    public func export(
        _ config: TwelveSUnresolvedFastaExportConfiguration
    ) async throws -> TwelveSUnresolvedFastaExportResult {
        let startedAt = Date()
        let metadataURL = config.metadataURL ?? config.outputURL.appendingPathExtension("metadata.tsv")
        try validate(bundleURL: config.bundleURL, outputURL: config.outputURL, force: config.forceOverwrite)
        if FileManager.default.fileExists(atPath: metadataURL.path) {
            if config.forceOverwrite {
                try FileManager.default.removeItem(at: metadataURL)
            } else {
                throw TwelveSResultExportError.outputExists(metadataURL.path)
            }
        }
        let result = try TwelveSAmpliconResultBundle.loadResult(from: config.bundleURL)
        let selectedIDs = Set(config.sequenceIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let sequences = result.unresolvedSequences.filter { sequence in
            if !selectedIDs.isEmpty, !selectedIDs.contains(sequence.sequenceID) {
                return false
            }
            guard sequence.readCount >= config.minimumReads else { return false }
            guard config.includeChimeraCandidates || !sequence.isChimeraCandidate else { return false }
            return true
        }.sorted {
            if $0.readCount != $1.readCount { return $0.readCount > $1.readCount }
            return $0.sequenceID.localizedStandardCompare($1.sequenceID) == .orderedAscending
        }
        try FileManager.default.createDirectory(
            at: config.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try writeFasta(sequences, to: config.outputURL)
            try writeMetadata(sequences, to: metadataURL)
            let provenanceURL = try writeUnresolvedProvenance(
                config: config,
                metadataURL: metadataURL,
                exportedSequenceCount: sequences.count,
                startedAt: startedAt,
                completedAt: Date()
            )
            return TwelveSUnresolvedFastaExportResult(
                outputURL: config.outputURL.standardizedFileURL,
                metadataURL: metadataURL.standardizedFileURL,
                provenanceURL: provenanceURL.standardizedFileURL
            )
        } catch {
            try? FileManager.default.removeItem(at: config.outputURL)
            try? FileManager.default.removeItem(at: metadataURL)
            try? FileManager.default.removeItem(
                at: config.outputURL.appendingPathExtension("lungfish-provenance.json")
            )
            throw error
        }
    }

    private func writeFasta(_ sequences: [TwelveSUnresolvedSequence], to url: URL) throws {
        var text = ""
        for sequence in sequences {
            text += ">\(sequence.sequenceID) read_count=\(sequence.readCount) sequence_sha256=\(sequence.sequenceSHA256) chimera_status=\(sequence.chimeraStatus.rawValue)\n"
            text += "\(sequence.sequence)\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeMetadata(_ sequences: [TwelveSUnresolvedSequence], to url: URL) throws {
        var lines = ["sequence_id\tsequence_sha256\tread_count\tsample_counts\tchimera_status\tnote"]
        for sequence in sequences {
            let sampleCounts = sequence.sampleCounts
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: ",")
            lines.append([
                sequence.sequenceID,
                sequence.sequenceSHA256,
                String(sequence.readCount),
                sampleCounts,
                sequence.chimeraStatus.rawValue,
                sequence.note ?? "",
            ].map(twelveSExportTSVEscape).joined(separator: "\t"))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

private extension TwelveSUnresolvedSequence {
    var isChimeraCandidate: Bool {
        chimeraStatus == .candidate || chimeraStatus == .confirmed
    }

    var sequenceSHA256: String {
        SHA256.hash(data: Data(sequence.uppercased().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private func validate(bundleURL: URL, outputURL: URL, force: Bool) throws {
    guard FileManager.default.fileExists(atPath: bundleURL.path) else {
        throw TwelveSResultExportError.missingBundle(bundleURL.path)
    }
    if FileManager.default.fileExists(atPath: outputURL.path) {
        if force {
            try FileManager.default.removeItem(at: outputURL)
        } else {
            throw TwelveSResultExportError.outputExists(outputURL.path)
        }
    }
}

private func unresolvedTable(_ sequences: [TwelveSUnresolvedSequence]) -> [[String]] {
    let header = ["Sequence ID", "Reads", "Chimera", "Sequence", "Sample Counts"]
    let body = sequences.map {
        [
            $0.sequenceID,
            String($0.readCount),
            $0.chimeraStatus.displayName,
            $0.sequence,
            $0.sampleCounts
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { "\($0.key):\($0.value)" }
                .joined(separator: "; "),
        ]
    }
    return [header] + body
}

private func writeDelimited(_ rows: [[String]], delimiter: String, to url: URL) throws {
    let text = rows
        .map { row in row.map { twelveSExportDelimitedEscape($0, delimiter: delimiter) }.joined(separator: delimiter) }
        .joined(separator: "\n") + "\n"
    try text.write(to: url, atomically: true, encoding: .utf8)
}

private func writeWorkbook(sheets: [(name: String, rows: [[String]])], to outputURL: URL) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: outputURL.path) {
        try fm.removeItem(at: outputURL)
    }
    let buildURL = fm.temporaryDirectory
        .appendingPathComponent("lungfish-12s-export-xlsx-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: buildURL) }
    try fm.createDirectory(at: buildURL.appendingPathComponent("_rels", isDirectory: true), withIntermediateDirectories: true)
    try fm.createDirectory(at: buildURL.appendingPathComponent("xl/_rels", isDirectory: true), withIntermediateDirectories: true)
    try fm.createDirectory(at: buildURL.appendingPathComponent("xl/worksheets", isDirectory: true), withIntermediateDirectories: true)
    try contentTypesXML(sheetCount: sheets.count)
        .write(to: buildURL.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
    try rootRelsXML.write(to: buildURL.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
    try workbookXML(sheets: sheets.map(\.name))
        .write(to: buildURL.appendingPathComponent("xl/workbook.xml"), atomically: true, encoding: .utf8)
    try workbookRelsXML(sheetCount: sheets.count)
        .write(to: buildURL.appendingPathComponent("xl/_rels/workbook.xml.rels"), atomically: true, encoding: .utf8)
    try stylesXML.write(to: buildURL.appendingPathComponent("xl/styles.xml"), atomically: true, encoding: .utf8)
    for (index, sheet) in sheets.enumerated() {
        try worksheetXML(rows: sheet.rows)
            .write(
                to: buildURL.appendingPathComponent("xl/worksheets/sheet\(index + 1).xml"),
                atomically: true,
                encoding: .utf8
            )
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = buildURL
    process.arguments = ["-qr", outputURL.path, "."]
    let stderrPipe = Pipe()
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw TwelveSResultExportError.zipFailed(stderr)
    }
}

private func writeExportProvenance(
    config: TwelveSResultExportConfiguration,
    visibleRowCount: Int,
    startedAt: Date,
    completedAt: Date
) throws -> URL {
    let argv = config.argv.isEmpty
        ? twelveSExportReplayArgv(for: config)
        : config.argv
    var builder = ProvenanceRunBuilder(
        workflowName: "lungfish fastq 12s-export",
        workflowVersion: WorkflowRun.currentAppVersion,
        toolName: CLICommandIdentity.executableName,
        toolVersion: WorkflowRun.currentAppVersion
    )
    .argv(argv)
    .durableReplayArgv(argv)
    .reproducibleCommand(argv.map(twelveSExportShellEscape).joined(separator: " "))
    .options(
        explicit: [
            "bundle": .file(config.bundleURL),
            "output": .file(config.outputURL),
            "format": .string(config.format.rawValue),
            "minimumExactReads": .integer(config.minimumExactReads),
            "filterText": .string(config.filterText),
            "taxonGroups": .array(config.taxonGroups.map { .string($0) }),
            "excludedTaxonGroups": .array(config.excludedTaxonGroups.map { .string($0) }),
            "excludeHuman": .boolean(config.excludeHuman),
            "requireAlternateMatches": .boolean(config.requireAlternateMatches),
            "minimumUnresolvedReads": .integer(config.minimumUnresolvedReads),
            "chimeraFilter": .string(config.chimeraFilter.rawValue),
            "forceOverwrite": .boolean(config.forceOverwrite),
        ],
        defaults: [
            "minimumExactReads": .integer(0),
            "filterText": .string(""),
            "excludeHuman": .boolean(false),
            "requireAlternateMatches": .boolean(false),
            "minimumUnresolvedReads": .integer(0),
            "chimeraFilter": .string(TwelveSExportChimeraFilter.all.rawValue),
            "forceOverwrite": .boolean(false),
        ],
        resolved: [
            "visibleRowCount": .integer(visibleRowCount),
            "minimumExactReads": .integer(config.minimumExactReads),
            "filterText": .string(config.filterText),
            "excludeHuman": .boolean(config.excludeHuman),
            "requireAlternateMatches": .boolean(config.requireAlternateMatches),
            "minimumUnresolvedReads": .integer(config.minimumUnresolvedReads),
            "chimeraFilter": .string(config.chimeraFilter.rawValue),
        ]
    )
    for input in try sourceInputs(for: config.bundleURL) {
        builder = try builder.input(input.url, format: input.format, role: input.role)
    }
    let envelope = try builder
        .output(config.outputURL, format: config.format.provenanceFormat, role: .report)
        .runtime(ProvenanceRuntimeIdentity(user: WorkflowRun.currentUser))
        .complete(exitStatus: 0, startedAt: startedAt, endedAt: completedAt)
    let sidecarURL = config.outputURL.appendingPathExtension("lungfish-provenance.json")
    return try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: sidecarURL)
}

private func writeUnresolvedProvenance(
    config: TwelveSUnresolvedFastaExportConfiguration,
    metadataURL: URL,
    exportedSequenceCount: Int,
    startedAt: Date,
    completedAt: Date
) throws -> URL {
    let argv = config.argv.isEmpty
        ? twelveSUnresolvedReplayArgv(for: config)
        : config.argv
    var builder = ProvenanceRunBuilder(
        workflowName: "lungfish fastq 12s-export-unresolved",
        workflowVersion: WorkflowRun.currentAppVersion,
        toolName: CLICommandIdentity.executableName,
        toolVersion: WorkflowRun.currentAppVersion
    )
    .argv(argv)
    .durableReplayArgv(argv)
    .reproducibleCommand(argv.map(twelveSExportShellEscape).joined(separator: " "))
    .options(
        explicit: [
            "bundle": .file(config.bundleURL),
            "output": .file(config.outputURL),
            "metadataOutput": .file(metadataURL),
            "minimumReads": .integer(config.minimumReads),
            "includeChimeraCandidates": .boolean(config.includeChimeraCandidates),
            "sequenceIDs": .array(config.sequenceIDs.map { .string($0) }),
            "forceOverwrite": .boolean(config.forceOverwrite),
        ],
        defaults: [
            "minimumReads": .integer(5),
            "includeChimeraCandidates": .boolean(false),
            "sequenceIDs": .array([ParameterValue]()),
            "forceOverwrite": .boolean(false),
        ],
        resolved: [
            "exportedSequenceCount": .integer(exportedSequenceCount),
            "minimumReads": .integer(config.minimumReads),
            "includeChimeraCandidates": .boolean(config.includeChimeraCandidates),
            "sequenceIDs": .array(config.sequenceIDs.map { .string($0) }),
        ]
    )
    for input in try sourceInputs(for: config.bundleURL) {
        builder = try builder.input(input.url, format: input.format, role: input.role)
    }
    let envelope = try builder
        .output(config.outputURL, format: .fasta, role: .output)
        .output(metadataURL, format: .text, role: .output)
        .runtime(ProvenanceRuntimeIdentity(user: WorkflowRun.currentUser))
        .complete(exitStatus: 0, startedAt: startedAt, endedAt: completedAt)
    let sidecarURL = config.outputURL.appendingPathExtension("lungfish-provenance.json")
    return try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: sidecarURL)
}

private struct TwelveSExportSourceInput {
    let url: URL
    let format: FileFormat?
    let role: FileRole
}

private func twelveSExportReplayArgv(for config: TwelveSResultExportConfiguration) -> [String] {
    var argv = [
        CLICommandIdentity.executableName, "fastq", "12s-export",
        "--bundle", config.bundleURL.path,
        "--export-format", config.format.rawValue,
        "--output", config.outputURL.path,
    ]
    if config.minimumExactReads != 0 {
        argv += ["--min-exact-reads", String(config.minimumExactReads)]
    }
    if !config.filterText.isEmpty {
        argv += ["--filter", config.filterText]
    }
    for group in config.taxonGroups {
        argv += ["--taxon-group", group]
    }
    for group in config.excludedTaxonGroups {
        argv += ["--exclude-taxon-group", group]
    }
    if config.excludeHuman {
        argv.append("--exclude-human")
    }
    if config.requireAlternateMatches {
        argv.append("--require-alternate-matches")
    }
    if config.minimumUnresolvedReads != 0 {
        argv += ["--min-unresolved-reads", String(config.minimumUnresolvedReads)]
    }
    if config.chimeraFilter != .all {
        argv += ["--chimera-status", config.chimeraFilter.rawValue]
    }
    if config.forceOverwrite {
        argv.append("--force")
    }
    return argv
}

private func twelveSUnresolvedReplayArgv(for config: TwelveSUnresolvedFastaExportConfiguration) -> [String] {
    var argv = [
        CLICommandIdentity.executableName, "fastq", "12s-export-unresolved",
        "--bundle", config.bundleURL.path,
        "--min-reads", String(config.minimumReads),
        "--output", config.outputURL.path,
    ]
    if let metadataURL = config.metadataURL {
        argv += ["--metadata-output", metadataURL.path]
    }
    if config.includeChimeraCandidates {
        argv.append("--include-chimera-candidates")
    }
    for sequenceID in config.sequenceIDs {
        argv += ["--sequence-id", sequenceID]
    }
    if config.forceOverwrite {
        argv.append("--force")
    }
    return argv
}

private func sourceInputs(for bundleURL: URL) throws -> [TwelveSExportSourceInput] {
    var inputs: [TwelveSExportSourceInput] = []
    var seen = Set<String>()

    func append(_ url: URL, format: FileFormat?, role: FileRole) {
        let standardizedURL = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardizedURL.path) else { return }
        let key = "\(role.rawValue)\u{0}\(standardizedURL.path)"
        guard seen.insert(key).inserted else { return }
        inputs.append(TwelveSExportSourceInput(url: standardizedURL, format: format, role: role))
    }

    func appendResolved(_ path: String?, format: FileFormat?, role: FileRole) {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        append(TwelveSAmpliconResultBundle.resolvedURL(for: path, in: bundleURL), format: format, role: role)
    }

    append(TwelveSAmpliconResultBundle.manifestURL(in: bundleURL), format: .json, role: .input)
    let manifest = try TwelveSAmpliconResultBundle.loadManifest(from: bundleURL)
    appendResolved(manifest.referencePath, format: .fasta, role: .reference)
    appendResolved(manifest.targetTablePath, format: .text, role: .input)
    appendResolved(manifest.alternateMatchesTablePath, format: .text, role: .input)
    appendResolved(manifest.countMatrixPath, format: .text, role: .input)
    appendResolved(manifest.sampleTablePath, format: .text, role: .input)
    appendResolved(manifest.readFatePath, format: .json, role: .input)
    appendResolved(manifest.unresolvedTablePath, format: .text, role: .input)
    appendResolved(manifest.unresolvedFastaPath, format: .fasta, role: .input)
    appendResolved(manifest.provenancePath, format: .json, role: .log)
    return inputs
}

private func twelveSExportDelimitedEscape(_ value: String, delimiter: String) -> String {
    let needsQuotes = value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r")
    guard needsQuotes else { return value }
    return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
}

private func twelveSExportTSVEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
}

private func twelveSExportShellEscape(_ value: String) -> String {
    guard !value.isEmpty else { return "''" }
    if value.range(of: #"[^A-Za-z0-9_./:=@+-]"#, options: .regularExpression) == nil {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private extension TwelveSResultExportWorkflow {
    static func formatDouble(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}

private func worksheetXML(rows: [[String]]) -> String {
    let rowXML = rows.enumerated().map { offset, row in
        xlsxRow(index: offset + 1, values: row)
    }.joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
      <sheetData>
    \(rowXML)
      </sheetData>
    </worksheet>
    """
}

private func xlsxRow(index: Int, values: [String]) -> String {
    let cells = values.enumerated().map { column, value in
        let reference = "\(xlsxColumnName(column + 1))\(index)"
        let style = index == 1 ? #" s="1""# : ""
        return #"<c r="\#(reference)" t="inlineStr"\#(style)><is><t>\#(xlsxXMLStringEscape(value))</t></is></c>"#
    }.joined()
    return #"    <row r="\#(index)">\#(cells)</row>"#
}

private func xlsxColumnName(_ index: Int) -> String {
    var index = index
    var name = ""
    while index > 0 {
        index -= 1
        let scalar = UnicodeScalar(65 + (index % 26))!
        name = String(Character(scalar)) + name
        index /= 26
    }
    return name
}

private func xlsxXMLStringEscape(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
}

private func contentTypesXML(sheetCount: Int) -> String {
    let sheets = (1...sheetCount).map {
        #"<Override PartName="/xl/worksheets/sheet\#($0).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
    }.joined(separator: "\n  ")
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
      \(sheets)
    </Types>
    """
}

private let rootRelsXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>
"""

private func workbookXML(sheets: [String]) -> String {
    let sheetXML = sheets.enumerated().map { index, name in
        #"<sheet name="\#(xlsxXMLStringEscape(name))" sheetId="\#(index + 1)" r:id="rId\#(index + 1)"/>"#
    }.joined(separator: "\n    ")
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets>
        \(sheetXML)
      </sheets>
    </workbook>
    """
}

private func workbookRelsXML(sheetCount: Int) -> String {
    let sheetRels = (1...sheetCount).map {
        #"<Relationship Id="rId\#($0)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#($0).xml"/>"#
    }.joined(separator: "\n  ")
    return """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      \(sheetRels)
      <Relationship Id="rId\(sheetCount + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
    </Relationships>
    """
}

private let stylesXML = """
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="2"><font><sz val="11"/><name val="Helvetica"/></font><font><b/><sz val="11"/><name val="Helvetica"/></font></fonts>
  <fills count="1"><fill><patternFill patternType="none"/></fill></fills>
  <borders count="1"><border/></borders>
  <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
  <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" applyFont="1"/></cellXfs>
</styleSheet>
"""

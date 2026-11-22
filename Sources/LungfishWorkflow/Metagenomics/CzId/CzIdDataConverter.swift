// CzIdDataConverter.swift - CZ-ID taxon report import normalization
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

public enum CzIdDataConverter {
    public static let schemaVersion = "cz-id-taxon-report-v1"

    /// Reads a CZ-ID taxon report. czid-web writes its Report Table and bulk Sample Taxon Reports as comma CSV
    /// (`pipeline_report_service.rb` `report_csv`) with a numeric `tax_level`, `nt_count` and `nr_count`. A tab copy of
    /// it, and the older tab reports with `taxon_name`, `rank` and `nt_read_count`, read the same way. The delimiter is
    /// the header line's: a tab, else a comma.
    ///
    /// A report is refused, never imported with 0 reads, when it has no taxon ID, name or read count column, or when a
    /// row has no taxon ID or name (CZID-REAL-EXPORT-FORMAT). An empty cell under a count column is 0, because CZ-ID
    /// writes no count where a taxon has no hits.
    public static func parseTaxonReport(at url: URL) throws -> CzIdParsedTaxonReport {
        let text = try String(contentsOf: url, encoding: .utf8)
        let fileName = url.lastPathComponent
        // Each line keeps its number in the file, which is the row a spreadsheet shows, so a refusal can name it.
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .enumerated()
            .map { (number: $0.offset + 1, text: String($0.element)) }
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard let headerLine = lines.first else {
            throw CzIdDataConverterError.emptyReport(url)
        }

        let delimiter: Character = headerLine.text.contains("\t") ? "\t" : ","
        let headers = try splitFields(headerLine.text, delimiter: delimiter, url: url)
        // The first of two columns with the same name wins, as `stringValue` reads them.
        let index = Dictionary(
            headers.enumerated().map { ($0.element.normalizedHeaderKey, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )

        guard hasColumn(index, aliases: Aliases.taxId) else {
            throw CzIdDataConverterError.missingColumn(fileName: fileName, column: "tax_id")
        }
        guard hasColumn(index, aliases: Aliases.name) else {
            throw CzIdDataConverterError.missingColumn(fileName: fileName, column: "name")
        }
        let hasNTCount = hasColumn(index, aliases: Aliases.ntCount)
        let hasNRCount = hasColumn(index, aliases: Aliases.nrCount)
        guard hasNTCount || hasNRCount else {
            throw CzIdDataConverterError.missingCountColumn(fileName: fileName)
        }

        var rows: [CzIdTaxonReportRow] = []
        var metadata = CzIdImportMetadata()

        for line in lines.dropFirst() {
            let fields = try splitFields(line.text, delimiter: delimiter, url: url)
            guard !fields.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                continue
            }

            guard let taxId = intValue(fields, index, aliases: Aliases.taxId) else {
                throw CzIdDataConverterError.missingValue(fileName: fileName, row: line.number, column: "tax_id")
            }
            guard let name = stringValue(fields, index, aliases: Aliases.name) else {
                throw CzIdDataConverterError.missingValue(fileName: fileName, row: line.number, column: "name")
            }
            let rank = stringValue(fields, index, aliases: ["rank", "taxonrank", "tax_rank"])
                ?? stringValue(fields, index, aliases: ["taxlevel", "tax_level"]).map(rankName(forTaxLevel:))
                ?? "no rank"

            let ntCount = hasNTCount ? intValue(fields, index, aliases: Aliases.ntCount) ?? 0 : nil
            let nrCount = hasNRCount ? intValue(fields, index, aliases: Aliases.nrCount) ?? 0 : nil
            let ntRpm = doubleValue(fields, index, aliases: ["ntrpm", "nt_rpm", "rpm"])
            let nrRpm = doubleValue(fields, index, aliases: ["nrrpm", "nr_rpm"])

            let row = CzIdTaxonReportRow(
                taxId: taxId,
                name: name,
                rank: rank,
                // A report with NR counts only is counted by them, with their rPM, rather than written as 0 reads.
                ntReadCount: ntCount ?? nrCount ?? 0,
                ntRpm: (hasNTCount ? ntRpm : nrRpm) ?? 0,
                ntPercentIdentity: doubleValue(fields, index, aliases: ["ntpercentidentity", "nt_percent_identity", "percentidentity", "percent_identity", "pident"]),
                ntAlignmentLength: intValue(fields, index, aliases: ["ntalignmentlength", "nt_alignment_length", "alignmentlength", "alignment_length"]),
                ntEValue: doubleValue(fields, index, aliases: ["ntevalue", "nt_e_value", "evalue", "e_value"]),
                nrReadCount: nrCount,
                nrRpm: nrRpm,
                nrPercentIdentity: doubleValue(fields, index, aliases: ["nrpercentidentity", "nr_percent_identity"]),
                nrAlignmentLength: intValue(fields, index, aliases: ["nralignmentlength", "nr_alignment_length"]),
                nrEValue: doubleValue(fields, index, aliases: ["nrevalue", "nr_e_value"]),
                genusTaxId: intValue(fields, index, aliases: ["genustaxid", "genus_tax_id"])
            )
            rows.append(row)

            metadata.merge(
                CzIdImportMetadata(
                    sampleName: stringValue(fields, index, aliases: ["samplename", "sample_name", "sample"]),
                    projectId: stringValue(fields, index, aliases: ["projectid", "project_id"]),
                    pipelineVersion: stringValue(fields, index, aliases: ["pipelineversion", "pipeline_version", "czidpipelineversion"]),
                    ntDatabaseVersion: stringValue(fields, index, aliases: ["ntdbversion", "nt_db_version", "ntdatabaseversion"]),
                    nrDatabaseVersion: stringValue(fields, index, aliases: ["nrdbversion", "nr_db_version", "nrdatabaseversion"])
                )
            )
        }

        guard !rows.isEmpty else {
            throw CzIdDataConverterError.emptyReport(url)
        }

        if metadata.sampleName == nil {
            metadata.sampleName = url.deletingPathExtension().lastPathComponent
        }

        return CzIdParsedTaxonReport(metadata: metadata, rows: rows)
    }

    public static func convertTaxonReport(
        at url: URL,
        outputDirectory: URL,
        command: [String]? = nil,
        sourceInputURL: URL? = nil,
        sampleNameOverride: String? = nil,
        additionalInputURLs: [URL] = [],
        provenanceToolName: String = "lungfish cz-id import",
        provenanceParameters: [String: ParameterValue] = [:]
    ) throws -> CzIdConversion {
        let runClock = ProvenanceRunClock()
        let parsed = try parseTaxonReport(at: url)
        let sampleName = sampleNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? parsed.metadata.sampleName
            ?? url.deletingPathExtension().lastPathComponent

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let reportURL = outputDirectory.appendingPathComponent("classification.kreport")
        try kreportText(from: parsed.rows).write(to: reportURL, atomically: true, encoding: .utf8)

        let outputURL = outputDirectory.appendingPathComponent("classification.czid.tsv")
        try FileManager.default.copyItemReplacingExistingItem(at: url, to: outputURL)
        let recordedSourceFiles = sourceInputURL == nil ? [url] : [outputURL]

        let manifest = CzIdImportManifest(
            schemaVersion: schemaVersion,
            sampleName: sampleName,
            projectId: parsed.metadata.projectId,
            pipelineVersion: parsed.metadata.pipelineVersion,
            ntDatabaseVersion: parsed.metadata.ntDatabaseVersion,
            nrDatabaseVersion: parsed.metadata.nrDatabaseVersion,
            sourceFiles: recordedSourceFiles,
            rowCount: parsed.rows.count
        )
        let manifestURL = outputDirectory.appendingPathComponent("cz-id-manifest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: manifestURL, options: .atomic)

        let tree = try KreportParser.parse(url: reportURL)
        var config = ClassificationConfig(
            inputFiles: sourceInputURL == nil ? [url] : [outputURL],
            isPairedEnd: false,
            databaseName: "CZ-ID",
            inputFormat: .fastq,
            databaseVersion: parsed.metadata.databaseVersionString,
            databasePath: sourceInputURL == nil ? url.deletingLastPathComponent() : outputDirectory,
            outputDirectory: outputDirectory
        )
        // The taxonomy table, the sample picker and `build-db kraken2` all key
        // the sample on this name and otherwise fall back to the input file's
        // stem. The input is the copied `classification.czid.tsv`, so without
        // it every CZ-ID import showed "classification.czid" as its sample.
        config.sampleDisplayName = sampleName
        let result = ClassificationResult(
            config: config,
            tree: tree,
            reportURL: reportURL,
            outputURL: outputURL,
            brackenURL: nil,
            runtime: runClock.elapsed,
            toolVersion: parsed.metadata.pipelineVersion ?? "unknown",
            provenanceId: nil
        )
        try result.save(to: outputDirectory)

        try writeProvenance(
            input: url,
            sourceInput: sourceInputURL,
            outputs: [reportURL, outputURL, manifestURL, outputDirectory.appendingPathComponent("classification-result.json")],
            outputDirectory: outputDirectory,
            command: command ?? [CLICommandIdentity.executableName, "cz-id", "import", url.path, "--output-dir", outputDirectory.path],
            toolVersion: parsed.metadata.pipelineVersion ?? "unknown",
            runClock: runClock,
            additionalInputs: additionalInputURLs,
            toolName: provenanceToolName,
            parameters: provenanceParameters.merging(defaultProvenanceParameters(
                parsed: parsed,
                sampleName: sampleName,
                outputDirectory: outputDirectory,
                sourceInputURL: sourceInputURL,
                reportURL: url,
                reportPayloadURL: outputURL
            )) { explicit, _ in explicit }
        )

        return CzIdConversion(parsed: parsed, result: result, manifest: manifest)
    }

    /// The Kraken-style report of `rows`.
    ///
    /// CZ-ID lists each genus with its species under it (`genus_tax_id`). A genus row's count is its clade count,
    /// which already holds its species' reads, so the genus direct count is what its species leave and no read is
    /// counted twice. A report with no root row gets one, whose clade is the sample's total reads from `nt_count` /
    /// `nt_rpm` (CZ-ID writes no root and no unclassified row), or else the sum of the top-level clades.
    public static func kreportText(from rows: [CzIdTaxonReportRow]) -> String {
        let isRoot: (CzIdTaxonReportRow) -> Bool = { $0.rank.normalizedHeaderKey == "root" || $0.taxId == 1 }
        let genusIds = Set(rows.filter { $0.rank.normalizedHeaderKey == "genus" && !isRoot($0) }.map(\.taxId))
        let parentGenus: (CzIdTaxonReportRow) -> Int? = { row in
            guard let genus = row.genusTaxId, genus != row.taxId, genusIds.contains(genus),
                  row.rank.normalizedHeaderKey != "genus", !isRoot(row) else { return nil }
            return genus
        }

        let sortedRows = rows.sorted { lhs, rhs in
            if lhs.taxId == 1 { return true }
            if rhs.taxId == 1 { return false }
            return lhs.ntReadCount > rhs.ntReadCount
        }
        var childrenByGenus: [Int: [CzIdTaxonReportRow]] = [:]
        for row in sortedRows {
            if let genus = parentGenus(row) { childrenByGenus[genus, default: []].append(row) }
        }
        let topLevelRows = sortedRows.filter { parentGenus($0) == nil && !isRoot($0) }
        let topLevelReads = topLevelRows.reduce(0) { $0 + $1.ntReadCount }

        let rootRow = rows.first(where: isRoot)
        let totalReads = rootRow?.ntReadCount ?? totalReadsFromRPM(rows) ?? topLevelReads

        var lines: [String] = []
        if rootRow == nil {
            lines.append(kreportLine(
                percent: 100,
                clade: totalReads,
                direct: max(0, totalReads - topLevelReads),
                rankCode: "R",
                taxId: 1,
                name: "root"
            ))
        }

        func append(_ row: CzIdTaxonReportRow, direct: Int, indent: String) {
            let rankCode = isRoot(row) ? "R" : kreportRankCode(for: row.rank)
            let percent = totalReads > 0 ? (Double(row.ntReadCount) / Double(totalReads)) * 100.0 : 0.0
            lines.append(kreportLine(
                percent: percent,
                clade: row.ntReadCount,
                direct: direct,
                rankCode: rankCode,
                taxId: row.taxId,
                name: rankCode == "R" ? row.name : indent + row.name
            ))
        }

        for row in sortedRows where parentGenus(row) == nil {
            let children = isRoot(row) ? [] : childrenByGenus[row.taxId] ?? []
            let childReads = children.reduce(0) { $0 + $1.ntReadCount }
            append(row, direct: max(0, row.ntReadCount - childReads), indent: "  ")
            for child in children {
                append(child, direct: child.ntReadCount, indent: "    ")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// The sample's total reads from the taxon with the most reads, as `nt_count` / `nt_rpm` per million.
    private static func totalReadsFromRPM(_ rows: [CzIdTaxonReportRow]) -> Int? {
        guard let row = rows.filter({ $0.ntReadCount > 0 && $0.ntRpm > 0 }).max(by: { $0.ntReadCount < $1.ntReadCount }) else {
            return nil
        }
        return integer((Double(row.ntReadCount) / row.ntRpm * 1_000_000).rounded())
    }

    private static func kreportLine(
        percent: Double,
        clade: Int,
        direct: Int,
        rankCode: String,
        taxId: Int,
        name: String
    ) -> String {
        "\(String(format: "%.2f", percent))\t\(clade)\t\(direct)\t\(rankCode)\t\(taxId)\t\(name)"
    }

    private static func kreportRankCode(for rank: String) -> String {
        switch rank.normalizedHeaderKey {
        case "root": return "R"
        case "superkingdom", "domain": return "D"
        case "kingdom": return "K"
        case "phylum": return "P"
        case "class": return "C"
        case "order": return "O"
        case "family": return "F"
        case "genus": return "G"
        case "species": return "S"
        // A named taxon with no rank, or a rank word not listed here, is Kraken's no-rank `-`, a taxon at its depth
        // that keeps its reads. `U` is unclassified reads, and the kreport parser keeps one such line, so writing
        // each of these rows as `U` lost the reads of all but the last.
        default: return "-"
        }
    }

    /// The header names each value is read from. They are compared after `normalizedHeaderKey`.
    private enum Aliases {
        static let taxId = ["taxid", "tax_id", "taxonid", "taxon_id"]
        static let name = ["taxonname", "tax_name", "name", "taxon"]
        static let ntCount = ["ntreadcount", "nt_read_count", "ntreads", "reads", "readcount", "read_count", "nt_count"]
        static let nrCount = ["nrreadcount", "nr_read_count", "nrreads", "nr_count"]
    }

    /// czid-web's `tax_level` (`taxon_count.rb:24-31`): 1 species, 2 genus, 3 family, 4 order, 5 class, 6 phylum,
    /// 7 kingdom and 8 superkingdom. Any other value is kept as it is.
    private static func rankName(forTaxLevel level: String) -> String {
        let ranks = [1: "species", 2: "genus", 3: "family", 4: "order", 5: "class", 6: "phylum", 7: "kingdom", 8: "superkingdom"]
        return Int(level).flatMap { ranks[$0] } ?? level
    }

    private static func hasColumn(_ index: [String: Int], aliases: [String]) -> Bool {
        aliases.contains { index[$0.normalizedHeaderKey] != nil }
    }

    /// One line's fields. A tab report splits on tabs, as it always has. A comma report follows RFC 4180, because
    /// czid-web quotes `species_tax_ids` such as `"[1280, 1282]"`: a field in double quotes may hold the delimiter,
    /// and a doubled quote inside it is one quote. A quoted field that runs past its line is refused, not split.
    private static func splitFields(_ line: String, delimiter: Character, url: URL) throws -> [String] {
        guard delimiter == "," else {
            return line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
        var fields: [String] = []
        var field = ""
        var inQuotes = false
        var atFieldStart = true
        var characters = line.makeIterator()
        var pending: Character? = characters.next()
        while let character = pending {
            pending = characters.next()
            if inQuotes {
                if character == "\"" {
                    if pending == "\"" {
                        field.append("\"")
                        pending = characters.next()
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" && atFieldStart {
                inQuotes = true
                atFieldStart = false
            } else if character == delimiter {
                fields.append(field)
                field = ""
                atFieldStart = true
            } else {
                field.append(character)
                atFieldStart = false
            }
        }
        guard !inQuotes else {
            throw CzIdDataConverterError.unparseableReport(url)
        }
        fields.append(field)
        return fields
    }

    /// `value` as an `Int`, or nil when it is not finite or does not fit.
    private static func integer(_ value: Double) -> Int? {
        guard value.isFinite, abs(value) < 9.0e18 else { return nil }
        return Int(value)
    }

    private static func stringValue(_ fields: [String], _ index: [String: Int], aliases: [String]) -> String? {
        for alias in aliases.map(\.normalizedHeaderKey) {
            guard let fieldIndex = index[alias], fields.indices.contains(fieldIndex) else { continue }
            let value = fields[fieldIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func intValue(_ fields: [String], _ index: [String: Int], aliases: [String]) -> Int? {
        guard let value = stringValue(fields, index, aliases: aliases) else { return nil }
        if let intValue = Int(value) { return intValue }
        return Double(value).flatMap(integer)
    }

    private static func doubleValue(_ fields: [String], _ index: [String: Int], aliases: [String]) -> Double? {
        guard let value = stringValue(fields, index, aliases: aliases) else { return nil }
        return Double(value)
    }

    private static func writeProvenance(
        input: URL,
        sourceInput: URL?,
        outputs: [URL],
        outputDirectory: URL,
        command: [String],
        toolVersion: String,
        runClock: ProvenanceRunClock,
        additionalInputs: [URL] = [],
        toolName: String = "lungfish cz-id import",
        parameters: [String: ParameterValue] = [:]
    ) throws {
        var inputURLs: [URL] = []
        if let sourceInput {
            inputURLs.append(sourceInput)
            if sourceInput.standardizedFileURL != input.standardizedFileURL {
                inputURLs.append(input)
            }
        } else {
            inputURLs.append(input)
        }
        inputURLs.append(contentsOf: additionalInputs)

        let inputRecords = inputURLs.map { fileRecord(for: $0, role: .input) }
        let outputRecords = outputs.map { fileRecord(for: $0, role: outputRole(for: $0)) }
        let inputDescriptors = inputRecords.map { ProvenanceFileDescriptor(fileRecord: $0) }
        let outputDescriptors = outputRecords.map { ProvenanceFileDescriptor(fileRecord: $0) }
        let defaults = defaultOptionValues()
        var resolved = defaults
        for (key, value) in parameters {
            resolved[key] = value
        }
        let startedAt = runClock.startedAt
        let endedAt = runClock.now
        let step = StepExecution(
            toolName: toolName,
            toolVersion: toolVersion,
            command: command,
            inputs: inputRecords,
            outputs: outputRecords,
            exitCode: 0,
            wallTime: endedAt.timeIntervalSince(startedAt),
            stderr: nil,
            startTime: startedAt,
            endTime: endedAt
        )
        let legacyRun = WorkflowRun(
            name: "CZ-ID Import",
            startTime: startedAt,
            endTime: endedAt,
            status: .completed,
            steps: [step],
            parameters: parameters
        )
        let provenanceStep = ProvenanceStep(
            toolName: toolName,
            toolVersion: toolVersion,
            argv: command,
            inputs: inputDescriptors,
            outputs: outputDescriptors,
            exitStatus: 0,
            wallTimeSeconds: endedAt.timeIntervalSince(startedAt),
            stderr: nil,
            startedAt: startedAt,
            completedAt: endedAt
        )

        var builder = ProvenanceRunBuilder(
            workflowName: "CZ-ID Import",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: toolName,
            toolVersion: toolVersion
        )
        .argv(command)
        .durableReplayArgv(command)
        .options(
            // The status and the note say what the report names, so they are resolved defaults only. A reader must not
            // take them for options the person chose (DB-IDENTITY, the Provenance tab).
            explicit: parameters.filter { $0.key != "databaseIdentityStatus" && $0.key != "databaseIdentityNote" },
            defaults: defaults,
            resolved: resolved
        )
        .runtime(ProvenanceRuntimeIdentity())
        .step(provenanceStep)

        for (url, record) in zip(inputURLs, inputRecords) {
            builder = try appendInputRecord(record, url: url, to: builder)
        }
        for (url, record) in zip(outputs, outputRecords) {
            builder = try appendOutputRecord(record, url: url, to: builder)
        }

        let envelope = try builder.complete(
            exitStatus: 0,
            startedAt: startedAt,
            endedAt: endedAt,
            legacyWorkflowRun: legacyRun
        )
        try ProvenanceWriter().write(envelope, to: outputDirectory)
    }

    private static func appendInputRecord(
        _ record: FileRecord,
        url: URL,
        to builder: ProvenanceRunBuilder
    ) throws -> ProvenanceRunBuilder {
        if isDirectory(url) {
            return try builder.input(ProvenanceFileDescriptor(fileRecord: record))
        }
        return try builder.input(url, format: record.format, role: record.role)
    }

    private static func appendOutputRecord(
        _ record: FileRecord,
        url: URL,
        to builder: ProvenanceRunBuilder
    ) throws -> ProvenanceRunBuilder {
        if isDirectory(url) {
            return try builder.output(ProvenanceFileDescriptor(fileRecord: record))
        }
        return try builder.output(url, format: record.format, role: record.role)
    }

    private static func defaultProvenanceParameters(
        parsed: CzIdParsedTaxonReport,
        sampleName: String,
        outputDirectory: URL,
        sourceInputURL: URL?,
        reportURL: URL,
        reportPayloadURL: URL
    ) -> [String: ParameterValue] {
        MetagenomicsImportDatabaseIdentity.czId(
            ntVersion: parsed.metadata.ntDatabaseVersion,
            nrVersion: parsed.metadata.nrDatabaseVersion,
            adding: [
            "sampleName": .string(sampleName),
            "czIdSchemaVersion": .string(schemaVersion),
            "pipelineVersion": parsed.metadata.pipelineVersion.map(ParameterValue.string) ?? .string("unknown"),
            "ntDatabaseVersion": parsed.metadata.ntDatabaseVersion.map(ParameterValue.string) ?? .string("unknown"),
            "nrDatabaseVersion": parsed.metadata.nrDatabaseVersion.map(ParameterValue.string) ?? .string("unknown"),
            "projectId": parsed.metadata.projectId.map(ParameterValue.string) ?? .null,
            "reportPayload": .file(reportPayloadURL),
            "sourcePath": sourceInputURL.map(ParameterValue.file) ?? .file(reportURL),
            "outputDirectory": .file(outputDirectory),
            "outputDefaults": .string("classification.kreport, classification.czid.tsv, cz-id-manifest.json, classification-result.json"),
        ])
    }

    private static func defaultOptionValues() -> [String: ParameterValue] {
        [
            "projectId": .null,
            "metadataPath": .null,
            "nonHostFastqPath": .null,
            "outputDefaults": .string("classification.kreport, classification.czid.tsv, cz-id-manifest.json, classification-result.json"),
        ]
    }

    private static func fileRecord(for url: URL, role: FileRole) -> FileRecord {
        ProvenanceRecorder.fileOrDirectoryRecord(url: url, format: fileFormat(for: url), role: role)
    }

    private static func outputRole(for url: URL) -> FileRole {
        url.lastPathComponent == "classification.kreport" ? .report : .output
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func fileFormat(for url: URL) -> FileFormat {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "json": return .json
        case "tsv", "txt", "csv", "kreport": return .text
        default: return .unknown
        }
    }
}

public struct CzIdParsedTaxonReport: Sendable, Equatable {
    public let metadata: CzIdImportMetadata
    public let rows: [CzIdTaxonReportRow]
}

public struct CzIdConversion: Sendable {
    public let parsed: CzIdParsedTaxonReport
    public let result: ClassificationResult
    public let manifest: CzIdImportManifest?
}

public struct CzIdTaxonReportRow: Codable, Sendable, Equatable {
    public let taxId: Int
    public let name: String
    public let rank: String
    public let ntReadCount: Int
    public let ntRpm: Double
    public let ntPercentIdentity: Double?
    public let ntAlignmentLength: Int?
    public let ntEValue: Double?
    public let nrReadCount: Int?
    public let nrRpm: Double?
    public let nrPercentIdentity: Double?
    public let nrAlignmentLength: Int?
    public let nrEValue: Double?
    /// The genus a CZ-ID species row sits under (`genus_tax_id`), which places it in the kreport. It is not part of
    /// the encoded row, so `cz-id summary --format json` prints what it printed before.
    public var genusTaxId: Int? = nil

    private enum CodingKeys: String, CodingKey {
        case taxId, name, rank, ntReadCount, ntRpm, ntPercentIdentity, ntAlignmentLength, ntEValue
        case nrReadCount, nrRpm, nrPercentIdentity, nrAlignmentLength, nrEValue
    }
}

public struct CzIdImportMetadata: Codable, Sendable, Equatable {
    public var sampleName: String?
    public var projectId: String?
    public var pipelineVersion: String?
    public var ntDatabaseVersion: String?
    public var nrDatabaseVersion: String?

    public init(
        sampleName: String? = nil,
        projectId: String? = nil,
        pipelineVersion: String? = nil,
        ntDatabaseVersion: String? = nil,
        nrDatabaseVersion: String? = nil
    ) {
        self.sampleName = sampleName
        self.projectId = projectId
        self.pipelineVersion = pipelineVersion
        self.ntDatabaseVersion = ntDatabaseVersion
        self.nrDatabaseVersion = nrDatabaseVersion
    }

    public var databaseVersionString: String {
        let nt = ntDatabaseVersion ?? "unknown"
        let nr = nrDatabaseVersion ?? "unknown"
        return "nt=\(nt); nr=\(nr)"
    }

    mutating func merge(_ other: CzIdImportMetadata) {
        sampleName = sampleName ?? other.sampleName
        projectId = projectId ?? other.projectId
        pipelineVersion = pipelineVersion ?? other.pipelineVersion
        ntDatabaseVersion = ntDatabaseVersion ?? other.ntDatabaseVersion
        nrDatabaseVersion = nrDatabaseVersion ?? other.nrDatabaseVersion
    }
}

public struct CzIdImportManifest: Codable, Sendable, Equatable {
    public let schemaVersion: String
    public let sampleName: String
    public let projectId: String?
    public let pipelineVersion: String?
    public let ntDatabaseVersion: String?
    public let nrDatabaseVersion: String?
    public let sourceFiles: [URL]
    public let rowCount: Int

    public init(
        schemaVersion: String,
        sampleName: String,
        projectId: String?,
        pipelineVersion: String?,
        ntDatabaseVersion: String?,
        nrDatabaseVersion: String?,
        sourceFiles: [URL],
        rowCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.sampleName = sampleName
        self.projectId = projectId
        self.pipelineVersion = pipelineVersion
        self.ntDatabaseVersion = ntDatabaseVersion
        self.nrDatabaseVersion = nrDatabaseVersion
        self.sourceFiles = sourceFiles
        self.rowCount = rowCount
    }
}

public enum CzIdDataConverterError: Error, LocalizedError, Sendable, Equatable {
    case emptyReport(URL)
    /// The report has no taxon ID or no taxon name column (FIX-CZID Z1).
    case missingColumn(fileName: String, column: String)
    /// The report has no NT or NR read count column (FIX-CZID Z2).
    case missingCountColumn(fileName: String)
    /// A row has no taxon ID or name (FIX-CZID Z9). `row` is the line in the file, the header being 1.
    case missingValue(fileName: String, row: Int, column: String)
    /// A quoted field runs past its line.
    case unparseableReport(URL)

    public var errorDescription: String? {
        switch self {
        case .emptyReport(let url):
            return "CZ-ID taxon report is empty: \(url.path)"
        case .missingColumn(let fileName, let column):
            return "\(fileName) is missing the \(column) column required for CZ-ID taxon reports. Nothing was imported."
        case .missingCountColumn(let fileName):
            return "\(fileName) has no read count column (nt_count or nr_count), so counts cannot be assigned to taxa. Nothing was imported."
        case .missingValue(let fileName, let row, let column):
            return "Row \(row) of \(fileName) has no \(column) value. Nothing was imported."
        case .unparseableReport(let url):
            // The words of `CzIdImportPreviewError.reportNotFound`, since FIX-CZID decided none for this case.
            return "No parseable CZ-ID taxon report was found in \(url.path)"
        }
    }
}

private extension FileManager {
    func copyItemReplacingExistingItem(at source: URL, to destination: URL) throws {
        if fileExists(atPath: destination.path) {
            try removeItem(at: destination)
        }
        try copyItem(at: source, to: destination)
    }
}

private extension String {
    var normalizedHeaderKey: String {
        lowercased().filter { $0.isLetter || $0.isNumber }
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

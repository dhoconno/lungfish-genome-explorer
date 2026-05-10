// CzIdDataConverter.swift - CZ-ID taxon report import normalization
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import LungfishWorkflow

public enum CzIdDataConverter {
    public static let schemaVersion = "cz-id-taxon-report-v1"

    public static func parseTaxonReport(at url: URL) throws -> CzIdParsedTaxonReport {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard let headerLine = lines.first else {
            throw CzIdDataConverterError.emptyReport(url)
        }

        let headers = splitTSVLine(headerLine)
        let index = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($0.element.normalizedHeaderKey, $0.offset) })

        var rows: [CzIdTaxonReportRow] = []
        var metadata = CzIdImportMetadata()

        for line in lines.dropFirst() {
            let fields = splitTSVLine(line)
            guard !fields.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                continue
            }

            let taxId = intValue(fields, index, aliases: ["taxid", "tax_id", "taxonid", "taxon_id"])
            let name = stringValue(fields, index, aliases: ["taxonname", "tax_name", "name", "taxon"])
            let rank = stringValue(fields, index, aliases: ["rank", "taxonrank", "tax_rank"]) ?? "no rank"

            guard let taxId, let name, !name.isEmpty else {
                throw CzIdDataConverterError.missingRequiredColumns
            }

            let row = CzIdTaxonReportRow(
                taxId: taxId,
                name: name,
                rank: rank,
                ntReadCount: intValue(fields, index, aliases: ["ntreadcount", "nt_read_count", "ntreads", "reads", "readcount", "read_count"]) ?? 0,
                ntRpm: doubleValue(fields, index, aliases: ["ntrpm", "nt_rpm", "rpm"]) ?? 0,
                ntPercentIdentity: doubleValue(fields, index, aliases: ["ntpercentidentity", "nt_percent_identity", "percentidentity", "percent_identity", "pident"]),
                ntAlignmentLength: intValue(fields, index, aliases: ["ntalignmentlength", "nt_alignment_length", "alignmentlength", "alignment_length"]),
                ntEValue: doubleValue(fields, index, aliases: ["ntevalue", "nt_e_value", "evalue", "e_value"]),
                nrReadCount: intValue(fields, index, aliases: ["nrreadcount", "nr_read_count", "nrreads"]),
                nrRpm: doubleValue(fields, index, aliases: ["nrrpm", "nr_rpm"]),
                nrPercentIdentity: doubleValue(fields, index, aliases: ["nrpercentidentity", "nr_percent_identity"]),
                nrAlignmentLength: intValue(fields, index, aliases: ["nralignmentlength", "nr_alignment_length"]),
                nrEValue: doubleValue(fields, index, aliases: ["nrevalue", "nr_e_value"])
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
        let startedAt = Date()
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
        let result = ClassificationResult(
            config: ClassificationConfig(
                inputFiles: sourceInputURL == nil ? [url] : [outputURL],
                isPairedEnd: false,
                databaseName: "CZ-ID",
                inputFormat: .fastq,
                databaseVersion: parsed.metadata.databaseVersionString,
                databasePath: sourceInputURL == nil ? url.deletingLastPathComponent() : outputDirectory,
                outputDirectory: outputDirectory
            ),
            tree: tree,
            reportURL: reportURL,
            outputURL: outputURL,
            brackenURL: nil,
            runtime: Date().timeIntervalSince(startedAt),
            toolVersion: parsed.metadata.pipelineVersion ?? "unknown",
            provenanceId: nil
        )
        try result.save(to: outputDirectory)

        try writeProvenance(
            input: url,
            sourceInput: sourceInputURL,
            outputs: [reportURL, outputURL, manifestURL, outputDirectory.appendingPathComponent("classification-result.json")],
            outputDirectory: outputDirectory,
            command: command ?? ["lungfish", "cz-id", "import", url.path, "--output-dir", outputDirectory.path],
            toolVersion: parsed.metadata.pipelineVersion ?? "unknown",
            startedAt: startedAt,
            additionalInputs: additionalInputURLs,
            toolName: provenanceToolName,
            parameters: provenanceParameters.merging(defaultProvenanceParameters(
                parsed: parsed,
                sampleName: sampleName,
                outputDirectory: outputDirectory,
                sourceInputURL: sourceInputURL,
                reportURL: url
            )) { explicit, _ in explicit }
        )

        return CzIdConversion(parsed: parsed, result: result, manifest: manifest)
    }

    public static func kreportText(from rows: [CzIdTaxonReportRow]) -> String {
        let hasRoot = rows.contains { $0.rank.normalizedHeaderKey == "root" || $0.taxId == 1 }
        let totalReads = rows.first { $0.rank.normalizedHeaderKey == "root" || $0.taxId == 1 }?.ntReadCount
            ?? rows.reduce(0) { $0 + $1.ntReadCount }

        var lines: [String] = []
        if !hasRoot {
            lines.append(kreportLine(percent: 100, clade: totalReads, direct: totalReads, rankCode: "R", taxId: 1, name: "root"))
        }

        let sortedRows = rows.sorted { lhs, rhs in
            if lhs.taxId == 1 { return true }
            if rhs.taxId == 1 { return false }
            return lhs.ntReadCount > rhs.ntReadCount
        }

        for row in sortedRows {
            let rankCode = kreportRankCode(for: row.rank)
            let percent = totalReads > 0 ? (Double(row.ntReadCount) / Double(totalReads)) * 100.0 : 0.0
            let name = rankCode == "R" ? row.name : "  \(row.name)"
            lines.append(kreportLine(
                percent: percent,
                clade: row.ntReadCount,
                direct: row.ntReadCount,
                rankCode: rankCode,
                taxId: row.taxId,
                name: name
            ))
        }

        return lines.joined(separator: "\n") + "\n"
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
        default: return "U"
        }
    }

    private static func splitTSVLine(_ line: String) -> [String] {
        line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
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
        return Double(value).map(Int.init)
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
        startedAt: Date,
        additionalInputs: [URL] = [],
        toolName: String = "lungfish cz-id import",
        parameters: [String: ParameterValue] = [:]
    ) throws {
        var inputRecords: [FileRecord] = []
        if let sourceInput {
            inputRecords.append(fileRecord(for: sourceInput, role: .input))
            if sourceInput.standardizedFileURL != input.standardizedFileURL {
                inputRecords.append(fileRecord(for: input, role: .input))
            }
        } else {
            inputRecords.append(fileRecord(for: input, role: .input))
        }
        inputRecords.append(contentsOf: additionalInputs.map { fileRecord(for: $0, role: .input) })
        let outputRecords = outputs.map {
            FileRecord(
                path: $0.path,
                sha256: ProvenanceRecorder.sha256(of: $0),
                sizeBytes: fileSize($0),
                format: $0.pathExtension == "json" ? .json : .text,
                role: $0.lastPathComponent == "classification.kreport" ? .report : .output
            )
        }
        let endedAt = Date()
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
        let run = WorkflowRun(
            name: "CZ-ID Import",
            startTime: startedAt,
            endTime: endedAt,
            status: .completed,
            steps: [step],
            parameters: parameters
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run).write(
            to: outputDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            options: .atomic
        )
    }

    private static func defaultProvenanceParameters(
        parsed: CzIdParsedTaxonReport,
        sampleName: String,
        outputDirectory: URL,
        sourceInputURL: URL?,
        reportURL: URL
    ) -> [String: ParameterValue] {
        [
            "sampleName": .string(sampleName),
            "czIdSchemaVersion": .string(schemaVersion),
            "pipelineVersion": parsed.metadata.pipelineVersion.map(ParameterValue.string) ?? .string("unknown"),
            "ntDatabaseVersion": parsed.metadata.ntDatabaseVersion.map(ParameterValue.string) ?? .string("unknown"),
            "nrDatabaseVersion": parsed.metadata.nrDatabaseVersion.map(ParameterValue.string) ?? .string("unknown"),
            "projectId": parsed.metadata.projectId.map(ParameterValue.string) ?? .null,
            "reportPayload": .file(reportURL),
            "sourcePath": sourceInputURL.map(ParameterValue.file) ?? .file(reportURL),
            "outputDirectory": .file(outputDirectory),
            "outputDefaults": .string("classification.kreport, classification.czid.tsv, cz-id-manifest.json, classification-result.json"),
        ]
    }

    private static func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? UInt64
    }

    private static func fileRecord(for url: URL, role: FileRole) -> FileRecord {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return FileRecord(
            path: url.path,
            sha256: isDirectory ? nil : ProvenanceRecorder.sha256(of: url),
            sizeBytes: isDirectory ? nil : fileSize(url),
            format: fileFormat(for: url),
            role: role
        )
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
}

public enum CzIdDataConverterError: Error, LocalizedError, Sendable, Equatable {
    case emptyReport(URL)
    case missingRequiredColumns

    public var errorDescription: String? {
        switch self {
        case .emptyReport(let url):
            return "CZ-ID taxon report is empty: \(url.path)"
        case .missingRequiredColumns:
            return "CZ-ID taxon report must include tax_id, taxon_name, and rank columns"
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

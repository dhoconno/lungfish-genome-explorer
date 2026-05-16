// CzIdImportPreview.swift - App-side CZ-ID import source detection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public struct CzIdImportPreview: Sendable, Equatable {
    public enum SourceKind: String, Sendable, Equatable {
        case taxonReportFile
        case extractedFolder
        case zipArchive

        public var displayName: String {
            switch self {
            case .taxonReportFile: return "Taxon report file"
            case .extractedFolder: return "Extracted folder"
            case .zipArchive: return "ZIP archive"
            }
        }
    }

    public let sourceURL: URL
    public let sourceKind: SourceKind
    public let sourceArchiveURL: URL?
    public let reportURL: URL
    public let reportFileName: String
    public let sampleName: String
    public let projectId: String?
    public let pipelineVersion: String?
    public let ntDatabaseVersion: String?
    public let nrDatabaseVersion: String?
    public let rowCount: Int
    public let topTaxa: [CzIdTaxonReportRow]

    public static func scan(_ url: URL) async throws -> CzIdImportPreview {
        try await withResolvedReport(from: url) { resolved in
            try makePreview(from: resolved)
        }
    }

    public static func withResolvedReport<T>(
        from url: URL,
        _ body: (CzIdResolvedImportSource) throws -> T
    ) async throws -> T {
        let resolved = try resolve(url)
        defer { resolved.cleanup() }
        return try body(resolved)
    }

    private static func resolve(_ url: URL) throws -> CzIdResolvedImportSource {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists else {
            throw CzIdImportPreviewError.sourceNotFound(url)
        }

        if isDirectory.boolValue {
            let reportURL = try findTaxonReport(in: url)
            return CzIdResolvedImportSource(
                selectedSourceURL: url,
                sourceKind: .extractedFolder,
                sourceArchiveURL: nil,
                reportURL: reportURL,
                cleanupHandler: nil
            )
        }

        if url.pathExtension.lowercased() == "zip" {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("czid-preview-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            do {
                try unzipArchive(url, to: tempDir)
                let reportURL = try findTaxonReport(in: tempDir)
                return CzIdResolvedImportSource(
                    selectedSourceURL: url,
                    sourceKind: .zipArchive,
                    sourceArchiveURL: url,
                    reportURL: reportURL,
                    cleanupHandler: {
                        try? FileManager.default.removeItem(at: tempDir)
                    }
                )
            } catch {
                try? FileManager.default.removeItem(at: tempDir)
                throw error
            }
        }

        _ = try CzIdDataConverter.parseTaxonReport(at: url)
        return CzIdResolvedImportSource(
            selectedSourceURL: url,
            sourceKind: .taxonReportFile,
            sourceArchiveURL: nil,
            reportURL: url,
            cleanupHandler: nil
        )
    }

    private static func makePreview(from resolved: CzIdResolvedImportSource) throws -> CzIdImportPreview {
        let parsed = try CzIdDataConverter.parseTaxonReport(at: resolved.reportURL)
        let fallbackName = resolved.reportURL.deletingPathExtension().lastPathComponent
        let topTaxa = parsed.rows
            .filter { $0.taxId != 1 && $0.rank.lowercased() != "root" }
            .sorted { lhs, rhs in
                if lhs.ntReadCount == rhs.ntReadCount {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                return lhs.ntReadCount > rhs.ntReadCount
            }
            .prefix(5)

        return CzIdImportPreview(
            sourceURL: resolved.selectedSourceURL,
            sourceKind: resolved.sourceKind,
            sourceArchiveURL: resolved.sourceArchiveURL,
            reportURL: resolved.reportURL,
            reportFileName: resolved.reportURL.lastPathComponent,
            sampleName: parsed.metadata.sampleName ?? fallbackName,
            projectId: parsed.metadata.projectId,
            pipelineVersion: parsed.metadata.pipelineVersion,
            ntDatabaseVersion: parsed.metadata.ntDatabaseVersion,
            nrDatabaseVersion: parsed.metadata.nrDatabaseVersion,
            rowCount: parsed.rows.count,
            topTaxa: Array(topTaxa)
        )
    }

    private static func unzipArchive(_ archiveURL: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]

        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            throw CzIdImportPreviewError.archiveExtractionFailed(archiveURL, stderr)
        }
    }

    private static func findTaxonReport(in directoryURL: URL) throws -> URL {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw CzIdImportPreviewError.reportNotFound(directoryURL)
        }

        var candidates: [(url: URL, score: Int)] = []
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            guard isCandidateReportName(fileURL.lastPathComponent) else {
                continue
            }
            guard (try? CzIdDataConverter.parseTaxonReport(at: fileURL)) != nil else {
                continue
            }
            candidates.append((fileURL, candidateScore(fileURL)))
        }

        guard let best = candidates.sorted(by: { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.url.path.count < rhs.url.path.count
            }
            return lhs.score > rhs.score
        }).first else {
            throw CzIdImportPreviewError.reportNotFound(directoryURL)
        }
        return best.url
    }

    private static func isCandidateReportName(_ name: String) -> Bool {
        let lower = name.lowercased()
        let allowedExtensions = ["tsv", "txt", "csv"]
        guard let ext = lower.split(separator: ".").last,
              allowedExtensions.contains(String(ext)) else {
            return false
        }
        return lower.contains("taxon")
            || lower.contains("report")
            || lower.contains("czid")
            || lower.contains("cz-id")
    }

    private static func candidateScore(_ url: URL) -> Int {
        let lower = url.lastPathComponent.lowercased()
        var score = 0
        if lower == "taxon_report.tsv" { score += 100 }
        if lower.contains("taxon") { score += 30 }
        if lower.contains("report") { score += 30 }
        if lower.contains("czid") || lower.contains("cz-id") { score += 20 }
        if lower.hasSuffix(".tsv") { score += 10 }
        return score
    }
}

public struct CzIdResolvedImportSource {
    public let selectedSourceURL: URL
    public let sourceKind: CzIdImportPreview.SourceKind
    public let sourceArchiveURL: URL?
    public let reportURL: URL
    private let cleanupHandler: (() -> Void)?

    init(
        selectedSourceURL: URL,
        sourceKind: CzIdImportPreview.SourceKind,
        sourceArchiveURL: URL?,
        reportURL: URL,
        cleanupHandler: (() -> Void)?
    ) {
        self.selectedSourceURL = selectedSourceURL
        self.sourceKind = sourceKind
        self.sourceArchiveURL = sourceArchiveURL
        self.reportURL = reportURL
        self.cleanupHandler = cleanupHandler
    }

    public func cleanup() {
        cleanupHandler?()
    }
}

public enum CzIdImportPreviewError: Error, LocalizedError, Sendable, Equatable {
    case sourceNotFound(URL)
    case archiveExtractionFailed(URL, String)
    case reportNotFound(URL)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let url):
            return "CZ-ID source was not found: \(url.path)"
        case .archiveExtractionFailed(let url, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "Could not extract CZ-ID ZIP archive: \(url.lastPathComponent)"
            }
            return "Could not extract CZ-ID ZIP archive: \(detail)"
        case .reportNotFound(let url):
            return "No parseable CZ-ID taxon report was found in \(url.path)"
        }
    }
}

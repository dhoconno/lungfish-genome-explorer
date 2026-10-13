// FetchGenomeDirectFiles.swift - The --fasta-only and --no-bundle paths of lungfish-cli fetch genome
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// The `--fasta-only` and `--no-bundle` paths of `fetch genome`, which save the fetched files as
/// they came and build no bundle. They behave as before Phase 2.10, one accession at a time. An
/// assembly saves `<name>.fna.gz`, and `<name>.gff.gz` unless `--fasta-only`, with a record beside
/// each. A nucleotide record saves `<name>.fna` and no record.
struct FetchGenomeDirectFiles: Sendable {
    let request: FetchGenomeRequest
    let reporter: FetchGenomeReporter

    func fetchAssemblyFiles(
        _ accession: String,
        summary: NCBIAssemblySummary,
        service: NCBIService,
        apiKeySource: GenomeFetchProvenanceWriter.APIKeySource,
        runClock: ProvenanceRunClock
    ) async throws -> FetchGenomeOutput {
        let fileManager = FileManager.default
        let assemblyAccession = summary.assemblyAccession ?? accession
        let organism = summary.organism ?? summary.speciesName ?? "Unknown"
        let baseName = request.name ?? "\(organism.replacingOccurrences(of: " ", with: "_"))_\(assemblyAccession)"
        let fileInfo = try await service.getGenomeFileInfo(for: summary)
        let tempDir = try ProjectTempDirectory.createFromContext(prefix: ".lungfish-temp-", contextURL: request.outputURL)
        defer { try? fileManager.removeItem(at: tempDir) }

        reporter.info("Downloading FASTA...")
        let fastaGzPath = tempDir.appendingPathComponent(fileInfo.filename)
        _ = try await service.downloadGenomeFile(fileInfo, to: fastaGzPath) { _, _ in }
        try Task.checkCancellation()

        var gffPath: URL?
        var gffSourceURL: URL?
        if !request.fastaOnly, let gffURL = Self.gffURL(for: summary) {
            reporter.info("Downloading annotations (GFF3)...")
            do {
                let (tempURL, response) = try await URLSession.shared.download(from: gffURL)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    let downloaded = tempDir.appendingPathComponent(gffURL.lastPathComponent)
                    try fileManager.moveItem(at: tempURL, to: downloaded)
                    gffPath = downloaded
                    gffSourceURL = gffURL
                } else {
                    reporter.warning("Annotations not available for \(accession)")
                }
            } catch {
                reporter.warning("Could not download annotations for \(accession): \(error.localizedDescription)")
            }
        }
        try Task.checkCancellation()

        let finalFastaURL = request.outputURL.appendingPathComponent("\(baseName).fna.gz")
        let finalGFFURL = gffPath.map { _ in request.outputURL.appendingPathComponent("\(baseName).gff.gz") }
        var copied: [URL] = []
        do {
            try fileManager.copyItem(at: fastaGzPath, to: finalFastaURL)
            copied.append(finalFastaURL)
            if let gffPath, let finalGFFURL {
                try fileManager.copyItem(at: gffPath, to: finalGFFURL)
                copied.append(finalGFFURL)
            }
            try await GenomeFetchProvenanceWriter().writeDirectOutputs(.init(
                accession: accession,
                assemblyAccession: assemblyAccession,
                organism: organism,
                outputDirectory: request.outputURL,
                bundleName: request.name,
                fastaOnly: request.fastaOnly,
                noBundle: request.noBundle,
                apiKeySource: apiKeySource,
                outputFormat: request.outputFormat,
                quiet: request.quiet,
                fastaSourceURL: fileInfo.url,
                downloadedFastaURL: fastaGzPath,
                gffSourceURL: gffSourceURL,
                downloadedGFFURL: gffPath,
                finalFastaURL: finalFastaURL,
                finalGFFURL: finalGFFURL,
                runClock: runClock
            ))
        } catch {
            for url in copied {
                try? fileManager.removeItem(at: url)
                try? fileManager.removeItem(at: ProvenanceRecorder.fileSidecarURL(for: url))
            }
            throw error
        }
        return .files(copied)
    }

    func fetchNucleotideFASTA(_ accession: String, service: NCBIService) async throws -> FetchGenomeOutput {
        reporter.info("Fetching nucleotide record \(accession)...")
        let fastaData = try await service.efetch(database: .nucleotide, ids: [accession], format: .fasta)
        guard let fasta = String(data: fastaData, encoding: .utf8), fasta.hasPrefix(">") else {
            throw CLIError.networkError(reason: "Nucleotide record not found: \(accession)")
        }
        // The header names the sequence every downstream consumer matches on, so the file is named
        // from the record rather than from the query.
        let header = fasta.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let sequenceName = header.dropFirst().split(separator: " ").first.map(String.init) ?? accession
        let finalFastaURL = request.outputURL.appendingPathComponent("\(request.name ?? sequenceName).fna")
        try fastaData.write(to: finalFastaURL, options: .withoutOverwriting)
        return .files([finalFastaURL])
    }

    /// The `_genomic.gff.gz` beside the assembly's FASTA in its FTP folder, over HTTPS.
    static func gffURL(for summary: NCBIAssemblySummary) -> URL? {
        guard let ftpPath = summary.ftpPathRefSeq ?? summary.ftpPathGenBank,
              let folder = ftpPath.components(separatedBy: "/").last, !folder.isEmpty else {
            return nil
        }
        var httpPath = ftpPath
        if httpPath.hasPrefix("ftp://") {
            httpPath = httpPath.replacingOccurrences(of: "ftp://", with: "https://")
        } else if !httpPath.hasPrefix("https://"), !httpPath.hasPrefix("http://") {
            httpPath = "https://\(httpPath)"
        }
        return URL(string: "\(httpPath)/\(folder)_genomic.gff.gz")
    }
}

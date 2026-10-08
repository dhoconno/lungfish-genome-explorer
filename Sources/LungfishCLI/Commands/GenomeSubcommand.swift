// GenomeSubcommand.swift - Download genome assemblies from NCBI and create indexed bundles
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import CryptoKit
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

// MARK: - Genome Subcommand

/// Download genome assemblies from NCBI and create indexed bundles
struct GenomeSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "genome",
        abstract: "Download genomes from NCBI and create indexed bundles",
        discussion: """
            Downloads a genome from NCBI, including the FASTA sequence and GFF3
            annotations, then creates a .lungfishref bundle with proper indices.

            Assembly accessions (GCF_/GCA_) are resolved through the assembly
            database. Any other accession is fetched from nucleotide, which
            returns the exact record requested: asking the assembly database for
            a nucleotide accession returns the linked assembly instead, under a
            different sequence name.

            The bundle contains:
            - Compressed, indexed FASTA (bgzip + samtools faidx)
            - SQLite annotation database (converted from GFF3)
            - Manifest with metadata

            Examples:
              lungfish-cli fetch genome GCF_003047895.1 --output-dir ./genomes
              lungfish-cli fetch genome MN908947.3 --output-dir ./genomes
              lungfish-cli fetch genome GCF_000001405.40 --name "Human GRCh38" --output-dir ./
              lungfish-cli fetch genome GCF_003047895.1 --fasta-only --output-dir ./
            """
    )

    @Argument(help: "Assembly (GCF_003047895.1) or nucleotide (MN908947.3) accession")
    var accession: String

    @Option(
        name: .customLong("output-dir"),
        help: "Output directory for the bundle (default: current directory)"
    )
    var outputDir: String = "."

    @Option(
        name: .long,
        help: "Bundle name (default: derived from assembly)"
    )
    var name: String?

    @Flag(
        name: .customLong("fasta-only"),
        help: "Download only the FASTA sequence (no annotations, no bundle)"
    )
    var fastaOnly: Bool = false

    @Flag(
        name: .customLong("no-bundle"),
        help: "Download files but don't create a .lungfishref bundle"
    )
    var noBundle: Bool = false

    @Option(
        name: .customLong("api-key"),
        help: "NCBI API key for higher rate limits"
    )
    var apiKey: String?

    @OptionGroup var globalOptions: GlobalOptions

    func run() async throws {
        let runClock = ProvenanceRunClock()
        let formatter = TerminalFormatter(useColors: globalOptions.useColors)
        let fileManager = FileManager.default

        // Create output directory if needed
        let outputURL = URL(fileURLWithPath: outputDir)
        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

        if !globalOptions.quiet {
            print(formatter.header("Downloading Genome Assembly"))
            print("Accession: \(accession)")
            print("Output: \(outputURL.path)")
            print("")
        }

        // A nucleotide accession has no assembly record of its own, so the
        // assembly search would land on the linked RefSeq assembly and return a
        // differently named sequence. Fetch it from nuccore instead, where the
        // requested accession is what comes back.
        if NCBIAccessionKind.classify(accession) == .nucleotide {
            try await runNucleotideFetch(
                outputURL: outputURL,
                formatter: formatter,
                fileManager: fileManager,
                runClock: runClock
            )
            return
        }

        // Step 1: Search for the assembly to get metadata
        if !globalOptions.quiet {
            print(formatter.info("Searching for assembly \(accession)..."))
        }

        let explicitAPIKeyProvided = NCBIAPIKeyResolver.resolve(explicitAPIKey: apiKey, environment: [:]) != nil
        let resolvedAPIKeyProvided = NCBIAPIKeyResolver.resolve(explicitAPIKey: apiKey) != nil
        let apiKeySource: GenomeFetchProvenanceWriter.APIKeySource = if explicitAPIKeyProvided {
            .explicit
        } else if resolvedAPIKeyProvided {
            .environment
        } else {
            .none
        }
        let ncbiService = NCBIService(apiKey: apiKey)

        // Search the assembly database
        let searchResult = try await ncbiService.searchGenome(term: accession, retmax: 1)

        guard !searchResult.ids.isEmpty else {
            throw CLIError.networkError(reason: "Assembly not found: \(accession)")
        }

        // Get assembly summary
        let summaries = try await ncbiService.assemblyEsummary(ids: searchResult.ids)

        guard let summary = summaries.first else {
            throw CLIError.networkError(reason: "Could not retrieve assembly metadata for \(accession)")
        }

        let assemblyAccession = summary.assemblyAccession ?? accession
        let organism = summary.organism ?? summary.speciesName ?? "Unknown"
        let bundleName = name ?? "\(organism.replacingOccurrences(of: " ", with: "_"))_\(assemblyAccession)"

        if !globalOptions.quiet {
            print(formatter.success("Found: \(organism)"))
            print("  Assembly: \(assemblyAccession)")
            if let coverage = summary.coverage {
                print("  Coverage: \(coverage)")
            }
            print("")
        }

        // Step 2: Get download URLs and download files
        if !globalOptions.quiet {
            print(formatter.info("Getting download URLs..."))
        }

        let genomeFileInfo = try await ncbiService.getGenomeFileInfo(for: summary)

        // Create a temp directory for downloads
        let tempDir = try ProjectTempDirectory.createFromContext(prefix: ".lungfish-temp-", contextURL: outputURL)

        defer {
            // Clean up temp directory
            try? fileManager.removeItem(at: tempDir)
        }

        // Download FASTA
        if !globalOptions.quiet {
            let sizeStr = genomeFileInfo.estimatedSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown size"
            print(formatter.info("Downloading FASTA (\(sizeStr))..."))
        }

        let fastaGzPath = tempDir.appendingPathComponent(genomeFileInfo.filename)
        _ = try await ncbiService.downloadGenomeFile(genomeFileInfo, to: fastaGzPath) { downloaded, total in
            if !globalOptions.quiet && globalOptions.outputFormat == .text {
                let downloadedStr = ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
                if let total = total {
                    let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                    let percent = Int(Double(downloaded) / Double(total) * 100)
                    print("\r  \(downloadedStr) / \(totalStr) (\(percent)%)", terminator: "")
                } else {
                    print("\r  \(downloadedStr)", terminator: "")
                }
                fflush(stdout)
            }
        }

        if !globalOptions.quiet {
            print("") // newline after progress
            print(formatter.success("FASTA downloaded"))
        }

        // Download GFF3 annotations (if not fasta-only)
        var gffPath: URL?
        var gffSourceURL: URL?
        if !fastaOnly {
            if !globalOptions.quiet {
                print(formatter.info("Downloading annotations (GFF3)..."))
            }

            // Construct GFF3 URL from FTP path
            if let ftpPath = summary.ftpPathRefSeq ?? summary.ftpPathGenBank {
                let pathComponents = ftpPath.components(separatedBy: "/")
                if let assemblyDirName = pathComponents.last, !assemblyDirName.isEmpty {
                    let gffFilename = "\(assemblyDirName)_genomic.gff.gz"
                    var httpPath = ftpPath
                    if httpPath.hasPrefix("ftp://") {
                        httpPath = httpPath.replacingOccurrences(of: "ftp://", with: "https://")
                    } else if !httpPath.hasPrefix("https://") && !httpPath.hasPrefix("http://") {
                        httpPath = "https://\(httpPath)"
                    }

                    if let gffURL = URL(string: "\(httpPath)/\(gffFilename)") {
                        let downloadedGffPath = tempDir.appendingPathComponent(gffFilename)

                        do {
                            let (tempURL, response) = try await URLSession.shared.download(from: gffURL)
                            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                                try fileManager.moveItem(at: tempURL, to: downloadedGffPath)
                                gffPath = downloadedGffPath
                                gffSourceURL = gffURL
                                if !globalOptions.quiet {
                                    print(formatter.success("Annotations downloaded"))
                                }
                            } else {
                                if !globalOptions.quiet {
                                    print(formatter.warning("Annotations not available for this assembly"))
                                }
                            }
                        } catch {
                            if !globalOptions.quiet {
                                print(formatter.warning("Could not download annotations: \(error.localizedDescription)"))
                            }
                        }
                    }
                }
            }
        }

        // If fasta-only or no-bundle, just decompress and save
        if fastaOnly || noBundle {
            let finalFastaPath = outputURL.appendingPathComponent("\(bundleName).fna.gz")
            let finalGffPath = gffPath.map { _ in outputURL.appendingPathComponent("\(bundleName).gff.gz") }
            var copiedOutputURLs: [URL] = []

            do {
                try fileManager.copyItem(at: fastaGzPath, to: finalFastaPath)
                copiedOutputURLs.append(finalFastaPath)
                if let gff = gffPath, let finalGffPath {
                    try fileManager.copyItem(at: gff, to: finalGffPath)
                    copiedOutputURLs.append(finalGffPath)
                }
                try await GenomeFetchProvenanceWriter().writeDirectOutputs(
                    .init(
                        accession: accession,
                        assemblyAccession: assemblyAccession,
                        organism: organism,
                        outputDirectory: outputURL,
                        bundleName: name,
                        fastaOnly: fastaOnly,
                        noBundle: noBundle,
                        apiKeySource: apiKeySource,
                        outputFormat: globalOptions.outputFormat,
                        quiet: globalOptions.quiet,
                        fastaSourceURL: genomeFileInfo.url,
                        downloadedFastaURL: fastaGzPath,
                        gffSourceURL: gffSourceURL,
                        downloadedGFFURL: gffPath,
                        finalFastaURL: finalFastaPath,
                        finalGFFURL: finalGffPath,
                        runClock: runClock
                    )
                )
            } catch {
                cleanupGenomeFetchDirectOutputs(copiedOutputURLs)
                throw error
            }

            if !globalOptions.quiet {
                print("")
                print(formatter.success("Files saved:"))
                print("  FASTA: \(outputURL.appendingPathComponent("\(bundleName).fna.gz").path)")
                if gffPath != nil {
                    print("  GFF3: \(outputURL.appendingPathComponent("\(bundleName).gff.gz").path)")
                }
            }

            if globalOptions.outputFormat == .json {
                let result = GenomeDownloadResult(
                    accession: assemblyAccession,
                    organism: organism,
                    fastaPath: outputURL.appendingPathComponent("\(bundleName).fna.gz").path,
                    gffPath: finalGffPath?.path,
                    bundlePath: nil
                )
                let handler = JSONOutputHandler()
                handler.writeData(result, label: nil)
            }
            return
        }

        // Step 3: Create the .lungfishref bundle with proper indices
        if !globalOptions.quiet {
            print("")
            print(formatter.header("Creating Indexed Bundle"))
        }

        // Use NativeBundleBuilder to create the bundle
        let builder = await NativeBundleBuilder()

        // Check for required tools
        if let missingInfo = await builder.checkRequiredTools() {
            if !globalOptions.quiet {
                print(formatter.warning("Native bioinformatics tools not available."))
                print(formatter.warning("Missing: \(missingInfo.missingTools.map { $0.rawValue }.joined(separator: ", "))"))
                print(formatter.info("Creating basic bundle without optimized indices..."))
            }
        }

        // Decompress FASTA for bundle builder (it will re-compress with bgzip)
        let uncompressedFastaPath = tempDir.appendingPathComponent("sequence.fna")
        let decompressProcess = Process()
        decompressProcess.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        decompressProcess.arguments = ["-c", fastaGzPath.path]
        let outputPipe = Pipe()
        decompressProcess.standardOutput = outputPipe
        try decompressProcess.run()

        let fastaData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        decompressProcess.waitUntilExit()
        try fastaData.write(to: uncompressedFastaPath)

        // Prepare annotation inputs
        var annotationInputs: [AnnotationInput] = []
        if let gff = gffPath {
            // Pass GFF3 directly; NativeBundleBuilder handles .gff/.gff3 and .gz variants.
            annotationInputs.append(AnnotationInput(url: gff, name: "genes"))
        }

        let bundleStagingOutputURL = tempDir.appendingPathComponent("bundle-staging", isDirectory: true)
        try fileManager.createDirectory(at: bundleStagingOutputURL, withIntermediateDirectories: true)

        // Create build configuration
        let config = BuildConfiguration(
            name: name ?? organism,
            identifier: "com.ncbi.\(assemblyAccession.lowercased().replacingOccurrences(of: ".", with: "-"))",
            fastaURL: uncompressedFastaPath,
            annotationFiles: annotationInputs,
            variantFiles: [],
            signalFiles: [],
            outputDirectory: bundleStagingOutputURL,
            source: SourceInfo(
                organism: organism,
                commonName: nil,
                taxonomyId: summary.taxid,
                assembly: assemblyAccession,
                assemblyAccession: assemblyAccession,
                database: "NCBI",
                sourceURL: URL(string: "https://www.ncbi.nlm.nih.gov/datasets/genome/\(assemblyAccession)/"),
                downloadDate: Date(),
                notes: nil
            ),
            compressFASTA: true
        )
        let finalBundleURL = outputURL.appendingPathComponent(
            "\(Self.bundleDirectoryName(for: config.name)).lungfishref",
            isDirectory: true
        )
        if fileManager.fileExists(atPath: finalBundleURL.path) {
            throw CLIError.outputWriteFailed(path: finalBundleURL.path, reason: "Path already exists")
        }

        // Build the bundle
        let stagedBundleURL = try await builder.build(configuration: config) { step, progress, message in
            if !globalOptions.quiet && globalOptions.outputFormat == .text {
                let progressPercent = Int(progress * 100)
                print("\r  [\(progressPercent)%] \(message)", terminator: "")
                fflush(stdout)
            }
        }

        try fileManager.moveItem(at: stagedBundleURL, to: finalBundleURL)
        do {
            try await GenomeFetchProvenanceWriter().writeBundle(
                .init(
                    bundleURL: finalBundleURL,
                    accession: accession,
                    assemblyAccession: assemblyAccession,
                    organism: organism,
                    outputDirectory: outputURL,
                    bundleName: name,
                    fastaOnly: fastaOnly,
                    noBundle: noBundle,
                    apiKeySource: apiKeySource,
                    outputFormat: globalOptions.outputFormat,
                    quiet: globalOptions.quiet,
                    fastaSourceURL: genomeFileInfo.url,
                    downloadedFastaURL: fastaGzPath,
                    gffSourceURL: gffSourceURL,
                    downloadedGFFURL: gffPath,
                    runClock: runClock
                )
            )
        } catch {
            try removeGenomeFetchBundleAfterProvenanceFailure(finalBundleURL, provenanceError: error)
        }
        let bundleURL = finalBundleURL

        if !globalOptions.quiet {
            print("") // newline after progress
            print("")
            print(formatter.success("Bundle created successfully!"))
            print("")
            print("Bundle location: \(bundleURL.path)")
            print("")
            print("Contents:")
            print("  - Indexed FASTA sequence (bgzip + faidx)")
            if !annotationInputs.isEmpty {
                print("  - SQLite annotation database")
            }
            print("  - Manifest with metadata")
        }

        if globalOptions.outputFormat == .json {
            let result = GenomeDownloadResult(
                accession: assemblyAccession,
                organism: organism,
                fastaPath: nil,
                gffPath: nil,
                bundlePath: bundleURL.path
            )
            let handler = JSONOutputHandler()
            handler.writeData(result, label: nil)
        }
    }

    /// Builds a bundle from a nucleotide accession via nuccore efetch.
    ///
    /// The assembly path cannot serve these: NCBI's assembly database has no
    /// record for a GenBank nucleotide accession, so searching it returns the
    /// linked RefSeq assembly under the requested name. Callers that match on
    /// sequence name (primer BEDs, for one) then fail against a bundle that
    /// looks correct. Fetching from nuccore returns the requested record.
    private func runNucleotideFetch(
        outputURL: URL,
        formatter: TerminalFormatter,
        fileManager: FileManager,
        runClock: ProvenanceRunClock
    ) async throws {
        if !globalOptions.quiet {
            print(formatter.info("Fetching nucleotide record \(accession)..."))
        }

        let ncbiService = NCBIService(apiKey: apiKey)
        let fastaData = try await ncbiService.efetch(
            database: .nucleotide, ids: [accession], format: .fasta)

        guard let fasta = String(data: fastaData, encoding: .utf8),
              fasta.hasPrefix(">") else {
            throw CLIError.networkError(reason: "Nucleotide record not found: \(accession)")
        }

        // The header names the sequence every downstream consumer matches on,
        // so it is read from the record rather than assumed to be the query.
        let header = fasta.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let sequenceName = header.dropFirst().split(separator: " ").first.map(String.init) ?? accession
        let organism = header
            .drop(while: { $0 != " " })
            .trimmingCharacters(in: .whitespaces)
        let bundleName = name ?? sequenceName

        let tempDir = try ProjectTempDirectory.createFromContext(
            prefix: ".lungfish-temp-", contextURL: outputURL)
        defer { try? fileManager.removeItem(at: tempDir) }

        let fastaURL = tempDir.appendingPathComponent("sequence.fna")
        try fastaData.write(to: fastaURL)

        // Annotations are best-effort: not every nucleotide record carries a
        // GFF3, and a bundle without one is still usable.
        var gffURL: URL?
        if !fastaOnly {
            if !globalOptions.quiet {
                print(formatter.info("Downloading annotations (GFF3)..."))
            }
            if let gffData = try? await ncbiService.efetch(
                database: .nucleotide, ids: [accession], format: .gff3),
               let gffText = String(data: gffData, encoding: .utf8),
               gffText.contains("##gff-version") {
                let url = tempDir.appendingPathComponent("annotations.gff3")
                try gffData.write(to: url)
                gffURL = url
                if !globalOptions.quiet { print(formatter.success("Annotations downloaded")) }
            } else if !globalOptions.quiet {
                print(formatter.warning("Annotations not available for this record"))
            }
        }

        if fastaOnly || noBundle {
            let finalFastaPath = outputURL.appendingPathComponent("\(bundleName).fna")
            try fileManager.copyItem(at: fastaURL, to: finalFastaPath)
            if !globalOptions.quiet {
                print("")
                print(formatter.success("Files saved:"))
                print("  FASTA: \(finalFastaPath.path)")
            }
            return
        }

        if !globalOptions.quiet {
            print("")
            print(formatter.header("Creating Indexed Bundle"))
        }

        let builder = await NativeBundleBuilder()
        let stagingURL = tempDir.appendingPathComponent("bundle-staging", isDirectory: true)
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)

        let config = BuildConfiguration(
            name: bundleName,
            identifier: "com.ncbi.\(sequenceName.lowercased().replacingOccurrences(of: ".", with: "-"))",
            fastaURL: fastaURL,
            annotationFiles: gffURL.map { [AnnotationInput(url: $0, name: "genes")] } ?? [],
            variantFiles: [],
            signalFiles: [],
            outputDirectory: stagingURL,
            source: SourceInfo(
                organism: organism.isEmpty ? sequenceName : organism,
                commonName: nil,
                taxonomyId: nil,
                // A nucleotide record has no assembly; the sequence name is the
                // identifier that matters to consumers of this bundle.
                assembly: sequenceName,
                assemblyAccession: nil,
                database: "NCBI",
                sourceURL: URL(string: "https://www.ncbi.nlm.nih.gov/nuccore/\(sequenceName)"),
                downloadDate: Date(),
                notes: nil
            ),
            compressFASTA: true
        )

        let finalBundleURL = outputURL.appendingPathComponent(
            "\(Self.bundleDirectoryName(for: bundleName)).lungfishref", isDirectory: true)
        if fileManager.fileExists(atPath: finalBundleURL.path) {
            throw CLIError.outputWriteFailed(
                path: finalBundleURL.path, reason: "Path already exists")
        }

        let stagedBundleURL = try await builder.build(configuration: config) { _, progress, message in
            if !globalOptions.quiet && globalOptions.outputFormat == .text {
                print("\r  [\(Int(progress * 100))%] \(message)", terminator: "")
                fflush(stdout)
            }
        }
        try fileManager.moveItem(at: stagedBundleURL, to: finalBundleURL)

        if !globalOptions.quiet {
            print("")
            print(formatter.success("Bundle created: \(finalBundleURL.path)"))
        }

        if globalOptions.outputFormat == .json {
            let result = GenomeDownloadResult(
                accession: sequenceName,
                organism: organism.isEmpty ? sequenceName : organism,
                fastaPath: nil,
                gffPath: nil,
                bundlePath: finalBundleURL.path
            )
            JSONOutputHandler().writeData(result, label: nil)
        }
    }

    private static func bundleDirectoryName(for name: String) -> String {
        name
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
    }

    private func cleanupGenomeFetchDirectOutputs(_ outputURLs: [URL]) {
        let fileManager = FileManager.default
        for outputURL in outputURLs {
            try? fileManager.removeItem(at: outputURL)
            try? fileManager.removeItem(at: ProvenanceRecorder.fileSidecarURL(for: outputURL))
        }
    }

    private func removeGenomeFetchBundleAfterProvenanceFailure(
        _ bundleURL: URL,
        provenanceError: Error
    ) throws {
        do {
            try FileManager.default.removeItem(at: bundleURL)
        } catch {
            throw CLIError.outputWriteFailed(
                path: bundleURL.path,
                reason: "Provenance write failed (\(provenanceError.localizedDescription)); cleanup failed (\(error.localizedDescription))"
            )
        }
        throw provenanceError
    }
}

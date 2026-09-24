// GenBankBundleDownloadViewModel.swift - NCBI GenBank download and bundle building
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import os.log

private let genBankDownloadLogger = Logger(subsystem: LogSubsystem.app, category: "GenBankBundleDownload")

/// Builds NCBI GenBank nucleotide downloads into `.lungfishref` bundles.
///
/// This implementation avoids MainActor-only bundle builders so it can run safely
/// while the NCBI browser sheet is open.
public final class GenBankBundleDownloadViewModel: @unchecked Sendable {

    private let ncbiService: NCBIService
    private let toolRunner: NativeToolRunner

    public init(
        ncbiService: NCBIService = NCBIService(),
        toolRunner: NativeToolRunner = .shared
    ) {
        self.ncbiService = ncbiService
        self.toolRunner = toolRunner
    }

    /// Validates that required tools are available before attempting a download.
    ///
    /// - Throws: `BundleBuildError.missingTools` if essential tools are missing.
    public func validateTools() async throws {
        try await BundleBuildHelpers.validateTools(using: toolRunner)
    }

    public func downloadAndBuild(
        accession: String,
        outputDirectory: URL,
        includeGFF3Annotations: Bool = true,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let fileManager = FileManager.default
        let startedAt = Date()
        var provenanceSteps: [ProvenanceStep] = []
        var warnings: [String] = []

        // Pre-flight: verify tools are available
        progressHandler?(0.01, "Checking tools...")
        try await validateTools()

        let tempDir = try ProjectTempDirectory.createFromContext(
            prefix: "genbank-", contextURL: outputDirectory)
        defer { try? fileManager.removeItem(at: tempDir) }

        progressHandler?(0.02, "Resolving accession \(accession)...")
        genBankDownloadLogger.info("downloadAndBuild: Fetching raw GenBank for \(accession, privacy: .public)")

        let fetchStartedAt = Date()
        let (genBankContent, resolvedAccession) = try await ncbiService.fetchRawGenBank(accession: accession)
        let fetchCompletedAt = Date()
        let genBankURL = tempDir.appendingPathComponent("\(resolvedAccession).gb")
        try genBankContent.write(to: genBankURL, atomically: true, encoding: .utf8)

        progressHandler?(0.12, "Parsing GenBank record \(resolvedAccession)...")

        let reader = try GenBankReader(url: genBankURL)
        let records = try await reader.readAll()
        guard records.count == 1, let record = records.first else {
            throw DatabaseServiceError.parseError(message: "Expected one sequence record for \(accession); NCBI returned \(records.count).")
        }

        let bundleURL = BundleBuildHelpers.makeUniqueBundleURL(
            baseName: BundleBuildHelpers.sanitizedFilename(resolvedAccession),
            in: outputDirectory
        )
        var completed = false
        defer { if !completed { try? fileManager.removeItem(at: bundleURL) } }
        let sourcesDir = bundleURL.appendingPathComponent("sources", isDirectory: true)
        try fileManager.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        let durableGenBankURL = sourcesDir.appendingPathComponent("record.gb")
        try fileManager.copyItem(at: genBankURL, to: durableGenBankURL)
        provenanceSteps.append(try Self.fetchProvenanceStep(
            accession: resolvedAccession, format: "gb", output: durableGenBankURL,
            startedAt: fetchStartedAt, completedAt: fetchCompletedAt))
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        let annotationsDir = bundleURL.appendingPathComponent("annotations", isDirectory: true)
        try fileManager.createDirectory(at: genomeDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: annotationsDir, withIntermediateDirectories: true)

        progressHandler?(0.25, "Writing FASTA...")

        let plainFASTA = genomeDir.appendingPathComponent("sequence.fa")
        let fastaStartedAt = Date()
        try FASTAWriter(url: plainFASTA).write([record.sequence])
        provenanceSteps.append(try Self.conversionProvenanceStep(
            entryPoint: "GenBankReader.readAll (first record) + FASTAWriter.write",
            inputs: [durableGenBankURL], outputs: [plainFASTA],
            options: ["sequenceName": .string(record.sequence.name)], startedAt: fastaStartedAt))

        progressHandler?(0.35, "Compressing FASTA (bgzip)...")

        let fastaInput = try ProvenanceFileDescriptor.file(url: plainFASTA, format: .fasta, role: .input)
        let bgzipVersion = await toolRunner.getToolVersion(.bgzip) ?? "unknown"
        let bgzipStartedAt = Date()
        let bgzipResult = try await toolRunner.bgzipCompress(inputPath: plainFASTA, keepOriginal: true)
        guard bgzipResult.isSuccess else {
            throw BundleBuildError.compressionFailed(bgzipResult.combinedOutput)
        }

        let compressedFASTA = genomeDir.appendingPathComponent("sequence.fa.gz")

        provenanceSteps.append(try Self.nativeProvenanceStep(
            tool: .bgzip, version: bgzipVersion, result: bgzipResult,
            inputs: [fastaInput], outputs: [compressedFASTA], startedAt: bgzipStartedAt))
        progressHandler?(0.45, "Indexing FASTA (samtools faidx)...")

        let samtoolsVersion = await toolRunner.getToolVersion(.samtools) ?? "unknown"
        let faidxStartedAt = Date()
        let faiResult = try await toolRunner.indexFASTA(fastaPath: compressedFASTA)
        guard faiResult.isSuccess else {
            throw BundleBuildError.indexingFailed(faiResult.combinedOutput)
        }

        let faiURL = compressedFASTA.appendingPathExtension("fai")
        let gziURL = compressedFASTA.appendingPathExtension("gzi")

        provenanceSteps.append(try Self.nativeProvenanceStep(
            tool: .samtools, version: samtoolsVersion, result: faiResult,
            inputs: [try .file(url: compressedFASTA, format: .fasta, role: .input)],
            outputs: [faiURL, gziURL].filter { fileManager.fileExists(atPath: $0.path) },
            startedAt: faidxStartedAt))
        try Task.checkCancellation()
        let chromosomes = BundleBuildHelpers.addSingleSequenceAccessionAliases(
            to: try BundleBuildHelpers.parseFai(at: faiURL),
            accessions: [
                accession,
                resolvedAccession,
                record.accession,
                record.version,
                record.locus.name,
                record.sequence.name,
            ].compactMap { $0 }
        )
        let totalLength = chromosomes.reduce(Int64(0)) { $0 + $1.length }

        // Build chromosome sizes for annotation coordinate clipping
        let chromosomeSizes = chromosomes.map { ($0.name, $0.length) }

        var annotationTracks: [AnnotationTrackInfo] = []
        if includeGFF3Annotations {
            progressHandler?(0.52, "Fetching GFF3 annotations...")
            let gffURL = sourcesDir.appendingPathComponent("record.gff3")
            let gffStartedAt = Date()
            var gffFetchCompleted = false
            do {
                let data = try await ncbiService.efetch(database: .nucleotide, ids: [resolvedAccession], format: .gff3)
                try data.write(to: gffURL, options: .atomic)
                gffFetchCompleted = true
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                warnings.append("GFF3 fetch fallback: \(error.localizedDescription)")
            }
            if gffFetchCompleted {
                // Provenance errors must abort publication, not trigger annotation fallback.
                provenanceSteps.append(try Self.fetchProvenanceStep(
                    accession: resolvedAccession, format: "gff3", output: gffURL, startedAt: gffStartedAt))
                let conversionStartedAt = Date()
                var conversionError: String?
                do {
                    if let track = try await buildGFF3AnnotationTrack(
                        gff3URL: gffURL, annotationsDir: annotationsDir, chromosomeSizes: chromosomeSizes
                    ) {
                        annotationTracks.append(track)
                    } else {
                        warnings.append("GFF3 fallback: no usable annotation records; using GenBank FEATURES.")
                    }
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
                    conversionError = error.localizedDescription
                    warnings.append("GFF3 conversion fallback: \(error.localizedDescription)")
                }
                let database = annotationsDir.appendingPathComponent("ncbi_gff3_annotations.db")
                provenanceSteps.append(try Self.conversionProvenanceStep(
                    entryPoint: "AnnotationDatabase.createFromGFF3", inputs: [gffURL],
                    outputs: fileManager.fileExists(atPath: database.path) ? [database] : [],
                    options: ["clipToChromosomeBounds": .boolean(true)],
                    startedAt: conversionStartedAt, error: conversionError))
            }
        }

        // If GFF3 is unavailable or empty, fallback to GenBank FEATURES.
        if annotationTracks.isEmpty && !record.annotations.isEmpty {
            progressHandler?(0.55, "Converting annotations...")
            let annotationStartedAt = Date()

            do {
                // Write BED12+ directly from parsed GenBank annotations,
                // preserving ALL qualifiers (db_xref, product, protein_id, etc.)
                // and multi-interval (join) features as proper BED12 blocks.
                let bedURL = tempDir.appendingPathComponent("annotations.bed")
                writeGenBankAnnotationsToBED(
                    annotations: record.annotations,
                    chromName: record.locus.name,
                    to: bedURL
                )

                // Clip BED coordinates to chromosome boundaries.
                BundleBuildHelpers.clipBEDCoordinates(bedURL: bedURL, chromosomeSizes: chromosomeSizes)

                progressHandler?(0.65, "Creating annotation database...")

                // Create SQLite annotation database directly from BED12+.
                let dbURL = annotationsDir.appendingPathComponent("ncbi_genbank_annotations.db")
                let dbRecordCount = try AnnotationDatabase.createFromBED(bedURL: bedURL, outputURL: dbURL)
                genBankDownloadLogger.info("downloadAndBuild: Created annotation database with \(dbRecordCount) records")
                try? fileManager.removeItem(at: bedURL)
                provenanceSteps.append(try Self.conversionProvenanceStep(
                    entryPoint: "writeGenBankAnnotationsToBED + clipBEDCoordinates + AnnotationDatabase.createFromBED",
                    inputs: [durableGenBankURL], outputs: [dbURL],
                    options: ["chromosome": .string(record.locus.name), "clipToChromosomeBounds": .boolean(true),
                              "preserveQualifiers": .boolean(true), "bedFormat": .string("BED12+")],
                    startedAt: annotationStartedAt))

                annotationTracks.append(
                    AnnotationTrackInfo(
                        id: "ncbi_genbank_annotations",
                        name: "NCBI GenBank Annotations",
                        description: "Converted from GenBank FEATURES",
                        path: "annotations/ncbi_genbank_annotations.db",
                        databasePath: dbRecordCount > 0 ? "annotations/ncbi_genbank_annotations.db" : nil,
                        annotationType: .gene,
                        featureCount: dbRecordCount,
                        source: "NCBI",
                        version: nil
                    )
                )
            } catch {
                genBankDownloadLogger.error("downloadAndBuild: Annotation conversion failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        progressHandler?(0.85, "Writing bundle manifest...")

        let genomeInfo = GenomeInfo(
            path: "genome/sequence.fa.gz",
            indexPath: "genome/sequence.fa.gz.fai",
            gzipIndexPath: fileManager.fileExists(atPath: gziURL.path) ? "genome/sequence.fa.gz.gzi" : nil,
            totalLength: totalLength,
            chromosomes: chromosomes,
            md5Checksum: nil
        )

        let sourceInfo = SourceInfo(
            organism: record.sequence.description ?? record.definition ?? "Unknown",
            commonName: nil,
            taxonomyId: nil,
            assembly: record.sequence.name,
            assemblyAccession: resolvedAccession,
            database: "NCBI",
            sourceURL: URL(string: "https://www.ncbi.nlm.nih.gov/nuccore/\(resolvedAccession)"),
            downloadDate: Date(),
            notes: "Downloaded from NCBI GenBank and converted to Lungfish reference bundle"
        )

        let bundleIdentifier = "org.ncbi.genbank.\(resolvedAccession.lowercased().replacingOccurrences(of: ".", with: "-"))"

        // Build metadata groups from GenBank record fields
        let metadataGroups = genBankRecordMetadataGroups(record: record, resolvedAccession: resolvedAccession)

        let manifest = BundleManifest(
            name: resolvedAccession,
            identifier: bundleIdentifier,
            description: record.definition,
            source: sourceInfo,
            genome: genomeInfo,
            annotations: annotationTracks,
            variants: [],
            tracks: [],
            metadata: metadataGroups.isEmpty ? nil : metadataGroups
        )

        let validationErrors = manifest.validate()
        if !validationErrors.isEmpty {
            throw BundleBuildError.validationFailed(validationErrors.map { $0.localizedDescription })
        }

        try manifest.save(to: bundleURL)

        try Task.checkCancellation()
        try Self.writeDownloadProvenance(
            bundleURL: bundleURL, requestedAccession: accession, resolvedAccession: resolvedAccession,
            includeGFF3Annotations: includeGFF3Annotations, steps: provenanceSteps,
            startedAt: startedAt, stderr: warnings.joined(separator: "\n"))
        completed = true
        progressHandler?(1.0, "Bundle ready: \(bundleURL.lastPathComponent)")
        genBankDownloadLogger.info("downloadAndBuild: Bundle complete at \(bundleURL.path, privacy: .public)")
        return bundleURL
    }

    static func fetchProvenanceStep(
        accession: String, format: String, output: URL, startedAt: Date, completedAt: Date = Date()
    ) throws -> ProvenanceStep {
        var components = URLComponents(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi")!
        components.queryItems = [
            URLQueryItem(name: "db", value: "nuccore"),
            URLQueryItem(name: "id", value: accession),
            URLQueryItem(name: "rettype", value: format),
            URLQueryItem(name: "retmode", value: "text")
        ]
        let remoteURL = components.url!.absoluteString
        let payload = try ProvenanceFileDescriptor.file(url: output, role: .output)
        return ProvenanceStep(
            toolName: "NCBI EFetch (URLSession)", toolVersion: WorkflowRun.currentAppVersion,
            argv: [],
            reproducibleCommand: "curl --fail --location " + shellEscape(remoteURL)
                + " --output " + shellEscape(output.path),
            resolvedOptions: ["database": .string("nuccore"), "accession": .string(accession),
                              "rettype": .string(format), "retmode": .string("text"),
                              "commandPurpose": .string("Pinned replay URL; transport may resolve an accession through ESearch")],
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: [ProvenanceFileDescriptor(path: remoteURL,
                checksumSHA256: payload.checksumSHA256, fileSize: payload.fileSize, role: .input)],
            outputs: [payload], exitStatus: 0, wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            startedAt: startedAt, completedAt: completedAt)
    }

    static func conversionProvenanceStep(
        entryPoint: String, inputs: [URL], outputs: [URL],
        options: [String: ParameterValue], startedAt: Date, error: String? = nil
    ) throws -> ProvenanceStep {
        // These are in-process GUI transformations, so record the actual host argv
        // together with the versioned entry point and all resolved parameters.
        ProvenanceStep(toolName: entryPoint, toolVersion: WorkflowRun.currentAppVersion,
            argv: ProcessInfo.processInfo.arguments, resolvedOptions: options,
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: try inputs.map { try .file(url: $0, role: .input) },
            outputs: try outputs.map { try .file(url: $0, role: .output) },
            exitStatus: error == nil ? 0 : 1, wallTimeSeconds: Date().timeIntervalSince(startedAt),
            stderr: error, startedAt: startedAt, completedAt: Date())
    }

    private static func nativeProvenanceStep(
        tool: NativeTool, version: String, result: NativeToolResult,
        inputs: [ProvenanceFileDescriptor], outputs: [URL], startedAt: Date
    ) throws -> ProvenanceStep {
        let executable = result.arguments.first ?? tool.rawValue
        let environment: String?
        let prefix: String?
        switch tool.location {
        case .managed(let name, _):
            environment = name
            prefix = URL(fileURLWithPath: executable).deletingLastPathComponent().deletingLastPathComponent().path
        case .bundled:
            environment = nil
            prefix = nil
        }
        return ProvenanceStep(toolName: tool.rawValue, toolVersion: version, argv: result.arguments,
            runtimeIdentity: ProvenanceRuntimeIdentity(executablePath: executable,
                condaEnvironment: environment, condaPrefix: prefix), inputs: inputs,
            outputs: try outputs.map { try .file(url: $0, role: .output) },
            exitStatus: Int(result.exitCode), wallTimeSeconds: Date().timeIntervalSince(startedAt),
            stderr: ProvenanceStderr.normalized(result.stderr), startedAt: startedAt, completedAt: Date())
    }

    /// Called only after all payloads and the manifest are finalized. The normal
    /// project-copy importer rehydrates these paths when it relocates the bundle.
    static func writeDownloadProvenance(
        bundleURL: URL, requestedAccession: String, resolvedAccession: String,
        includeGFF3Annotations: Bool, steps: [ProvenanceStep], startedAt: Date, stderr: String
    ) throws {
        let options: [String: ParameterValue] = [
            "requestedAccession": .string(requestedAccession),
            "resolvedAccession": .string(resolvedAccession),
            "includeGFF3Annotations": .boolean(includeGFF3Annotations),
            "keepUncompressedFASTA": .boolean(true),
            "annotationFallback": .string("GenBank FEATURES when GFF3 is unavailable"),
            "outputBundle": .file(bundleURL),
            "containerRuntime": .string("none"),
            "condaEnvironments": .string("htslib, samtools (see per-step runtime identities)")
        ]
        var builder = ProvenanceRunBuilder(
            workflowName: "gui-genbank-download", workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish", toolVersion: WorkflowRun.currentAppVersion)
            .argv(ProcessInfo.processInfo.arguments)
            .options(explicit: options, defaults: ["includeGFF3Annotations": .boolean(true)], resolved: options)
            .runtime(ProvenanceRuntimeIdentity())
        for step in steps { builder = builder.step(step) }
        // Preserve the bundle root's path spelling. URL enumeration canonicalizes
        // /var to /private/var, which would prevent the copy importer rebinding it.
        guard let files = FileManager.default.enumerator(atPath: bundleURL.path) else {
            throw CocoaError(.fileReadUnknown)
        }
        while let relativePath = files.nextObject() as? String {
            let url = bundleURL.appendingPathComponent(relativePath)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            builder = try builder.output(url)
        }
        let envelope = try builder.complete(exitStatus: 0, stderr: stderr,
            startedAt: startedAt, endedAt: Date())
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func buildGFF3AnnotationTrack(
        gff3URL: URL,
        annotationsDir: URL,
        chromosomeSizes: [(String, Int64)]
    ) async throws -> AnnotationTrackInfo? {
        let gff3Content = try String(contentsOf: gff3URL, encoding: .utf8)
        guard gff3FeatureRowCount(in: gff3Content) > 0 else { return nil }

        let dbURL = annotationsDir.appendingPathComponent("ncbi_gff3_annotations.db")
        let dbRecordCount = try await AnnotationDatabase.createFromGFF3(
            gffURL: gff3URL,
            outputURL: dbURL,
            chromosomeSizes: chromosomeSizes
        )
        guard dbRecordCount > 0 else {
            genBankDownloadLogger.warning("downloadAndBuild: GFF3 conversion produced no annotation records")
            return nil
        }

        genBankDownloadLogger.info("downloadAndBuild: Created GFF3 annotation database with \(dbRecordCount) records")
        return AnnotationTrackInfo(
            id: "ncbi_gff3_annotations",
            name: "NCBI GFF3 Annotations",
            description: "GFF3 annotations from NCBI EFetch",
            path: "annotations/ncbi_gff3_annotations.db",
            databasePath: "annotations/ncbi_gff3_annotations.db",
            annotationType: .gene,
            featureCount: dbRecordCount,
            source: "NCBI",
            version: nil
        )
    }

    private func gff3FeatureRowCount(in content: String) -> Int {
        content.split(whereSeparator: \.isNewline).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#") && trimmed.split(separator: "\t", omittingEmptySubsequences: false).count >= 9
        }.count
    }

    /// Builds a `.lungfishref` bundle directly from a provided nucleotide sequence.
    ///
    /// Useful for sources (e.g. Pathoplexus-only records) that cannot be resolved
    /// via GenBank accession lookup but still provide sequence content.
    public func buildBundleFromSequence(
        accession: String,
        title: String?,
        sequence: String,
        outputDirectory: URL,
        sourceDatabase: String = "Pathoplexus",
        sourceURL: URL? = nil,
        notes: String? = nil,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let fileManager = FileManager.default

        progressHandler?(0.01, "Checking tools...")
        try await validateTools()

        let cleanedSequence = sequence
            .uppercased()
            .filter { "ACGTNURYKMSWBDHV.-".contains($0) }
        guard !cleanedSequence.isEmpty else {
            throw DatabaseServiceError.parseError(message: "No nucleotide sequence available for \(accession)")
        }

        let tempDir = try ProjectTempDirectory.createFromContext(
            prefix: "sequence-", contextURL: outputDirectory)
        defer { try? fileManager.removeItem(at: tempDir) }

        progressHandler?(0.12, "Writing FASTA...")
        let plainFASTA = tempDir.appendingPathComponent("sequence.fa")
        var fastaContent = ">\(accession)"
        if let title, !title.isEmpty { fastaContent += " \(title)" }
        fastaContent += "\n"
        var idx = cleanedSequence.startIndex
        while idx < cleanedSequence.endIndex {
            let endIdx = cleanedSequence.index(idx, offsetBy: 80, limitedBy: cleanedSequence.endIndex) ?? cleanedSequence.endIndex
            fastaContent += String(cleanedSequence[idx..<endIdx]) + "\n"
            idx = endIdx
        }
        try fastaContent.write(to: plainFASTA, atomically: true, encoding: .utf8)

        progressHandler?(0.30, "Compressing FASTA (bgzip)...")
        let bgzipResult = try await toolRunner.bgzipCompress(inputPath: plainFASTA, keepOriginal: false)
        guard bgzipResult.isSuccess else {
            throw BundleBuildError.compressionFailed(bgzipResult.combinedOutput)
        }

        let compressedFASTA = tempDir.appendingPathComponent("sequence.fa.gz")

        progressHandler?(0.45, "Indexing FASTA (samtools faidx)...")
        let faiResult = try await toolRunner.indexFASTA(fastaPath: compressedFASTA)
        guard faiResult.isSuccess else {
            throw BundleBuildError.indexingFailed(faiResult.combinedOutput)
        }

        let faiURL = compressedFASTA.appendingPathExtension("fai")
        let gziURL = compressedFASTA.appendingPathExtension("gzi")
        let chromosomes = try BundleBuildHelpers.parseFai(at: faiURL)
        let totalLength = chromosomes.reduce(Int64(0)) { $0 + $1.length }

        let bundleBaseName = BundleBuildHelpers.sanitizedFilename(accession)
        let bundleURL = BundleBuildHelpers.makeUniqueBundleURL(
            baseName: bundleBaseName.isEmpty ? "pathoplexus_sequence" : bundleBaseName,
            in: outputDirectory
        )
        let genomeDir = bundleURL.appendingPathComponent("genome", isDirectory: true)
        try fileManager.createDirectory(at: genomeDir, withIntermediateDirectories: true)

        try fileManager.moveItem(at: compressedFASTA, to: genomeDir.appendingPathComponent("sequence.fa.gz"))
        try fileManager.moveItem(at: faiURL, to: genomeDir.appendingPathComponent("sequence.fa.gz.fai"))
        let hasGzi = fileManager.fileExists(atPath: gziURL.path)
        if hasGzi {
            try fileManager.moveItem(at: gziURL, to: genomeDir.appendingPathComponent("sequence.fa.gz.gzi"))
        }

        progressHandler?(0.78, "Writing bundle manifest...")
        let genomeInfo = GenomeInfo(
            path: "genome/sequence.fa.gz",
            indexPath: "genome/sequence.fa.gz.fai",
            gzipIndexPath: hasGzi ? "genome/sequence.fa.gz.gzi" : nil,
            totalLength: totalLength,
            chromosomes: chromosomes,
            md5Checksum: nil
        )

        let sourceInfo = SourceInfo(
            organism: title ?? accession,
            commonName: nil,
            taxonomyId: nil,
            assembly: accession,
            assemblyAccession: accession,
            database: sourceDatabase,
            sourceURL: sourceURL,
            downloadDate: Date(),
            notes: notes ?? "Sequence downloaded from \(sourceDatabase) and converted to Lungfish reference bundle"
        )

        let manifest = BundleManifest(
            name: accession,
            identifier: "org.\(sourceDatabase.lowercased().replacingOccurrences(of: " ", with: "-")).\(accession.lowercased().replacingOccurrences(of: ".", with: "-"))",
            description: title,
            source: sourceInfo,
            genome: genomeInfo,
            annotations: [],
            variants: []
        )
        try manifest.save(to: bundleURL)

        progressHandler?(1.0, "Bundle ready: \(bundleURL.lastPathComponent)")
        return bundleURL
    }
}

// MARK: - GenBank Metadata Helpers

/// Builds metadata groups from a GenBank record for storage in the bundle manifest.
///
/// Creates two groups:
/// - **Record**: accession, version, definition, molecule type, topology, division, date
/// - **Sequence**: length, name, description
private func genBankRecordMetadataGroups(
    record: GenBankRecord,
    resolvedAccession: String
) -> [MetadataGroup] {
    var groups: [MetadataGroup] = []

    // Record group
    var recordItems: [MetadataItem] = []

    if let accession = record.accession {
        recordItems.append(MetadataItem(label: "Accession", value: accession))
    }
    if let version = record.version {
        recordItems.append(MetadataItem(label: "Version", value: version))
    }
    if let definition = record.definition {
        recordItems.append(MetadataItem(label: "Definition", value: definition))
    }
    recordItems.append(MetadataItem(label: "Molecule Type", value: record.locus.moleculeType.rawValue))
    recordItems.append(MetadataItem(label: "Topology", value: record.locus.topology.rawValue))
    if let division = record.locus.division {
        recordItems.append(MetadataItem(label: "Division", value: division))
    }
    if let date = record.locus.date {
        recordItems.append(MetadataItem(label: "Date", value: date))
    }

    if !recordItems.isEmpty {
        groups.append(MetadataGroup(name: "Record", items: recordItems))
    }

    // Sequence group
    var sequenceItems: [MetadataItem] = []

    sequenceItems.append(MetadataItem(label: "Length", value: formatGenBankBp(record.locus.length)))
    sequenceItems.append(MetadataItem(label: "Name", value: record.sequence.name))
    if let desc = record.sequence.description {
        sequenceItems.append(MetadataItem(label: "Description", value: desc))
    }

    if !sequenceItems.isEmpty {
        groups.append(MetadataGroup(name: "Sequence", items: sequenceItems))
    }

    return groups
}

/// Formats a base-pair count with appropriate units (bp, Kb, Mb, Gb).
private func formatGenBankBp(_ value: Int) -> String {
    if value >= 1_000_000_000 {
        return String(format: "%.1f Gb", Double(value) / 1_000_000_000)
    }
    if value >= 1_000_000 {
        return String(format: "%.1f Mb", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
        return String(format: "%.1f Kb", Double(value) / 1_000)
    }
    return "\(value) bp"
}

// MARK: - Direct GenBank → BED12+ Conversion

/// Writes GenBank annotations directly to BED12+ format, preserving ALL qualifiers.
///
/// This bypasses the lossy GFF3Writer → AnnotationConverter pipeline. Each annotation
/// is written as a single BED12 line with proper block structure for multi-interval
/// (join) features. Column 13 holds the GenBank feature type and column 14 holds
/// all qualifiers as percent-encoded `key=value;key=value` pairs.
///
/// All input features are emitted, including top-level `source` spans.
private func writeGenBankAnnotationsToBED(
    annotations: [SequenceAnnotation],
    chromName: String,
    to outputURL: URL
) {
    struct BEDEntry {
        let chromosome: String
        let start: Int
        let line: String
    }

    var entries: [BEDEntry] = []

    // Percent-encoding character set — must encode ; = \t \n % to preserve key=value;key=value format
    var allowedCharacters = CharacterSet.urlQueryAllowed
    allowedCharacters.remove(charactersIn: ";=\t\n%")

    for annotation in annotations {
        let chromosome = annotation.chromosome ?? chromName
        let intervals = annotation.intervals.sorted { $0.start < $1.start }
        guard !intervals.isEmpty else { continue }

        let name = annotation.name
        let score = 0
        let strand = annotation.strand.rawValue

        let color = annotation.type.defaultColor
        let r = Int(color.red * 255)
        let g = Int(color.green * 255)
        let b = Int(color.blue * 255)
        let itemRgb = "\(r),\(g),\(b)"

        // BED12 block structure for multi-interval (join) features.
        // Blocks must be in ascending order without overlap.
        // GenBank ribosomal frameshift joins (e.g. join(336..1637,1637..4642))
        // produce overlapping intervals — resolve by nudging the later block forward.
        var resolvedIntervals = intervals
        for i in 1..<resolvedIntervals.count {
            if resolvedIntervals[i].start < resolvedIntervals[i - 1].end {
                resolvedIntervals[i] = AnnotationInterval(
                    start: resolvedIntervals[i - 1].end,
                    end: resolvedIntervals[i].end
                )
            }
        }
        // Filter out degenerate zero-length blocks that may result from resolution
        resolvedIntervals = resolvedIntervals.filter { $0.start < $0.end }
        guard let featureStart = resolvedIntervals.first?.start,
              let featureEnd = resolvedIntervals.last?.end else {
            continue
        }
        let thickStart = featureStart
        let thickEnd = featureEnd

        let blockCount = resolvedIntervals.count
        let blockSizes = resolvedIntervals.map { "\($0.end - $0.start)" }.joined(separator: ",") + ","
        let blockStarts = resolvedIntervals.map { "\($0.start - featureStart)" }.joined(separator: ",") + ","

        // Column 13: real GenBank feature type
        let featureType = annotation.qualifiers[GenBankReader.rawFeatureTypeQualifierKey]?.firstValue
            ?? annotation.type.rawValue

        // Column 14: all qualifiers as key=value;key=value (percent-encoded)
        let qualifierPairs: [String] = annotation.qualifiers
            .filter { $0.key != GenBankReader.rawFeatureTypeQualifierKey }
            .sorted { $0.key < $1.key }
            .map { key, qualifier in
                let joinedValues = qualifier.values.joined(separator: ",")
                let encodedValues = joinedValues.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? joinedValues
                return "\(key)=\(encodedValues)"
            }
        let qualifiersString = qualifierPairs.joined(separator: ";")

        let bedLine = [
            chromosome,
            String(featureStart),
            String(featureEnd),
            name,
            String(score),
            strand,
            String(thickStart),
            String(thickEnd),
            itemRgb,
            String(blockCount),
            blockSizes,
            blockStarts,
            featureType,
            qualifiersString
        ].joined(separator: "\t")

        entries.append(BEDEntry(chromosome: chromosome, start: featureStart, line: bedLine))
    }

    // Sort by chromosome then start position
    entries.sort { a, b in
        if a.chromosome != b.chromosome {
            return a.chromosome < b.chromosome
        }
        return a.start < b.start
    }

    let bedContent = entries.map(\.line).joined(separator: "\n")
    try? bedContent.write(to: outputURL, atomically: true, encoding: .utf8)

    genBankDownloadLogger.info("writeGenBankAnnotationsToBED: \(entries.count) features written")
}

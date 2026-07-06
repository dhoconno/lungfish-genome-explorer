// AssemblyBundleBuilder.swift - Creates .lungfishref bundles from assembly output
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import CryptoKit
import os.log
import LungfishCore
import LungfishIO

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "AssemblyBundleBuilder")

// MARK: - AssemblyBundleBuilder

/// Creates a `.lungfishref` bundle from normalized assembly output.
///
/// Takes the contigs/scaffolds FASTA, compresses with bgzip, indexes with
/// samtools, copies assembly artifacts (log, graph, params), writes provenance,
/// and generates the bundle manifest.
///
/// Uses `NativeToolRunner` for bgzip and samtools (same tools used by
/// `NativeBundleBuilder` for NCBI downloads).
///
/// ## Usage
///
/// ```swift
/// let builder = AssemblyBundleBuilder()
/// let bundleURL = try await builder.build(
///     result: spadesResult,
///     config: spadesConfig,
///     provenance: provenance,
///     outputDirectory: outputDir,
///     bundleName: "MyAssembly"
/// ) { fraction, message in
///     print("\(Int(fraction * 100))%: \(message)")
/// }
/// ```
public final class AssemblyBundleBuilder: @unchecked Sendable {

    private let toolRunner = NativeToolRunner.shared

    public init() {}

    // MARK: - Build

    /// Creates a `.lungfishref` bundle from a legacy SPAdes result.
    ///
    /// - Parameters:
    ///   - result: The SPAdes assembly result
    ///   - config: The assembly configuration used
    ///   - provenance: Reproducibility metadata
    ///   - outputDirectory: Directory to create the bundle in
    ///   - bundleName: Human-readable name for the bundle
    ///   - progress: Progress callback (fraction 0-1, status message)
    /// - Returns: URL to the created `.lungfishref` bundle
    public func build(
        result: SPAdesAssemblyResult,
        config: SPAdesAssemblyConfig,
        provenance: AssemblyProvenance,
        outputDirectory: URL,
        bundleName: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> URL {
        let request = AssemblyRunRequest(
            tool: .spades,
            readType: .illuminaShortReads,
            inputURLs: config.allInputFiles,
            projectName: config.projectName,
            outputDirectory: config.outputDirectory,
            pairedEnd: !config.forwardReads.isEmpty
                && config.forwardReads.count == config.reverseReads.count
                && config.unpairedReads.isEmpty,
            threads: config.threads,
            memoryGB: config.memoryGB,
            minContigLength: config.minContigLength,
            selectedProfileID: config.mode.rawValue,
            extraArguments: config.customArgs
        )
        return try await build(
            result: AssemblyResult.fromLegacy(result),
            request: request,
            provenance: provenance,
            outputDirectory: outputDirectory,
            bundleName: bundleName,
            progress: progress
        )
    }

    /// Creates a `.lungfishref` bundle from a normalized assembly result.
    public func build(
        result: AssemblyResult,
        request: AssemblyRunRequest,
        provenance: AssemblyProvenance,
        outputDirectory: URL,
        bundleName: String,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> URL {
        let safeName = bundleName
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        let publishedBundleURL = outputDirectory.appendingPathComponent("\(safeName).lungfishref")
        let stagingBundleURL = try makeStagingBundleURL(for: publishedBundleURL)
        let stagingPreexisted = FileManager.default.fileExists(atPath: stagingBundleURL.path)
        var didPublishBundle = false

        logger.info("Creating assembly bundle at \(publishedBundleURL.path)")

        do {
            try prepareOutputDestination(for: publishedBundleURL)

            // 1. Create bundle directory structure
            progress(0.0, "Creating bundle structure...")
            try createBundleStructure(at: stagingBundleURL)

            // 2. Process contigs FASTA (bgzip + index)
            progress(0.05, "Compressing contigs with bgzip...")
            let genomeInfo = try await processContigsFASTA(
                contigsPath: result.contigsPath,
                bundleURL: stagingBundleURL,
                progress: progress
            )

            // 3. Copy assembly artifacts
            progress(0.60, "Copying assembly artifacts...")
            try copyAssemblyArtifacts(result: result, bundleURL: stagingBundleURL)

            // 4. Write provenance
            progress(0.70, "Writing provenance record...")
            let assemblyDir = stagingBundleURL.appendingPathComponent("assembly")
            try provenance.save(to: assemblyDir)

            // 5. Build metadata groups for Inspector display
            progress(0.75, "Building metadata...")
            let metadataGroups = buildMetadataGroups(
                result: result,
                request: request,
                provenance: provenance
            )

            // 6. Write manifest
            progress(0.80, "Writing manifest...")
            let manifest = BundleManifest(
                name: bundleName,
                identifier: "org.lungfish.assembly.\(safeName.lowercased())",
                description: "De novo assembly using \(result.tool.displayName)",
                source: SourceInfo(
                    organism: bundleName,
                    assembly: safeName,
                    database: "\(result.tool.displayName) \(provenance.assemblerVersion ?? "unknown")",
                    notes: "Assembled from \(request.inputURLs.count) input file(s)"
                ),
                genome: genomeInfo,
                metadata: metadataGroups
            )
            try manifest.save(to: stagingBundleURL)

            // 7. Validate
            progress(0.90, "Validating bundle...")
            try validateBundle(at: stagingBundleURL)

            try publishBundle(from: stagingBundleURL, to: publishedBundleURL)
            didPublishBundle = true
            do {
                progress(0.95, "Writing bundle provenance...")
                try writeCanonicalBundleProvenance(
                    result: result,
                    request: request,
                    provenance: provenance,
                    bundleURL: publishedBundleURL
                )
            } catch {
                try? FileManager.default.removeItem(at: publishedBundleURL)
                throw error
            }

            progress(1.0, "Bundle created successfully")
            logger.info("Assembly bundle created: \(publishedBundleURL.path)")
            return publishedBundleURL

        } catch {
            if !stagingPreexisted,
               !didPublishBundle,
               FileManager.default.fileExists(atPath: stagingBundleURL.path) {
                try? FileManager.default.removeItem(at: stagingBundleURL)
            }
            throw error
        }
    }

    // MARK: - Private: Bundle Structure

    private func createBundleStructure(at bundleURL: URL) throws {
        let fm = FileManager.default

        if fm.fileExists(atPath: bundleURL.path) {
            throw AssemblyBundleBuildError.outputBundleAlreadyExists(bundleURL)
        }

        let directories = [
            bundleURL,
            bundleURL.appendingPathComponent("genome"),
            bundleURL.appendingPathComponent("assembly"),
        ]

        for dir in directories {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    private func prepareOutputDestination(for publishedBundleURL: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: publishedBundleURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: publishedBundleURL.path) {
            throw AssemblyBundleBuildError.outputBundleAlreadyExists(publishedBundleURL)
        }
    }

    private func makeStagingBundleURL(for publishedBundleURL: URL) throws -> URL {
        let parentURL = publishedBundleURL.deletingLastPathComponent()
        let baseName = publishedBundleURL.deletingPathExtension().lastPathComponent
        let stagingName = ".\(baseName).building-\(UUID().uuidString)"
        return parentURL.appendingPathComponent(stagingName, isDirectory: true)
    }

    private func publishBundle(from stagingBundleURL: URL, to publishedBundleURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: publishedBundleURL.path) {
            throw AssemblyBundleBuildError.outputBundleAlreadyExists(publishedBundleURL)
        }
        try fm.moveItem(at: stagingBundleURL, to: publishedBundleURL)
    }

    private func writeCanonicalBundleProvenance(
        result: AssemblyResult,
        request: AssemblyRunRequest,
        provenance: AssemblyProvenance,
        bundleURL: URL
    ) throws {
        let command = provenance.commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let argv = command.isEmpty ? [result.tool.rawValue] : ["/bin/sh", "-lc", command]
        let outputs = try assemblyBundleOutputDescriptors(bundleURL: bundleURL)
        let startedAt = provenance.assemblyDate <= Date() ? provenance.assemblyDate : Date()
        let endedAt = Date()

        var builder = ProvenanceRunBuilder(
            workflowName: "Assembly Bundle Wrapping",
            workflowVersion: "1",
            toolName: provenance.assembler,
            toolVersion: provenance.assemblerVersion ?? "unknown"
        )
        .argv(argv)
        .durableReplayArgv(argv)
        .reproducibleCommand(command.isEmpty ? argv.map(shellEscape).joined(separator: " ") : command)
        .options(
            explicit: assemblyProvenanceOptions(request: request, provenance: provenance),
            defaults: [:],
            resolved: assemblyProvenanceOptions(request: request, provenance: provenance)
        )
        .runtime(ProvenanceRuntimeIdentity(
            condaEnvironment: provenance.managedEnvironment,
            containerImage: provenance.containerImage,
            containerDigest: provenance.containerImageDigest
        ))

        let inputs = canonicalInputDescriptors(from: provenance.inputs)
        for input in inputs {
            builder = try addCanonicalInput(input, to: builder)
        }
        for output in outputs {
            builder = try addCanonicalOutput(output, to: builder)
        }
        if !provenance.steps.isEmpty {
            for step in provenance.steps {
                builder = builder.step(step)
            }
        } else {
            builder = builder.step(ProvenanceStep(
                toolName: provenance.assembler,
                toolVersion: provenance.assemblerVersion ?? "unknown",
                argv: argv,
                inputs: inputs,
                outputs: outputs,
                exitStatus: 0,
                wallTimeSeconds: provenance.wallTimeSeconds,
                startedAt: startedAt,
                completedAt: endedAt
            ))
        }

        let envelope = try builder.complete(
            exitStatus: 0,
            startedAt: startedAt,
            endedAt: endedAt
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
    }

    private func addCanonicalInput(
        _ descriptor: ProvenanceFileDescriptor,
        to builder: ProvenanceRunBuilder
    ) throws -> ProvenanceRunBuilder {
        if descriptorIsRemote(descriptor) {
            return try builder.input(descriptor)
        }

        let url = URL(fileURLWithPath: descriptor.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return builder
        }
        return try builder.input(url, format: descriptor.format, role: descriptor.role)
    }

    private func addCanonicalOutput(
        _ descriptor: ProvenanceFileDescriptor,
        to builder: ProvenanceRunBuilder
    ) throws -> ProvenanceRunBuilder {
        if descriptorIsRemote(descriptor) || descriptorLooksLikeDirectory(descriptor) {
            return try builder.output(descriptor)
        }
        return try builder.output(
            URL(fileURLWithPath: descriptor.path),
            format: descriptor.format,
            role: descriptor.role
        )
    }

    private func descriptorIsRemote(_ descriptor: ProvenanceFileDescriptor) -> Bool {
        descriptor.path.contains("://")
            && URLComponents(string: descriptor.path)?.scheme?.lowercased() != "file"
    }

    private func descriptorLooksLikeDirectory(_ descriptor: ProvenanceFileDescriptor) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: descriptor.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func assemblyProvenanceOptions(
        request: AssemblyRunRequest,
        provenance: AssemblyProvenance
    ) -> [String: ParameterValue] {
        [
            "assembler": .string(provenance.assembler),
            "executionBackend": .string(provenance.executionBackend.rawValue),
            "readType": .string(request.readType.rawValue),
            "projectName": .string(request.projectName),
            "outputDirectory": .file(request.outputDirectory),
            "threads": .integer(request.threads),
            "memoryGB": request.memoryGB.map(ParameterValue.integer) ?? .null,
            "minContigLength": request.effectiveMinContigLength.map(ParameterValue.integer) ?? .null,
            "pairedEnd": .boolean(request.pairedEnd),
            "extraArguments": .array(request.extraArguments.map(ParameterValue.string)),
        ]
    }

    private func canonicalInputDescriptors(from records: [InputFileRecord]) -> [ProvenanceFileDescriptor] {
        records.compactMap { record in
            guard let sha256 = record.sha256, record.sizeBytes >= 0 else { return nil }
            return ProvenanceFileDescriptor(
                path: record.originalPath ?? record.filename,
                checksumSHA256: sha256,
                fileSize: UInt64(record.sizeBytes),
                role: .input
            )
        }
    }

    private func assemblyBundleOutputDescriptors(bundleURL: URL) throws -> [ProvenanceFileDescriptor] {
        var descriptors = [try directoryDescriptor(url: bundleURL, role: .output)]
        guard let enumerator = FileManager.default.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return descriptors
        }
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            if fileURL.path.contains("/provenance/") || fileURL.lastPathComponent == ProvenanceRecorder.provenanceFilename {
                continue
            }
            descriptors.append(try ProvenanceFileDescriptor.file(
                url: fileURL,
                format: assemblyBundleOutputFormat(for: fileURL),
                role: assemblyBundleOutputRole(for: fileURL)
            ))
        }
        return descriptors.sorted {
            $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }
    }

    private func directoryDescriptor(url: URL, role: FileRole) throws -> ProvenanceFileDescriptor {
        let manifest = try ProvenanceFileHasher.directoryManifest(for: url, role: role)
        return ProvenanceFileDescriptor(
            path: url.standardizedFileURL.path,
            checksumSHA256: directoryChecksum(from: manifest),
            fileSize: directorySize(from: manifest),
            format: .unknown,
            role: role
        )
    }

    private func directoryChecksum(from manifest: ProvenanceDirectoryManifest) -> String {
        let canonical = manifest.files
            .sorted { $0.path < $1.path }
            .map { descriptor in
                [
                    descriptor.path,
                    descriptor.checksumSHA256 ?? "",
                    descriptor.fileSize.map(String.init) ?? "0",
                ].joined(separator: "\t")
            }
            .joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func directorySize(from manifest: ProvenanceDirectoryManifest) -> UInt64 {
        manifest.files.reduce(UInt64(0)) { total, descriptor in
            total + (descriptor.fileSize ?? 0)
        }
    }

    private func assemblyBundleOutputFormat(for url: URL) -> FileFormat {
        let filename = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "json":
            return .json
        case "fa", "fasta", "fna":
            return .fasta
        case "gz" where filename.hasSuffix(".fa.gz") || filename.hasSuffix(".fasta.gz"):
            return .fasta
        case "log", "txt", "gfa", "fai", "gzi":
            return .text
        default:
            return .unknown
        }
    }

    private func assemblyBundleOutputRole(for url: URL) -> FileRole {
        switch url.pathExtension.lowercased() {
        case "fai", "gzi":
            return .index
        case "log":
            return .log
        default:
            return .output
        }
    }

    // MARK: - Private: FASTA Processing

    private func processContigsFASTA(
        contigsPath: URL,
        bundleURL: URL,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> GenomeInfo {
        let genomeDir = bundleURL.appendingPathComponent("genome")
        let destFASTA = genomeDir.appendingPathComponent("contigs.fa")

        // Copy contigs to bundle
        try FileManager.default.copyItem(at: contigsPath, to: destFASTA)

        // Parse chromosomes/contigs from the FASTA before compression
        let chromosomes = try parseFASTAIndex(destFASTA)

        // bgzip compress
        progress(0.15, "Compressing contigs with bgzip...")
        let bgzipResult = try await toolRunner.bgzipCompress(
            inputPath: destFASTA,
            keepOriginal: false
        )

        let compressedPath: URL
        if bgzipResult.isSuccess {
            compressedPath = URL(fileURLWithPath: destFASTA.path + ".gz")
            logger.info("Contigs compressed with bgzip")
            // Remove uncompressed if bgzip didn't
            if FileManager.default.fileExists(atPath: destFASTA.path) {
                try? FileManager.default.removeItem(at: destFASTA)
            }
        } else {
            logger.warning("bgzip failed (\(bgzipResult.exitCode)): \(bgzipResult.stderr), using uncompressed")
            compressedPath = destFASTA
        }

        // samtools faidx
        progress(0.35, "Indexing contigs with samtools...")
        let indexResult = try await toolRunner.indexFASTA(fastaPath: compressedPath)

        if !indexResult.isSuccess {
            logger.warning("samtools faidx failed: \(indexResult.stderr), creating manual index")
            let indexURL = URL(fileURLWithPath: compressedPath.path + ".fai")
            try writeFASTAIndex(chromosomes: chromosomes, to: indexURL)
        }

        progress(0.50, "FASTA processing complete")

        let totalLength = chromosomes.reduce(Int64(0)) { $0 + $1.length }
        let isCompressed = compressedPath.pathExtension == "gz"
        let relativePath = isCompressed ? "genome/contigs.fa.gz" : "genome/contigs.fa"

        return GenomeInfo(
            path: relativePath,
            indexPath: "\(relativePath).fai",
            gzipIndexPath: isCompressed ? "\(relativePath).gzi" : nil,
            totalLength: totalLength,
            chromosomes: chromosomes
        )
    }

    /// Parses a FASTA file to extract chromosome/contig information for the index.
    private func parseFASTAIndex(_ fastaURL: URL) throws -> [ChromosomeInfo] {
        let content = try String(contentsOf: fastaURL, encoding: .utf8)
        var chromosomes: [ChromosomeInfo] = []
        var currentName: String?
        var currentDescription: String?
        var currentLength: Int64 = 0
        var currentOffset: Int64 = 0
        var lineBases = 0
        var lineWidth = 0
        var byteOffset: Int64 = 0
        var firstSequenceLine = true

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineBytes = Int64(line.utf8.count) + 1  // +1 for newline

            if line.hasPrefix(">") {
                // Flush previous
                if let name = currentName {
                    chromosomes.append(ChromosomeInfo(
                        name: name,
                        length: currentLength,
                        offset: currentOffset,
                        lineBases: lineBases,
                        lineWidth: lineWidth,
                        fastaDescription: currentDescription
                    ))
                }
                // Parse header
                let header = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                guard !header.isEmpty else {
                    currentName = nil  // Skip malformed empty header
                    continue
                }
                let parts = header.split(separator: " ", maxSplits: 1)
                currentName = String(parts[0])
                currentDescription = parts.count > 1 ? String(parts[1]) : nil
                currentLength = 0
                currentOffset = byteOffset + lineBytes  // offset to first sequence byte
                firstSequenceLine = true
            } else if currentName != nil {
                let bases = line.filter { $0 != " " && $0 != "\t" }.count
                currentLength += Int64(bases)
                if firstSequenceLine && bases > 0 {
                    lineBases = bases
                    lineWidth = Int(lineBytes)
                    firstSequenceLine = false
                }
            }

            byteOffset += lineBytes
        }

        // Flush last contig
        if let name = currentName {
            chromosomes.append(ChromosomeInfo(
                name: name,
                length: currentLength,
                offset: currentOffset,
                lineBases: lineBases,
                lineWidth: lineWidth,
                fastaDescription: currentDescription
            ))
        }

        return chromosomes
    }

    /// Writes a .fai index file manually (fallback if samtools is unavailable).
    private func writeFASTAIndex(chromosomes: [ChromosomeInfo], to url: URL) throws {
        let lines = chromosomes.map { chr in
            "\(chr.name)\t\(chr.length)\t\(chr.offset)\t\(chr.lineBases)\t\(chr.lineWidth)"
        }
        let content = lines.joined(separator: "\n") + "\n"
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Private: Assembly Artifacts

    private func copyAssemblyArtifacts(result: AssemblyResult, bundleURL: URL) throws {
        let assemblyDir = bundleURL.appendingPathComponent("assembly")
        let fm = FileManager.default

        // Copy scaffolds if present
        if let scaffoldsPath = result.scaffoldsPath,
           fm.fileExists(atPath: scaffoldsPath.path) {
            try fm.copyItem(
                at: scaffoldsPath,
                to: assemblyDir.appendingPathComponent("scaffolds.fasta")
            )
        }

        // Copy assembly graph if present
        if let graphPath = result.graphPath,
           fm.fileExists(atPath: graphPath.path) {
            try fm.copyItem(
                at: graphPath,
                to: assemblyDir.appendingPathComponent("assembly_graph.gfa")
            )
        }

        // Copy assembler log if present
        if let logPath = result.logPath,
           fm.fileExists(atPath: logPath.path) {
            try fm.copyItem(
                at: logPath,
                to: assemblyDir.appendingPathComponent("assembly.log")
            )
        }

        // Copy params.txt if present
        if let paramsPath = result.paramsPath,
           fm.fileExists(atPath: paramsPath.path) {
            try fm.copyItem(
                at: paramsPath,
                to: assemblyDir.appendingPathComponent("params.txt")
            )
        }
    }

    // MARK: - Private: Metadata

    private func buildMetadataGroups(
        result: AssemblyResult,
        request: AssemblyRunRequest,
        provenance: AssemblyProvenance
    ) -> [MetadataGroup] {
        var groups: [MetadataGroup] = []

        // Assembly Statistics group
        let stats = result.statistics
        var statsItems: [MetadataItem] = [
            MetadataItem(label: "Contigs", value: "\(stats.contigCount)"),
            MetadataItem(label: "Total Length", value: "\(stats.totalLengthBP.formatted()) bp"),
            MetadataItem(label: "N50", value: "\(stats.n50.formatted()) bp"),
            MetadataItem(label: "L50", value: "\(stats.l50)"),
            MetadataItem(label: "N90", value: "\(stats.n90.formatted()) bp"),
            MetadataItem(label: "Largest Contig", value: "\(stats.largestContigBP.formatted()) bp"),
            MetadataItem(label: "GC Content", value: String(format: "%.1f%%", stats.gcPercent)),
        ]
        if stats.contigCount > 0 {
            statsItems.append(MetadataItem(
                label: "Mean Length",
                value: String(format: "%.0f bp", stats.meanLengthBP)
            ))
        }
        groups.append(MetadataGroup(name: "Assembly Statistics", items: statsItems))

        // Assembly Parameters group
        var paramItems: [MetadataItem] = [
            MetadataItem(label: "Assembler", value: "\(result.tool.displayName) \(provenance.assemblerVersion ?? "unknown")"),
            MetadataItem(label: "Read Type", value: request.readType.displayName),
            MetadataItem(label: "Threads", value: "\(request.threads)"),
        ]
        if let profile = request.selectedProfileID, !profile.isEmpty {
            paramItems.append(MetadataItem(label: "Profile", value: profile))
        }
        if let memoryGB = request.memoryGB {
            paramItems.append(MetadataItem(label: "Memory", value: "\(memoryGB) GB"))
        }
        if let minContigLength = request.effectiveMinContigLength {
            paramItems.append(MetadataItem(label: "Min Contig Length", value: "\(minContigLength) bp"))
        }

        let minutes = Int(result.wallTimeSeconds) / 60
        let seconds = Int(result.wallTimeSeconds) % 60
        paramItems.append(MetadataItem(
            label: "Wall Time",
            value: minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
        ))

        groups.append(MetadataGroup(name: "Assembly Parameters", items: paramItems))

        // Input Files group
        let inputItems = request.inputURLs.map { url in
            MetadataItem(label: url.lastPathComponent, value: "input")
        }
        if !inputItems.isEmpty {
            groups.append(MetadataGroup(name: "Input Files", items: inputItems))
        }

        return groups
    }

    // MARK: - Private: Validation

    private func validateBundle(at bundleURL: URL) throws {
        let fm = FileManager.default

        // Check manifest exists
        let manifestURL = bundleURL.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else {
            throw AssemblyBundleBuildError.validationFailed("manifest.json not found")
        }

        // Check genome directory has FASTA
        let genomeDir = bundleURL.appendingPathComponent("genome")
        let contents = try fm.contentsOfDirectory(atPath: genomeDir.path)
        guard contents.contains(where: { $0.hasPrefix("contigs.fa") }) else {
            throw AssemblyBundleBuildError.validationFailed("No contigs FASTA in genome/")
        }

        // Check assembly directory has provenance
        let assemblyDir = bundleURL.appendingPathComponent("assembly")
        guard fm.fileExists(atPath: assemblyDir.appendingPathComponent("provenance.json").path) else {
            throw AssemblyBundleBuildError.validationFailed("provenance.json not found in assembly/")
        }
    }
}

// MARK: - AssemblyBundleBuildError

/// Errors from assembly bundle creation.
public enum AssemblyBundleBuildError: Error, LocalizedError {
    case contigsNotFound(URL)
    case bgzipFailed(String)
    case indexFailed(String)
    case outputBundleAlreadyExists(URL)
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .contigsNotFound(let url):
            return "Contigs FASTA not found: \(url.lastPathComponent)"
        case .bgzipFailed(let detail):
            return "bgzip compression failed: \(detail)"
        case .indexFailed(let detail):
            return "FASTA indexing failed: \(detail)"
        case .outputBundleAlreadyExists(let url):
            return "Output assembly bundle already exists: \(url.path)"
        case .validationFailed(let detail):
            return "Bundle validation failed: \(detail)"
        }
    }
}

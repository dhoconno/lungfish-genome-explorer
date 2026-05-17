import Foundation
import LungfishIO
import LungfishWorkflow

enum FASTQBundleMergeServiceError: LocalizedError {
    case requiresAtLeastTwoBundles
    case noFASTQPayload(bundleName: String)
    case outputBundleAlreadyExists(bundleName: String)
    case mixedPairingLayouts
    case unsupportedReadComposition(bundleName: String)
    case pairedBundleMissingMate(bundleName: String)
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .requiresAtLeastTwoBundles:
            return "Select at least two FASTQ bundles to merge."
        case .noFASTQPayload(let bundleName):
            return "No FASTQ payload was found in \(bundleName)."
        case .outputBundleAlreadyExists(let bundleName):
            return "\(bundleName) already exists."
        case .mixedPairingLayouts:
            return "Selected FASTQ bundles mix single-end and paired/interleaved layouts."
        case .unsupportedReadComposition(let bundleName):
            return "\(bundleName) has a mixed read composition that merge does not support yet."
        case .pairedBundleMissingMate(let bundleName):
            return "\(bundleName) is missing one mate file."
        case .toolFailed(let detail):
            return detail
        }
    }
}

enum FASTQBundleMergeService {
    private enum MergeMode {
        case virtualSingleEnd
        case physical

        var provenanceName: String {
            switch self {
            case .virtualSingleEnd:
                return "virtual-single-end"
            case .physical:
                return "materialized"
            }
        }
    }

    private struct ResolvedInput {
        let fastqURLs: [URL]
        let pairingMode: IngestionMetadata.PairingMode
        let originalFilenames: [String]
    }

    static func merge(
        sourceBundleURLs: [URL],
        outputDirectory: URL,
        bundleName: String
    ) async throws -> URL {
        try await merge(
            sourceBundleURLs: sourceBundleURLs,
            outputDirectory: outputDirectory,
            bundleName: bundleName,
            provenanceWriter: .live
        )
    }

    static func merge(
        sourceBundleURLs: [URL],
        outputDirectory: URL,
        bundleName: String,
        provenanceWriter: BundleMergeProvenanceSidecarWriter
    ) async throws -> URL {
        guard sourceBundleURLs.count >= 2 else {
            throw FASTQBundleMergeServiceError.requiresAtLeastTwoBundles
        }

        let startedAt = Date()
        let bundleURL = try makeOutputBundleURL(
            outputDirectory: outputDirectory,
            bundleName: bundleName
        )
        guard !FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw FASTQBundleMergeServiceError.outputBundleAlreadyExists(
                bundleName: bundleURL.lastPathComponent
            )
        }

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: false)

        do {
            let mergeMode = determineMode(for: sourceBundleURLs)
            switch mergeMode {
            case .virtualSingleEnd:
                try await createVirtualBundle(
                    at: bundleURL,
                    sourceBundleURLs: sourceBundleURLs,
                    bundleName: bundleName
                )
            case .physical:
                try await createPhysicalBundle(
                    at: bundleURL,
                    sourceBundleURLs: sourceBundleURLs,
                    outputDirectory: outputDirectory,
                    bundleName: bundleName
                )
            }
            try writeMergeProvenance(
                sourceBundleURLs: sourceBundleURLs,
                bundleURL: bundleURL,
                bundleName: bundleName,
                mergeMode: mergeMode,
                startedAt: startedAt,
                completedAt: Date(),
                provenanceWriter: provenanceWriter
            )
            return bundleURL
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }
    }

    private static func determineMode(for bundleURLs: [URL]) -> MergeMode {
        for bundleURL in bundleURLs {
            if FASTQBundle.isDerivedBundle(bundleURL) {
                return .physical
            }
            if FASTQBundle.classifiedFileURLs(for: bundleURL) != nil {
                return .physical
            }
            let physicalURLs = physicalFASTQURLs(in: bundleURL)
            guard physicalURLs.count == 1 else {
                return .physical
            }
            if inferredPairingMode(for: bundleURL, fastqURLs: physicalURLs) != .singleEnd {
                return .physical
            }
        }
        return .virtualSingleEnd
    }

    private static func createVirtualBundle(
        at bundleURL: URL,
        sourceBundleURLs: [URL],
        bundleName: String
    ) async throws {
        let fm = FileManager.default
        let chunksDirectory = bundleURL.appendingPathComponent("chunks", isDirectory: true)
        try fm.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)

        var entries: [FASTQSourceFileManifest.SourceFileEntry] = []
        var previewInputs: [URL] = []

        for (index, sourceBundleURL) in sourceBundleURLs.enumerated() {
            guard let sourceFASTQ = physicalFASTQURLs(in: sourceBundleURL).first else {
                throw FASTQBundleMergeServiceError.noFASTQPayload(
                    bundleName: sourceBundleURL.deletingPathExtension().lastPathComponent
                )
            }

            let linkedURL = chunksDirectory.appendingPathComponent(
                String(format: "%03d-%@", index, sourceFASTQ.lastPathComponent)
            )
            do {
                try fm.linkItem(at: sourceFASTQ, to: linkedURL)
            } catch {
                try fm.copyItem(at: sourceFASTQ, to: linkedURL)
            }

            entries.append(
                FASTQSourceFileManifest.SourceFileEntry(
                    filename: "chunks/\(linkedURL.lastPathComponent)",
                    originalPath: sourceFASTQ.path,
                    sizeBytes: fileSize(at: sourceFASTQ),
                    isSymlink: false
                )
            )
            previewInputs.append(linkedURL)
        }

        try FASTQSourceFileManifest(files: entries).save(to: bundleURL)
        try await writePreview(
            from: previewInputs,
            to: bundleURL.appendingPathComponent("preview.fastq")
        )
        try FASTQBundleCSVMetadata.save(
            FASTQSampleMetadata(sampleName: bundleName).toLegacyCSV(),
            to: bundleURL
        )
    }

    private static func createPhysicalBundle(
        at bundleURL: URL,
        sourceBundleURLs: [URL],
        outputDirectory: URL,
        bundleName: String
    ) async throws {
        let tempDirectory = try ProjectTempDirectory.createFromContext(
            prefix: "fastq-merge-",
            contextURL: outputDirectory
        )
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        var resolvedInputs: [ResolvedInput] = []
        for sourceBundleURL in sourceBundleURLs {
            let resolved = try await resolvePhysicalMergeInput(
                for: sourceBundleURL,
                tempDirectory: tempDirectory
            )
            resolvedInputs.append(resolved)
        }

        let normalizedPairings = Set(
            resolvedInputs.map { resolved in
                resolved.pairingMode == .pairedEnd ? IngestionMetadata.PairingMode.interleaved : resolved.pairingMode
            }
        )
        guard normalizedPairings.count == 1,
              let outputPairing = normalizedPairings.first else {
            throw FASTQBundleMergeServiceError.mixedPairingLayouts
        }

        let flattenedInputs = resolvedInputs.flatMap(\.fastqURLs)
        guard let firstInput = flattenedInputs.first else {
            throw FASTQBundleMergeServiceError.requiresAtLeastTwoBundles
        }

        let outputFASTQ = bundleURL.appendingPathComponent(
            mergedFASTQFilename(for: firstInput)
        )
        FileManager.default.createFile(atPath: outputFASTQ.path, contents: nil)

        let outputHandle = try FileHandle(forWritingTo: outputFASTQ)
        defer { try? outputHandle.close() }

        for inputURL in flattenedInputs {
            try appendFile(at: inputURL, to: outputHandle)
        }

        FASTQMetadataStore.save(
            PersistedFASTQMetadata(
                ingestion: IngestionMetadata(
                    isCompressed: isCompressedFASTQ(firstInput),
                    pairingMode: outputPairing,
                    originalFilenames: resolvedInputs.flatMap(\.originalFilenames)
                )
            ),
            for: outputFASTQ
        )
        try FASTQBundleCSVMetadata.save(
            FASTQSampleMetadata(sampleName: bundleName).toLegacyCSV(),
            to: bundleURL
        )
    }

    private static func resolvePhysicalMergeInput(
        for bundleURL: URL,
        tempDirectory: URL
    ) async throws -> ResolvedInput {
        if let classifiedURLs = FASTQBundle.classifiedFileURLs(for: bundleURL) {
            let roles = Set(classifiedURLs.keys)
            if roles == [.pairedR1, .pairedR2],
               let r1 = classifiedURLs[.pairedR1],
               let r2 = classifiedURLs[.pairedR2] {
                let interleavedURL = tempDirectory.appendingPathComponent(
                    "interleaved-\(UUID().uuidString).fastq"
                )
                try await interleavePairedInputs(r1: r1, r2: r2, outputURL: interleavedURL)
                return ResolvedInput(
                    fastqURLs: [interleavedURL],
                    pairingMode: .interleaved,
                    originalFilenames: [r1.lastPathComponent, r2.lastPathComponent]
                )
            }
            throw FASTQBundleMergeServiceError.unsupportedReadComposition(
                bundleName: bundleURL.deletingPathExtension().lastPathComponent
            )
        }

        if FASTQBundle.isDerivedBundle(bundleURL) {
            let materializedURL = try await FASTQDerivativeService.shared.materializeDatasetFASTQ(
                fromBundle: bundleURL,
                tempDirectory: tempDirectory,
                progress: nil
            )
            let pairing = FASTQBundle.loadDerivedManifest(in: bundleURL)?.pairingMode ?? .singleEnd
            let normalizedPairing = pairing == .pairedEnd ? IngestionMetadata.PairingMode.interleaved : pairing
            return ResolvedInput(
                fastqURLs: [materializedURL],
                pairingMode: normalizedPairing,
                originalFilenames: [materializedURL.lastPathComponent]
            )
        }

        let physicalURLs = physicalFASTQURLs(in: bundleURL)
        guard !physicalURLs.isEmpty else {
            throw FASTQBundleMergeServiceError.noFASTQPayload(
                bundleName: bundleURL.deletingPathExtension().lastPathComponent
            )
        }

        let pairing = inferredPairingMode(for: bundleURL, fastqURLs: physicalURLs)
        if pairing == .pairedEnd {
            guard physicalURLs.count == 2 else {
                throw FASTQBundleMergeServiceError.pairedBundleMissingMate(
                    bundleName: bundleURL.deletingPathExtension().lastPathComponent
                )
            }
            let interleavedURL = tempDirectory.appendingPathComponent(
                "interleaved-\(UUID().uuidString).fastq"
            )
            try await interleavePairedInputs(
                r1: physicalURLs[0],
                r2: physicalURLs[1],
                outputURL: interleavedURL
            )
            return ResolvedInput(
                fastqURLs: [interleavedURL],
                pairingMode: .interleaved,
                originalFilenames: physicalURLs.map(\.lastPathComponent)
            )
        }

        return ResolvedInput(
            fastqURLs: physicalURLs,
            pairingMode: pairing,
            originalFilenames: physicalURLs.map(\.lastPathComponent)
        )
    }

    private static func interleavePairedInputs(
        r1: URL,
        r2: URL,
        outputURL: URL
    ) async throws {
        let runner = NativeToolRunner.shared
        let result = try await runner.run(
            .reformat,
            arguments: [
                "in1=\(r1.path)",
                "in2=\(r2.path)",
                "out=\(outputURL.path)",
                "interleaved=t",
            ],
            environment: await bbToolsEnvironment(),
            timeout: 1800
        )
        guard result.isSuccess else {
            throw FASTQBundleMergeServiceError.toolFailed(
                "reformat.sh interleave failed: \(result.stderr)"
            )
        }
    }

    private static func writePreview(
        from inputURLs: [URL],
        to outputURL: URL,
        maxReads: Int = 1_000
    ) async throws {
        var previewLines: [String] = []
        previewLines.reserveCapacity(maxReads * 4)

        var lineBuffer: [String] = []
        lineBuffer.reserveCapacity(4)
        var readsCollected = 0

        outer: for inputURL in inputURLs {
            for try await line in inputURL.linesAutoDecompressing() {
                if line.isEmpty && lineBuffer.isEmpty {
                    continue
                }
                lineBuffer.append(line)
                guard lineBuffer.count == 4 else { continue }

                previewLines.append(contentsOf: lineBuffer)
                lineBuffer.removeAll(keepingCapacity: true)
                readsCollected += 1

                if readsCollected >= maxReads {
                    break outer
                }
            }
            lineBuffer.removeAll(keepingCapacity: true)
        }

        let contents = previewLines.isEmpty ? "" : previewLines.joined(separator: "\n") + "\n"
        try contents.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    private static func physicalFASTQURLs(in bundleURL: URL) -> [URL] {
        if let manifest = try? FASTQSourceFileManifest.load(from: bundleURL) {
            let urls = manifest.resolveFileURLs(relativeTo: bundleURL)
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existing.isEmpty {
                return existing
            }
        }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let fastqURLs = contents
            .filter { FASTQBundle.isFASTQFileURL($0) }
            .sorted {
                $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
            }
        let nonPreview = fastqURLs.filter { $0.lastPathComponent != "preview.fastq" }
        return nonPreview.isEmpty ? fastqURLs : nonPreview
    }

    private static func inferredPairingMode(
        for bundleURL: URL,
        fastqURLs: [URL]
    ) -> IngestionMetadata.PairingMode {
        if let derivedPairing = FASTQBundle.loadDerivedManifest(in: bundleURL)?.pairingMode {
            return derivedPairing
        }

        let metadataPairings = fastqURLs.compactMap { FASTQMetadataStore.load(for: $0)?.ingestion?.pairingMode }
        if let firstPairing = metadataPairings.first,
           metadataPairings.allSatisfy({ $0 == firstPairing }) {
            return firstPairing
        }

        if fastqURLs.count == 2 {
            return .pairedEnd
        }

        return .singleEnd
    }

    private static func mergedFASTQFilename(for inputURL: URL) -> String {
        if inputURL.pathExtension.lowercased() == "gz" {
            return "reads.fastq.gz"
        }
        return "reads.fastq"
    }

    private static func isCompressedFASTQ(_ inputURL: URL) -> Bool {
        inputURL.pathExtension.lowercased() == "gz"
    }

    private static func appendFile(at inputURL: URL, to outputHandle: FileHandle) throws {
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        defer { try? inputHandle.close() }

        while true {
            let chunk = inputHandle.readData(ofLength: 1_048_576)
            if chunk.isEmpty { break }
            outputHandle.write(chunk)
        }
    }

    private static func writeMergeProvenance(
        sourceBundleURLs: [URL],
        bundleURL: URL,
        bundleName: String,
        mergeMode: MergeMode,
        startedAt: Date,
        completedAt: Date,
        provenanceWriter: BundleMergeProvenanceSidecarWriter
    ) throws {
        let inputPayloadURLs = sourceBundleURLs.flatMap(provenanceInputURLs(in:))
        let outputPayloadURLs = try BundleMergeProvenance.regularPayloadFileURLs(in: bundleURL)
        try BundleMergeProvenance.write(
            request: BundleMergeProvenance.Request(
                workflowName: "lungfish fastq merge",
                sourceBundleURLs: sourceBundleURLs,
                inputPayloadURLs: inputPayloadURLs,
                outputBundleURL: bundleURL,
                outputPayloadURLs: outputPayloadURLs,
                bundleName: bundleName,
                mergeMode: mergeMode.provenanceName,
                defaults: [
                    "previewMaxReads": .integer(1_000),
                    "pairedEndNormalization": .string("interleave paired-end sources"),
                ],
                resolvedDefaults: [
                    "previewMaxReads": .integer(1_000),
                    "pairedEndNormalization": .string("interleave paired-end sources"),
                ],
                startedAt: startedAt,
                completedAt: completedAt
            ),
            sidecarWriter: provenanceWriter
        )
    }

    private static func provenanceInputURLs(in bundleURL: URL) -> [URL] {
        if let classifiedURLs = FASTQBundle.classifiedFileURLs(for: bundleURL) {
            return classifiedURLs.values.sorted {
                $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
            }
        }

        if let urls = FASTQBundle.resolveAllFASTQURLs(for: bundleURL),
           !urls.isEmpty {
            return urls
        }

        if let sequenceURL = FASTQBundle.resolvePrimarySequenceURL(for: bundleURL) {
            return [sequenceURL]
        }

        let derivedManifestURL = FASTQBundle.derivedManifestURL(in: bundleURL)
        if FileManager.default.fileExists(atPath: derivedManifestURL.path) {
            return [derivedManifestURL]
        }

        return physicalFASTQURLs(in: bundleURL)
    }

    private static func fileSize(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    private static func makeOutputBundleURL(
        outputDirectory: URL,
        bundleName: String
    ) throws -> URL {
        let trimmedName = bundleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = trimmedName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let finalName = safeName.isEmpty ? "Merged FASTQ" : safeName
        return outputDirectory.appendingPathComponent(
            "\(finalName).\(FASTQBundle.directoryExtension)",
            isDirectory: true
        )
    }

    private static func bbToolsEnvironment() async -> [String: String] {
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return CoreToolLocator.bbToolsEnvironment(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            existingPath: existingPath
        )
    }
}

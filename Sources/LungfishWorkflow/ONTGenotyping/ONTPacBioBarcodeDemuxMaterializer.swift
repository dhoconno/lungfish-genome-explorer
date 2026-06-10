import Foundation
import LungfishIO

public struct ONTPacBioBarcodeDemuxMaterializationRequest: Sendable {
    public static var defaultChunkJobs: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    public let inputURL: URL
    public let barcodeDefinitionsURL: URL
    public let outputDirectory: URL
    public let force: Bool
    public let threads: Int
    public let maxReadsPerSlice: Int
    public let maxInputBytesPerCutadapt: Int64
    public let chunkJobs: Int

    public init(
        inputURL: URL,
        barcodeDefinitionsURL: URL,
        outputDirectory: URL,
        force: Bool = false,
        threads: Int = 1,
        chunkJobs: Int = ONTPacBioBarcodeDemuxMaterializationRequest.defaultChunkJobs,
        maxReadsPerSlice: Int = 100_000,
        maxInputBytesPerCutadapt: Int64 = 512 * 1024 * 1024
    ) {
        self.inputURL = inputURL.standardizedFileURL
        self.barcodeDefinitionsURL = barcodeDefinitionsURL.standardizedFileURL
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.force = force
        self.threads = max(1, threads)
        self.maxReadsPerSlice = max(0, maxReadsPerSlice)
        self.maxInputBytesPerCutadapt = max(1, maxInputBytesPerCutadapt)
        self.chunkJobs = max(1, chunkJobs)
    }
}

public struct ONTPacBioBarcodeDemuxMaterializationResult: Sendable {
    public let outputDirectory: URL
    public let manifestURL: URL
    public let outputBundleURLs: [URL]
    public let inputChunkCount: Int
    public let executedCutadaptChunkCount: Int
    public let inputReadCount: Int
    public let assignedReadCount: Int
    public let unassignedReadCount: Int
    public let chunkJobs: Int
    public let cutadaptRuns: [ONTPacBioBarcodeDemuxCutadaptRun]
}

public struct ONTPacBioBarcodeDemuxCutadaptRun: Sendable, Codable, Equatable {
    public let inputPath: String
    public let argv: [String]
    public let exitStatus: Int
    public let wallTimeSeconds: Double
    public let stderr: String?

    public init(
        inputPath: String,
        argv: [String],
        exitStatus: Int,
        wallTimeSeconds: Double,
        stderr: String?
    ) {
        self.inputPath = inputPath
        self.argv = argv
        self.exitStatus = exitStatus
        self.wallTimeSeconds = wallTimeSeconds
        self.stderr = stderr
    }
}

public enum ONTPacBioBarcodeDemuxMaterializerError: LocalizedError, Sendable, Equatable {
    case missingInput(URL)
    case missingBarcodeDefinitions(URL)
    case outputExists(URL)
    case noBarcodeRows(URL)
    case noInputFASTQs(URL)
    case noCutadaptCommand(URL)
    case noSampleOutputs

    public var errorDescription: String? {
        switch self {
        case .missingInput(let url):
            return "Input ONT FASTQ file or directory does not exist: \(url.path)"
        case .missingBarcodeDefinitions(let url):
            return "Barcode definition CSV does not exist: \(url.path)"
        case .outputExists(let url):
            return "Output directory already exists: \(url.path). Use --force to replace it."
        case .noBarcodeRows(let url):
            return "No PacBio barcode-pair rows were found in \(url.path). Expected columns: sample,forward_barcode,reverse_barcode."
        case .noInputFASTQs(let url):
            return "No physical FASTQ chunks could be resolved from \(url.path)."
        case .noCutadaptCommand(let url):
            return "Chunk demultiplexing did not report its cutadapt command for \(url.path)."
        case .noSampleOutputs:
            return "cutadapt completed, but no sample FASTQ outputs were produced."
        }
    }
}

public final class ONTPacBioBarcodeDemuxMaterializer: Sendable {
    public static let manifestFilename = "ont-pacbio-barcode-demux-manifest.json"

    private let pipeline: DemultiplexingPipeline

    public init(pipeline: DemultiplexingPipeline = DemultiplexingPipeline()) {
        self.pipeline = pipeline
    }

    public func run(
        _ request: ONTPacBioBarcodeDemuxMaterializationRequest,
        progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> ONTPacBioBarcodeDemuxMaterializationResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: request.inputURL.path) else {
            throw ONTPacBioBarcodeDemuxMaterializerError.missingInput(request.inputURL)
        }
        guard fileManager.fileExists(atPath: request.barcodeDefinitionsURL.path) else {
            throw ONTPacBioBarcodeDemuxMaterializerError.missingBarcodeDefinitions(request.barcodeDefinitionsURL)
        }
        if fileManager.fileExists(atPath: request.outputDirectory.path) {
            guard request.force else {
                throw ONTPacBioBarcodeDemuxMaterializerError.outputExists(request.outputDirectory)
            }
            try fileManager.removeItem(at: request.outputDirectory)
        }
        try fileManager.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)

        let kitName = request.barcodeDefinitionsURL.deletingPathExtension().lastPathComponent
        let barcodeKit = try BarcodeKitRegistry.loadCustomKit(from: request.barcodeDefinitionsURL, name: kitName)
        guard !barcodeKit.barcodes.isEmpty else {
            throw ONTPacBioBarcodeDemuxMaterializerError.noBarcodeRows(request.barcodeDefinitionsURL)
        }

        let inputFASTQs = try ONTBarcodeDemuxGenotypingPipeline.resolveInputFASTQURLs(for: request.inputURL)
        guard !inputFASTQs.isEmpty else {
            throw ONTPacBioBarcodeDemuxMaterializerError.noInputFASTQs(request.inputURL)
        }

        let tempRoot = request.outputDirectory.appendingPathComponent(".chunked-cutadapt-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }

        let cutadaptVersion = await NativeToolRunner.shared.getToolVersion(.cutadapt) ?? "unknown"
        var buildersBySample: [String: SampleBuilder] = [:]
        var cutadaptRuns: [ONTPacBioBarcodeDemuxCutadaptRun] = []
        var inputReadCount = 0
        var assignedReadCount = 0
        var unassignedReadCount = 0
        var executedChunkCount = 0
        var chunkOrdinal = 0
        let hasSubSlicedInputs = inputFASTQs.contains {
            Self.requiresSubSlicing(
                $0,
                maxReadsPerSlice: request.maxReadsPerSlice,
                maxInputBytesPerCutadapt: request.maxInputBytesPerCutadapt
            )
        }
        let effectiveChunkJobs = hasSubSlicedInputs ? 1 : min(request.chunkJobs, inputFASTQs.count)
        progress(
            0.02,
            "Found \(inputFASTQs.count) ONT FASTQ chunks; running up to \(effectiveChunkJobs) cutadapt job(s)"
        )

        func physicalChunkProgress(processed: Int) -> Double {
            0.02 + (0.88 * Double(processed) / Double(max(1, inputFASTQs.count)))
        }

        func consume(_ chunk: ChunkMaterialization) async throws {
            executedChunkCount += 1
            cutadaptRuns.append(chunk.cutadaptRun)
            assignedReadCount += chunk.assignedReadCount
            unassignedReadCount += chunk.unassignedReadCount
            inputReadCount += chunk.inputReadCount
            try await appendSampleOutputs(
                from: chunk.result,
                into: request.outputDirectory,
                buildersBySample: &buildersBySample
            )
            try? fileManager.removeItem(at: chunk.outputDirectory)
        }

        if effectiveChunkJobs > 1 {
            var submittedInputIndex = 0
            var nextAppendOrdinal = 1
            var processedInputChunks = 0
            var pendingChunks: [Int: ChunkMaterialization] = [:]
            try await withThrowingTaskGroup(of: ChunkMaterialization.self) { group in
                let initialJobs = min(effectiveChunkJobs, inputFASTQs.count)
                for _ in 0..<initialJobs {
                    let inputIndex = submittedInputIndex
                    submittedInputIndex += 1
                    let inputFASTQ = inputFASTQs[inputIndex]
                    group.addTask {
                        try await Self.runCutadaptChunk(
                            inputFASTQ: inputFASTQ,
                            inputIndex: inputIndex,
                            inputCount: inputFASTQs.count,
                            chunkOrdinal: inputIndex + 1,
                            tempRoot: tempRoot,
                            request: request,
                            barcodeKit: barcodeKit,
                            pipeline: DemultiplexingPipeline(
                                runner: NativeToolRunner(),
                                cutadaptVersionOverride: cutadaptVersion
                            ),
                            progress: progress
                        )
                    }
                }

                while let chunk = try await group.next() {
                    processedInputChunks += 1
                    progress(
                        physicalChunkProgress(processed: processedInputChunks),
                        "Processed \(processedInputChunks)/\(inputFASTQs.count) chunks (\(chunk.inputName); \(chunk.assignedReadCount) assigned, \(chunk.unassignedReadCount) unassigned)"
                    )
                    pendingChunks[chunk.ordinal] = chunk
                    while let ready = pendingChunks.removeValue(forKey: nextAppendOrdinal) {
                        try await consume(ready)
                        nextAppendOrdinal += 1
                    }
                    if submittedInputIndex < inputFASTQs.count {
                        let inputIndex = submittedInputIndex
                        submittedInputIndex += 1
                        let inputFASTQ = inputFASTQs[inputIndex]
                        group.addTask {
                            try await Self.runCutadaptChunk(
                                inputFASTQ: inputFASTQ,
                                inputIndex: inputIndex,
                                inputCount: inputFASTQs.count,
                                chunkOrdinal: inputIndex + 1,
                                tempRoot: tempRoot,
                                request: request,
                                barcodeKit: barcodeKit,
                                pipeline: DemultiplexingPipeline(
                                    runner: NativeToolRunner(),
                                    cutadaptVersionOverride: cutadaptVersion
                                ),
                                progress: progress
                            )
                        }
                    }
                }
            }
        } else {
            var processedInputChunks = 0
            for (inputIndex, inputFASTQ) in inputFASTQs.enumerated() {
                var sliceCount = 0
                var chunkAssignedReadCount = 0
                var chunkUnassignedReadCount = 0
                try await forEachSlice(
                    inputFASTQ: inputFASTQ,
                    inputIndex: inputIndex,
                    tempRoot: tempRoot,
                    maxReadsPerSlice: request.maxReadsPerSlice,
                    maxInputBytesPerCutadapt: request.maxInputBytesPerCutadapt
                ) { slice in
                    chunkOrdinal += 1
                    let chunk = try await Self.runCutadaptChunk(
                        inputFASTQ: slice,
                        inputIndex: inputIndex,
                        inputCount: inputFASTQs.count,
                        chunkOrdinal: chunkOrdinal,
                        tempRoot: tempRoot,
                        request: request,
                        barcodeKit: barcodeKit,
                        pipeline: pipeline,
                        progress: progress
                    )
                    sliceCount += 1
                    chunkAssignedReadCount += chunk.assignedReadCount
                    chunkUnassignedReadCount += chunk.unassignedReadCount
                    try await consume(chunk)
                }
                processedInputChunks += 1
                progress(
                    physicalChunkProgress(processed: processedInputChunks),
                    "Processed \(processedInputChunks)/\(inputFASTQs.count) chunks (\(inputFASTQ.lastPathComponent); \(sliceCount) cutadapt slice(s), \(chunkAssignedReadCount) assigned, \(chunkUnassignedReadCount) unassigned)"
                )
            }
        }

        guard !buildersBySample.isEmpty else {
            throw ONTPacBioBarcodeDemuxMaterializerError.noSampleOutputs
        }

        progress(0.92, "Finalizing sample FASTQ bundles...")
        var sampleOutputs: [SampleOutput] = []
        for builder in buildersBySample.values.sorted(by: {
            $0.sampleID.localizedStandardCompare($1.sampleID) == .orderedAscending
        })
        {
            sampleOutputs.append(
                try await builder.finalize(
                    inputURL: request.inputURL,
                    barcodeDefinitionsURL: request.barcodeDefinitionsURL,
                    cutadaptVersion: cutadaptVersion
                )
            )
        }

        let manifestURL = request.outputDirectory.appendingPathComponent(Self.manifestFilename)
        let sampleTotals: [String: Int] = Dictionary(uniqueKeysWithValues: sampleOutputs.map {
            ($0.sampleID, $0.readCount)
        })
        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "toolName": "lungfish fastq ont-pacbio-barcode-demux",
            "input": request.inputURL.path,
            "barcodes": request.barcodeDefinitionsURL.path,
            "outputDirectory": request.outputDirectory.path,
            "inputChunkCount": inputFASTQs.count,
            "executedCutadaptChunkCount": executedChunkCount,
            "inputReadCount": inputReadCount,
            "assignedReadCount": assignedReadCount,
            "unassignedReadCount": unassignedReadCount,
            "payloadCompression": "gzip",
            "cutadaptThreadsPerChunk": request.threads,
            "requestedChunkJobs": request.chunkJobs,
            "chunkJobs": effectiveChunkJobs,
            "maxReadsPerSlice": request.maxReadsPerSlice,
            "maxInputBytesPerCutadapt": request.maxInputBytesPerCutadapt,
            "sampleTotals": sampleTotals,
            "samples": sampleOutputs.map { $0.manifestItem },
            "cutadaptRuns": cutadaptRuns.map { run in
                [
                    "input": run.inputPath,
                    "argv": run.argv,
                    "exitStatus": run.exitStatus,
                    "wallTimeSeconds": run.wallTimeSeconds,
                    "stderr": run.stderr as Any,
                ]
            },
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: manifestURL, options: .atomic)

        progress(1.0, "PacBio barcode demultiplexing complete")
        return ONTPacBioBarcodeDemuxMaterializationResult(
            outputDirectory: request.outputDirectory,
            manifestURL: manifestURL,
            outputBundleURLs: sampleOutputs.map { $0.bundleURL },
            inputChunkCount: inputFASTQs.count,
            executedCutadaptChunkCount: executedChunkCount,
            inputReadCount: inputReadCount,
            assignedReadCount: assignedReadCount,
            unassignedReadCount: unassignedReadCount,
            chunkJobs: effectiveChunkJobs,
            cutadaptRuns: cutadaptRuns
        )
    }

    private static func requiresSubSlicing(
        _ inputFASTQ: URL,
        maxReadsPerSlice: Int,
        maxInputBytesPerCutadapt: Int64
    ) -> Bool {
        maxReadsPerSlice > 0 && inputFASTQ.fileSizeBytes > maxInputBytesPerCutadapt
    }

    private static func runCutadaptChunk(
        inputFASTQ: URL,
        inputIndex: Int,
        inputCount: Int,
        chunkOrdinal: Int,
        tempRoot: URL,
        request: ONTPacBioBarcodeDemuxMaterializationRequest,
        barcodeKit: BarcodeKitDefinition,
        pipeline: DemultiplexingPipeline,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ChunkMaterialization {
        let chunkOutputDirectory = tempRoot.appendingPathComponent(
            String(format: "cutadapt-%05d", chunkOrdinal),
            isDirectory: true
        )
        progress(
            0.02,
            "Running cutadapt on chunk \(inputIndex + 1)/\(inputCount): \(inputFASTQ.lastPathComponent)"
        )
        let result = try await pipeline.run(
            config: DemultiplexConfig(
                inputURL: inputFASTQ,
                barcodeKit: barcodeKit,
                outputDirectory: chunkOutputDirectory,
                barcodeLocation: .bothEnds,
                trimBarcodes: true,
                unassignedDisposition: .keep,
                threads: request.threads
            ),
            progress: { _, _ in }
        )
        guard let nativeCommand = result.nativeCommand else {
            throw ONTPacBioBarcodeDemuxMaterializerError.noCutadaptCommand(inputFASTQ)
        }
        let assignedReadCount: Int = result.manifest.barcodes.reduce(0) { $0 + $1.readCount }
        let unassignedReadCount: Int = result.manifest.unassigned.readCount
        return ChunkMaterialization(
            ordinal: chunkOrdinal,
            inputName: inputFASTQ.lastPathComponent,
            outputDirectory: chunkOutputDirectory,
            result: result,
            cutadaptRun: ONTPacBioBarcodeDemuxCutadaptRun(
                inputPath: inputFASTQ.path,
                argv: nativeCommand,
                exitStatus: 0,
                wallTimeSeconds: result.wallClockSeconds,
                stderr: nil
            ),
            assignedReadCount: assignedReadCount,
            unassignedReadCount: unassignedReadCount,
            inputReadCount: assignedReadCount + unassignedReadCount
        )
    }

    private struct ChunkMaterialization: Sendable {
        let ordinal: Int
        let inputName: String
        let outputDirectory: URL
        let result: DemultiplexResult
        let cutadaptRun: ONTPacBioBarcodeDemuxCutadaptRun
        let assignedReadCount: Int
        let unassignedReadCount: Int
        let inputReadCount: Int
    }

    private func forEachSlice(
        inputFASTQ: URL,
        inputIndex: Int,
        tempRoot: URL,
        maxReadsPerSlice: Int,
        maxInputBytesPerCutadapt: Int64,
        body: (URL) async throws -> Void
    ) async throws {
        guard maxReadsPerSlice > 0,
              inputFASTQ.fileSizeBytes > maxInputBytesPerCutadapt else {
            try await body(inputFASTQ)
            return
        }

        let sliceDirectory = tempRoot.appendingPathComponent(
            String(format: "slices-%05d", inputIndex + 1),
            isDirectory: true
        )
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: sliceDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sliceDirectory) }

        var currentHandle: FileHandle?
        var currentURL: URL?
        var readsInSlice = 0
        var totalReads = 0
        var recordLines: [String] = []
        recordLines.reserveCapacity(4)

        func openNextSlice() throws {
            try currentHandle?.close()
            let url = sliceDirectory.appendingPathComponent(
                String(format: "slice-%05d.fastq", totalReads / maxReadsPerSlice + 1)
            )
            fileManager.createFile(atPath: url.path, contents: nil)
            currentHandle = try FileHandle(forWritingTo: url)
            currentURL = url
            readsInSlice = 0
        }

        func closeCurrentSlice() throws -> URL? {
            guard let url = currentURL else { return nil }
            try currentHandle?.close()
            currentHandle = nil
            currentURL = nil
            return url
        }

        for try await line in inputFASTQ.linesAutoDecompressing() {
            recordLines.append(line)
            guard recordLines.count == 4 else { continue }
            if currentHandle == nil {
                try openNextSlice()
            } else if readsInSlice >= maxReadsPerSlice, let finishedURL = try closeCurrentSlice() {
                try await body(finishedURL)
                try? fileManager.removeItem(at: finishedURL)
                try openNextSlice()
            }
            let text = recordLines.joined(separator: "\n") + "\n"
            try currentHandle?.write(contentsOf: Data(text.utf8))
            readsInSlice += 1
            totalReads += 1
            recordLines.removeAll(keepingCapacity: true)
            if totalReads % 10_000 == 0 {
                try Task.checkCancellation()
            }
        }
        if !recordLines.isEmpty {
            throw FASTQError.incompleteRecord(line: totalReads * 4 + recordLines.count)
        }
        if let finishedURL = try closeCurrentSlice() {
            try await body(finishedURL)
            try? fileManager.removeItem(at: finishedURL)
        }
    }

    private func appendSampleOutputs(
        from chunkResult: DemultiplexResult,
        into outputDirectory: URL,
        buildersBySample: inout [String: SampleBuilder]
    ) async throws {
        let countsByBarcode = Dictionary(uniqueKeysWithValues: chunkResult.manifest.barcodes.map {
            ($0.barcodeID, (readCount: $0.readCount, baseCount: $0.baseCount))
        })

        for chunkBundleURL in chunkResult.outputBundleURLs {
            let sampleID = chunkBundleURL.deletingPathExtension().lastPathComponent
            guard let payloadURL = FASTQBundle.resolvePrimaryFASTQURL(for: chunkBundleURL),
                  let counts = countsByBarcode[sampleID],
                  counts.readCount > 0 else {
                continue
            }
            let builder: SampleBuilder
            if let existing = buildersBySample[sampleID] {
                builder = existing
            } else {
                builder = try SampleBuilder(sampleID: sampleID, outputDirectory: outputDirectory)
                buildersBySample[sampleID] = builder
            }
            try await builder.append(payloadURL, readCount: counts.readCount, baseCount: counts.baseCount)
        }
    }

    private final class SampleBuilder {
        let sampleID: String
        let bundleURL: URL
        let fastqURL: URL
        private let statisticsCollector = FASTQStatisticsCollector()
        private(set) var readCount = 0
        private(set) var baseCount: Int64 = 0

        init(sampleID: String, outputDirectory: URL) throws {
            self.sampleID = sampleID
            self.bundleURL = outputDirectory.appendingPathComponent(
                "\(sampleID).\(FASTQBundle.directoryExtension)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            self.fastqURL = bundleURL.appendingPathComponent("\(sampleID).fastq.gz")
            FileManager.default.createFile(atPath: fastqURL.path, contents: nil)
        }

        func append(_ sourceURL: URL, readCount: Int, baseCount: Int64) async throws {
            let reader = FASTQReader(validateSequence: false)
            for try await record in reader.records(from: sourceURL) {
                statisticsCollector.process(record)
            }

            let input = try FileHandle(forReadingFrom: sourceURL)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: fastqURL)
            defer { try? output.close() }
            try output.seekToEnd()
            while true {
                let data = input.readData(ofLength: 1_048_576)
                if data.isEmpty { break }
                try output.write(contentsOf: data)
            }
            self.readCount += readCount
            self.baseCount += baseCount
        }

        func finalize(
            inputURL: URL,
            barcodeDefinitionsURL: URL,
            cutadaptVersion: String
        ) async throws -> SampleOutput {
            let checksum = try PayloadChecksum.sha256Hex(fileAt: fastqURL)
            let operation = FASTQDerivativeOperation(
                kind: .demultiplex,
                barcodeID: sampleID,
                sampleName: sampleID,
                toolUsed: "cutadapt",
                toolVersion: cutadaptVersion,
                toolCommand: "lungfish fastq ont-pacbio-barcode-demux"
            )
            let manifest = FASTQDerivedBundleManifest(
                name: sampleID,
                parentBundleRelativePath: ".",
                rootBundleRelativePath: ".",
                rootFASTQFilename: fastqURL.lastPathComponent,
                payload: .full(fastqFilename: fastqURL.lastPathComponent),
                lineage: [operation],
                operation: operation,
                cachedStatistics: statisticsCollector.finalize(),
                pairingMode: nil,
                sequenceFormat: .fastq,
                provenance: SampleProvenance(
                    sampleID: sampleID,
                    libraryPrep: "Full-length MHC ONT amplicon with PacBio barcode pairs",
                    notes: "Materialized per-sample ONT reads after chunked cutadapt demultiplexing with PacBio barcode pairs from \(barcodeDefinitionsURL.lastPathComponent). Source: \(inputURL.path)"
                ),
                payloadChecksums: PayloadChecksum(checksums: [fastqURL.lastPathComponent: checksum]),
                materializationState: .materialized(checksum: checksum)
            )
            try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
            return SampleOutput(
                sampleID: sampleID,
                bundleURL: bundleURL.standardizedFileURL,
                fastqURL: fastqURL.standardizedFileURL,
                readCount: readCount,
                baseCount: baseCount,
                checksum: checksum
            )
        }
    }

    private struct SampleOutput: Sendable {
        let sampleID: String
        let bundleURL: URL
        let fastqURL: URL
        let readCount: Int
        let baseCount: Int64
        let checksum: String

        var manifestItem: [String: Any] {
            [
                "sample": sampleID,
                "bundle": bundleURL.lastPathComponent,
                "fastq": fastqURL.path,
                "readCount": readCount,
                "baseCount": baseCount,
                "sha256": checksum,
            ]
        }
    }
}

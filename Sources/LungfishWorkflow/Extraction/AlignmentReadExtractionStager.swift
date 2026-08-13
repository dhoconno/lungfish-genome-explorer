// AlignmentReadExtractionStager.swift - Alignment evidence staging workflow
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// Runtime identity resolved for one native scientific tool execution.
public struct AlignmentReadExtractionToolIdentity: Sendable, Equatable {
    public let executablePath: String?
    public let executableChecksumSHA256: String?
    public let version: String

    public init(
        executablePath: String?,
        executableChecksumSHA256: String?,
        version: String
    ) {
        self.executablePath = executablePath
        self.executableChecksumSHA256 = executableChecksumSHA256
        self.version = version
    }
}

public typealias AlignmentReadExtractionProcessRunner = @Sendable (
    NativeTool,
    [String],
    TimeInterval
) async throws -> NativeToolResult

public typealias AlignmentReadExtractionToolIdentityResolver = @Sendable (
    NativeTool
) async -> AlignmentReadExtractionToolIdentity

/// Stages scientific alignment read extraction inside a unique transaction
/// directory. No caller-provided output path is ever passed to a subprocess.
public final class AlignmentReadExtractionStager: @unchecked Sendable {
    private let processRunner: AlignmentReadExtractionProcessRunner
    private let toolIdentityResolver: AlignmentReadExtractionToolIdentityResolver

    public init(
        toolRunner: NativeToolRunner = .shared,
        processRunner: AlignmentReadExtractionProcessRunner? = nil,
        toolIdentityResolver: AlignmentReadExtractionToolIdentityResolver? = nil
    ) {
        self.processRunner = processRunner ?? { tool, arguments, timeout in
            try await toolRunner.run(tool, arguments: arguments, timeout: timeout)
        }
        self.toolIdentityResolver = toolIdentityResolver ?? { tool in
            let executableURL = try? await toolRunner.toolPath(for: tool)
            let executableChecksum = executableURL.flatMap { try? ProvenanceFileHasher.sha256(of: $0) }
            let version = await toolRunner.getToolVersion(tool) ?? "unknown"
            return AlignmentReadExtractionToolIdentity(
                executablePath: executableURL?.path,
                executableChecksumSHA256: executableChecksum,
                version: version
            )
        }
    }

    /// Stages a selected region from the exact BAM/CRAM and explicit index
    /// supplied by the immutable App context. No header-based fuzzy matching,
    /// adjacent-index discovery, or fallback-to-all behavior is used here.
    public func stageRegion(
        config: BAMRegionExtractionConfig
    ) async throws -> AlignmentReadExtractionTransaction {
        var records: [AlignmentReadExtractionExecutionRecord] = []
        let startedAt = Date()
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: config.bamURL.path) else {
            throw failure(
                .missingInput,
                "Alignment evidence is missing: \(config.bamURL.path)",
                records: records
            )
        }
        guard let indexURL = config.indexURL else {
            throw failure(
                .missingInput,
                "An explicit alignment index is required for region extraction.",
                records: records
            )
        }
        guard fileManager.fileExists(atPath: indexURL.path) else {
            throw failure(
                .missingInput,
                "Alignment index is missing: \(indexURL.path)",
                records: records
            )
        }
        guard !config.regions.isEmpty, !config.fallbackToAll else {
            throw failure(
                .missingInput,
                "Selected-region extraction requires an explicit non-empty region and never falls back to all reads.",
                records: records
            )
        }

        let transactionDirectory: URL
        do {
            transactionDirectory = try ProjectTempDirectory.createFromContext(
                prefix: "lungfish-alignment-read-extraction-",
                contextURL: config.bamURL
            )
        } catch {
            throw failure(
                .launchFailed,
                "Could not create an extraction transaction directory: \(error.localizedDescription)",
                records: records
            )
        }
        var shouldCleanUp = true
        defer {
            if shouldCleanUp {
                try? fileManager.removeItem(at: transactionDirectory)
            }
        }

        let baseName = ExtractionBundleNaming.sanitizeFilename(config.outputBaseName)
        let filteredBAM = transactionDirectory.appendingPathComponent("\(baseName).filtered.bam")
        let viewArguments = config.explicitViewArguments(outputBAM: filteredBAM)
        let viewRecord = try await runCollectingFailures(
            tool: .samtools,
            arguments: viewArguments,
            inputURLs: [config.bamURL, indexURL] + (config.decodingReferenceURL.map { [$0] } ?? []),
            outputURLs: [filteredBAM],
            visibleOptions: regionVisibleOptions(config),
            resolvedDefaults: regionResolvedDefaults(config),
            accumulatedRecords: records
        )
        records.append(viewRecord.record)
        guard viewRecord.result.isSuccess else {
            throw failure(
                .subprocessFailed,
                "samtools view failed: \(viewRecord.result.stderr)",
                records: records
            )
        }

        let countRecord = try await runCollectingFailures(
            tool: .samtools,
            arguments: ["view", "-c", filteredBAM.path],
            inputURLs: [filteredBAM],
            outputURLs: [],
            visibleOptions: [:],
            resolvedDefaults: [:],
            accumulatedRecords: records
        )
        records.append(countRecord.record)
        guard countRecord.result.isSuccess else {
            throw failure(
                .subprocessFailed,
                "samtools view -c failed: \(countRecord.result.stderr)",
                records: records
            )
        }
        let readCount = Int(
            countRecord.result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        ) ?? 0
        guard readCount > 0 else {
            throw failure(
                .emptyExtraction,
                "The selected region contained no reads after the requested filters.",
                records: records
            )
        }

        let outputFASTQ = transactionDirectory.appendingPathComponent("\(baseName).fastq")
        let otherFASTQ = transactionDirectory.appendingPathComponent("\(baseName).other.fastq")
        let r1FASTQ = transactionDirectory.appendingPathComponent("\(baseName).r1.fastq")
        let r2FASTQ = transactionDirectory.appendingPathComponent("\(baseName).r2.fastq")
        let singletonFASTQ = transactionDirectory.appendingPathComponent("\(baseName).singletons.fastq")
        let fastqRecord = try await runCollectingFailures(
            tool: .samtools,
            arguments: [
                "fastq", "-F", "0",
                "-0", otherFASTQ.path,
                "-1", r1FASTQ.path,
                "-2", r2FASTQ.path,
                "-s", singletonFASTQ.path,
                filteredBAM.path,
            ],
            inputURLs: [filteredBAM],
            outputURLs: [otherFASTQ, r1FASTQ, r2FASTQ, singletonFASTQ],
            visibleOptions: [
                "recordClassPolicy": .string("preserve primary records selected by samtools view"),
                "matePolicy": .string("retain mates emitted by filtered alignment records"),
            ],
            resolvedDefaults: ["samtoolsFastqExcludedFlags": .integer(0)],
            accumulatedRecords: records
        )
        records.append(fastqRecord.record)
        guard fastqRecord.result.isSuccess else {
            throw failure(
                .subprocessFailed,
                "samtools fastq failed: \(fastqRecord.result.stderr)",
                records: records
            )
        }

        do {
            try mergeFASTQParts(
                [otherFASTQ, singletonFASTQ, r1FASTQ, r2FASTQ],
                to: outputFASTQ
            )
        } catch {
            let completedAt = Date()
            records.append(
                internalRecord(
                    stage: .payloadStaging,
                    toolName: "lungfish alignment FASTQ merge",
                    argv: ["Lungfish.app", "alignment", "extract", "merge-fastq", outputFASTQ.path],
                    inputs: descriptors(forExisting: [otherFASTQ, singletonFASTQ, r1FASTQ, r2FASTQ], role: .input),
                    outputs: [],
                    exitStatus: 1,
                    startedAt: completedAt,
                    completedAt: completedAt,
                    stderr: error.localizedDescription
                )
            )
            throw failure(
                .subprocessFailed,
                "Could not materialize staged FASTQ payload: \(error.localizedDescription)",
                records: records
            )
        }
        guard fileSize(of: outputFASTQ) > 0 else {
            throw failure(
                .emptyExtraction,
                "The selected region produced no sequence-bearing records.",
                records: records
            )
        }
        let completedAt = Date()
        records.append(
            internalRecord(
                stage: .payloadStaging,
                toolName: "lungfish alignment FASTQ merge",
                argv: ["Lungfish.app", "alignment", "extract", "merge-fastq", outputFASTQ.path],
                inputs: descriptors(forExisting: [otherFASTQ, singletonFASTQ, r1FASTQ, r2FASTQ], role: .input),
                outputs: descriptors(forExisting: [outputFASTQ], role: .output, format: .fastq),
                exitStatus: 0,
                startedAt: completedAt,
                completedAt: completedAt
            )
        )

        do {
            let transaction = try AlignmentReadExtractionTransaction(
                stagingDirectoryURL: transactionDirectory,
                stagedFiles: [
                    .init(
                        stagedURL: outputFASTQ,
                        relativeFinalPath: outputFASTQ.lastPathComponent,
                        format: .fastq
                    ),
                ],
                readCount: readCount,
                pairedEnd: false,
                executionRecords: records,
                startedAt: startedAt
            )
            shouldCleanUp = false
            return transaction
        } catch let transactionFailure as AlignmentReadExtractionFailure {
            throw transactionFailure
        } catch {
            throw failure(
                .subprocessFailed,
                "Could not finalize alignment extraction transaction: \(error.localizedDescription)",
                records: records
            )
        }
    }

    /// Stages selected read names from retained source FASTQs. The legacy
    /// caller output directory is deliberately ignored: every payload remains
    /// transaction-owned until publication.
    public func stageReadIDsFromSourceFASTQs(
        config: ReadIDExtractionConfig,
        recordsWithoutSequence: Int = 0,
        missingSequenceMessage: String? = nil
    ) async throws -> AlignmentReadExtractionTransaction {
        let fileManager = FileManager.default
        var records: [AlignmentReadExtractionExecutionRecord] = []
        let startedAt = Date()
        guard !config.sourceFASTQs.isEmpty, !config.readIDs.isEmpty else {
            throw failure(.missingInput, "Source FASTQs and selected read names are required.", records: records)
        }
        for source in config.sourceFASTQs where !fileManager.fileExists(atPath: source.path) {
            throw failure(.missingInput, "Source FASTQ is missing: \(source.path)", records: records)
        }

        let transactionDirectory: URL
        do {
            transactionDirectory = try ProjectTempDirectory.createFromContext(
                prefix: "lungfish-alignment-source-read-extraction-",
                contextURL: config.sourceFASTQs[0]
            )
        } catch {
            throw failure(.launchFailed, "Could not create an extraction transaction directory: \(error.localizedDescription)", records: records)
        }
        var shouldCleanUp = true
        defer {
            if shouldCleanUp { try? fileManager.removeItem(at: transactionDirectory) }
        }

        let readNameURL = transactionDirectory.appendingPathComponent("selected_read_names.txt")
        do {
            let patterns = config.keepReadPairs
                ? config.readIDs.map(Self.pairedReadPattern)
                : Array(config.readIDs)
            try patterns.sorted().joined(separator: "\n")
                .write(to: readNameURL, atomically: true, encoding: .utf8)
        } catch {
            throw failure(.launchFailed, "Could not stage selected read names: \(error.localizedDescription)", records: records)
        }

        let baseName = ExtractionBundleNaming.sanitizeFilename(config.outputBaseName)
        var stagedFiles: [AlignmentReadExtractionStagedFile] = []
        let visibleOptions: [String: ParameterValue] = [
            "keepReadPairs": .boolean(config.keepReadPairs),
            "selectedReadNameCount": .integer(config.readIDs.count),
        ]
        let resolvedDefaults: [String: ParameterValue] = [
            "sourcePreference": .string("retained-source-fastq"),
            "seqkitThreads": .integer(4),
            "readNameMatching": .string(
                config.keepReadPairs
                    ? "anchored seqkit identifier regex with optional /1 or /2 mate suffix"
                    : "exact seqkit identifier field"
            ),
        ]

        for (index, sourceURL) in config.sourceFASTQs.enumerated() {
            let suffix = config.sourceFASTQs.count == 1 ? "" : "_R\(index + 1)"
            let relativePath = "\(baseName)\(suffix).fastq.gz"
            let outputURL = transactionDirectory.appendingPathComponent(relativePath)
            var arguments = ["grep"]
            if config.keepReadPairs { arguments.append("-r") }
            arguments += [
                "-f", readNameURL.path, sourceURL.path,
                "-o", outputURL.path, "--threads", "4",
            ]
            let execution = try await runCollectingFailures(
                tool: .seqkit,
                arguments: arguments,
                inputURLs: [sourceURL, readNameURL],
                outputURLs: [outputURL],
                visibleOptions: visibleOptions,
                resolvedDefaults: resolvedDefaults,
                accumulatedRecords: records
            )
            records.append(execution.record)
            guard execution.result.isSuccess else {
                throw failure(.subprocessFailed, "seqkit grep failed: \(execution.result.stderr)", records: records)
            }
            guard fileSize(of: outputURL) > 0 else {
                throw failure(.emptyExtraction, "Selected read names produced an empty FASTQ payload.", records: records)
            }
            stagedFiles.append(.init(stagedURL: outputURL, relativeFinalPath: relativePath, format: .fastq))
        }

        let countExecution = try await runCollectingFailures(
            tool: .seqkit,
            arguments: ["stats", "-T", stagedFiles[0].stagedURL.path],
            inputURLs: [stagedFiles[0].stagedURL],
            outputURLs: [],
            visibleOptions: visibleOptions,
            resolvedDefaults: resolvedDefaults,
            accumulatedRecords: records
        )
        records.append(countExecution.record)
        guard countExecution.result.isSuccess else {
            throw failure(.subprocessFailed, "seqkit stats failed: \(countExecution.result.stderr)", records: records)
        }
        let readCount = parseSeqkitReadCount(countExecution.result.stdout)
        guard readCount > 0 else {
            throw failure(.emptyExtraction, "Selected read names produced no sequence records.", records: records)
        }

        let transaction = try AlignmentReadExtractionTransaction(
            stagingDirectoryURL: transactionDirectory,
            stagedFiles: stagedFiles,
            readCount: readCount,
            pairedEnd: config.isPairedEnd,
            recordsWithoutSequence: recordsWithoutSequence,
            missingSequenceMessage: missingSequenceMessage,
            executionRecords: records,
            startedAt: startedAt
        )
        shouldCleanUp = false
        return transaction
    }

    /// Stages selected QNAMEs directly from the captured alignment evidence,
    /// retaining the explicit record-class and mate policies in every tool
    /// execution record.
    public func stageReadIDsFromBAM(
        config: ReadIDBAMExtractionConfig,
        recordsWithoutSequence: Int = 0,
        missingSequenceMessage: String? = nil
    ) async throws -> AlignmentReadExtractionTransaction {
        let fileManager = FileManager.default
        var records: [AlignmentReadExtractionExecutionRecord] = []
        let startedAt = Date()
        guard fileManager.fileExists(atPath: config.bamURL.path) else {
            throw failure(.missingInput, "Alignment evidence is missing: \(config.bamURL.path)", records: records)
        }
        guard !config.readIDs.isEmpty else {
            throw failure(.missingInput, "At least one selected read name is required.", records: records)
        }

        let transactionDirectory: URL
        do {
            transactionDirectory = try ProjectTempDirectory.createFromContext(
                prefix: "lungfish-alignment-qname-extraction-",
                contextURL: config.bamURL
            )
        } catch {
            throw failure(.launchFailed, "Could not create an extraction transaction directory: \(error.localizedDescription)", records: records)
        }
        var shouldCleanUp = true
        defer {
            if shouldCleanUp { try? fileManager.removeItem(at: transactionDirectory) }
        }

        let baseName = ExtractionBundleNaming.sanitizeFilename(config.outputBaseName)
        let readNameURL = transactionDirectory.appendingPathComponent("\(baseName)_read_names.txt")
        do {
            try config.readIDs.sorted().joined(separator: "\n")
                .write(to: readNameURL, atomically: true, encoding: .utf8)
        } catch {
            throw failure(.launchFailed, "Could not stage selected read names: \(error.localizedDescription)", records: records)
        }

        let visibleOptions: [String: ParameterValue] = [
            "includeSecondary": .boolean(config.includeSecondary),
            "excludeDuplicates": .boolean(config.excludeDuplicates),
            "format": .string(config.format.rawValue),
            "selectedReadNameCount": .integer(config.readIDs.count),
        ]
        let resolvedDefaults: [String: ParameterValue] = [
            "flagFilter": .integer(config.flagFilter),
            "matePolicy": .string("samtools-qname-matches-both-mates; unmatched-mates-to-singletons"),
            "conversionExcludedFlags": .integer(0),
        ]

        let filteredBAM = transactionDirectory.appendingPathComponent("filtered.bam")
        var viewArguments = ["view", "-b", "-N", readNameURL.path]
        if config.flagFilter != 0 { viewArguments += ["-F", String(config.flagFilter)] }
        viewArguments += ["-o", filteredBAM.path, config.bamURL.path]
        let viewExecution = try await runCollectingFailures(
            tool: .samtools,
            arguments: viewArguments,
            inputURLs: [config.bamURL, readNameURL],
            outputURLs: [filteredBAM],
            visibleOptions: visibleOptions,
            resolvedDefaults: resolvedDefaults,
            accumulatedRecords: records
        )
        records.append(viewExecution.record)
        guard viewExecution.result.isSuccess else {
            throw failure(.subprocessFailed, "samtools view failed: \(viewExecution.result.stderr)", records: records)
        }

        let countExecution = try await runCollectingFailures(
            tool: .samtools,
            arguments: ["view", "-c", filteredBAM.path],
            inputURLs: [filteredBAM],
            outputURLs: [],
            visibleOptions: visibleOptions,
            resolvedDefaults: resolvedDefaults,
            accumulatedRecords: records
        )
        records.append(countExecution.record)
        guard countExecution.result.isSuccess else {
            throw failure(.subprocessFailed, "samtools view -c failed: \(countExecution.result.stderr)", records: records)
        }
        let readCount = Int(countExecution.result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard readCount > 0 else {
            throw failure(.emptyExtraction, "No selected read names matched the requested record policies.", records: records)
        }

        let collatedBAM = transactionDirectory.appendingPathComponent("collated.bam")
        let collateExecution = try await runCollectingFailures(
            tool: .samtools,
            arguments: ["collate", "-o", collatedBAM.path, filteredBAM.path],
            inputURLs: [filteredBAM],
            outputURLs: [collatedBAM],
            visibleOptions: visibleOptions,
            resolvedDefaults: resolvedDefaults,
            accumulatedRecords: records
        )
        records.append(collateExecution.record)
        guard collateExecution.result.isSuccess else {
            throw failure(.subprocessFailed, "samtools collate failed: \(collateExecution.result.stderr)", records: records)
        }

        let outputExtension = config.format.rawValue
        let outputURL = transactionDirectory.appendingPathComponent("\(baseName).\(outputExtension)")
        let singletonURL = transactionDirectory.appendingPathComponent("\(baseName)_singletons.\(outputExtension)")
        let otherURL = transactionDirectory.appendingPathComponent("\(baseName)_other.\(outputExtension)")
        let conversionExecution = try await runCollectingFailures(
            tool: .samtools,
            arguments: [
                config.format.rawValue, "-F", "0",
                "-0", otherURL.path,
                "-s", singletonURL.path,
                "-o", outputURL.path,
                collatedBAM.path,
            ],
            inputURLs: [collatedBAM],
            outputURLs: [outputURL, singletonURL, otherURL],
            visibleOptions: visibleOptions,
            resolvedDefaults: resolvedDefaults,
            accumulatedRecords: records
        )
        records.append(conversionExecution.record)
        guard conversionExecution.result.isSuccess else {
            throw failure(.subprocessFailed, "samtools \(config.format.rawValue) failed: \(conversionExecution.result.stderr)", records: records)
        }

        if fileSize(of: otherURL) > 0 {
            do { try appendFile(otherURL, to: outputURL) }
            catch {
                throw failure(.subprocessFailed, "Could not merge unpaired records: \(error.localizedDescription)", records: records)
            }
        }
        var stagedFiles: [AlignmentReadExtractionStagedFile] = []
        let format: FileFormat = config.format == .fasta ? .fasta : .fastq
        if fileSize(of: outputURL) > 0 {
            stagedFiles.append(.init(stagedURL: outputURL, relativeFinalPath: outputURL.lastPathComponent, format: format))
        }
        if fileSize(of: singletonURL) > 0 {
            stagedFiles.append(.init(stagedURL: singletonURL, relativeFinalPath: singletonURL.lastPathComponent, format: format))
        }
        stagedFiles.append(.init(stagedURL: readNameURL, relativeFinalPath: readNameURL.lastPathComponent, format: .text))
        guard stagedFiles.count > 1 else {
            throw failure(.emptyExtraction, "Selected read names produced no sequence-bearing records.", records: records)
        }

        let completedAt = Date()
        records.append(internalRecord(
            stage: .payloadStaging,
            toolName: "lungfish alignment extraction payload finalizer",
            argv: ["Lungfish.app", "alignment", "extract", "finalize-qname-payloads"],
            inputs: descriptors(forExisting: [outputURL, singletonURL, readNameURL], role: .input),
            outputs: descriptors(forExisting: stagedFiles.map(\.stagedURL), role: .output),
            exitStatus: 0,
            startedAt: completedAt,
            completedAt: completedAt
        ))

        let transaction = try AlignmentReadExtractionTransaction(
            stagingDirectoryURL: transactionDirectory,
            stagedFiles: stagedFiles,
            readCount: readCount,
            pairedEnd: true,
            recordsWithoutSequence: recordsWithoutSequence,
            missingSequenceMessage: missingSequenceMessage,
            executionRecords: records,
            startedAt: startedAt
        )
        shouldCleanUp = false
        return transaction
    }

    private func run(
        tool: NativeTool,
        arguments: [String],
        inputURLs: [URL],
        outputURLs: [URL],
        visibleOptions: [String: ParameterValue],
        resolvedDefaults: [String: ParameterValue]
    ) async throws -> (result: NativeToolResult, record: AlignmentReadExtractionExecutionRecord) {
        let startedAt = Date()
        let identity = await toolIdentityResolver(tool)
        do {
            try Task.checkCancellation()
            let result = try await processRunner(tool, arguments, 7200)
            let completedAt = Date()
            let argv = result.arguments.isEmpty
                ? ([identity.executablePath ?? tool.executableName] + arguments)
                : result.arguments
            let record = AlignmentReadExtractionExecutionRecord(
                stage: .payloadStaging,
                toolName: tool.rawValue,
                toolVersion: identity.version,
                executablePath: identity.executablePath,
                executableChecksumSHA256: identity.executableChecksumSHA256,
                argv: argv,
                visibleOptions: visibleOptions,
                resolvedDefaults: resolvedDefaults,
                inputs: descriptors(forExisting: inputURLs, role: .input),
                outputs: descriptors(forExisting: outputURLs, role: .output),
                exitStatus: Int(result.exitCode),
                startedAt: startedAt,
                completedAt: completedAt,
                stderr: result.stderr
            )
            return (result, record)
        } catch is CancellationError {
            let completedAt = Date()
            let record = AlignmentReadExtractionExecutionRecord(
                stage: .payloadStaging,
                toolName: tool.rawValue,
                toolVersion: identity.version,
                executablePath: identity.executablePath,
                executableChecksumSHA256: identity.executableChecksumSHA256,
                argv: [identity.executablePath ?? tool.executableName] + arguments,
                visibleOptions: visibleOptions,
                resolvedDefaults: resolvedDefaults,
                inputs: descriptors(forExisting: inputURLs, role: .input),
                outputs: descriptors(forExisting: outputURLs, role: .output),
                exitStatus: nil,
                startedAt: startedAt,
                completedAt: completedAt,
                stderr: "Cancelled."
            )
            throw AlignmentReadExtractionFailure(
                kind: .cancelled,
                message: "Alignment extraction was cancelled while running \(tool.rawValue).",
                executionRecords: [record]
            )
        } catch {
            let completedAt = Date()
            let record = AlignmentReadExtractionExecutionRecord(
                stage: .payloadStaging,
                toolName: tool.rawValue,
                toolVersion: identity.version,
                executablePath: identity.executablePath,
                executableChecksumSHA256: identity.executableChecksumSHA256,
                argv: [identity.executablePath ?? tool.executableName] + arguments,
                visibleOptions: visibleOptions,
                resolvedDefaults: resolvedDefaults,
                inputs: descriptors(forExisting: inputURLs, role: .input),
                outputs: descriptors(forExisting: outputURLs, role: .output),
                exitStatus: nil,
                startedAt: startedAt,
                completedAt: completedAt,
                stderr: error.localizedDescription
            )
            throw AlignmentReadExtractionFailure(
                kind: .launchFailed,
                message: "Could not launch \(tool.rawValue): \(error.localizedDescription)",
                executionRecords: [record]
            )
        }
    }

    private func runCollectingFailures(
        tool: NativeTool,
        arguments: [String],
        inputURLs: [URL],
        outputURLs: [URL],
        visibleOptions: [String: ParameterValue],
        resolvedDefaults: [String: ParameterValue],
        accumulatedRecords: [AlignmentReadExtractionExecutionRecord]
    ) async throws -> (result: NativeToolResult, record: AlignmentReadExtractionExecutionRecord) {
        do {
            return try await run(
                tool: tool,
                arguments: arguments,
                inputURLs: inputURLs,
                outputURLs: outputURLs,
                visibleOptions: visibleOptions,
                resolvedDefaults: resolvedDefaults
            )
        } catch let failure as AlignmentReadExtractionFailure {
            throw AlignmentReadExtractionFailure(
                kind: failure.kind,
                message: failure.message,
                executionRecords: accumulatedRecords + failure.executionRecords
            )
        }
    }

    private func mergeFASTQParts(_ parts: [URL], to outputURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        fileManager.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        for part in parts where fileSize(of: part) > 0 {
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }
            while true {
                let data = input.readData(ofLength: 1 << 20)
                guard !data.isEmpty else { break }
                output.write(data)
            }
        }
    }

    private func appendFile(_ inputURL: URL, to outputURL: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: outputURL.path) {
            fileManager.createFile(atPath: outputURL.path, contents: nil)
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        try output.seekToEnd()
        let input = try FileHandle(forReadingFrom: inputURL)
        defer { try? input.close() }
        while true {
            let data = try input.read(upToCount: 1 << 20) ?? Data()
            guard !data.isEmpty else { break }
            try output.write(contentsOf: data)
        }
    }

    private func parseSeqkitReadCount(_ stdout: String) -> Int {
        let lines = stdout.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2 else { return 0 }
        let headers = lines[0].split(separator: "\t").map(String.init)
        let values = lines[1].split(separator: "\t").map(String.init)
        guard let index = headers.firstIndex(of: "num_seqs"), index < values.count else { return 0 }
        return Int(values[index].replacingOccurrences(of: ",", with: "")) ?? 0
    }

    private static func pairedReadPattern(_ readID: String) -> String {
        let baseID: String
        if readID.hasSuffix("/1") || readID.hasSuffix("/2") {
            baseID = String(readID.dropLast(2))
        } else {
            baseID = readID
        }
        return "^\(NSRegularExpression.escapedPattern(for: baseID))(?:/[12])?$"
    }

    private func descriptors(
        forExisting urls: [URL],
        role: FileRole,
        format: FileFormat? = nil
    ) -> [ProvenanceFileDescriptor] {
        urls.compactMap { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try? ProvenanceFileDescriptor.file(url: url, format: format, role: role)
        }
    }

    private func fileSize(of url: URL) -> UInt64 {
        (try? ProvenanceFileHasher.fileSize(of: url)) ?? 0
    }

    private func failure(
        _ kind: AlignmentReadExtractionFailureKind,
        _ message: String,
        records: [AlignmentReadExtractionExecutionRecord]
    ) -> AlignmentReadExtractionFailure {
        AlignmentReadExtractionFailure(kind: kind, message: message, executionRecords: records)
    }

    private func regionVisibleOptions(
        _ config: BAMRegionExtractionConfig
    ) -> [String: ParameterValue] {
        [
            "regionsOneBasedInclusive": .array(config.regions.map(ParameterValue.string)),
            "minimumMapQ": config.minMapQ.map(ParameterValue.integer) ?? .null,
            "excludedFlags": config.excludedFlags.map(ParameterValue.integer) ?? .null,
            "readGroups": .array(config.readGroups.map(ParameterValue.string)),
        ]
    }

    private func regionResolvedDefaults(
        _ config: BAMRegionExtractionConfig
    ) -> [String: ParameterValue] {
        [
            "explicitIndexRequired": .boolean(true),
            "fallbackToAll": .boolean(false),
            "deduplicateReads": .boolean(config.deduplicateReads),
            "regionCoordinateConvention": .string("one-based-inclusive samtools region derived from zero-based-half-open context"),
        ]
    }

    private func internalRecord(
        stage: AlignmentReadExtractionExecutionStage,
        toolName: String,
        argv: [String],
        inputs: [ProvenanceFileDescriptor],
        outputs: [ProvenanceFileDescriptor],
        exitStatus: Int?,
        startedAt: Date,
        completedAt: Date,
        stderr: String? = nil
    ) -> AlignmentReadExtractionExecutionRecord {
        AlignmentReadExtractionExecutionRecord(
            stage: stage,
            toolName: toolName,
            toolVersion: WorkflowRun.currentAppVersion,
            argv: argv,
            inputs: inputs,
            outputs: outputs,
            exitStatus: exitStatus,
            startedAt: startedAt,
            completedAt: completedAt,
            stderr: stderr
        )
    }
}

// OrientPipeline.swift - Orient FASTQ reads using vsearch
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishIO
import os.log

private let logger = Logger(subsystem: LogSubsystem.workflow, category: "OrientPipeline")

/// Configuration for the orient pipeline.
public struct OrientConfig: Sendable {
    /// Path to the input FASTQ file.
    public let inputURL: URL

    /// Path to the reference FASTA file (in the desired forward orientation).
    public let referenceURL: URL

    /// Word length for vsearch k-mer matching (3-15, default 12).
    public let wordLength: Int

    /// Low-complexity masking mode for the database ("dust" or "none").
    public let dbMask: String

    /// Low-complexity masking mode for queries ("dust" or "none").
    public let qMask: String

    /// Whether to save unoriented reads as a separate derivative.
    public let saveUnoriented: Bool

    /// Number of threads (0 = all cores).
    public let threads: Int

    /// Additional vsearch arguments appended verbatim after Lungfish-managed options.
    public let extraArguments: [String]

    public init(
        inputURL: URL,
        referenceURL: URL,
        wordLength: Int = 12,
        dbMask: String = "dust",
        qMask: String = "dust",
        saveUnoriented: Bool = true,
        threads: Int = 0,
        extraArguments: [String] = []
    ) {
        self.inputURL = inputURL
        self.referenceURL = referenceURL
        self.wordLength = wordLength
        self.dbMask = dbMask
        self.qMask = qMask
        self.saveUnoriented = saveUnoriented
        self.threads = threads
        self.extraArguments = extraArguments
    }

    public func vsearchArguments(
        orientedOutput: URL,
        tabbedOutput: URL,
        unmatchedOutput: URL?
    ) -> [String] {
        var args: [String] = [
            "--orient", inputURL.path,
            "--db", referenceURL.path,
            "--fastqout", orientedOutput.path,
            "--tabbedout", tabbedOutput.path,
            "--wordlength", String(wordLength),
            "--dbmask", dbMask,
            "--qmask", qMask,
            "--threads", String(threads),
        ]
        if let unmatchedOutput {
            args.append(contentsOf: ["--notmatched", unmatchedOutput.path])
        }
        args += extraArguments
        return args
    }

    public func vsearchArgumentsForTesting(
        orientedOutput: URL,
        tabbedOutput: URL,
        unmatchedOutput: URL?
    ) -> [String] {
        vsearchArguments(
            orientedOutput: orientedOutput,
            tabbedOutput: tabbedOutput,
            unmatchedOutput: unmatchedOutput
        )
    }
}

/// Result of an orient pipeline run.
public struct OrientResult: Sendable {
    /// Path to the oriented FASTQ output.
    public let orientedFASTQ: URL

    /// Path to the unoriented reads output (nil if saveUnoriented was false).
    public let unorientedFASTQ: URL?

    /// Path to the tabbed orientation results.
    public let tabbedOutput: URL

    /// Number of reads that were already in forward orientation.
    public let forwardCount: Int

    /// Number of reads that were reverse-complemented.
    public let reverseComplementedCount: Int

    /// Number of reads that could not be oriented.
    public let unmatchedCount: Int

    /// Total reads processed.
    public var totalCount: Int { forwardCount + reverseComplementedCount + unmatchedCount }

    /// Wall clock time in seconds.
    public let wallClockSeconds: Double
}

/// Optional caller context for pipeline-level orient provenance.
public struct OrientProvenanceContext: Sendable {
    public let workflowName: String
    public let argv: [String]
    public let reproducibleCommand: String?
    public let options: ProvenanceOptions?
    public let inputFileRecords: [FileRecord]?
    public let pathReplacements: [String: String]

    public init(
        workflowName: String = "lungfish orient",
        argv: [String] = [],
        reproducibleCommand: String? = nil,
        options: ProvenanceOptions? = nil,
        inputFileRecords: [FileRecord]? = nil,
        pathReplacements: [String: String] = [:]
    ) {
        self.workflowName = workflowName
        self.argv = argv
        self.reproducibleCommand = reproducibleCommand
        self.options = options
        self.inputFileRecords = inputFileRecords
        self.pathReplacements = pathReplacements
    }
}

/// Pipeline for orienting FASTQ reads against a reference using vsearch.
///
/// Uses `vsearch --orient` to determine the correct orientation of each read
/// relative to a reference sequence. Reads that are in reverse complement
/// orientation are RC'd to match the reference.
///
/// Results are stored as a lightweight orient-map TSV file rather than a
/// full copy of the oriented FASTQ.
public final class OrientPipeline: @unchecked Sendable {
    private let runner: NativeToolRunner

    public init(runner: NativeToolRunner? = nil) {
        if let runner {
            self.runner = runner
        } else {
            self.runner = NativeToolRunner()
        }
    }

    /// Runs the orient pipeline.
    ///
    /// - Parameters:
    ///   - config: Orient configuration
    ///   - progress: Progress callback (fraction 0-1, message)
    /// - Returns: OrientResult with paths and statistics
    public func run(
        config: OrientConfig,
        provenanceContext: OrientProvenanceContext? = nil,
        progress: @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> OrientResult {
        let startTime = Date()
        let fm = FileManager.default

        // Validate inputs exist
        guard fm.fileExists(atPath: config.inputURL.path) else {
            throw OrientPipelineError.inputNotFound(config.inputURL)
        }
        guard fm.fileExists(atPath: config.referenceURL.path) else {
            throw OrientPipelineError.referenceNotFound(config.referenceURL)
        }

        // Create work directory
        let workDir = try ProjectTempDirectory.create(
            prefix: "lungfish-orient-",
            contextURL: config.inputURL,
            policy: .requireProjectContext
        )

        progress(0.05, "Starting orientation against reference...")

        // Build vsearch arguments
        let orientedOutput = workDir.appendingPathComponent("oriented.fastq")
        let tabbedOutput = workDir.appendingPathComponent("orient-results.tsv")

        var unmatchedOutput: URL?
        if config.saveUnoriented {
            unmatchedOutput = workDir.appendingPathComponent("unoriented.fastq")
        }
        let args = config.vsearchArguments(
            orientedOutput: orientedOutput,
            tabbedOutput: tabbedOutput,
            unmatchedOutput: unmatchedOutput
        )

        progress(0.10, "Running vsearch orient...")

        let vsearchStart = Date()
        let result: NativeToolResult
        do {
            result = try await runner.run(
                .vsearch,
                arguments: args,
                workingDirectory: workDir,
                timeout: 1800
            )
        } catch {
            let vsearchEnd = Date()
            let failureMessage = toolFailureMessage(error)
            let failureResult = OrientResult(
                orientedFASTQ: orientedOutput,
                unorientedFASTQ: unmatchedOutput,
                tabbedOutput: tabbedOutput,
                forwardCount: 0,
                reverseComplementedCount: 0,
                unmatchedCount: 0,
                wallClockSeconds: Date().timeIntervalSince(startTime)
            )
            let vsearchVersion = await runner.getToolVersion(.vsearch) ?? "unknown"
            try writeProvenance(
                config: config,
                result: failureResult,
                vsearchResult: NativeToolResult(
                    exitCode: -1,
                    stdout: "",
                    stderr: failureMessage,
                    arguments: [NativeTool.vsearch.executableName] + args
                ),
                vsearchArguments: args,
                vsearchStartedAt: vsearchStart,
                vsearchCompletedAt: vsearchEnd,
                workflowStartedAt: startTime,
                workflowCompletedAt: Date(),
                vsearchVersion: vsearchVersion,
                context: provenanceContext
            )
            throw OrientPipelineError.vsearchFailed(failureMessage)
        }
        let vsearchEnd = Date()

        guard result.isSuccess else {
            let failureResult = OrientResult(
                orientedFASTQ: orientedOutput,
                unorientedFASTQ: unmatchedOutput,
                tabbedOutput: tabbedOutput,
                forwardCount: 0,
                reverseComplementedCount: 0,
                unmatchedCount: 0,
                wallClockSeconds: Date().timeIntervalSince(startTime)
            )
            let vsearchVersion = await runner.getToolVersion(.vsearch) ?? "unknown"
            try writeProvenance(
                config: config,
                result: failureResult,
                vsearchResult: result,
                vsearchArguments: args,
                vsearchStartedAt: vsearchStart,
                vsearchCompletedAt: vsearchEnd,
                workflowStartedAt: startTime,
                workflowCompletedAt: Date(),
                vsearchVersion: vsearchVersion,
                context: provenanceContext
            )
            throw OrientPipelineError.vsearchFailed(result.stderr)
        }

        progress(0.70, "Parsing orientation results...")

        // Parse the tabbed output to count orientations
        let forwardCount: Int
        let rcCount: Int
        let unmatchedCount: Int
        do {
            let counts = try parseOrientResults(tabbedOutput)
            forwardCount = counts.forward
            rcCount = counts.rc
            unmatchedCount = counts.unmatched
        } catch {
            let failureMessage = toolFailureMessage(error)
            let failureResult = OrientResult(
                orientedFASTQ: orientedOutput,
                unorientedFASTQ: unmatchedOutput,
                tabbedOutput: tabbedOutput,
                forwardCount: 0,
                reverseComplementedCount: 0,
                unmatchedCount: 0,
                wallClockSeconds: Date().timeIntervalSince(startTime)
            )
            let vsearchVersion = await runner.getToolVersion(.vsearch) ?? "unknown"
            try writeProvenance(
                config: config,
                result: failureResult,
                vsearchResult: result,
                vsearchArguments: args,
                vsearchStartedAt: vsearchStart,
                vsearchCompletedAt: vsearchEnd,
                workflowStartedAt: startTime,
                workflowCompletedAt: Date(),
                vsearchVersion: vsearchVersion,
                context: provenanceContext,
                workflowExitStatus: -1,
                workflowStderr: failureMessage
            )
            throw error
        }

        progress(0.90, "Orient complete: \(forwardCount) forward, \(rcCount) RC'd, \(unmatchedCount) unmatched")

        let elapsed = Date().timeIntervalSince(startTime)
        logger.info("Orient complete in \(String(format: "%.1f", elapsed))s: \(forwardCount) fwd, \(rcCount) rc, \(unmatchedCount) unmatched")

        let orientResult = OrientResult(
            orientedFASTQ: orientedOutput,
            unorientedFASTQ: unmatchedOutput,
            tabbedOutput: tabbedOutput,
            forwardCount: forwardCount,
            reverseComplementedCount: rcCount,
            unmatchedCount: unmatchedCount,
            wallClockSeconds: elapsed
        )
        let vsearchVersion = await runner.getToolVersion(.vsearch) ?? "unknown"
        try writeProvenance(
            config: config,
            result: orientResult,
            vsearchResult: result,
            vsearchArguments: args,
            vsearchStartedAt: vsearchStart,
            vsearchCompletedAt: vsearchEnd,
            workflowStartedAt: startTime,
            workflowCompletedAt: Date(),
            vsearchVersion: vsearchVersion,
            context: provenanceContext
        )
        return orientResult
    }

    /// Creates an orient-map TSV from vsearch tabbed output.
    ///
    /// The orient-map format is simpler than vsearch's tabbed output:
    /// just `read_id\t+/-\n` for each read that was successfully oriented.
    /// Unmatched reads (orientation "?") are excluded.
    ///
    /// - Parameters:
    ///   - tabbedOutput: URL to vsearch's --tabbedout file
    ///   - outputURL: URL to write the orient-map TSV
    /// - Returns: Tuple of (forwardCount, rcCount) for reads written
    public func createOrientMap(
        from tabbedOutput: URL,
        to outputURL: URL
    ) throws -> (forwardCount: Int, rcCount: Int) {
        let fm = FileManager.default
        let tmpURL = outputURL.appendingPathExtension("tmp")
        _ = fm.createFile(atPath: tmpURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmpURL)
        var forwardCount = 0
        var rcCount = 0

        do {
            try forEachOrientRecord(in: tabbedOutput) { readID, orientation in
                if orientation == "+" {
                    handle.write(Data("\(readID)\t+\n".utf8))
                    forwardCount += 1
                } else if orientation == "-" {
                    handle.write(Data("\(readID)\t-\n".utf8))
                    rcCount += 1
                }
            }
            try handle.close()
        } catch {
            try? handle.close()
            try? fm.removeItem(at: tmpURL)
            throw error
        }

        if rename(tmpURL.path, outputURL.path) != 0 {
            try? fm.removeItem(at: outputURL)
            try fm.moveItem(at: tmpURL, to: outputURL)
        }

        return (forwardCount, rcCount)
    }

    // MARK: - Private

    /// Parses vsearch tabbed output to count orientations.
    func parseOrientResults(_ url: URL) throws -> (forward: Int, rc: Int, unmatched: Int) {
        var forward = 0
        var rc = 0
        var unmatched = 0

        try forEachOrientRecord(in: url) { _, orientation in
            switch orientation {
            case "+": forward += 1
            case "-": rc += 1
            default: unmatched += 1
            }
        }
        return (forward, rc, unmatched)
    }

    private func forEachOrientRecord(
        in url: URL,
        _ body: (String, String) throws -> Void
    ) throws {
        try streamLines(in: url) { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2 else { return }
            try body(String(fields[0]), String(fields[1]))
        }
    }

    private func streamLines(
        in url: URL,
        _ body: (String) throws -> Void
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var buffer = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            try drainLines(from: &buffer, flushRemainder: false, body)
        }
        try drainLines(from: &buffer, flushRemainder: true, body)
    }

    private func drainLines(
        from buffer: inout Data,
        flushRemainder: Bool,
        _ body: (String) throws -> Void
    ) throws {
        var lineStart = buffer.startIndex
        while let newlineIndex = buffer[lineStart...].firstIndex(of: 0x0A) {
            try emitLine(buffer[lineStart..<newlineIndex], body)
            lineStart = buffer.index(after: newlineIndex)
        }

        if lineStart > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<lineStart)
        }

        if flushRemainder, !buffer.isEmpty {
            try emitLine(buffer[buffer.startIndex..<buffer.endIndex], body)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private func emitLine(
        _ rawLine: Data.SubSequence,
        _ body: (String) throws -> Void
    ) throws {
        let lineBytes = rawLine.last == 0x0D ? rawLine.dropLast() : rawLine
        guard !lineBytes.isEmpty else { return }
        try body(String(decoding: lineBytes, as: UTF8.self))
    }

    private func writeProvenance(
        config: OrientConfig,
        result: OrientResult,
        vsearchResult: NativeToolResult,
        vsearchArguments: [String],
        vsearchStartedAt: Date,
        vsearchCompletedAt: Date,
        workflowStartedAt: Date,
        workflowCompletedAt: Date,
        vsearchVersion: String,
        context: OrientProvenanceContext?,
        workflowExitStatus: Int? = nil,
        workflowStderr: String? = nil
    ) throws {
        let stepArgv = vsearchResult.arguments.isEmpty
            ? [NativeTool.vsearch.executableName] + vsearchArguments
            : vsearchResult.arguments
        let pathReplacements = context?.pathReplacements ?? [:]
        let provenanceInputRecords = context?.inputFileRecords ?? [
            ProvenanceRecorder.fileRecord(url: config.inputURL, format: .fastq, role: .input),
        ]
        let inputs = provenanceInputRecords + [
            ProvenanceRecorder.fileRecord(url: config.referenceURL, format: .fasta, role: .reference),
        ]
        var outputs = [
            outputRecordIfPresent(url: result.orientedFASTQ, format: .fastq, role: .output),
            outputRecordIfPresent(url: result.tabbedOutput, format: .text, role: .output),
        ].compactMap { $0 }
        if let unorientedFASTQ = result.unorientedFASTQ,
           let outputRecord = outputRecordIfPresent(url: unorientedFASTQ, format: .fastq, role: .output) {
            outputs.append(outputRecord)
        }

        let stepDurableArgv = rewriteArguments(stepArgv, using: pathReplacements)
        let step = ProvenanceStep(
            toolName: NativeTool.vsearch.executableName,
            toolVersion: vsearchVersion,
            argv: stepArgv,
            durableReplayArgv: stepDurableArgv,
            reproducibleCommand: commandLine(from: stepDurableArgv),
            inputs: inputs.map { ProvenanceFileDescriptor(fileRecord: $0) },
            outputs: outputs.map { ProvenanceFileDescriptor(fileRecord: $0) },
            exitStatus: Int(vsearchResult.exitCode),
            wallTimeSeconds: vsearchCompletedAt.timeIntervalSince(vsearchStartedAt),
            stderr: nonEmpty(vsearchResult.stderr),
            startedAt: vsearchStartedAt,
            completedAt: vsearchCompletedAt
        )

        let topLevelArgv: [String]
        if let context, !context.argv.isEmpty {
            topLevelArgv = context.argv
        } else {
            topLevelArgv = stepArgv
        }
        let topLevelDurableArgv = rewriteArguments(topLevelArgv, using: pathReplacements)
        let options = context?.options ?? defaultProvenanceOptions(for: config)
        let resultStatistics: [String: ParameterValue] = [
            "forwardCount": .integer(result.forwardCount),
            "reverseComplementedCount": .integer(result.reverseComplementedCount),
            "unmatchedCount": .integer(result.unmatchedCount),
        ]
        let envelope = try ProvenanceRunBuilder(
            workflowName: context?.workflowName ?? "lungfish orient",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: NativeTool.vsearch.executableName,
            toolVersion: vsearchVersion
        )
        .argv(topLevelArgv)
        .durableReplayArgv(topLevelDurableArgv)
        .reproducibleCommand(commandLine(from: topLevelDurableArgv))
        .options(
            explicit: options.explicit.merging(resultStatistics) { _, statistic in statistic },
            defaults: options.defaults,
            resolved: options.resolvedDefaults.merging(resultStatistics) { _, statistic in statistic }
        )
        .runtime(
            ProvenanceRuntimeIdentity(
                executablePath: stepArgv.first ?? NativeTool.vsearch.executableName,
                condaEnvironment: "vsearch"
            )
        )
        .step(step)
        .complete(
            exitStatus: workflowExitStatus ?? Int(vsearchResult.exitCode),
            stderr: workflowStderr ?? vsearchResult.stderr,
            startedAt: workflowStartedAt,
            endedAt: workflowCompletedAt
        )

        try ProvenanceWriter().write(envelope, to: result.orientedFASTQ.deletingLastPathComponent())
    }

    private func defaultProvenanceOptions(for config: OrientConfig) -> ProvenanceOptions {
        let resolved: [String: ParameterValue] = [
            "input": .file(config.inputURL),
            "reference": .file(config.referenceURL),
            "wordLength": .integer(config.wordLength),
            "dbMask": .string(config.dbMask),
            "qMask": .string(config.qMask),
            "saveUnoriented": .boolean(config.saveUnoriented),
            "threads": .integer(config.threads),
            "extraArguments": .array(config.extraArguments.map(ParameterValue.string)),
        ]
        return ProvenanceOptions(
            explicit: resolved,
            defaults: [
                "wordLength": .integer(12),
                "dbMask": .string("dust"),
                "qMask": .string("dust"),
                "saveUnoriented": .boolean(true),
                "threads": .integer(0),
                "extraArguments": .array([]),
            ],
            resolvedDefaults: resolved
        )
    }

    private func nonEmpty(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
    }

    private func toolFailureMessage(_ error: Error) -> String {
        let localized = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let trimmed = localized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(describing: error) : trimmed
    }

    private func commandLine(from argv: [String]) -> String {
        argv.map(shellEscape).joined(separator: " ")
    }

    private func outputRecordIfPresent(
        url: URL,
        format: FileFormat? = nil,
        role: FileRole
    ) -> FileRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return ProvenanceRecorder.fileRecord(url: url, format: format, role: role)
    }

    private func rewriteArguments(_ argv: [String], using replacements: [String: String]) -> [String] {
        argv.map { rewriteArgument($0, using: replacements) }
    }

    private func rewriteArgument(_ argument: String, using replacements: [String: String]) -> String {
        for (source, destination) in replacementPairs(for: replacements) where argument == source {
            return destination
        }
        guard let equalsIndex = argument.firstIndex(of: "=") else {
            return argument
        }
        let prefix = argument[...equalsIndex]
        let value = String(argument[argument.index(after: equalsIndex)...])
        for (source, destination) in replacementPairs(for: replacements) where value == source {
            return String(prefix) + destination
        }
        return argument
    }

    private func replacementPairs(for replacements: [String: String]) -> [(source: String, destination: String)] {
        var pairs: [(String, String)] = []
        var seen = Set<String>()
        for (source, destination) in replacements {
            if seen.insert(source).inserted {
                pairs.append((source, destination))
            }
            let standardizedSource = URL(fileURLWithPath: source).standardizedFileURL.path
            if seen.insert(standardizedSource).inserted {
                pairs.append((standardizedSource, destination))
            }
        }
        return pairs.sorted {
            if $0.0.count != $1.0.count {
                return $0.0.count > $1.0.count
            }
            return $0.0 < $1.0
        }
    }
}

// MARK: - Errors

public enum OrientPipelineError: Error, LocalizedError, Sendable {
    case vsearchFailed(String)
    case referenceNotFound(URL)
    case inputNotFound(URL)

    public var errorDescription: String? {
        switch self {
        case .vsearchFailed(let stderr):
            return "vsearch orient failed: \(stderr)"
        case .referenceNotFound(let url):
            return "Reference FASTA not found: \(url.lastPathComponent)"
        case .inputNotFound(let url):
            return "Input FASTQ not found: \(url.lastPathComponent)"
        }
    }
}

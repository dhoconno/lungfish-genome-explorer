// SRADownloadBundle.swift - lungfish-cli fetch sra download --bundle, one run downloaded and imported into a project
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// The import sheet's settings as `--bundle` receives them, plain values a task can hold.
struct SRADownloadImportSettings: Sendable {
    var platform = "auto"
    var pairing = "auto"
    /// The `--quality-binning` value, or nil to take the recipe's declared value or the import default.
    var qualityBinning: String?
    var compression = "balanced"
    var recipe = "none"
    /// The recipe switches an option set, by switch id.
    var switchOptions: [String: Bool] = [:]
    var noOptimizeStorage = false
    var clumpingTool: String?
    var threads: Int?
    var quiet = false
    var useColors = false
}

/// One `fetch sra download --bundle` run (Phase 2.10 lane A45 M3, ruling A45-M3 section 1): one run
/// downloaded and imported into the project, in one process with one SIGTERM.
///
/// The run stages in `<project>/.tmp/fetch-sra-<UUID>`. It downloads the run into a folder of the
/// staging folder, sorts the files into reads with the rule the window applies, imports them into a
/// project of the staging folder with the settings it was given (``FASTQImportRun``, shared with
/// `import fastq`), adds the download's facts to the bundle's metadata sidecar, writes its record,
/// checks for a cancel and publishes the bundle into `<project>/Imports/` by a rename. The record
/// is relocated to the final place, and the staging folder goes with the staged FASTQ files, which
/// a removal step of the record names (2.8 P1) off the run level (2.8 B3). A SIGTERM at any point
/// removes the staging folder and ends the run with a failed line and exit 125.
struct SRADownloadBundleRun: Sendable {
    enum Outcome: Sendable {
        case bundle(URL, record: URL?)
        case failed(String)
        /// A failure whose failed line a shared step already printed.
        case reported(ExitCode)
        case cancelled
    }

    /// The share of the bar the download takes, the import taking the rest.
    static let downloadShare = 0.5
    static let stagingPrefix = "fetch-sra-"

    let request: SRADownloadRequest
    let reporter: SRADownloadReporter
    let trace: SRADownloadTraceCapture
    let projectURL: URL
    let settings: SRADownloadImportSettings
    /// The command that makes this run, which its record states.
    let argv: [String]

    func execute() async -> Outcome {
        let staging: URL
        do {
            staging = try ProjectTempDirectory.create(prefix: Self.stagingPrefix, in: projectURL)
        } catch {
            return .failed("Could not stage in \(projectURL.path): \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            return try await build(in: staging)
        } catch let code as ExitCode {
            return .reported(code)
        } catch is CancellationError {
            return .cancelled
        } catch let refusal as SRARunRefusal {
            return .failed(refusal.reason)
        } catch let error as SRAError {
            return Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
        } catch {
            return Task.isCancelled ? .cancelled : .failed("Download failed: \(SRADownloadMessages.reason(of: error))")
        }
    }

    /// Prints the end of the run and throws the exit status of a run that did not complete.
    static func finish(_ outcome: Outcome, reporter: SRADownloadReporter) throws {
        switch outcome {
        case let .bundle(bundle, record):
            reporter.completeBundle(bundle, record: record)
        case .cancelled:
            reporter.failedRun(SRADownloadReporter.cancelledMessage)
            throw CLIExitCode.cancelled.exitCode
        case let .failed(message):
            reporter.failedRun(message)
            throw CLIExitCode.failure.exitCode
        case let .reported(code):
            throw code
        }
    }

    private func build(in staging: URL) async throws -> Outcome {
        let accession = request.accession
        guard SRAAccessionParser.namesOneFolder(accession) else {
            return .failed("\(accession) cannot name a staging folder, so it was not downloaded")
        }
        let service = SRADownloadSubcommand.makeService()
        let runFolder = staging.appendingPathComponent(accession, isDirectory: true)
        try FileManager.default.createDirectory(at: runFolder, withIntermediateDirectories: true)

        // 1. The download, ENA first and the SRA Toolkit on a fallback.
        reporter.info("Downloading FASTQ for \(accession)...")
        reporter.info(
            request.useToolkit || request.sourcePreference == .ncbi
                ? "Using SRA Toolkit (prefetch + fasterq-dump)" : "Using ENA direct download"
        )
        let files = try await request.downloadFiles(service: service, into: runFolder, trace: trace, reporter: reporter)
        try Task.checkCancellation()

        // 2. The reads: mates 1 and 2 as a pair, with the reads whose mate is missing beside them.
        let sorted = try await request.sortRunReads(files, service: service, enaRecord: trace.enaRecord)
        let reads = sorted.reads
        if let warning = sorted.layoutWarning { reporter.layoutWarning(warning) }
        let ncbiRun = trace.enaRecord == nil ? await service.ncbiRunInfo(forRun: accession) : nil
        try Task.checkCancellation()

        // 3. The import, into a project of the staging folder.
        let importProject = staging.appendingPathComponent("import", isDirectory: true)
        try FileManager.default.createDirectory(at: importProject, withIntermediateDirectories: true)
        var importRun = FASTQImportRun(input: reads.files.map(\.path), samplesheet: nil, project: importProject.path)
        importRun.platform = settings.platform
        // A run that arrived as mates 1 and 2 imports as one pair, whatever the sheet's choice.
        importRun.pairing = reads.r2 == nil ? settings.pairing : "paired"
        importRun.qualityBinning = settings.qualityBinning
        importRun.compression = settings.compression
        importRun.recipe = settings.recipe
        importRun.switchOptions = settings.switchOptions
        importRun.noOptimizeStorage = settings.noOptimizeStorage
        importRun.clumpingTool = settings.clumpingTool
        importRun.threads = settings.threads
        importRun.quiet = settings.quiet
        importRun.useColors = settings.useColors
        let importStartedAt = Date()
        guard let result = try await importRun.run(reporter: reporter, cancellation: .followsCallingTask) else {
            return .failed("The import of \(accession) did not run")
        }
        let importCompletedAt = Date()
        if let failure = result.errors.last {
            return .failed("\(failure.sample): \(failure.error)")
        }
        let importsFolder = importProject.appendingPathComponent("Imports", isDirectory: true)
        let bundleNames = ((try? FileManager.default.contentsOfDirectory(atPath: importsFolder.path)) ?? [])
            .filter { $0.hasSuffix(".lungfishfastq") }
        guard bundleNames.count == 1, let bundleName = bundleNames.first else {
            return .failed("The import of \(accession) made \(bundleNames.count) bundle(s), not one")
        }
        let stagedBundle = importsFolder.appendingPathComponent(bundleName, isDirectory: true)
        try Task.checkCancellation()

        // 4. The metadata sidecar keeps ENA's record of the run, or NCBI's, and where and when it came from.
        let contents = (try? FileManager.default.contentsOfDirectory(at: stagedBundle, includingPropertiesForKeys: nil)) ?? []
        guard let fastqURL = contents.first(where: { Self.isFASTQ($0.lastPathComponent) }) else {
            return .failed("The bundle of \(accession) holds no FASTQ file")
        }
        var metadata = FASTQMetadataStore.load(for: fastqURL) ?? PersistedFASTQMetadata()
        metadata.enaReadRecord = trace.enaRecord
        metadata.sraRunInfo = metadata.sraRunInfo ?? (trace.enaRecord == nil ? ncbiRun : nil)
        metadata.downloadDate = Date()
        metadata.downloadSource = trace.downloadSource.rawValue
        FASTQMetadataStore.save(metadata, for: fastqURL)
        let sidecarName = FASTQMetadataStore.metadataURL(for: fastqURL).lastPathComponent

        // 5. The record, written last, in the staged bundle.
        try writeRecord(
            accession: accession, reads: reads, layoutWarning: sorted.layoutWarning, metadata: metadata,
            fastqURL: fastqURL, bundle: stagedBundle, startedAt: importStartedAt, completedAt: importCompletedAt
        )
        try amendRecord(of: stagedBundle, removing: reads.files)
        try Task.checkCancellation()

        // 6. Publish by a rename, and relocate the record to the final place.
        let importsInProject = projectURL.appendingPathComponent("Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: importsInProject, withIntermediateDirectories: true)
        let finalBundle = importsInProject.appendingPathComponent(bundleName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: finalBundle.path) else {
            return .failed("Output FASTQ bundle already exists: \(finalBundle.path)")
        }
        _ = try PortableRename.exclusive(stagedBundle, to: finalBundle)
        // A bundle in its final place is finished, so a record that cannot be rewritten removes it. `rebase`
        // relocates the run's record, states the sidecar's digest as it stands (the import wrote its records
        // before step 4 took the download's facts into the sidecar) and writes the root record and the record
        // of every output from it, in place of the records the import wrote under `provenance/`, which name
        // the staged folder (BIO ruling on lane A45 M3c, section b item 3).
        do {
            try FetchNCBIBundleRecord.rebase(bundle: finalBundle, from: stagedBundle, refreshingDigestsOf: [sidecarName])
        } catch {
            try? FileManager.default.removeItem(at: finalBundle)
            throw error
        }
        let record = finalBundle.appendingPathComponent(BundleKindDescriptor.SidecarNaming.rootRecordFileName)
        return .bundle(finalBundle, record: FileManager.default.fileExists(atPath: record.path) ? record : nil)
    }

    private static func isFASTQ(_ name: String) -> Bool {
        [".fastq.gz", ".fq.gz", ".fastq", ".fq"].contains { name.hasSuffix($0) }
    }

    /// The leaf's record of an SRA import (`writeGUISRAFASTQImportProvenance`), under its own workflow
    /// name with `lungfish-cli` as the run's tool (Phase 2.11 K3), with the download's
    /// steps from this process and the import's own steps merged in from the bundle's record.
    private func writeRecord(
        accession: String, reads: SRARunReads, layoutWarning: String?, metadata: PersistedFASTQMetadata,
        fastqURL: URL, bundle: URL, startedAt: Date, completedAt: Date
    ) throws {
        let readCounts: [URL: Int]? = {
            guard let r2 = reads.r2, let unpaired = reads.unpaired, let classification = metadata.readClassification else { return nil }
            func count(_ role: ReadClassification.FileRole) -> Int {
                classification.files.filter { $0.role == role }.reduce(0) { $0 + $1.readCount }
            }
            return [reads.r1: count(.pairedR1), r2: count(.pairedR2), unpaired: count(.unpaired)]
        }()
        try writeGUISRAFASTQImportProvenance(
            accession: accession,
            readRecord: trace.enaRecord,
            downloadSource: trace.downloadSource.rawValue,
            preferredSource: request.sourcePreference,
            layoutWarning: layoutWarning,
            fallbackMessage: trace.fallbackMessage,
            enaDownloadSteps: trace.stepExecutions(),
            toolkitDownloadTraces: [],
            cliArguments: Array(argv.dropFirst()),
            cliCommandLine: argv.map { shellEscape($0) }.joined(separator: " "),
            cliStartedAt: startedAt,
            cliCompletedAt: completedAt,
            stagedFASTQFiles: FASTQBatchImporter.inputFilesKept(of: reads.files, by: metadata.ingestion),
            stagedReadCounts: readCounts,
            finalFASTQURL: fastqURL,
            bundleURL: bundle,
            platform: settings.platform,
            recipeName: settings.recipe == "none" ? nil : settings.recipe,
            qualityBinning: metadata.ingestion?.qualityBinning ?? settings.qualityBinning ?? QualityBinningScheme.importDefault.rawValue,
            optimizeStorage: !settings.noOptimizeStorage && settings.clumpingTool != "none",
            compressionLevel: settings.compression,
            cliBinaryPath: { nil },
            runTool: (CLICommandIdentity.executableName, WorkflowRun.currentAppVersion)
        )
    }

    /// The record's run level states this command, and a removal step names the staged FASTQ files
    /// the run deletes next, with the digest they had (2.8 P1). The step is not at the run level (2.8 B3).
    private func amendRecord(of bundle: URL, removing staged: [URL]) throws {
        guard var envelope = ProvenanceRecorder.loadEnvelope(from: bundle) else { return }
        envelope.argv = argv
        envelope.reproducibleCommand = argv.map { shellEscape($0) }.joined(separator: " ")
        let removed = try staged.map { try ProvenanceFileDescriptor.file(url: $0, role: .input) }
        if let step = RecordedRemovalStep.step(
            toolName: CLICommandIdentity.executableName, api: "FileManager.removeItem", removing: removed, clock: ProvenanceRunClock()
        ) {
            envelope.steps.append(step)
        }
        try ProvenanceWriter().write(
            envelope, toSidecar: bundle.appendingPathComponent(ProvenanceRecorder.provenanceFilename))
    }
}

extension SRADownloadTraceCapture {
    /// The recorded steps of the transfers. The steps of an attempt that did not serve the run stay
    /// recorded, marked failed, as the window marks them.
    func stepExecutions() -> [StepExecution] {
        let sraToolsVersion = try? ManagedToolLock.loadFromBundle().entry(id: ManagedToolID(rawValue: "sra-tools"))?.version
        let failedStepCount = failedAttemptStepCount
        let failedAttempt = SRAService.FASTQDownloadStepTrace.failedAttemptOption
        func format(_ path: String) -> FileFormat? {
            let lowercase = path.lowercased()
            if [".fastq", ".fq", ".fastq.gz", ".fq.gz"].contains(where: lowercase.hasSuffix) { return .fastq }
            return lowercase.hasSuffix(".sra") ? .unknown : nil
        }
        return steps.enumerated().map { index, step in
            StepExecution(
                toolName: step.toolName,
                toolVersion: step.recordedToolVersion(sraToolsVersion: sraToolsVersion),
                command: step.command,
                resolvedOptions: index < failedStepCount ? [failedAttempt.key: .string(failedAttempt.value)] : nil,
                inputs: step.inputs.map { FileRecord(path: $0, format: format($0), role: .input) },
                outputs: step.outputs.map { ProvenanceRecorder.fileRecord(url: $0, format: .fastq, role: .output) },
                exitCode: step.exitCode,
                wallTime: step.wallTime,
                stderr: step.stderr,
                startTime: step.startedAt,
                endTime: step.completedAt
            )
        }
    }
}

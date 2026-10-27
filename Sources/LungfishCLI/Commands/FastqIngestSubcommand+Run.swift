// FastqIngestSubcommand+Run.swift - The order of one in-place ingest
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// The points of an ingest that a test can watch, in the order they happen.
enum FastqIngestStep: String, Sendable, Equatable {
    /// The pipeline's output, built in the hidden folder, is synced.
    case stageSynced
    /// The output holds its final name.
    case renamed
    /// The folder that holds the output is synced.
    case folderSynced
    /// The metadata sidecar is written and synced.
    case sidecarWritten
    /// The record, with the digest of each original, is written.
    case recorded
    /// The originals are removed. Absent without `--delete-originals`.
    case originalsRemoved
}

enum FastqIngestObservation {
    /// Sees each step as it happens, for the current task and the tasks it starts.
    @TaskLocal static var observer: (@Sendable (FastqIngestStep) -> Void)?

    static func note(_ step: FastqIngestStep) {
        observer?(step)
    }
}

/// One in-place ingest, after its arguments are read. SWIFT's L6 order, stated once:
///
/// 1. The pipeline writes its output into a staging folder, under the project's `.tmp` folder when the input
///    sits in a project, else in the system temp folder when that folder is on the input's volume, else in
///    a hidden folder beside the input. It never deletes.
/// 2. The digest of each original is read, so the record can name it.
/// 3. The output is synced, then renamed into place with ``PortableRename``, then the folder is synced.
/// 4. The metadata sidecar is written and synced.
/// 5. The record is written. Its input list holds the digest of each original.
/// 6. Only now, with `--delete-originals`, are the originals removed.
///
/// A cancel or a failure before step 3 leaves every original in place and removes the hidden
/// folder. From step 3 on the run does not check cancellation, because the output is published
/// and the remaining steps are short, so a late SIGTERM does not strand a published output
/// without its sidecar and record.
struct FastqIngestRun {
    struct Options: Sendable {
        var pairingMode: FASTQIngestionConfig.PairingMode
        var binning: QualityBinningScheme
        var skipClumpify: Bool
        var deleteOriginals: Bool
        var threads: Int
    }

    struct Outcome: Sendable {
        let output: URL
        let message: String
    }

    let inputs: [URL]
    let options: Options
    let command: [String]
    let parameters: [String: ParameterValue]
    let defaults: [String: ParameterValue]
    let events: CLIEventEmitter
    let clock: ProvenanceRunClock
    /// The clumping choice to run with, in place of the one the pipeline makes from the size of the
    /// input. Only a test supplies it, to show what a run does when `auto` resolves to `none`.
    var clumpingResolution: ClumpingToolResolution?
    /// Whether the command was sent SIGTERM, read when a run fails. `run()` of the command passes the
    /// flag of its own ``SIGTERMCancellation`` scope. The flag stays set after an instance ends and
    /// until the next begins, so a caller with no scope passes nothing and a failure stays a failure
    /// (review A47 fix 6 (a)).
    var signalled: @Sendable () -> Bool = { false }

    /// The share of the progress bar that the pipeline's own fraction fills. The steps after it
    /// take the rest, so the bar does not reach 100% while the digest and the record are written.
    private static let pipelineShare = 0.9

    func run() async throws -> Outcome {
        try checkInputs()
        let fileManager = FileManager.default
        let folder = inputs[0].deletingLastPathComponent()
        let staging = try Self.makeStagingFolder(for: inputs[0])
        defer { try? fileManager.removeItem(at: staging) }
        var published = false
        do {
            return try await ingest(folder: folder, staging: staging, published: &published)
        } catch {
            // The pipeline wraps a tool's cancellation in its own error, so the task says whether
            // this was a cancel. The app signals the leaf and its tree together, and the tool can die
            // of that SIGTERM before the leaf's handler cancels the task, which a busy machine makes
            // likely. The flag the handler sets says the signal came. Once the output is published the
            // run is no longer cancellable.
            if !published, Task.isCancelled || error is CancellationError || signalled() {
                throw CancellationError()
            }
            throw error
        }
    }

    /// The hidden folder the pipeline writes into. An input that sits in a project stages under the project's
    /// `.tmp` folder, so no stage file ever sits in a bundle (SWIFT 4) and the project's cleanup finds the folder
    /// of a run that was killed outright. Next comes the system temp folder, with the marker the app's launch sweep
    /// reads (2.11 S8). Last the folder sits beside the input. The rename into the input's folder must stay on one
    /// volume, so a folder that cannot be made, or that sits on another volume than the input's folder, gives way
    /// to the next.
    static func makeStagingFolder(for input: URL) throws -> URL {
        let folder = input.deletingLastPathComponent()
        let roots: [URL?] = ProjectTempDirectory.findProjectRoot(input).map { [$0, nil] } ?? [nil]
        for root in roots {
            guard let staging = try? ProjectTempDirectory.create(prefix: "lungfish-ingest-", in: root) else { continue }
            if let stagingVolume = volumeReader(staging), stagingVolume == volumeReader(folder) {
                return staging
            }
            try? FileManager.default.removeItem(at: staging)
        }
        let beside = folder.appendingPathComponent(".lungfish-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: beside, withIntermediateDirectories: false)
        return beside
    }

    /// Reads the volume of a folder. A test replaces it to put the system temp folder on another volume.
    @TaskLocal static var volumeReader: @Sendable (URL) -> Int? = { FastqIngestRun.volume(of: $0) }

    /// The number of the volume that holds `url`, nil when it cannot be read.
    static func volume(of url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        return attributes?[.systemNumber] as? Int
    }

    private func checkInputs() throws {
        for url in inputs {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw CLIError.inputFileNotFound(path: url.path)
            }
        }
        if inputs.count == 2, inputs[0] == inputs[1] {
            throw CLIError.validationFailed(errors: ["--pair names the input file again. Give the R2 file."])
        }
    }

    private func ingest(folder: URL, staging: URL, published: inout Bool) async throws -> Outcome {
        let events = self.events
        let config = FASTQIngestionConfig(
            inputFiles: inputs,
            pairingMode: options.pairingMode,
            outputDirectory: staging,
            threads: options.threads,
            deleteOriginals: false,
            qualityBinning: options.binning,
            skipClumpify: options.skipClumpify
        )
        let result = try await FASTQIngestionPipeline().run(config: config, clumpingResolution: clumpingResolution) { fraction, message in
            events.emitProgress(fraction * Self.pipelineShare, message: message)
        }
        try Task.checkCancellation()
        if !result.wasClumpified, !options.skipClumpify {
            events.emitLog(.warning, "Clumping was skipped. \(result.clumpingResolution.reason)")
        }

        // The pipeline names its output in the hidden folder. A skipped clumpify of one gzip file
        // writes nothing there and returns the input itself, which then stays as the output.
        let staged = result.outputFile
        let isStaged = staged.deletingLastPathComponent().resolvingSymlinksInPath().path == staging.resolvingSymlinksInPath().path
        let finalOutput = isStaged ? Self.finalOutputURL(folder: folder, inputs: inputs) : staged

        // Step 2. The digest is read from the original while it exists, and before anything
        // is published, so a cancel during a long read still publishes nothing.
        events.emitProgress(0.92, message: "Recording the digests of the original and ingested files...")
        let originals = try inputs.map { url in
            FileRecord(
                path: url.path,
                sha256: try ProvenanceFileHasher.sha256(of: url, cancellationCheck: { try Task.checkCancellation() }),
                sizeBytes: try ProvenanceFileHasher.fileSize(of: url),
                format: .fastq,
                role: .input
            )
        }
        // The staged output is read here too, once, while a cancel can still stop the read. The record, the merge
        // into a record that stands and the output's sidecar all take this digest, so the output is not read
        // again after the publish, where the run no longer checks cancellation (review A47 fix 6 (e), SWIFT 5).
        let outputRecord = try Self.outputRecord(staged: staged, final: finalOutput, originals: originals)
        try Task.checkCancellation()

        // Step 3.
        if isStaged {
            events.emitProgress(0.94, message: "Moving the output into place...")
            try FastqIngestDurability.syncFile(at: staged)
            FastqIngestObservation.note(.stageSynced)
            try Task.checkCancellation()
            try Self.publish(staged: staged, as: finalOutput)
            published = true
            FastqIngestObservation.note(.renamed)
            try FastqIngestDurability.syncFolder(at: folder)
            FastqIngestObservation.note(.folderSynced)
        } else {
            published = true
        }

        // Step 4.
        events.emitProgress(0.96, message: "Writing the metadata sidecar...")
        let sidecarURL = FASTQMetadataStore.metadataURL(for: finalOutput)
        try writeSidecar(result: result, output: finalOutput, sidecarURL: sidecarURL)
        FastqIngestObservation.note(.sidecarWritten)

        // Step 5.
        events.emitProgress(0.98, message: "Writing the record...")
        try await writeRecord(
            result: result,
            staged: staged,
            output: finalOutput,
            outputRecord: outputRecord,
            sidecarURL: sidecarURL,
            originals: originals,
            folder: folder
        )
        FastqIngestObservation.note(.recorded)

        // Step 6.
        if options.deleteOriginals {
            events.emitProgress(0.99, message: "Removing the original file...")
            try removeOriginals(keeping: finalOutput)
            FastqIngestObservation.note(.originalsRemoved)
        }

        let saved = ByteCountFormatter.string(
            fromByteCount: result.originalSizeBytes - result.finalSizeBytes,
            countStyle: .file
        )
        let message = result.wasClumpified
            ? "Clumpified and compressed (saved \(saved))"
            : "Compressed (saved \(saved))"
        return Outcome(output: finalOutput, message: message)
    }

    // MARK: - Steps

    /// The name the output takes in the input's folder: the input's base name with `.fastq.gz`, or
    /// `.clumped.fastq.gz` when an input already holds the first name. The app's run names it so.
    static func finalOutputURL(folder: URL, inputs: [URL]) -> URL {
        let base = FASTQIngestionPipeline.deriveBaseName(from: inputs[0])
        let plain = folder.appendingPathComponent("\(base).fastq.gz")
        if inputs.contains(where: { $0.standardizedFileURL == plain.standardizedFileURL }) {
            return folder.appendingPathComponent("\(base).clumped.fastq.gz")
        }
        return plain
    }

    /// Moves `staged` to `final`. A file that holds the final name is swapped out, so the name
    /// never empties, and the hidden folder carries the old file away when the run ends.
    static func publish(staged: URL, as final: URL) throws {
        if FileManager.default.fileExists(atPath: final.path) {
            try PortableRename.swap(staged, final)
        } else {
            try PortableRename.exclusive(staged, to: final)
        }
    }

    private func writeSidecar(result: FASTQIngestionResult, output: URL, sidecarURL: URL) throws {
        let pairingMode: IngestionMetadata.PairingMode = result.pairingMode == .singleEnd ? .singleEnd : .interleaved
        let ingestion = IngestionMetadata(
            isClumpified: result.wasClumpified,
            isCompressed: true,
            pairingMode: pairingMode,
            qualityBinning: result.qualityBinning.rawValue,
            originalFilenames: result.originalFilenames,
            ingestionDate: Date(),
            originalSizeBytes: result.originalSizeBytes,
            storageInputSizeBytes: result.originalSizeBytes,
            storageOutputSizeBytes: result.finalSizeBytes
        )
        var metadata = FASTQMetadataStore.load(for: inputs[0]) ?? PersistedFASTQMetadata()
        metadata.ingestion = ingestion
        try FASTQMetadataStore.write(metadata, for: output)
        try FastqIngestDurability.syncFile(at: sidecarURL)
    }

    /// The output's record: its digest and size read from the staged file before the publish, under the final
    /// name. An input that stays as the output was read as an original, and that read is the output's.
    private static func outputRecord(staged: URL, final: URL, originals: [FileRecord]) throws -> FileRecord {
        let finalPath = final.standardizedFileURL.path
        if let same = originals.first(where: { URL(fileURLWithPath: $0.path).standardizedFileURL.path == finalPath }) {
            return FileRecord(path: final.path, sha256: same.sha256, sizeBytes: same.sizeBytes, format: .fastq, role: .output)
        }
        return FileRecord(
            path: final.path,
            sha256: try ProvenanceFileHasher.sha256(of: staged, cancellationCheck: { try Task.checkCancellation() }),
            sizeBytes: try ProvenanceFileHasher.fileSize(of: staged),
            format: .fastq,
            role: .output
        )
    }

    private func writeRecord(
        result: FASTQIngestionResult,
        staged: URL,
        output: URL,
        outputRecord: FileRecord,
        sidecarURL: URL,
        originals: [FileRecord],
        folder: URL
    ) async throws {
        var parameters = self.parameters
        parameters["output"] = .file(output)
        parameters["outputPairingMode"] = .string(result.pairingMode.rawValue)
        parameters["wasClumpified"] = .boolean(result.wasClumpified)
        let sidecarRecord = ProvenanceRecorder.fileRecord(url: sidecarURL, format: .json, role: .output)
        // The record that stands in the folder is the file's history, such as the download or the
        // import it came with. The run joins it as the app's route does, with the removed originals'
        // outputs pointing at the new file (ruling on A47 M3, section 1).
        let existing = try Self.existingRecord(folder: folder, inputs: inputs)
        let replaced = options.deleteOriginals ? inputs : []
        // The record takes each original's digest from the read above and never reopens the file,
        // which `--delete-originals` removes next. An input that stays as the output is read as usual.
        let consumed = Set(
            originals
                .filter { URL(fileURLWithPath: $0.path).standardizedFileURL != output.standardizedFileURL }
                .map { URL(fileURLWithPath: $0.path).canonicalFilePath }
        )
        try await CLIProvenanceSupport.recordSingleStepRun(
            name: Self.recordName,
            parameters: parameters,
            defaults: defaults,
            toolName: "FASTQIngestionPipeline",
            toolVersion: WorkflowRun.currentAppVersion,
            command: command,
            stepCommand: command,
            stepOutputs: [outputRecord, sidecarRecord],
            extraSteps: result.provenanceSteps
                .map { $0.relocated(from: staged, to: output) }
                .map(ProvenanceStep.init(stepExecution:)),
            inputs: originals,
            outputs: [outputRecord],
            consumedInputSnapshotPaths: consumed,
            recordedOutputSnapshotPaths: [URL(fileURLWithPath: outputRecord.path).canonicalFilePath],
            exitCode: 0,
            wallTime: clock.now.timeIntervalSince(clock.startedAt),
            stderr: nil,
            status: .completed,
            outputDirectory: folder,
            envelopeTransform: existing.map { found in
                { fresh in
                    try InPlaceIngestionProvenance.mergedInPlaceIngestionEnvelope(
                        existingEnvelope: found.envelope,
                        sourceProvenanceURL: found.sourceURL,
                        ingestionEnvelope: fresh,
                        replacedInputFiles: replaced,
                        finalFASTQURL: output,
                        finalFASTQDescriptor: ProvenanceFileDescriptor(fileRecord: outputRecord)
                    )
                }
            }
        )
    }

    /// The name the run's record carries, which a cancelled run's record carries too.
    static let recordName = "lungfish fastq ingest"

    /// The record that stands in `folder` for `inputs`, in the order the app's route looks
    /// (`InPlaceIngestionProvenance`): the folder's root record, then a record of an input's own.
    /// This command's own `cancelled` record is not history to join. A merge keeps the old record's
    /// status and exit status, so a later run replaces it.
    static func existingRecord(folder: URL, inputs: [URL]) throws -> (envelope: ProvenanceEnvelope, sourceURL: URL?)? {
        guard let found = try InPlaceIngestionProvenance.existingInPlaceIngestionProvenance(
            outputDirectory: folder,
            inputFiles: inputs
        ) else {
            return nil
        }
        if found.envelope.status == .cancelled, found.envelope.workflowName == recordName {
            return nil
        }
        return found
    }

    /// A removed original takes its own record and metadata sidecars with it, since both describe a file that
    /// is gone (WF-1). The output's sidecar carries the first input's metadata on and the run's record merges the
    /// folder's history, so the folder keeps one record for each file in it. The second file of a pair keeps its
    /// metadata sidecar, which the output's does not carry. A sidecar that cannot be removed does not fail a run
    /// whose output is in place.
    private func retireSidecars(of original: URL) {
        var sidecars = [ProvenanceRecorder.fileSidecarURL(for: original)]
        if original == inputs[0] { sidecars.append(FASTQMetadataStore.metadataURL(for: original)) }
        for sidecar in sidecars { try? FileManager.default.removeItem(at: sidecar) }
    }

    /// Removes each input except the one that is the output itself, which a skipped clumpify of one
    /// gzip file leaves in place.
    private func removeOriginals(keeping output: URL) throws {
        var failures: [String] = []
        for original in inputs where original.standardizedFileURL != output.standardizedFileURL {
            do {
                try FileManager.default.removeItem(at: original)
                retireSidecars(of: original)
            } catch {
                failures.append("\(original.lastPathComponent) (\(error.localizedDescription))")
            }
        }
        if !failures.isEmpty {
            throw FastqIngestError.originalsNotRemoved(output: output, failures: failures)
        }
    }
}

enum FastqIngestError: LocalizedError {
    case originalsNotRemoved(output: URL, failures: [String])

    var errorDescription: String? {
        switch self {
        case .originalsNotRemoved(let output, let failures):
            return "The reads are in \(output.lastPathComponent) and the run is recorded, "
                + "but these originals could not be removed: \(failures.joined(separator: ", "))"
        }
    }
}

/// Flushes a file or a folder to the drive, through the system calls ``DurableReplace`` makes, so a
/// test that replaces them for a task sees these syncs too.
enum FastqIngestDurability {
    static func syncFile(at url: URL) throws {
        try sync(url, isFolder: false)
    }

    static func syncFolder(at url: URL) throws {
        try sync(url, isFolder: true)
    }

    private static func sync(_ url: URL, isFolder: Bool) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw DurableReplace.ReplaceError.systemFailure(path: url.path, operation: "open to sync", code: errno)
        }
        defer { Darwin.close(descriptor) }
        let operations = DurableReplace.currentOperations
        // The full flush reaches the drive. A volume that refuses it still takes the plain sync.
        if operations.fullFlush(descriptor) == 0 {
            return
        }
        let status = isFolder ? operations.syncDirectory(descriptor) : operations.syncFile(descriptor)
        guard status == 0 else {
            throw DurableReplace.ReplaceError.systemFailure(
                path: url.path,
                operation: isFolder ? "sync the folder" : "sync the file",
                code: errno
            )
        }
    }
}

extension StepExecution {
    /// This step with the path `old` replaced by `new` in its command and its output paths, so a
    /// step the pipeline ran on its hidden output names the file where it ended up.
    func relocated(from old: URL, to new: URL) -> StepExecution {
        func swapped(_ text: String) -> String {
            text.replacingOccurrences(of: old.path, with: new.path)
        }
        return StepExecution(
            id: id,
            toolName: toolName,
            toolVersion: toolVersion,
            githubReleaseVersion: githubReleaseVersion,
            containerImage: containerImage,
            containerDigest: containerDigest,
            command: command.map(swapped),
            durableReplayArgv: durableReplayArgv?.map(swapped),
            resolvedOptions: resolvedOptions,
            runtimeIdentity: runtimeIdentity,
            inputs: inputs,
            outputs: outputs.map {
                FileRecord(path: swapped($0.path), sha256: $0.sha256, sizeBytes: $0.sizeBytes, format: $0.format, role: $0.role)
            },
            exitCode: exitCode,
            wallTime: wallTime,
            peakMemoryBytes: peakMemoryBytes,
            stderr: stderr,
            dependsOn: dependsOn,
            parentStepID: parentStepID,
            managedToolID: managedToolID,
            toolVersionEvidence: toolVersionEvidence,
            startTime: startTime,
            endTime: endTime
        )
    }
}

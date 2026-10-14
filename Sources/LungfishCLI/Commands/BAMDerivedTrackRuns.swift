// BAMDerivedTrackRuns.swift - The runs of bam filter and bam annotate, with CLIEvent lines and a SIGTERM cancel
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

/// The run of `lungfish-cli bam filter` (Phase 2.10 lane A54, census row p36).
///
/// The leaf calls the service the Inspector awaited, `BundleAlignmentFilterService`. With
/// `--format json` standard output holds only `CLIEvent` lines. The first is a `start` event with
/// the row's first detail, each stage of the service is a `progress` event with the service's words,
/// and `complete` names the derived BAM, its index and its statistics database, in that order, so the
/// BAM's file name is the new track's ID. SIGTERM, the app's Cancel, cancels the service. The bundle
/// is not changed then, because the service stages the BAM outside it and puts back whatever it
/// wrote when it stops after the attachment began. The run is recorded as cancelled and exits 125.
struct BAMFilterRun: Sendable {
    let target: AlignmentFilterTarget
    let sourceTrackID: String
    let outputTrackName: String
    let outputTrackID: String?
    let request: AlignmentFilterRequest
    let runtime: BAMCommand.FilterSubcommand.Runtime

    @discardableResult
    func execute(output: AlignmentWorkflowLeafOutput) async throws -> BundleAlignmentFilterResult {
        let startedAt = Date()
        output.events.emitStart("Preparing \(outputTrackName)...")
        output.say("Filtering alignment track '\(sourceTrackID)' into '\(outputTrackName)'.")
        let progress = output.progressHandler
        let ran = await runCancellingOnSIGTERM { [self] in
            try await runtime.runFilter(target, sourceTrackID, outputTrackName, outputTrackID, request, progress)
        }
        switch ran {
        case .success(let result):
            let bam = absolutePath(result.trackInfo.sourcePath, in: result.bundleURL)
            let index = absolutePath(result.trackInfo.indexPath, in: result.bundleURL)
            var outputs = [bam, index]
            if let metadata = result.trackInfo.metadataDBPath {
                outputs.append(absolutePath(metadata, in: result.bundleURL))
            }
            output.events.emitComplete(
                outputs: outputs,
                message: "Created filtered alignment track \"\(result.trackInfo.name)\"."
            )
            output.say("Created filtered BAM track '\(result.trackInfo.name)' (\(result.trackInfo.id)).")
            output.say("Bundle: \(result.bundleURL.path)")
            if let mappingResult = result.mappingResultURL {
                output.say("Mapping result: \(mappingResult.path)")
            }
            output.say("Source alignment track: \(sourceTrackID)")
            output.say("BAM: \(bam)")
            output.say("BAI: \(index)")
            if outputs.count > 2 { output.say("Metadata DB: \(outputs[2])") }
            return result
        case .failure(let error):
            if error is CancellationError || SIGTERMCancellation.signalCaught {
                throw output.cancelled(
                    "Filtering cancelled. The bundle was not changed.",
                    record: cancelledRecord(startedAt: startedAt)
                )
            }
            if case BundleAlignmentFilterServiceError.sourceTrackNotFound = error {
                throw output.refused(error.localizedDescription)
            }
            throw output.failed(error.localizedDescription)
        }
    }

    private func cancelledRecord(startedAt: Date) -> CancelledAlignmentWorkflowRecord {
        let place: URL
        switch target {
        case .bundle(let url), .mappingResult(let url): place = url
        }
        return CancelledAlignmentWorkflowRecord(
            workflow: "lungfish bam filter",
            argv: BundleAlignmentFilterService.cliArgv(
                target: target,
                sourceTrackID: sourceTrackID,
                outputTrackID: outputTrackID,
                outputTrackName: outputTrackName,
                filterRequest: request
            ),
            explicit: [
                "alignmentTrack": .string(sourceTrackID),
                "outputTrackName": .string(outputTrackName),
            ],
            note: "Cancelled before the filtered alignment was published. The bundle was not changed.",
            startedAt: startedAt,
            url: CancelledAlignmentWorkflowRecord.newURL(
                in: CancelledAlignmentWorkflowRecord.folder(in: place),
                workflow: "lungfish bam filter"
            )
        )
    }
}

/// The run of `lungfish-cli bam annotate` (Phase 2.10 lane A54, census row p37).
///
/// The leaf calls the service the Inspector awaited, `MappedReadsAnnotationService`, and speaks
/// events as `bam filter` does. `complete` names the annotation database. SIGTERM cancels the
/// service, which puts back the files it wrote when it stops after it began writing, so the bundle
/// is not changed. The run is recorded as cancelled and exits 125.
struct BAMAnnotateRun: Sendable {
    let request: MappedReadsAnnotationRequest
    let sourceTrackID: String
    let runtime: BAMCommand.AnnotateSubcommand.Runtime

    @discardableResult
    func execute(output: AlignmentWorkflowLeafOutput) async throws -> MappedReadsAnnotationResult {
        let startedAt = Date()
        output.events.emitStart("Preparing \(request.outputTrackName)...")
        output.say("Converting mapped reads from '\(sourceTrackID)' into '\(request.outputTrackName)'.")
        let progress = output.progressHandler
        let ran = await runCancellingOnSIGTERM { [self] in
            try await runtime.runAnnotate(request, progress)
        }
        switch ran {
        case .success(let result):
            let database = absolutePath(result.databasePath, in: result.bundleURL)
            let track = result.annotationTrackInfo
            output.events.emitComplete(outputs: [database], message: "Created annotation track \"\(track.name)\".")
            output.say("Created annotation track '\(track.name)' (\(track.id)) from mapped reads.")
            output.say("Bundle: \(result.bundleURL.path)")
            output.say("Source alignment track: \(result.sourceAlignmentTrackID) (\(result.sourceAlignmentTrackName))")
            output.say("Database: \(database)")
            output.say("Converted reads: \(result.convertedRecordCount)")
            output.say("Skipped unmapped reads: \(result.skippedUnmappedCount)")
            output.say("Skipped secondary/supplementary reads: \(result.skippedSecondarySupplementaryCount)")
            return result
        case .failure(let error):
            if error is CancellationError || SIGTERMCancellation.signalCaught {
                throw output.cancelled(
                    "Conversion cancelled. The bundle was not changed.",
                    record: cancelledRecord(startedAt: startedAt)
                )
            }
            if let serviceError = error as? MappedReadsAnnotationServiceError, serviceError.isRefusal {
                throw output.refused(error.localizedDescription)
            }
            throw output.failed(error.localizedDescription)
        }
    }

    private func cancelledRecord(startedAt: Date) -> CancelledAlignmentWorkflowRecord {
        CancelledAlignmentWorkflowRecord(
            workflow: "lungfish bam annotate",
            argv: MappedReadsAnnotationService.cliArgv(
                request: request,
                bundleURL: request.bundleURL,
                outputTrackName: request.outputTrackName
            ),
            explicit: [
                "alignmentTrack": .string(sourceTrackID),
                "outputTrackName": .string(request.outputTrackName),
            ],
            note: "Cancelled before the annotation track was published. The bundle was not changed.",
            startedAt: startedAt,
            url: CancelledAlignmentWorkflowRecord.newURL(
                in: CancelledAlignmentWorkflowRecord.folder(in: request.bundleURL),
                workflow: "lungfish bam annotate"
            )
        )
    }
}

private extension MappedReadsAnnotationServiceError {
    /// The errors that name a request the service cannot take, before it writes anything.
    var isRefusal: Bool {
        switch self {
        case .sourceTrackNotFound, .outputTrackExists, .invalidOutputTrackID: return true
        default: return false
        }
    }
}

/// `path` as the service stored it, made absolute within `bundleURL` when it is relative.
private func absolutePath(_ path: String, in bundleURL: URL) -> String {
    path.hasPrefix("/") ? path : bundleURL.appendingPathComponent(path).path
}

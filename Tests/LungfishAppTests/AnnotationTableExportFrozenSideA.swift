// AnnotationTableExportFrozenSideA.swift - Side A of the annotation table export parity class, frozen
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.39 (B2), ARCH ruling on the export shape 1.7, R-A1. The lane deletes the app's in-process table
// writer once `bundle export-annotation-table` runs behind the row, so `AnnotationTableExportCLIGUIParityReplayTests`
// keeps it here as its side A.

import Foundation
@testable import LungfishApp
import LungfishCore
import LungfishWorkflow

/// `AnnotationTableExportService.export` with the retained-selection helper's `init` and `publish(_:
/// preserveOriginalSources: true)`, inlined as it stood at 9d5378e3e. It retains the snapshot and the payload in a new
/// `.lungfish-export-inputs/<UUID>/` folder beside the output, then publishes the payload and its record in one
/// transaction with the `/bin/cp` replay, the old argv and the two replay keys.
enum AnnotationTableExportFrozenSideA {
    static let replayScope = "retained-selection snapshot byte replay"

    static func export(
        snapshot: AnnotationTableExportSnapshot,
        format: ScientificTableFormat,
        outputURL: URL,
        runClock: ProvenanceRunClock = ProvenanceRunClock(),
        shouldCancel: @Sendable () -> Bool = { false }
    ) throws {
        if shouldCancel() { throw ScientificTableWriterError.cancelled }
        guard !snapshot.sourceURLs.isEmpty else {
            throw AnnotationTableExportServiceError.noScientificSources
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let directory = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".lungfish-export-inputs/\(UUID())", isDirectory: true)
        let payloadURL = directory.appendingPathComponent("selected." + outputURL.pathExtension)
        let selectionURL = directory.appendingPathComponent("selection.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(snapshot).write(to: selectionURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        do {
            let writerReport = try ScientificTableWriter.writeWithReport(
                snapshot.table, format: format, to: payloadURL, shouldCancel: shouldCancel
            )
            if shouldCancel() { throw ScientificTableWriterError.cancelled }
            var argv = [
                "Lungfish.app", "export-annotation-table",
                "--tab", snapshot.tab,
                "--scope", snapshot.scope.rawValue,
                "--format", format.rawValue,
                "--output", outputURL.path,
            ]
            for sourceURL in snapshot.sourceURLs {
                argv.append(contentsOf: ["--source", sourceURL.path])
            }
            var resolved = snapshot.recordResolved(writerReport: writerReport)
            resolved["replayScope"] = .string(replayScope)
            resolved["replaysUpstreamAnalysis"] = .boolean(false)
            var seen = Set<String>()
            let sourceURLs = (snapshot.sourceURLs + [payloadURL, selectionURL]).filter {
                seen.insert($0.standardizedFileURL.path).inserted
            }
            try ScientificFileExportProvenance.writeAtomically(.init(
                workflowName: "lungfish app annotation table export",
                sourceURLs: sourceURLs,
                outputURL: outputURL,
                outputFormat: AnnotationTableExportSnapshot.provenanceFormat(format),
                argv: argv,
                durableReplayArgv: ["/bin/cp", payloadURL.path, outputURL.path],
                explicitOptions: [
                    "sourcePaths": .array(snapshot.sourceURLs.map(ParameterValue.file)),
                    "outputPath": .file(outputURL),
                    "outputFormat": .string(format.rawValue),
                    "scope": .string(snapshot.scope.rawValue),
                    "tab": .string(snapshot.tab),
                ],
                defaults: AnnotationTableExportSnapshot.recordDefaults,
                resolved: resolved,
                runClock: runClock
            )) { stagedURL in
                try FileManager.default.copyItem(at: payloadURL, to: stagedURL)
            }
        } catch {
            if !(error is ScientificPublicationRecoveryRequired) {
                try? FileManager.default.removeItem(at: directory)
            }
            throw error
        }
    }
}

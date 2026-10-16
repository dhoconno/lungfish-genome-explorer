// ViewerViewController+AnnotatedReferenceImport.swift - The annotated reference import of a FASTA selection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishOperations
import LungfishWorkflow
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "ViewerViewController")

/// The annotated reference import of a FASTA selection lives here, moved out of
/// ViewerViewController.swift, which is at its size baseline (2.11 A48 M3).
extension ViewerViewController {
    func createReferenceBundle(
        from records: [String],
        suggestedName: String,
        annotationsByRecord: [String: [SequenceAnnotation]],
        sourceAlignmentBundleURL: URL? = nil
    ) {
        guard !annotationsByRecord.isEmpty else {
            createReferenceBundle(from: records, suggestedName: suggestedName)
            return
        }
        let projectURL = projectURLForDerivedReferenceBundle(sourceAlignmentBundleURL: sourceAlignmentBundleURL)
        guard canWriteProjectOutputs(projectURL: projectURL, workflowName: "Annotated reference import") else { return }
        guard !records.isEmpty, let projectURL else {
            createReferenceBundle(from: records, suggestedName: suggestedName)
            return
        }

        let stagingRoot: URL
        let durableSourceURLs = ([sourceAlignmentBundleURL] + fastaExportSourceURLs()).compactMap { $0 }
        do {
            _ = try ReferenceSequenceFolder.ensureFolder(in: projectURL)
            // The FASTA, the BED and the selection are one annotation-extraction
            // staging set. Keep them in a plain registered session directory rather
            // than appending an unrecorded BED file to a provenance-bearing FASTA bundle.
            stagingRoot = try TempFileManager.shared.createRegisteredTempDirectory(
                prefix: "lungfish-fasta-ops-annotated-"
            )
        } catch {
            presentBlockingAlert(title: "Annotated Reference Import Failed", message: error.localizedDescription)
            return
        }

        let stem = Self.sanitizedFilesystemStem(suggestedName)
        let sourceURL = stagingRoot.appendingPathComponent("selection.fasta")
        let annotationURL = stagingRoot.appendingPathComponent("selected-annotations.bed")
        // The BED drops each annotation's id, chromosome and note, which the extraction record
        // keeps, so the selection goes to the command beside it (ruling A48 F2, BIO 4).
        let selectionURL = stagingRoot.appendingPathComponent("selected-annotations.json")
        do {
            try records.joined(separator: "").write(to: sourceURL, atomically: true, encoding: .utf8)
            try Self.writeAnnotationBED(annotationsByRecord, to: annotationURL)
            try JSONEncoder().encode(MSAExtractionAnnotationProvenance.annotationSelectionValue(annotationsByRecord))
                .write(to: selectionURL)
        } catch {
            TempFileManager.shared.unregisterSessionTempDirectory(stagingRoot)
            try? FileManager.default.removeItem(at: stagingRoot)
            logger.error("createReferenceBundle: Could not stage annotated MSA extraction - \(error.localizedDescription, privacy: .public)")
            presentBlockingAlert(title: "Annotated Reference Import Failed", message: error.localizedDescription)
            return
        }

        // The import runs `import fasta` (2.11 A48 M3), which builds the bundle, attaches the BED as
        // a track and writes the extraction record, so the app writes nothing after it exits.
        let arguments = AppDelegate.referenceImportArguments(
            sourceURL: sourceURL,
            projectURL: projectURL,
            preferredBundleName: suggestedName,
            provenanceInputFiles: durableSourceURLs,
            annotationsURL: annotationURL,
            annotationSelectionURL: selectionURL,
            sourceAlignmentBundleURL: sourceAlignmentBundleURL
        )
        let startResult = Self.beginAnnotatedReferenceImportOperation(
            arguments: arguments,
            bundleStem: stem,
            routeContext: OperationRouteContext(projectURL: projectURL, windowStateScope: windowStateScope)
        ) { opID in
            Task { @MainActor in
                defer {
                    TempFileManager.shared.unregisterSessionTempDirectory(stagingRoot)
                    try? FileManager.default.removeItem(at: stagingRoot)
                }
                let outcome = await AppDelegate.runReferenceImport(
                    arguments: arguments,
                    operationID: opID,
                    detail: Self.annotatedReferenceImportDetail(bundleURL:),
                    run: { arguments, id in try await CLIBundleBuildRunner.launch(arguments: arguments, operationID: id) }
                )
                if let error = outcome.error {
                    logger.error("createReferenceBundle: Annotated bundle creation failed - \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if case .refused = startResult {
            // Nothing was launched, so nothing else removes the staged files.
            TempFileManager.shared.unregisterSessionTempDirectory(stagingRoot)
            try? FileManager.default.removeItem(at: stagingRoot)
        }
    }

    /// The row's complete words for the annotated bundle at `bundleURL`, with the feature count of
    /// the track the command attached, read from its manifest.
    nonisolated static func annotatedReferenceImportDetail(bundleURL: URL) -> String {
        let featureCount = (try? BundleManifest.load(from: bundleURL))?.annotations
            .reduce(0) { $0 + ($1.featureCount ?? 0) } ?? 0
        return "Created \(bundleURL.lastPathComponent) with \(featureCount) annotation(s)"
    }

    nonisolated private static func writeAnnotationBED(
        _ annotationsByRecord: [String: [SequenceAnnotation]],
        to url: URL
    ) throws {
        let lines = annotationsByRecord.keys.sorted().flatMap { recordName -> [String] in
            annotationsByRecord[recordName, default: []].compactMap { annotation in
                guard !annotation.intervals.isEmpty else { return nil }
                // BED12 requires blockStarts strictly ascending relative to chromStart,
                // regardless of the feature's transcription-order interval storage
                // (SequenceAnnotation preserves parser order, which for an
                // origin-spanning circular feature is not genomic-ascending).
                let genomicOrder = annotation.intervals.sorted { $0.start < $1.start }
                let start = genomicOrder.first?.start ?? 0
                let end = genomicOrder.map(\.end).max() ?? start
                guard end > start else { return nil }
                let blockSizes = genomicOrder.map { "\($0.length)" }.joined(separator: ",") + ","
                let blockStarts = genomicOrder.map { "\($0.start - start)" }.joined(separator: ",") + ","
                let attributes = annotation.qualifiers
                    .map { key, qualifier in
                        "\(escapeBEDAttribute(key))=\(qualifier.values.map(escapeBEDAttribute).joined(separator: ","))"
                    }
                    .sorted()
                    .joined(separator: ";")
                return [
                    sanitizeBEDField(recordName),
                    "\(start)",
                    "\(end)",
                    sanitizeBEDField(annotation.name),
                    "0",
                    annotation.strand.rawValue,
                    "\(start)",
                    "\(end)",
                    "0,0,0",
                    "\(annotation.intervals.count)",
                    blockSizes,
                    blockStarts,
                    annotation.type.rawValue,
                    attributes,
                ].joined(separator: "\t")
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    nonisolated private static func sanitizeBEDField(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func escapeBEDAttribute(_ value: String) -> String {
        sanitizeBEDField(value)
            .replacingOccurrences(of: ";", with: "%3B")
            .replacingOccurrences(of: "=", with: "%3D")
    }
}

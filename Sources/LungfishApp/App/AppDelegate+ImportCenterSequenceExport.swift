// AppDelegate+ImportCenterSequenceExport.swift - The Import Center's sequence export, moved out of AppDelegate+ImportCenter.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishOperations
import LungfishWorkflow

/// The Import Center's sequence export lives here, moved out of
/// AppDelegate+ImportCenter.swift, which is at its size baseline. It holds the
/// single and batch export, the recorded `convert` commands and the in-app
/// writer for a selection `convert` cannot read.
extension AppDelegate {

    /// Exports the sources to `outputURL` and returns the count of sequences written.
    ///
    /// A selection of files that `convert` reads, reference bundles included, runs as
    /// `lungfish-cli convert` (``SequenceExportRoute``), the command the row records, and the command
    /// compresses. A selection with a captured document snapshot, or a file `convert` does not read, is
    /// written here and compressed on the same ``SequenceExportCompressor``.
    nonisolated func performSequenceExport(
        sources: [SequenceExportSourceResolver.Source],
        outputURL: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) async throws -> Int {
        let runClock = ProvenanceRunClock()
        let containsCapturedDocuments = sources.contains { $0.document != nil }
        if !containsCapturedDocuments, !sources.isEmpty,
           sources.allSatisfy({ SequenceExportRoute.convertReads($0.metadata.url) }) {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return try await SequenceExportRoute.run(
                arguments: SequenceExportRoute.arguments(
                    inputs: sources.map { $0.metadata.url },
                    outputURL: outputURL,
                    format: format,
                    compression: compression
                ),
                outputURL: outputURL
            )
        }

        // Collect all sequences and annotations
        var allSequences: [LungfishCore.Sequence] = []
        var allAnnotations: [SequenceAnnotation] = []
        var sourceRecords: [(LungfishCore.Sequence, [SequenceAnnotation])] = []

        for source in sources {
            try Task.checkCancellation()
            let sequences: [LungfishCore.Sequence]
            let annotations: [SequenceAnnotation]
            if let document = source.document {
                sequences = document.sequences
                annotations = document.annotations
            } else {
                (sequences, annotations) = try await loadSequencesForExport(from: source.metadata.url)
            }
            allSequences.append(contentsOf: sequences)
            allAnnotations.append(contentsOf: annotations)
            sourceRecords.append(contentsOf: sequences.map { ($0, annotations) })
        }

        guard !allSequences.isEmpty else {
            throw NSError(domain: "com.lungfish.browser", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No sequences found in selected files."])
        }

        let exportTempDir = try ProjectTempDirectory.createFromContext(prefix: "export-", contextURL: outputURL)
        defer { try? FileManager.default.removeItem(at: exportTempDir) }
        let writeURL = exportTempDir.appendingPathComponent("export.\(format == .genbank ? "gb" : "fa")")

        // Write the file
        switch format {
        case .fasta:
            let writer = FASTAWriter(url: writeURL)
            try writer.write(allSequences)

        case .genbank:
            var records: [GenBankRecord] = []
            for (sequence, sourceAnnotations) in sourceRecords {
                let seqAnnotations = sourceAnnotations.filter {
                    $0.chromosome == nil || $0.chromosome == sequence.name
                }
                let moleculeType: MoleculeType
                switch sequence.alphabet {
                case .dna: moleculeType = .dna
                case .rna: moleculeType = .rna
                case .protein: moleculeType = .protein
                }
                let locus = LocusInfo(
                    name: sequence.name,
                    length: sequence.length,
                    moleculeType: moleculeType,
                    topology: .linear,
                    division: nil,
                    date: Self.currentDateString()
                )
                records.append(GenBankRecord(
                    sequence: sequence,
                    annotations: seqAnnotations,
                    locus: locus,
                    definition: sequence.description,
                    accession: nil,
                    version: nil
                ))
            }
            let writer = GenBankWriter(url: writeURL)
            try writer.write(records)
        }

        // Compress the written file before the record is written, so the writer below copies a finished payload.
        let payloadURL: URL
        if let kind = compression.compressorKind {
            payloadURL = exportTempDir.appendingPathComponent(writeURL.lastPathComponent + "." + kind.fileExtension)
            try await SequenceExportCompressor.compress(source: writeURL, to: payloadURL, kind: kind)
        } else {
            payloadURL = writeURL
        }

        let sourceURLs = sources.map { $0.metadata.url }
        let selectionMetadata = try containsCapturedDocuments ? JSONEncoder().encode(sources.map(\.metadata)) : nil
        try Self.writeSequenceExportProvenance(
            sourceURLs: sourceURLs,
            outputURL: outputURL,
            format: format,
            compression: compression,
            sequenceCount: allSequences.count,
            annotationCount: allAnnotations.count,
            runClock: runClock,
            selectionMetadata: selectionMetadata
        ) { staged in
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: payloadURL, to: staged)
            try Task.checkCancellation()
        }

        return allSequences.count
    }

    nonisolated static func batchSequenceExportTargets(
        for bundleURLs: [URL],
        outputFolder: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) -> [URL: URL] {
        var usedNames = Set<String>()
        var targets: [URL: URL] = [:]

        for bundleURL in bundleURLs {
            let rawBase = bundleURL.deletingPathExtension().lastPathComponent
            let base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "reference" : rawBase
            var filename = "\(base).\(format.fileExtension)"
            if let compressionExtension = compression.fileExtension {
                filename += ".\(compressionExtension)"
            }

            if usedNames.contains(filename) {
                var counter = 2
                repeat {
                    filename = "\(base)-\(counter).\(format.fileExtension)"
                    if let compressionExtension = compression.fileExtension {
                        filename += ".\(compressionExtension)"
                    }
                    counter += 1
                } while usedNames.contains(filename)
            }

            usedNames.insert(filename)
            targets[bundleURL] = outputFolder.appendingPathComponent(filename)
        }

        return targets
    }

    /// The `convert` command of each bundle, in order, which the batch runs one after another.
    nonisolated static func batchSequenceExportCLICommands(
        for bundleURLs: [URL],
        outputFolder: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) -> [String] {
        let targets = batchSequenceExportTargets(
            for: bundleURLs,
            outputFolder: outputFolder,
            format: format,
            compression: compression
        )
        return bundleURLs.compactMap { bundleURL in
            guard let outputURL = targets[bundleURL] else { return nil }
            return sequenceExportCLICommand(
                inputURLs: [bundleURL],
                outputURL: outputURL,
                format: format,
                compression: compression
            )
        }
    }

    /// The `lungfish-cli convert` command the export runs, which the row records. It is nil when there is no
    /// file for `convert` to read, which is a selection with a captured document snapshot, or when `convert`
    /// cannot read one of the files.
    nonisolated static func sequenceExportCLICommand(
        inputURLs: [URL],
        outputURL: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) -> String? {
        guard !inputURLs.isEmpty, inputURLs.allSatisfy(SequenceExportRoute.convertReads) else { return nil }
        let arguments = SequenceExportRoute.arguments(
            inputs: inputURLs,
            outputURL: outputURL,
            format: format,
            compression: compression
        )
        return OperationCenter.buildCLICommand(subcommand: "convert", args: Array(arguments.dropFirst()))
    }

    @discardableResult
    nonisolated private static func writeSequenceExportProvenance(
        sourceURLs: [URL],
        outputURL: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression,
        sequenceCount: Int,
        annotationCount: Int,
        runClock: ProvenanceRunClock,
        selectionMetadata: Data? = nil,
        writeOutput: (URL) throws -> Void
    ) throws -> URL {
        let request = ScientificFileExportProvenance.Request(
            workflowName: "lungfish app sequence export",
            sourceURLs: sourceURLs.map(\.standardizedFileURL),
            outputURL: outputURL,
            outputFormat: sequenceExportProvenanceFormat(for: format),
            argv: sequenceExportProvenanceArgv(
                sourceURLs: sourceURLs,
                outputURL: outputURL,
                format: format,
                compression: compression
            ),
            explicitOptions: [
                "outputPath": .file(outputURL),
                "format": .string(format.cliFormat),
                "compression": .string(compression.provenanceValue),
            ],
            defaults: [
                "includeAnnotations": .boolean(true),
            ],
            resolved: [
                "sourceCount": .integer(sourceURLs.count),
                "sequenceCount": .integer(sequenceCount),
                "annotationCount": .integer(annotationCount),
                "format": .string(format.cliFormat),
                "compression": .string(compression.provenanceValue),
            ],
            runClock: runClock
        )
        if let selectionMetadata {
            let snapshot = try RetainedSelectionExportSnapshot(outputURL: outputURL, selectionMetadata: selectionMetadata)
            do {
                try writeOutput(snapshot.payloadURL)
                try snapshot.publish(request)
                return ProvenanceRecorder.fileSidecarURL(for: outputURL)
            } catch {
                snapshot.discardAfterFailure(error)
                throw error
            }
        }
        return try ScientificFileExportProvenance.writeAtomically(request, writeOutput: writeOutput)
    }

    nonisolated private static func sequenceExportProvenanceArgv(
        sourceURLs: [URL],
        outputURL: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) -> [String] {
        var argv = ["Lungfish.app", "export-sequences"]
        for url in sourceURLs {
            argv.append(contentsOf: ["--input", url.path])
        }
        argv.append(contentsOf: [
            "--output", outputURL.path,
            "--format", format.cliFormat,
            "--compression", compression.provenanceValue,
        ])
        return argv
    }

    nonisolated private static func sequenceExportProvenanceFormat(for format: SequenceExportFormat) -> FileFormat {
        switch format {
        case .fasta:
            return .fasta
        case .genbank:
            return .genBank
        }
    }

    nonisolated func loadBundleAnnotations(bundleURL: URL, manifest: BundleManifest) throws -> [SequenceAnnotation] {
        var annotations: [SequenceAnnotation] = []
        for track in manifest.annotations {
            guard let dbPath = track.databasePath else { continue }
            guard let dbURL = try? BundleManifest.validatedBundleMemberURL(
                for: dbPath,
                in: bundleURL,
                field: "annotations[\(track.id)].databasePath"
            ) else { continue }
            guard FileManager.default.fileExists(atPath: dbURL.path) else { continue }
            let db = try AnnotationDatabase(url: dbURL)
            let records = db.query(limit: Int.max)
            annotations.append(contentsOf: records.map { $0.toAnnotation() })
        }
        return annotations
    }
}

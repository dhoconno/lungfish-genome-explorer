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
/// single and batch export, the reference bundle export and their provenance.
extension AppDelegate {

    /// Loads sequences from sidebar URLs or documents, writes to output file, and optionally compresses.
    nonisolated func performSequenceExport(
        sources: [SequenceExportSourceResolver.Source],
        outputURL: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) async throws -> Int {
        let runClock = ProvenanceRunClock()
        let sidebarURLs = sources.filter { $0.document == nil }.map { $0.metadata.url }
        let containsCapturedDocuments = sources.contains { $0.document != nil }
        if !containsCapturedDocuments, sidebarURLs.count == 1,
           let bundleURL = sidebarURLs.first,
           bundleURL.pathExtension.lowercased() == "lungfishref" {
            return try await performReferenceBundleSequenceExport(
                bundleURL: bundleURL,
                outputURL: outputURL,
                format: format,
                compression: compression
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
            if compression == .none {
                try FileManager.default.copyItem(at: writeURL, to: staged)
            } else {
                try compressExportFile(writeURL, to: staged, compression: compression)
            }
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
                inputURL: bundleURL,
                outputURL: outputURL,
                format: format,
                compression: compression
            )
        }
    }

    nonisolated static func sequenceExportCLICommand(
        inputURL: URL?,
        outputURL: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) -> String? {
        guard let inputURL else { return nil }
        guard compression == .none else { return nil }
        if inputURL.pathExtension.lowercased() == "lungfishref" {
            let args = Array(referenceBundleSequenceExportCLIArguments(
                bundleURL: inputURL,
                outputURL: outputURL,
                format: format
            ).dropFirst())
            return OperationCenter.buildCLICommand(subcommand: "convert", args: args)
        }
        var args = [
            inputURL.path,
            "--to", outputURL.path,
            "--to-format", format.cliFormat,
        ]
        // The run keeps the source file's annotations in a GenBank export, and
        // `convert` drops them unless it is told to include them.
        if format == .genbank { args.append("--include-annotations") }
        args.append("--force")
        return OperationCenter.buildCLICommand(subcommand: "convert", args: args)
    }

    nonisolated static func referenceBundleSequenceExportCLIArguments(
        bundleURL: URL,
        outputURL: URL,
        format: SequenceExportFormat
    ) -> [String] {
        [
            "convert",
            bundleURL.path,
            "--to", outputURL.path,
            "--to-format", format.cliFormat,
            "--include-annotations",
            "--force",
            "--quiet",
        ]
    }

    nonisolated private func performReferenceBundleSequenceExport(
        bundleURL: URL,
        outputURL: URL,
        format: SequenceExportFormat,
        compression: SequenceExportCompression
    ) async throws -> Int {
        let runClock = ProvenanceRunClock()
        let manifest = try BundleManifest.load(from: bundleURL)
        try Task.checkCancellation()
        guard let genome = manifest.genome, !genome.chromosomes.isEmpty else {
            throw NSError(domain: "com.lungfish.browser", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No genome sequence in bundle \(bundleURL.lastPathComponent)"])
        }

        if compression == .none {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let cliOutput = try await LungfishCLIRunner.run(arguments: Self.referenceBundleSequenceExportCLIArguments(
                bundleURL: bundleURL,
                outputURL: outputURL,
                format: format
            ))
            if !cliOutput.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                debugLog("performReferenceBundleSequenceExport: CLI stderr: \(cliOutput.stderr)")
            }
            return genome.chromosomes.count
        }

        let exportTempDir = try ProjectTempDirectory.createFromContext(prefix: "export-", contextURL: outputURL)
        defer { try? FileManager.default.removeItem(at: exportTempDir) }
        let writeURL = exportTempDir.appendingPathComponent("export.\(format.fileExtension)")

        let bundle = try await ReferenceBundle(url: bundleURL)
        let annotations = try loadBundleAnnotations(bundleURL: bundleURL, manifest: manifest)

        switch format {
        case .fasta:
            let writer = FASTAWriter(url: writeURL)
            for chromosome in genome.chromosomes {
                try Task.checkCancellation()
                let sequence = try await sequenceForWholeChromosome(chromosome, in: bundle)
                try writer.append(sequence)
            }
        case .genbank:
            let writer = GenBankWriter(url: writeURL)
            for chromosome in genome.chromosomes {
                try Task.checkCancellation()
                let sequence = try await sequenceForWholeChromosome(chromosome, in: bundle)
                let seqAnnotations = annotations.filter {
                    $0.chromosome == nil || $0.chromosome == sequence.name
                }
                let locus = LocusInfo(
                    name: sequence.name,
                    length: sequence.length,
                    moleculeType: .dna,
                    topology: .linear,
                    division: nil,
                    date: Self.currentDateString()
                )
                let record = GenBankRecord(
                    sequence: sequence,
                    annotations: seqAnnotations,
                    locus: locus,
                    definition: sequence.description,
                    accession: nil,
                    version: nil
                )
                try writer.append(record)
            }
        }

        try Self.writeSequenceExportProvenance(
            sourceURLs: [bundleURL],
            outputURL: outputURL,
            format: format,
            compression: compression,
            sequenceCount: genome.chromosomes.count,
            annotationCount: annotations.count,
            runClock: runClock
        ) { staged in
            try Task.checkCancellation()
            try compressExportFile(writeURL, to: staged, compression: compression)
            try Task.checkCancellation()
        }

        return genome.chromosomes.count
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

    nonisolated private func sequenceForWholeChromosome(_ chromosome: ChromosomeInfo, in bundle: ReferenceBundle) async throws -> LungfishCore.Sequence {
        let region = GenomicRegion(chromosome: chromosome.name, start: 0, end: Int(chromosome.length))
        let bases = try await bundle.fetchSequence(region: region)
        return try LungfishCore.Sequence(
            name: chromosome.name,
            description: chromosome.fastaDescription,
            alphabet: .dna,
            bases: bases
        )
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

    nonisolated func compressExportFile(
        _ writeURL: URL,
        to outputURL: URL,
        compression: SequenceExportCompression
    ) throws {
        let process = Process()
        switch compression {
        case .gzip:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        case .zstd:
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zstd")
        case .none:
            return
        }
        process.arguments = ["-c", writeURL.path]
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "com.lungfish.browser", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Compression failed for \(outputURL.lastPathComponent)."])
        }
    }
}

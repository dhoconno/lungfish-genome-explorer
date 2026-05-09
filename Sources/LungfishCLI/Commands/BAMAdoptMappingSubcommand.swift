// BAMAdoptMappingSubcommand.swift - Attach a fresh `lungfish map` mapping result
// to a reference bundle as a new alignment track.
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension BAMCommand {
    struct AdoptMappingSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "adopt-mapping",
            abstract: "Attach a `lungfish map` result to a reference bundle as a new alignment track"
        )

        @Option(name: .customLong("bundle"), help: "Path to the reference bundle directory (.lungfishref)")
        var bundlePath: String

        @Option(name: .customLong("mapping-result"), help: "Path to the mapping analysis directory produced by `lungfish map`")
        var mappingResultPath: String

        @Option(name: .customLong("name"), help: "Display name for the new alignment track")
        var trackName: String

        @Option(name: .customLong("track-id"), help: "Override the auto-generated alignment track identifier")
        var trackIDOverride: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let startedAt = Date()
            let bundleURL = URL(fileURLWithPath: bundlePath)
            let mappingURL = URL(fileURLWithPath: mappingResultPath)
            let artifacts = try resolveMappingArtifacts(from: mappingURL)
            let bamURL = artifacts.bamURL
            let baiURL = artifacts.baiURL
            guard FileManager.default.fileExists(atPath: bamURL.path) else {
                throw ValidationError("Mapping result is missing BAM at \(bamURL.path)")
            }
            guard FileManager.default.fileExists(atPath: baiURL.path) else {
                throw ValidationError("Mapping result is missing BAM index at \(baiURL.path)")
            }
            let outputTrackID = trackIDOverride ?? "aln_\(UUID().uuidString.prefix(8))"
            let commandArgv = adoptMappingArgv(outputTrackID: String(outputTrackID))
            let inputRecords = adoptMappingInputRecords(mappingURL: mappingURL, bamURL: bamURL, baiURL: baiURL)
            let manifest = try BundleManifest.load(from: bundleURL)
            let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
            let originalManifestData = try Data(contentsOf: manifestURL)
            let request = PreparedAlignmentAttachmentRequest(
                bundleURL: bundleURL,
                stagedBAMURL: bamURL,
                stagedIndexURL: baiURL,
                outputTrackID: String(outputTrackID),
                outputTrackName: trackName,
                relativeDirectory: "alignments/mapped",
                format: .bam
            )
            let service = PreparedAlignmentAttachmentService(
                manifestSaver: { _, _ in }
            )
            let attachment = try await service.attach(request: request)
            do {
                try writeAdoptMappingProvenance(
                    bundleURL: bundleURL,
                    mappingURL: mappingURL,
                    attachment: attachment,
                    commandArgv: commandArgv,
                    inputRecords: inputRecords,
                    startedAt: startedAt,
                    completedAt: Date()
                )
                try PreparedAlignmentAttachmentService.atomicManifestSave(
                    manifest: manifest.addingAlignmentTrack(attachment.trackInfo),
                    bundleURL: bundleURL
                )
            } catch {
                rollbackAdoptedMappingArtifacts(attachment: attachment, originalManifestData: originalManifestData, manifestURL: manifestURL)
                throw error
            }
            if !globalOptions.quiet {
                print("Attached alignment track '\(trackName)' (\(outputTrackID)) to bundle.")
            }
        }

        private func resolveMappingArtifacts(from mappingURL: URL) throws -> (bamURL: URL, baiURL: URL) {
            if MappingResult.exists(in: mappingURL) {
                let result = try MappingResult.load(from: mappingURL)
                return (result.bamURL, result.baiURL)
            }
            return (
                mappingURL.appendingPathComponent("sorted.bam"),
                mappingURL.appendingPathComponent("sorted.bam.bai")
            )
        }

        private func adoptMappingArgv(outputTrackID: String) -> [String] {
            var argv = [
                "lungfish",
                "bam",
                "adopt-mapping",
                "--bundle", bundlePath,
                "--mapping-result", mappingResultPath,
                "--name", trackName,
                "--track-id", outputTrackID,
                "--format", globalOptions.outputFormat.rawValue
            ]
            if globalOptions.quiet {
                argv.append("--quiet")
            }
            return argv
        }

        private func adoptMappingInputRecords(
            mappingURL: URL,
            bamURL: URL,
            baiURL: URL
        ) -> [FileRecord] {
            var records = [
                ProvenanceRecorder.fileRecord(url: bamURL, format: .bam, role: .input),
                ProvenanceRecorder.fileRecord(url: baiURL, role: .index)
            ]
            let mappingResultURL = mappingURL.appendingPathComponent("mapping-result.json")
            if FileManager.default.fileExists(atPath: mappingResultURL.path) {
                records.append(ProvenanceRecorder.fileRecord(url: mappingResultURL, format: .json, role: .input))
            }
            let legacyMappingResultURL = mappingURL.appendingPathComponent("alignment-result.json")
            if FileManager.default.fileExists(atPath: legacyMappingResultURL.path) {
                records.append(ProvenanceRecorder.fileRecord(url: legacyMappingResultURL, format: .json, role: .input))
            }
            let sourceProvenanceURL = mappingURL.appendingPathComponent(MappingProvenance.filename)
            if FileManager.default.fileExists(atPath: sourceProvenanceURL.path) {
                records.append(ProvenanceRecorder.fileRecord(url: sourceProvenanceURL, format: .json, role: .input))
            }
            return records
        }

        private func writeAdoptMappingProvenance(
            bundleURL: URL,
            mappingURL: URL,
            attachment: PreparedAlignmentAttachmentResult,
            commandArgv: [String],
            inputRecords: [FileRecord],
            startedAt: Date,
            completedAt: Date
        ) throws {
            let finalDirectoryURL = attachment.bamURL.deletingLastPathComponent()
            let preservedMappingProvenanceURL = try preserveMappingProvenance(
                from: mappingURL,
                to: finalDirectoryURL,
                bundleURL: bundleURL
            )
            let provenanceURL = attachment.bamURL
                .deletingPathExtension()
                .appendingPathExtension("adopt-mapping-provenance.json")
            let wallTime = completedAt.timeIntervalSince(startedAt)
            var outputRecords = [
                ProvenanceRecorder.fileRecord(url: attachment.bamURL, format: .bam, role: .output),
                ProvenanceRecorder.fileRecord(url: attachment.indexURL, role: .index),
                ProvenanceRecorder.fileRecord(url: attachment.metadataDBURL, role: .output)
            ]
            if let preservedMappingProvenanceURL {
                outputRecords.append(
                    ProvenanceRecorder.fileRecord(url: preservedMappingProvenanceURL, format: .json, role: .output)
                )
            }

            let step = StepExecution(
                toolName: "lungfish-cli",
                toolVersion: LungfishCLI.configuration.version,
                command: commandArgv,
                inputs: inputRecords,
                outputs: outputRecords,
                exitCode: 0,
                wallTime: wallTime,
                stderr: nil,
                startTime: startedAt,
                endTime: completedAt
            )
            let run = WorkflowRun(
                name: "lungfish bam adopt-mapping",
                startTime: startedAt,
                endTime: completedAt,
                status: .completed,
                appVersion: "lungfish-cli \(LungfishCLI.configuration.version)",
                hostOS: WorkflowRun.currentHostOS,
                steps: [step],
                parameters: [
                    "bundlePath": .string(bundleURL.standardizedFileURL.path),
                    "mappingResultPath": .string(mappingURL.standardizedFileURL.path),
                    "trackName": .string(trackName),
                    "trackID": .string(attachment.trackInfo.id),
                    "trackIDWasDefaulted": .boolean(trackIDOverride == nil),
                    "relativeDirectory": .string("alignments/mapped"),
                    "format": .string(attachment.trackInfo.format.rawValue),
                    "quiet": .boolean(globalOptions.quiet),
                    "outputFormat": .string(globalOptions.outputFormat.rawValue),
                    "containerRuntime": .string("none"),
                    "condaEnvironment": .string("none"),
                    "sourceMappingProvenancePath": preservedMappingProvenanceURL.map {
                        .string(bundleRelativePath(for: $0, bundleURL: bundleURL))
                    } ?? .null,
                    "adoptMappingProvenancePath": .string(bundleRelativePath(for: provenanceURL, bundleURL: bundleURL))
                ]
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(run).write(to: provenanceURL, options: .atomic)

            let metadataDB = try AlignmentMetadataDatabase.openForUpdate(at: attachment.metadataDBURL)
            metadataDB.setFileInfo(
                "adopt_mapping_provenance_path",
                value: bundleRelativePath(for: provenanceURL, bundleURL: bundleURL)
            )
            if let preservedMappingProvenanceURL {
                metadataDB.setFileInfo(
                    "source_mapping_provenance_path",
                    value: bundleRelativePath(for: preservedMappingProvenanceURL, bundleURL: bundleURL)
                )
            }
            metadataDB.addProvenanceRecord(
                tool: "lungfish-cli",
                subcommand: "bam adopt-mapping",
                version: LungfishCLI.configuration.version,
                command: commandArgv.map(shellEscape).joined(separator: " "),
                timestamp: startedAt,
                inputFile: mappingURL.standardizedFileURL.path,
                outputFile: attachment.bamURL.standardizedFileURL.path,
                exitCode: 0,
                duration: wallTime
            )
        }

        private func preserveMappingProvenance(
            from mappingURL: URL,
            to finalDirectoryURL: URL,
            bundleURL: URL
        ) throws -> URL? {
            let sourceURL = mappingURL.appendingPathComponent(MappingProvenance.filename)
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                return nil
            }

            let destinationURL = finalDirectoryURL.appendingPathComponent(MappingProvenance.filename)
            if let provenance = MappingProvenance.load(from: mappingURL) {
                try provenance.withViewerBundleURL(bundleURL).save(to: finalDirectoryURL)
            } else {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
            return destinationURL
        }

        private func rollbackAdoptedMappingArtifacts(
            attachment: PreparedAlignmentAttachmentResult,
            originalManifestData: Data,
            manifestURL: URL
        ) {
            let provenanceURL = attachment.bamURL
                .deletingPathExtension()
                .appendingPathExtension("adopt-mapping-provenance.json")
            let rehydratedMappingProvenanceURL = attachment.bamURL
                .deletingLastPathComponent()
                .appendingPathComponent(MappingProvenance.filename)
            for url in [
                provenanceURL,
                rehydratedMappingProvenanceURL,
                attachment.metadataDBURL,
                attachment.indexURL,
                attachment.bamURL,
            ] {
                try? FileManager.default.removeItem(at: url)
            }
            try? originalManifestData.write(to: manifestURL, options: .atomic)
        }

        private func bundleRelativePath(for url: URL, bundleURL: URL) -> String {
            let bundlePath = bundleURL.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
            guard path.hasPrefix(prefix) else {
                return path
            }
            return String(path.dropFirst(prefix.count))
        }
    }
}

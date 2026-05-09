// BAMPrimerTrimSubcommand.swift - lungfish-cli bam primer-trim
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension BAMCommand {
    /// Errors raised by `bam primer-trim` before delegating to the pipeline. Conforms
    /// to `LocalizedError` so `error.localizedDescription` carries the message text
    /// (ArgumentParser's `ValidationError` does not).
    struct PrimerTrimRuntimeError: Error, LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    /// Result returned by `executeForTesting`. Mirrors the CLI's `runComplete`
    /// payload but is consumable from Swift tests without re-parsing JSON.
    struct PrimerTrimAdoptionResult: Sendable {
        let trackInfo: AlignmentTrackInfo
        let bamURL: URL
        let indexURL: URL
        let provenanceSidecarURL: URL
    }

    /// Wire-format event for the JSON output mode. One JSON object per line.
    struct PrimerTrimEvent: Codable, Sendable {
        let event: String
        let progress: Double?
        let message: String
        let bundlePath: String?
        let sourceAlignmentTrackID: String?
        let outputAlignmentTrackID: String?
        let outputAlignmentTrackName: String?
        let bamPath: String?
        let baiPath: String?
        let provenanceSidecarPath: String?
    }

    struct PrimerTrimSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "primer-trim",
            abstract: "Trim amplicon primers from a bundle BAM and adopt the result as a new alignment track"
        )

        @Option(name: .customLong("bundle"), help: "Path to the reference bundle directory (.lungfishref)")
        var bundlePath: String

        @Option(name: .customLong("alignment-track"), help: "Source alignment track identifier")
        var alignmentTrackID: String

        @Option(name: .customLong("scheme"), help: "Path to the .lungfishprimers bundle directory")
        var schemePath: String

        @Option(name: .customLong("name"), help: "Display name for the new primer-trimmed alignment track")
        var outputTrackName: String

        @Option(
            name: .customLong("target-reference"),
            help: "Override the @SQ SN used to resolve the primer scheme (defaults to the primer scheme's canonical accession)"
        )
        var targetReferenceName: String?

        @Option(name: .customLong("ivar-min-quality"), help: "Minimum Phred quality for the sliding-window trim")
        var ivarMinQuality: Int = 20

        @Option(name: .customLong("ivar-min-length"), help: "Minimum read length to retain after trimming")
        var ivarMinLength: Int = 30

        @Option(name: .customLong("ivar-sliding-window"), help: "Sliding-window width for ivar trim")
        var ivarSlidingWindow: Int = 4

        @Option(name: .customLong("ivar-primer-offset"), help: "Primer coordinate offset (bp)")
        var ivarPrimerOffset: Int = 0

        @OptionGroup var globalOptions: TextAndJSONGlobalOptions

        static func parse(_ arguments: [String]) throws -> Self {
            let trimmed = arguments.first == configuration.commandName
                ? Array(arguments.dropFirst())
                : arguments
            guard let parsed = try Self.parseAsRoot(trimmed) as? Self else {
                throw ValidationError("Failed to parse bam primer-trim arguments.")
            }
            return parsed
        }

        func validate() throws {
            if bundlePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--bundle must not be empty.")
            }
            if alignmentTrackID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--alignment-track must not be empty.")
            }
            if schemePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--scheme must not be empty.")
            }
            if outputTrackName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--name must not be empty.")
            }
        }

        func run() async throws {
            let resolvedGlobalOptions = try globalOptions.resolved(with: ProcessInfo.processInfo.arguments)
            let emit: (String) -> Void = { line in
                if resolvedGlobalOptions.outputFormat == .text && resolvedGlobalOptions.quiet {
                    return
                }
                print(line)
            }
            _ = try await execute(emit: emit, format: resolvedGlobalOptions.outputFormat)
        }

        func executeForTesting(emit: @escaping (String) -> Void) async throws -> BAMCommand.PrimerTrimAdoptionResult {
            try await execute(emit: emit, format: .text)
        }

        private func execute(
            emit: @escaping (String) -> Void,
            format: OutputFormat
        ) async throws -> BAMCommand.PrimerTrimAdoptionResult {
            let bundleURL = URL(fileURLWithPath: bundlePath)
            let schemeURL = URL(fileURLWithPath: schemePath)

            let emitEvent: (BAMCommand.PrimerTrimEvent) -> Void = { event in
                switch format {
                case .json:
                    if let line = encode(event: event) {
                        emit(line)
                    }
                case .text:
                    emit(event.message)
                default:
                    // OutputFormat has cases beyond .text/.json (e.g. .yaml) that this command
                    // does not produce a structured form for. Mirror .text so the user still
                    // sees progress lines.
                    emit(event.message)
                }
            }

            emitEvent(BAMCommand.PrimerTrimEvent(
                event: "runStart",
                progress: 0.0,
                message: "Starting primer trim",
                bundlePath: bundleURL.path,
                sourceAlignmentTrackID: alignmentTrackID,
                outputAlignmentTrackID: nil,
                outputAlignmentTrackName: outputTrackName,
                bamPath: nil,
                baiPath: nil,
                provenanceSidecarPath: nil
            ))

            // Resolve the bundle and source alignment track.
            let manifest: BundleManifest
            do {
                manifest = try BundleManifest.load(from: bundleURL)
            } catch {
                let wrapped = BAMCommand.PrimerTrimRuntimeError(
                    message: "Failed to load bundle manifest at \(bundleURL.path): \(error.localizedDescription)"
                )
                emitFailure(error: wrapped, emitEvent: emitEvent, bundleURL: bundleURL)
                throw wrapped
            }
            guard let sourceTrack = manifest.alignments.first(where: { $0.id == alignmentTrackID }) else {
                let err = BAMCommand.PrimerTrimRuntimeError(message: "Alignment track '\(alignmentTrackID)' not found in bundle manifest.")
                emitFailure(error: err, emitEvent: emitEvent, bundleURL: bundleURL)
                throw err
            }
            let sourceBAMURL = bundleURL.appendingPathComponent(sourceTrack.sourcePath)
            guard FileManager.default.fileExists(atPath: sourceBAMURL.path) else {
                let err = BAMCommand.PrimerTrimRuntimeError(message: "Source BAM missing on disk at \(sourceBAMURL.path).")
                emitFailure(error: err, emitEvent: emitEvent, bundleURL: bundleURL)
                throw err
            }

            // Reject name collisions deterministically before touching disk.
            if manifest.alignments.contains(where: { $0.name == outputTrackName }) {
                let err = BAMCommand.PrimerTrimRuntimeError(message: "An alignment track named '\(outputTrackName)' already exists in this bundle.")
                emitFailure(error: err, emitEvent: emitEvent, bundleURL: bundleURL)
                throw err
            }

            // Load the primer scheme.
            emitEvent(BAMCommand.PrimerTrimEvent(
                event: "preflightStart",
                progress: 0.02,
                message: "Resolving primer scheme",
                bundlePath: bundleURL.path,
                sourceAlignmentTrackID: alignmentTrackID,
                outputAlignmentTrackID: nil,
                outputAlignmentTrackName: outputTrackName,
                bamPath: nil,
                baiPath: nil,
                provenanceSidecarPath: nil
            ))
            let scheme: PrimerSchemeBundle
            do {
                scheme = try PrimerSchemeBundle.load(from: schemeURL)
            } catch {
                emitFailure(error: error, emitEvent: emitEvent, bundleURL: bundleURL)
                throw error
            }

            // Determine the target reference name (defaults to the scheme's canonical accession).
            let trimmedOverride = (targetReferenceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let targetReference = trimmedOverride.isEmpty ? scheme.manifest.canonicalAccession : trimmedOverride
            let workflowCommand = [
                "lungfish-cli", "bam", "primer-trim",
                "--bundle", bundleURL.path,
                "--alignment-track", alignmentTrackID,
                "--scheme", schemeURL.path,
                "--name", outputTrackName,
                "--target-reference", targetReference,
                "--ivar-min-quality", String(ivarMinQuality),
                "--ivar-min-length", String(ivarMinLength),
                "--ivar-sliding-window", String(ivarSlidingWindow),
                "--ivar-primer-offset", String(ivarPrimerOffset)
            ]

            emitEvent(BAMCommand.PrimerTrimEvent(
                event: "preflightComplete",
                progress: 0.08,
                message: "Scheme: \(scheme.manifest.name) (\(scheme.manifest.primerCount) primers)",
                bundlePath: bundleURL.path,
                sourceAlignmentTrackID: alignmentTrackID,
                outputAlignmentTrackID: nil,
                outputAlignmentTrackName: outputTrackName,
                bamPath: nil,
                baiPath: nil,
                provenanceSidecarPath: nil
            ))

            // Stage outputs in a temp directory. Adoption moves them into the bundle on success.
            let stagingRoot = try ProjectTempDirectory.create(
                prefix: "primer-trim-",
                contextURL: bundleURL,
                policy: .systemOnly
            )
            defer { try? FileManager.default.removeItem(at: stagingRoot) }
            let stagedBAMURL = stagingRoot.appendingPathComponent("trimmed.bam")

            let request = BAMPrimerTrimRequest(
                sourceBAMURL: sourceBAMURL,
                primerSchemeBundle: scheme,
                outputBAMURL: stagedBAMURL,
                minReadLength: ivarMinLength,
                minQuality: ivarMinQuality,
                slidingWindow: ivarSlidingWindow,
                primerOffset: ivarPrimerOffset,
                workflowCommand: workflowCommand
            )

            emitEvent(BAMCommand.PrimerTrimEvent(
                event: "stageStart",
                progress: 0.10,
                message: "ivar trim",
                bundlePath: bundleURL.path,
                sourceAlignmentTrackID: alignmentTrackID,
                outputAlignmentTrackID: nil,
                outputAlignmentTrackName: outputTrackName,
                bamPath: nil,
                baiPath: nil,
                provenanceSidecarPath: nil
            ))

            let pipelineResult: BAMPrimerTrimResult
            let emitterBox = PrimerTrimEventEmitter(emitEvent)
            let bundlePathString = bundleURL.path
            let sourceTrackID = alignmentTrackID
            let outputName = outputTrackName
            do {
                pipelineResult = try await BAMPrimerTrimPipeline.run(
                    request,
                    targetReferenceName: targetReference,
                    runner: NativeToolRunner.shared,
                    progress: { progress, message in
                        emitterBox.emit(BAMCommand.PrimerTrimEvent(
                            event: "stageProgress",
                            progress: 0.10 + (progress * 0.70),  // map pipeline 0–1 onto 0.10–0.80
                            message: message,
                            bundlePath: bundlePathString,
                            sourceAlignmentTrackID: sourceTrackID,
                            outputAlignmentTrackID: nil,
                            outputAlignmentTrackName: outputName,
                            bamPath: nil,
                            baiPath: nil,
                            provenanceSidecarPath: nil
                        ))
                    }
                )
            } catch {
                emitFailure(error: error, emitEvent: emitEvent, bundleURL: bundleURL)
                throw error
            }

            emitEvent(BAMCommand.PrimerTrimEvent(
                event: "stageComplete",
                progress: 0.80,
                message: "Pipeline complete; adopting into bundle",
                bundlePath: bundleURL.path,
                sourceAlignmentTrackID: alignmentTrackID,
                outputAlignmentTrackID: nil,
                outputAlignmentTrackName: outputTrackName,
                bamPath: nil,
                baiPath: nil,
                provenanceSidecarPath: nil
            ))

            // Adopt the trimmed BAM as a new alignment track.
            //
            // Rollback discipline: the provenance sidecar is NOT a known artifact to
            // PreparedAlignmentAttachmentService, so we have to land it ourselves.
            // We compute the final BAM path up-front from the pre-generated outputTrackID
            // (PreparedAlignmentAttachmentService names the BAM "<trackID>.bam" inside
            // <bundle>/<relativeDirectory>) and write the sidecar to its final location
            // BEFORE invoking attach. If attach then fails, the catch removes the orphan
            // sidecar — leaving the bundle fully unchanged. If attach succeeds, the
            // sidecar is already in place with final bundle paths; a later rewrite only
            // refreshes those records from the final files.
            let outputTrackID = Self.makeTrackID()
            let relativeDirectory = "alignments/primer-trimmed"
            let finalBAMURL = bundleURL
                .appendingPathComponent(relativeDirectory, isDirectory: true)
                .appendingPathComponent("\(outputTrackID).bam")
            let finalSidecarURL = PrimerTrimProvenanceLoader.sidecarURL(forBAMAt: finalBAMURL)

            emitEvent(BAMCommand.PrimerTrimEvent(
                event: "attachStart",
                progress: 0.90,
                message: "Adopting trimmed BAM into bundle",
                bundlePath: bundleURL.path,
                sourceAlignmentTrackID: alignmentTrackID,
                outputAlignmentTrackID: outputTrackID,
                outputAlignmentTrackName: outputTrackName,
                bamPath: nil,
                baiPath: nil,
                provenanceSidecarPath: nil
            ))

            // Land a final-path sidecar BEFORE attach so a failed attach can be
            // cleanly rolled back, and so any post-attach rewrite failure still
            // leaves provenance pointing at the bundle-owned payload paths. The
            // checksum and size values are preserved from the staged outputs here;
            // after attach succeeds, the sidecar is refreshed from the final files.
            do {
                try FileManager.default.createDirectory(
                    at: finalSidecarURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let finalIndexURL = URL(fileURLWithPath: finalBAMURL.path + ".bai")
                let provisionalFinalProvenance = pipelineResult.provenance.relocatingFinalOutputs(
                    outputBAMURL: finalBAMURL,
                    outputBAMIndexURL: finalIndexURL
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(provisionalFinalProvenance).write(to: finalSidecarURL, options: .atomic)
            } catch {
                emitFailure(error: error, emitEvent: emitEvent, bundleURL: bundleURL)
                throw error
            }

            let attachmentService = PreparedAlignmentAttachmentService()
            let attachmentRequest = PreparedAlignmentAttachmentRequest(
                bundleURL: bundleURL,
                stagedBAMURL: pipelineResult.outputBAMURL,
                stagedIndexURL: pipelineResult.outputBAMIndexURL,
                outputTrackID: outputTrackID,
                outputTrackName: outputTrackName,
                relativeDirectory: relativeDirectory
            )
            let attachment: PreparedAlignmentAttachmentResult
            do {
                attachment = try await attachmentService.attach(request: attachmentRequest)
            } catch {
                // Rollback: attach failed, so the manifest was not updated and the BAM/BAI
                // were not promoted. Remove the orphan sidecar so the bundle is fully
                // unchanged (no half-state).
                try? FileManager.default.removeItem(at: finalSidecarURL)
                emitFailure(error: error, emitEvent: emitEvent, bundleURL: bundleURL)
                throw error
            }

            do {
                let finalProvenance = pipelineResult.provenance.relocatingFinalOutputs(
                    outputBAMURL: attachment.bamURL,
                    outputBAMIndexURL: attachment.indexURL
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(finalProvenance).write(to: finalSidecarURL, options: .atomic)
            } catch {
                // A final-path sidecar was already written before attach. Keep the
                // successful attachment rather than reporting a failed command with a
                // valid bundle state.
            }

            emitEvent(BAMCommand.PrimerTrimEvent(
                event: "attachComplete",
                progress: 0.97,
                message: "Adopted track \(attachment.trackInfo.name)",
                bundlePath: bundleURL.path,
                sourceAlignmentTrackID: alignmentTrackID,
                outputAlignmentTrackID: attachment.trackInfo.id,
                outputAlignmentTrackName: attachment.trackInfo.name,
                bamPath: attachment.bamURL.path,
                baiPath: attachment.indexURL.path,
                provenanceSidecarPath: finalSidecarURL.path
            ))
            emitEvent(BAMCommand.PrimerTrimEvent(
                event: "runComplete",
                progress: 1.0,
                message: "Primer trim complete",
                bundlePath: bundleURL.path,
                sourceAlignmentTrackID: alignmentTrackID,
                outputAlignmentTrackID: attachment.trackInfo.id,
                outputAlignmentTrackName: attachment.trackInfo.name,
                bamPath: attachment.bamURL.path,
                baiPath: attachment.indexURL.path,
                provenanceSidecarPath: finalSidecarURL.path
            ))

            return BAMCommand.PrimerTrimAdoptionResult(
                trackInfo: attachment.trackInfo,
                bamURL: attachment.bamURL,
                indexURL: attachment.indexURL,
                provenanceSidecarURL: finalSidecarURL
            )
        }

        private func emitFailure(
            error: Error,
            emitEvent: (BAMCommand.PrimerTrimEvent) -> Void,
            bundleURL: URL
        ) {
            emitEvent(BAMCommand.PrimerTrimEvent(
                event: "runFailed",
                progress: nil,
                message: error.localizedDescription,
                bundlePath: bundleURL.path,
                sourceAlignmentTrackID: alignmentTrackID,
                outputAlignmentTrackID: nil,
                outputAlignmentTrackName: outputTrackName,
                bamPath: nil,
                baiPath: nil,
                provenanceSidecarPath: nil
            ))
        }

        private static func makeTrackID() -> String {
            "aln_\(String(UUID().uuidString.prefix(8)))"
        }
    }
}

private func encode(event: BAMCommand.PrimerTrimEvent) -> String? {
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(event) else { return nil }
    return String(data: data, encoding: .utf8)
}

private final class PrimerTrimEventEmitter: @unchecked Sendable {
    let emit: (BAMCommand.PrimerTrimEvent) -> Void

    init(_ emit: @escaping (BAMCommand.PrimerTrimEvent) -> Void) {
        self.emit = emit
    }
}

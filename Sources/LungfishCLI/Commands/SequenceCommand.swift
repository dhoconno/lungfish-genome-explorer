// SequenceCommand.swift - reference-bundle sequence annotation operations
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishWorkflow

struct SequenceCommand: AsyncParsableCommand {
    static let defaultFrames = "+1,+2,+3,-1,-2,-3"

    static let configuration = CommandConfiguration(
        commandName: "sequence",
        abstract: "Run CLI-backed operations on reference bundle sequences",
        subcommands: [
            AnnotateORFs.self,
            DeleteAnnotations.self,
            DeleteAnnotationTrack.self
        ]
    )

    struct AnnotateORFs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "annotate-orfs",
            abstract: "Find open reading frames and add them as a new annotation track"
        )

        @Argument(help: "Reference bundle to update")
        var bundle: String

        @Option(help: "Sequence/chromosome name. Defaults to the first sequence in the bundle.")
        var sequence: String?

        @Option(help: "0-based inclusive start coordinate. Defaults to 0.")
        var start: Int?

        @Option(help: "0-based exclusive end coordinate. Defaults to the sequence length.")
        var end: Int?

        @Option(help: "Comma-separated reading frames, e.g. +1,+2,+3,-1,-2,-3.")
        var frames: String = SequenceCommand.defaultFrames

        @Option(name: .customLong("table"), help: "NCBI genetic code table ID.")
        var table: Int = 1

        @Option(name: .customLong("min-length"), help: "Minimum ORF length in nucleotides.")
        var minLength: Int = 100

        @Flag(name: .customLong("include-partial"), help: "Include ORFs that run off the selected range.")
        var includePartial: Bool = false

        @Flag(name: .customLong("allow-alternative-starts"), help: "Allow alternative starts for the selected genetic code.")
        var allowAlternativeStarts: Bool = false

        @Option(name: .customLong("track-id"), help: "Annotation track ID. Defaults to a workflow-provided ID.")
        var trackID: String?

        @Option(name: .customLong("track-name"), help: "Annotation track display name.")
        var trackName: String?

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            guard minLength > 0 else {
                throw ValidationError("--min-length must be greater than zero.")
            }
            let normalizedSequence = sequence?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let normalizedTrackID = trackID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let normalizedTrackName = trackName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let parsedFrames = try parseReadingFrames(frames)
            let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL
            let resolved = try resolveSequenceRange(bundleURL: bundleURL, sequence: normalizedSequence, start: start, end: end)
            let request = SequenceAnnotationTrackWorkflow.Request(
                bundleURL: bundleURL,
                sequenceName: normalizedSequence,
                start: start,
                end: end,
                frames: parsedFrames,
                tableID: table,
                trackID: normalizedTrackID,
                trackName: normalizedTrackName,
                kind: .orf(
                    minLength: minLength,
                    includePartial: includePartial,
                    allowAlternativeStarts: allowAlternativeStarts
                ),
                command: provenanceCommandArguments(
                    subcommand: "annotate-orfs",
                    bundle: bundle,
                    sequence: normalizedSequence,
                    start: start,
                    end: end,
                    frames: frames,
                    table: table,
                    trackID: normalizedTrackID,
                    trackName: normalizedTrackName,
                    quiet: globalOptions.quiet,
                    extra: [
                        "--min-length", String(minLength),
                    ] + (includePartial ? ["--include-partial"] : [])
                      + (allowAlternativeStarts ? ["--allow-alternative-starts"] : [])
                ),
                explicitOptions: [
                    "operation": .string("annotate-orfs"),
                    "bundle": .file(bundleURL),
                    "sequence": normalizedSequence.map(ParameterValue.string) ?? .string(""),
                    "start": start.map(ParameterValue.integer) ?? .integer(0),
                    "end": end.map(ParameterValue.integer) ?? .integer(Int(resolved.chromosome.length)),
                    "frames": .string(frames),
                    "table": .integer(table),
                    "min_length": .integer(minLength),
                    "include_partial": .boolean(includePartial),
                    "allow_alternative_starts": .boolean(allowAlternativeStarts),
                    "track_id": normalizedTrackID.map(ParameterValue.string) ?? .string("orfs"),
                    "track_name": normalizedTrackName.map(ParameterValue.string) ?? .string("ORFs"),
                ],
                defaultOptions: [
                    "sequence": .string(resolved.chromosome.name),
                    "start": .integer(0),
                    "end": .integer(Int(resolved.chromosome.length)),
                    "frames": .string(SequenceCommand.defaultFrames),
                    "table": .integer(1),
                    "min_length": .integer(100),
                    "include_partial": .boolean(false),
                    "allow_alternative_starts": .boolean(false),
                    "track_id": .string("orfs"),
                    "track_name": .string("ORFs"),
                ],
                resolvedOptions: resolved.options.merging([
                    "frames": .array(parsedFrames.map { .string($0.rawValue) }),
                    "table": .integer(table),
                    "min_length": .integer(minLength),
                    "include_partial": .boolean(includePartial),
                    "allow_alternative_starts": .boolean(allowAlternativeStarts),
                    "track_id": .string(normalizedTrackID ?? "orfs"),
                    "track_name": .string(normalizedTrackName ?? "ORFs"),
                ], uniquingKeysWith: { _, new in new }),
                toolVersion: cliVersion
            )

            let result = try await SequenceAnnotationTrackWorkflow.run(request)
            if !globalOptions.quiet {
                print("Created annotation track \(result.track.id) with \(result.featureCount) feature(s).")
            }
        }
    }

    struct DeleteAnnotationTrack: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete-annotation-track",
            abstract: "Delete an annotation track from a reference bundle"
        )

        @Argument(help: "Reference bundle to update")
        var bundle: String

        @Option(name: .customLong("track-id"), help: "Annotation track ID to delete.")
        var trackID: String

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL
            let manifest = try BundleManifest.load(from: bundleURL)
            let trackName = manifest.annotations.first { $0.id == trackID }?.name ?? trackID
            let command = deleteAnnotationTrackCommandArguments(
                bundle: bundle,
                trackID: trackID,
                quiet: globalOptions.quiet
            )
            let request = SequenceAnnotationTrackWorkflow.DeleteTrackRequest(
                bundleURL: bundleURL,
                trackID: trackID,
                command: command,
                explicitOptions: [
                    "operation": .string("delete-annotation-track"),
                    "track_id": .string(trackID),
                ],
                defaultOptions: [:],
                resolvedOptions: [
                    "operation": .string("delete-annotation-track"),
                    "bundle": .file(bundleURL),
                    "track_id": .string(trackID),
                    "track_name": .string(trackName),
                ],
                toolVersion: cliVersion
            )

            let result = try await SequenceAnnotationTrackWorkflow.deleteTrack(request)
            if !globalOptions.quiet {
                print("Deleted annotation track \(result.trackID).")
            }
        }
    }

    struct DeleteAnnotations: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete-annotations",
            abstract: "Delete annotation rows from a reference bundle annotation track"
        )

        @Argument(help: "Reference bundle to update")
        var bundle: String

        @Option(name: .customLong("track-id"), help: "Annotation track ID containing the rows.")
        var trackID: String

        @Option(name: .customLong("row-id"), parsing: .upToNextOption, help: "Annotation database row ID to delete. Repeat or pass multiple values.")
        var rowIDs: [Int64] = []

        @OptionGroup var globalOptions: GlobalOptions

        func run() async throws {
            guard !rowIDs.isEmpty else {
                throw ValidationError("At least one --row-id value is required.")
            }
            let bundleURL = URL(fileURLWithPath: bundle, isDirectory: true).standardizedFileURL
            let manifest = try BundleManifest.load(from: bundleURL)
            let trackName = manifest.annotations.first { $0.id == trackID }?.name ?? trackID
            let command = deleteAnnotationsCommandArguments(
                bundle: bundle,
                trackID: trackID,
                rowIDs: rowIDs,
                quiet: globalOptions.quiet
            )
            let request = SequenceAnnotationTrackWorkflow.DeleteAnnotationsRequest(
                bundleURL: bundleURL,
                trackID: trackID,
                rowIDs: rowIDs,
                command: command,
                explicitOptions: [
                    "operation": .string("delete-annotations"),
                    "track_id": .string(trackID),
                    "row_ids": .array(rowIDs.map { .integer(Int($0)) }),
                ],
                defaultOptions: [:],
                resolvedOptions: [
                    "operation": .string("delete-annotations"),
                    "bundle": .file(bundleURL),
                    "track_id": .string(trackID),
                    "track_name": .string(trackName),
                    "row_ids": .array(rowIDs.map { .integer(Int($0)) }),
                ],
                toolVersion: cliVersion
            )

            let result = try await SequenceAnnotationTrackWorkflow.deleteAnnotations(request)
            if !globalOptions.quiet {
                let suffix = result.removedTrack ? " and removed empty track" : ""
                print("Deleted \(result.deletedCount) annotation(s) from \(result.trackID)\(suffix).")
            }
        }
    }

}

private let cliVersion = "0.4.0-alpha.16"

private func parseReadingFrames(_ rawValue: String) throws -> [ReadingFrame] {
    let tokens = rawValue
        .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
        .map(String.init)
    guard !tokens.isEmpty else {
        throw ValidationError("At least one reading frame is required.")
    }
    return try tokens.map { token in
        guard let frame = ReadingFrame(rawValue: token) else {
            throw ValidationError("Invalid reading frame '\(token)'. Use +1,+2,+3,-1,-2,-3.")
        }
        return frame
    }
}

private func provenanceCommandArguments(
    subcommand: String,
    bundle: String,
    sequence: String?,
    start: Int?,
    end: Int?,
    frames: String,
    table: Int,
    trackID: String?,
    trackName: String?,
    quiet: Bool,
    extra: [String]
) -> [String] {
    if let observed = observedProcessSequenceCommandArguments(subcommand: subcommand) {
        return observed
    }
    return synthesizedCommandArguments(
        executable: "lungfish-cli",
        subcommand: subcommand,
        bundle: bundle,
        sequence: sequence,
        start: start,
        end: end,
        frames: frames,
        table: table,
        trackID: trackID,
        trackName: trackName,
        quiet: quiet,
        extra: extra
    )
}

private func observedProcessSequenceCommandArguments(subcommand: String) -> [String]? {
    let rawArguments = CommandLine.arguments
    guard let executable = rawArguments.first else { return nil }
    let processArguments = Array(rawArguments.dropFirst())
    let normalizedArguments = LungfishCLI.normalizedArgumentsForParsing(processArguments)
    guard let sequenceIndex = normalizedArguments.firstIndex(of: "sequence"),
          normalizedArguments.indices.contains(normalizedArguments.index(after: sequenceIndex)),
          normalizedArguments[normalizedArguments.index(after: sequenceIndex)] == subcommand else {
        return nil
    }
    return [executable] + processArguments
}

private func deleteAnnotationTrackCommandArguments(
    bundle: String,
    trackID: String,
    quiet: Bool
) -> [String] {
    if let observed = observedProcessSequenceCommandArguments(subcommand: "delete-annotation-track") {
        return observed
    }
    var arguments = [
        "lungfish-cli",
        "sequence",
        "delete-annotation-track",
        bundle,
        "--track-id",
        trackID,
    ]
    if quiet {
        arguments.append("--quiet")
    }
    return arguments
}

private func deleteAnnotationsCommandArguments(
    bundle: String,
    trackID: String,
    rowIDs: [Int64],
    quiet: Bool
) -> [String] {
    if let observed = observedProcessSequenceCommandArguments(subcommand: "delete-annotations") {
        return observed
    }
    var arguments = [
        "lungfish-cli",
        "sequence",
        "delete-annotations",
        bundle,
        "--track-id",
        trackID,
    ]
    for rowID in rowIDs {
        arguments.append("--row-id")
        arguments.append(String(rowID))
    }
    if quiet {
        arguments.append("--quiet")
    }
    return arguments
}

private func synthesizedCommandArguments(
    executable: String,
    subcommand: String,
    bundle: String,
    sequence: String?,
    start: Int?,
    end: Int?,
    frames: String,
    table: Int,
    trackID: String?,
    trackName: String?,
    quiet: Bool,
    extra: [String]
) -> [String] {
    var arguments = [
        executable,
        "sequence",
        subcommand,
        bundle,
    ]
    if let sequence {
        arguments += ["--sequence", sequence]
    }
    if let start {
        arguments += ["--start", String(start)]
    }
    if let end {
        arguments += ["--end", String(end)]
    }
    arguments += ["--frames", frames, "--table", String(table)]
    if let trackID {
        arguments += ["--track-id", trackID]
    }
    if let trackName {
        arguments += ["--track-name", trackName]
    }
    arguments += extra
    if quiet {
        arguments.append("--quiet")
    }
    return arguments
}

private func resolveSequenceRange(
    bundleURL: URL,
    sequence: String?,
    start: Int?,
    end: Int?
) throws -> (chromosome: ChromosomeInfo, options: [String: ParameterValue]) {
    let manifest = try BundleManifest.load(from: bundleURL)
    guard let genome = manifest.genome else {
        throw ValidationError("Reference bundle does not contain genome sequence data.")
    }
    let chromosome: ChromosomeInfo?
    if let sequence {
        chromosome = genome.chromosomes.first { $0.name == sequence || $0.aliases.contains(sequence) }
            ?? mapVCFChromosomes([sequence], toBundleChromosomes: genome.chromosomes)[sequence]
                .flatMap { mapped in genome.chromosomes.first { $0.name == mapped } }
    } else {
        chromosome = genome.chromosomes.first
    }
    guard let chromosome else {
        throw ValidationError("Sequence not found in reference bundle: \(sequence ?? "")")
    }
    let resolvedStart = start ?? 0
    let resolvedEnd = end ?? Int(chromosome.length)
    return (
        chromosome,
        [
            "sequence": .string(chromosome.name),
            "start": .integer(resolvedStart),
            "end": .integer(resolvedEnd),
            "coordinate_system": .string("0-based half-open"),
            "bundle": .file(bundleURL),
        ]
    )
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

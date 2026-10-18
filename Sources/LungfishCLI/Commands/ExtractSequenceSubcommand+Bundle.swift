// ExtractSequenceSubcommand+Bundle.swift - extract sequence --bundle, a region bundle that keeps the source's tracks
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// A refusal of `extract sequence --bundle` before it writes anything, which exits 3 and names the fix.
struct ExtractSequenceBundleRefusal: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension ExtractSequenceSubcommand {
    static let bundleCancelledMessage = "Extraction cancelled. Nothing was published."

    /// Builds the region bundle the viewer's extraction builds, over `SequenceExtractionBundleBuilder`
    /// (2.11 A48 M2). With `--format json` standard output holds only `CLIEvent` lines, with the words
    /// the app's row shows. SIGTERM, the app's Cancel, stops the run before it publishes, records it as
    /// cancelled beside the bundle it would have published and exits 125. A refusal exits 3.
    func runBundle(fromFASTA: Bool) async throws {
        let eventsOn = globalOptions.outputFormat == .json
        let events = CLIEventEmitter(enabled: eventsOn, emit: printEventLine)
        let startedAt = Date()
        let pendingCancel = PendingTaskCancel<Result<(URL, Int), any Error>>()
        let termination = SIGTERMCancellation(cancelling: pendingCancel, secondSignalEndsProcess: true)
        let command = self
        let task = Task { () -> Result<(URL, Int), any Error> in
            do {
                return .success(try await fromFASTA ? command.buildFASTARegionBundle(events: events) : command.buildRegionBundle(events: events))
            } catch {
                // A tool stopped by the cancel fails with its own error, which is the cancel.
                return .failure(Task.isCancelled ? CancellationError() : error)
            }
        }
        pendingCancel.attach(task)
        let outcome = await task.value
        termination.end()
        switch outcome {
        case .success(let (bundleURL, length)):
            events.emitComplete(output: bundleURL.path, message: "Bundle ready")
            if !globalOptions.quiet {
                printHumanLine("Extracted \(length) bp to \(bundleURL.path)", eventsOn: eventsOn)
            }
        case .failure(let error) where error is CancellationError:
            await recordCancelledBundleRun(startedAt: startedAt)
            events.emitFailed(Self.bundleCancelledMessage)
            printHumanLine(Self.bundleCancelledMessage, eventsOn: eventsOn)
            throw CLIExitCode.cancelled.exitCode
        case .failure(let refusal as ExtractSequenceBundleRefusal):
            events.emitFailed(refusal.message)
            printHumanLine(refusal.message, eventsOn: eventsOn)
            throw CLIExitCode.inputError.exitCode
        case .failure(let error):
            events.emitFailed(CLIFailureWords.describe(error))
            throw error
        }
    }

    /// The run, which returns the published bundle and the length of the extracted sequence.
    private func buildRegionBundle(events: CLIEventEmitter) async throws -> (URL, Int) {
        let runClock = ProvenanceRunClock()
        let sourceURL = URL(fileURLWithPath: input, isDirectory: true).standardizedFileURL
        guard let output, output.hasSuffix(".lungfishref") else {
            throw ExtractSequenceBundleRefusal("--bundle writes a reference bundle. Add -o <name>.lungfishref.")
        }
        let outputURL = URL(fileURLWithPath: output, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue,
              sourceURL.pathExtension == "lungfishref" else {
            throw ExtractSequenceBundleRefusal("No reference bundle at \(sourceURL.path). --bundle reads a .lungfishref folder.")
        }
        // The publish swaps the stage over a bundle at the output, so an output that is the source,
        // lies inside it or holds it would replace the input (review A48-M2 Fix 4).
        let sourcePath = Self.resolvedPath(sourceURL)
        let outputPath = Self.resolvedPath(outputURL)
        if outputPath == sourcePath || outputPath.hasPrefix(sourcePath + "/") || sourcePath.hasPrefix(outputPath + "/") {
            throw ExtractSequenceBundleRefusal(
                "-o \(output) is the source bundle, lies inside it or holds it, and --bundle never replaces its input. "
                    + "Give another -o <name>.lungfishref."
            )
        }
        if noSamples && !samples.isEmpty {
            throw ExtractSequenceBundleRefusal("--no-samples keeps no sample, so it cannot go with --samples. Give one of them.")
        }
        try refuseFeatureOptionsWithoutAFeature()
        if sourceDocument != nil {
            throw ExtractSequenceBundleRefusal(
                "--source-document names the document a FASTA input was written from. Leave it out with --bundle."
            )
        }

        let source = try await ReferenceBundle(url: sourceURL)
        let request = try extractionRequest(region: region)
        let result = try extractionResult(request: request, from: source)
        events.emitStart("Extracting \(result.sourceName)")
        events.emitProgress(0, message: "Preparing...")

        let sampleFilter: Set<String>? = noSamples ? [] : (samples.isEmpty ? nil : Set(samples))
        let tracks = Self.sourceTracks(of: source)
        let sourceName = source.manifest.name
        let argv = Self.observedArguments() ?? [CLICommandIdentity.executableName] + SequenceExtractionPipeline.cliArguments(
            source: request.source, flank5Prime: request.flank5Prime, flank3Prime: request.flank3Prime,
            reverseComplement: reverseComplement, concatenateExons: concatenateExons, sourceBundleURL: sourceURL,
            bundleName: name, sampleFilter: sampleFilter, outputBundleURL: outputURL, nextFreeName: nextFreeName
        )
        let context = SequenceExtractionBundleCommandContext(
            workflowName: "lungfish extract sequence",
            toolName: "lungfish extract sequence",
            toolVersion: LungfishCLI.configuration.version,
            argv: argv,
            explicitOptions: SequenceExtractionPipeline.extractionExplicitOptions(
                result: result, sourceBundleURL: sourceURL, sourceBundleName: sourceName, desiredBundleName: name,
                sampleFilter: sampleFilter, isConcatenated: concatenateExons
            ),
            defaultOptions: SequenceExtractionPipeline.extractionDefaultOptions,
            resolvedOptions: SequenceExtractionPipeline.extractionResolvedOptions(
                result: result, bundleURL: outputURL, sourceBundleURL: sourceURL, sourceBundleName: sourceName,
                desiredBundleName: name, sampleFilter: sampleFilter, isConcatenated: concatenateExons
            ),
            inputURLs: [],
            runClock: runClock
        )
        let bundleURL = try await SequenceExtractionBundleBuilder().buildBundle(
            request: SequenceExtractionBundleBuildRequest(
                result: result,
                outputDirectory: outputURL.deletingLastPathComponent(),
                outputBundleURL: outputURL,
                sourceBundleURL: sourceURL,
                sourceBundleName: sourceName,
                desiredBundleName: name,
                sourceBundleChromosomes: source.manifest.genome?.chromosomes ?? [],
                sourceAnnotationTracks: tracks.annotations,
                sourceVariantTracks: tracks.variants,
                sampleFilter: sampleFilter,
                isConcatenated: concatenateExons,
                publishesUnderNextFreeName: nextFreeName,
                commandContext: context
            ),
            progressHandler: { fraction, message in events.emitProgress(fraction, message: message) }
        )
        return (bundleURL, result.nucleotideSequence.count)
    }

    /// The words a record of a GenBank document's region keeps, since the bundle keeps no annotation
    /// of the document (2.12 R-B3). Carrying them is Phase 5b's payload change.
    static let annotationsNotCarried = "not carried: a region bundle of a GenBank document keeps its sequence only"

    /// The region bundle of a FASTA input, `extract sequence <fasta> <region> -o <name>.lungfishref`,
    /// the route of a viewer with no reference bundle (2.12 lane 12.12, A48-GAP). It extracts a region or
    /// a feature of several parts as the viewer does from the sequence it shows, and records the options
    /// the in-process route recorded, the FASTA it read and, with `--source-document`, the document the
    /// FASTA was written from. A GenBank document's annotations are not carried, and the record says so.
    private func buildFASTARegionBundle(events: CLIEventEmitter) async throws -> (URL, Int) {
        let runClock = ProvenanceRunClock()
        guard let output else { throw ExtractSequenceBundleRefusal("Add -o <name>.lungfishref.") }
        let outputURL = URL(fileURLWithPath: output, isDirectory: true).standardizedFileURL
        let inputURL = URL(fileURLWithPath: input).standardizedFileURL
        guard FileManager.default.fileExists(atPath: inputURL.path) else { throw CLIError.inputFileNotFound(path: input) }
        let detectURL = inputURL.pathExtension.lowercased() == "gz" ? inputURL.deletingPathExtension() : inputURL
        guard ["fa", "fasta", "fna", "faa"].contains(detectURL.pathExtension.lowercased()) else {
            throw CLIError.unsupportedFormat(format: "\(detectURL.pathExtension.lowercased()) (extract requires FASTA input)")
        }
        if !samples.isEmpty || noSamples {
            throw ExtractSequenceBundleRefusal(
                "--samples and --no-samples keep the calls of a source bundle's samples. Add --bundle, or leave them out."
            )
        }
        try refuseFeatureOptionsWithoutAFeature()
        let documentURL = try sourceDocument.map { path -> URL in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ExtractSequenceBundleRefusal("No document at \(url.path). --source-document names the file the FASTA was written from.")
            }
            return url
        }

        let (request, sequence) = try fastaRequest(in: try await FASTAReader(url: inputURL).readAll())
        let result = try SequenceExtractor.extract(
            request: request, sequenceProvider: Self.clampedProvider(sequence), chromosomeLength: sequence.length
        )
        events.emitStart("Extracting \(result.sourceName)")
        events.emitProgress(0, message: "Preparing...")

        let argv = Self.observedArguments() ?? [CLICommandIdentity.executableName] + SequenceExtractionPipeline.cliFASTAArguments(
            source: request.source, flank5Prime: request.flank5Prime, flank3Prime: request.flank3Prime,
            reverseComplement: reverseComplement, concatenateExons: concatenateExons, inputURL: inputURL,
            sequenceName: sequence.name, sourceDocumentURL: documentURL, bundleName: name, outputBundleURL: outputURL
        )
        var added: [String: ParameterValue] = ["input": .file(inputURL)]
        if let documentURL { added["source_document"] = .file(documentURL) }
        var resolved = SequenceExtractionPipeline.extractionResolvedOptions(
            result: result, bundleURL: outputURL, sourceBundleURL: nil, sourceBundleName: nil,
            desiredBundleName: name, sampleFilter: nil, isConcatenated: concatenateExons
        ).merging(added) { _, new in new }
        if let documentURL, Self.isGenBank(documentURL) {
            resolved["source_annotations"] = .string(Self.annotationsNotCarried)
        }
        let context = SequenceExtractionBundleCommandContext(
            workflowName: "lungfish extract sequence",
            toolName: "lungfish extract sequence",
            toolVersion: LungfishCLI.configuration.version,
            argv: argv,
            explicitOptions: SequenceExtractionPipeline.extractionExplicitOptions(
                result: result, sourceBundleURL: nil, sourceBundleName: nil, desiredBundleName: name,
                sampleFilter: nil, isConcatenated: concatenateExons
            ).merging(added) { _, new in new },
            defaultOptions: SequenceExtractionPipeline.extractionDefaultOptions,
            resolvedOptions: resolved,
            inputURLs: [inputURL] + (documentURL.map { [$0] } ?? []),
            runClock: runClock
        )
        let bundleURL = try await SequenceExtractionBundleBuilder().buildBundle(
            request: SequenceExtractionBundleBuildRequest(
                result: result,
                outputDirectory: outputURL.deletingLastPathComponent(),
                outputBundleURL: outputURL,
                desiredBundleName: name ?? outputURL.deletingPathExtension().lastPathComponent,
                isConcatenated: concatenateExons,
                publishesUnderNextFreeName: nextFreeName,
                commandContext: context
            ),
            progressHandler: { fraction, message in events.emitProgress(fraction, message: message) }
        )
        return (bundleURL, result.nucleotideSequence.count)
    }

    /// The request for the region or the feature of the FASTA sequence the region names, and that
    /// sequence, found by its exact name and then without case. A region without a name reads the
    /// file's one sequence, as the FASTA output does.
    private func fastaRequest(in sequences: [LungfishCore.Sequence]) throws -> (ExtractionRequest, LungfishCore.Sequence) {
        let available = sequences.map(\.name).joined(separator: ", ")
        var named = region
        if !region.contains(":") {
            guard sequences.count == 1 else {
                throw CLIError.conversionFailed(reason: "Multiple sequences in file. Specify which one: \(available)")
            }
            named = "\(sequences[0].name):\(region)"
        }
        let request = try extractionRequest(region: named)
        let chromosome: String
        switch request.source {
        case .region(let name, _, _): chromosome = name
        case .annotation(let annotation): chromosome = annotation.chromosome ?? ""
        }
        guard let sequence = sequences.first(where: { $0.name == chromosome })
            ?? sequences.first(where: { $0.name.lowercased() == chromosome.lowercased() }) else {
            throw CLIError.conversionFailed(reason: "Sequence '\(chromosome)' not found. Available: \(available)")
        }
        guard case .region(_, let start, let end) = request.source else { return (request, sequence) }
        guard end <= sequence.length else {
            throw CLIError.conversionFailed(reason: "End position \(end) exceeds sequence length \(sequence.length)")
        }
        let region = ExtractionRequest(
            source: .region(chromosome: sequence.name, start: start, end: end),
            flank5Prime: request.flank5Prime, flank3Prime: request.flank3Prime, reverseComplement: request.reverseComplement
        )
        return (region, sequence)
    }

    /// The viewer's provider over a sequence it holds whole, clamped to its length.
    static func clampedProvider(_ sequence: LungfishCore.Sequence) -> SequenceExtractor.SequenceProvider {
        { _, start, end in
            let clampedStart = max(0, start)
            let clampedEnd = min(sequence.length, end)
            guard clampedStart < clampedEnd else { return nil }
            return sequence[clampedStart..<clampedEnd]
        }
    }

    /// Whether `url` names a GenBank file, by its extension.
    static func isGenBank(_ url: URL) -> Bool {
        let detect = url.pathExtension.lowercased() == "gz" ? url.deletingPathExtension() : url
        return ["gb", "gbk", "gbff", "genbank"].contains(detect.pathExtension.lowercased())
    }

    /// Refuses the feature's options without `--feature-name`, which they describe.
    private func refuseFeatureOptionsWithoutAFeature() throws {
        if featureName == nil && (featureType != nil || strand != nil || concatenateExons) {
            throw ExtractSequenceBundleRefusal("--feature-type, --strand and --concatenate-exons describe a feature. Add --feature-name.")
        }
    }

    /// The viewer's request for the region, or for the feature `--feature-name` names, whose parts
    /// the region lists 1-based and inclusive in their stored order.
    private func extractionRequest(region: String) throws -> ExtractionRequest {
        guard let colon = region.lastIndex(of: ":"), colon != region.startIndex else {
            throw ExtractSequenceBundleRefusal("--bundle needs a region with its sequence name, such as chr1:1000-2000.")
        }
        let chromosome = String(region[..<colon])
        let intervals = try region[region.index(after: colon)...].split(separator: ",").map { part -> AnnotationInterval in
            let bounds = part.split(separator: "-")
            guard bounds.count == 2, let start = Int(bounds[0]), let end = Int(bounds[1]), start >= 1, start <= end else {
                throw ExtractSequenceBundleRefusal("Invalid part '\(part)' of the region. Expected start-end, 1-based and inclusive.")
            }
            return AnnotationInterval(start: start - 1, end: end)
        }
        guard let first = intervals.first else {
            throw ExtractSequenceBundleRefusal("The region \(region) names no part. Expected name:start-end.")
        }
        let effectiveFlank5 = flank5 ?? flank
        let effectiveFlank3 = flank3 ?? flank
        guard let featureName else {
            guard intervals.count == 1 else {
                throw ExtractSequenceBundleRefusal("A region of several parts is a feature's. Add --feature-name.")
            }
            return ExtractionRequest(
                source: .region(chromosome: chromosome, start: first.start, end: first.end),
                flank5Prime: effectiveFlank5, flank3Prime: effectiveFlank3, reverseComplement: reverseComplement
            )
        }
        guard let type = AnnotationType(rawValue: featureType ?? AnnotationType.region.rawValue) else {
            throw ExtractSequenceBundleRefusal("Unknown feature type '\(featureType ?? "")'.")
        }
        guard let parsedStrand = Strand(rawValue: strand ?? Strand.unknown.rawValue) else {
            throw ExtractSequenceBundleRefusal("Unknown strand '\(strand ?? "")'. Use + or -.")
        }
        let annotation = SequenceAnnotation(
            type: type, name: featureName, chromosome: chromosome, intervals: intervals, strand: parsedStrand
        )
        return ExtractionRequest(
            source: .annotation(annotation), flank5Prime: effectiveFlank5, flank3Prime: effectiveFlank3,
            reverseComplement: reverseComplement, concatenateExons: concatenateExons
        )
    }

    /// Extracts `request` from the bundle's genome, clamped to the chromosome as the viewer reads it.
    private func extractionResult(request: ExtractionRequest, from source: ReferenceBundle) throws -> LungfishCore.ExtractionResult {
        let chromosome: String
        switch request.source {
        case .region(let name, _, _): chromosome = name
        case .annotation(let annotation): chromosome = annotation.chromosome ?? ""
        }
        guard let info = source.chromosome(named: chromosome) else {
            let available = source.chromosomeNames.joined(separator: ", ")
            throw ExtractSequenceBundleRefusal("Sequence '\(chromosome)' is not in the bundle. Available: \(available)")
        }
        // The one reader of reference bases for extraction (review A48-M2 Fix 8).
        return try SequenceExtractor.extract(
            request: request,
            sequenceProvider: ClampedSequenceProvider(bundle: source).extractionProvider,
            chromosomeLength: Int(info.length)
        )
    }

    /// The path of `url` with the symbolic links of the part that exists resolved, so two names of one
    /// folder compare equal whether or not the folder exists yet.
    private static func resolvedPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }

    /// Every annotation and variant track of the bundle that has a database, as the viewer collects them.
    private static func sourceTracks(of bundle: ReferenceBundle) -> (
        annotations: [SequenceExtractionSourceAnnotationTrack], variants: [SequenceExtractionSourceVariantTrack]
    ) {
        let annotations = bundle.annotationTrackIds.compactMap { id -> SequenceExtractionSourceAnnotationTrack? in
            guard let track = bundle.annotationTrack(id: id), let path = track.databasePath,
                  let url = try? bundle.memberURL(for: path, field: "annotations[\(id)].databasePath") else { return nil }
            return SequenceExtractionSourceAnnotationTrack(
                id: track.id, name: track.name, databaseURL: url, annotationType: track.annotationType
            )
        }
        let variants = bundle.variantTrackIds.compactMap { id -> SequenceExtractionSourceVariantTrack? in
            guard let track = bundle.variantTrack(id: id), let path = track.databasePath,
                  let url = try? bundle.memberURL(for: path, field: "variants[\(id)].databasePath") else { return nil }
            return SequenceExtractionSourceVariantTrack(
                id: track.id, name: track.name, databaseURL: url, variantType: track.variantType
            )
        }
        return (annotations, variants)
    }

    /// The words the process was started with when it runs `extract sequence`, which the record names.
    private static func observedArguments() -> [String]? {
        let raw = CommandLine.arguments
        guard let executable = raw.first else { return nil }
        let arguments = Array(raw.dropFirst())
        let normalized = LungfishCLI.normalizedArgumentsForParsing(arguments)
        guard normalized.starts(with: ["extract", "sequence"]) else { return nil }
        return [executable] + arguments
    }

    /// Records the run a cancel stopped as cancelled, beside the bundle it would have published. A
    /// failure to write it does not hide the cancel.
    private func recordCancelledBundleRun(startedAt: Date) async {
        guard let output else { return }
        let outputURL = URL(fileURLWithPath: output, isDirectory: true).standardizedFileURL
        _ = try? await CLIProvenanceSupport.recordSingleStepRun(
            name: "lungfish extract sequence",
            parameters: ["input": .file(URL(fileURLWithPath: input)), "region": .string(region), "output": .file(outputURL)],
            toolName: "lungfish extract sequence",
            toolVersion: LungfishCLI.configuration.version,
            command: Self.observedArguments() ?? [CLICommandIdentity.executableName, "extract", "sequence", input, region],
            inputs: [],
            outputs: [],
            exitCode: CLIExitCode.cancelled.exitCode.rawValue,
            wallTime: Date().timeIntervalSince(startedAt),
            stderr: Self.bundleCancelledMessage,
            status: .cancelled,
            outputDirectory: outputURL.deletingLastPathComponent(),
            writeFileSidecars: false
        )
    }
}

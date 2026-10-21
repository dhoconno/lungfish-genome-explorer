// SequenceExtractionPipeline.swift - Background bundle creation from extracted sequences
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// Builds a `.lungfishref` bundle from the viewer's extracted sequence and records the run as
/// `Lungfish Genome Explorer sequence extract-bundle`. It names the bundle and the command, and
/// ``SequenceExtractionBundleBuilder`` builds it, with the source bundle's annotation and variant
/// tracks and the sample filter when the run keeps them, and writes its one record (2.11 A48 M1).
package final class SequenceExtractionPipeline: Sendable {

    package typealias SourceAnnotationTrack = SequenceExtractionSourceAnnotationTrack
    package typealias SourceVariantTrack = SequenceExtractionSourceVariantTrack

    package init() {}

    /// Creates a `.lungfishref` bundle from an extraction result.
    ///
    /// - Parameters:
    ///   - result: The extraction result containing the nucleotide sequence.
    ///   - outputDirectory: Where to create the bundle.
    ///   - sourceBundleURL: Optional source bundle for metadata inheritance.
    ///   - progressHandler: Optional progress callback (fraction, message).
    /// - Returns: URL of the created `.lungfishref` bundle.
    package func buildBundle(
        from result: LungfishCore.ExtractionResult,
        outputDirectory: URL,
        sourceBundleURL: URL? = nil,
        sourceBundleName: String? = nil,
        desiredBundleName: String? = nil,
        sourceBundleChromosomes: [ChromosomeInfo] = [],
        sourceAnnotationTracks: [SourceAnnotationTrack] = [],
        sourceVariantTracks: [SourceVariantTrack] = [],
        sampleFilter: Set<String>? = nil,
        isConcatenated: Bool = false,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> URL {
        let outputBundleURL = SequenceExtractionBundleBuilder.uniqueBundleURL(
            for: result,
            desiredBundleName: desiredBundleName,
            in: outputDirectory
        )
        let context = SequenceExtractionBundleCommandContext(
            workflowName: "lungfish gui sequence extraction",
            toolName: "lungfish gui sequence extraction",
            toolVersion: WorkflowRun.currentAppVersion,
            argv: Self.extractionProvenanceArguments(
                result: result,
                bundleURL: outputBundleURL,
                sourceBundleURL: sourceBundleURL,
                sourceBundleName: sourceBundleName,
                desiredBundleName: desiredBundleName,
                sampleFilter: sampleFilter,
                isConcatenated: isConcatenated
            ),
            explicitOptions: Self.extractionExplicitOptions(
                result: result,
                sourceBundleURL: sourceBundleURL,
                sourceBundleName: sourceBundleName,
                desiredBundleName: desiredBundleName,
                sampleFilter: sampleFilter,
                isConcatenated: isConcatenated
            ),
            defaultOptions: Self.extractionDefaultOptions,
            resolvedOptions: Self.extractionResolvedOptions(
                result: result,
                bundleURL: outputBundleURL,
                sourceBundleURL: sourceBundleURL,
                sourceBundleName: sourceBundleName,
                desiredBundleName: desiredBundleName,
                sampleFilter: sampleFilter,
                isConcatenated: isConcatenated
            ),
            inputURLs: []
        )
        return try await SequenceExtractionBundleBuilder().buildBundle(
            request: SequenceExtractionBundleBuildRequest(
                result: result,
                outputDirectory: outputDirectory,
                outputBundleURL: outputBundleURL,
                sourceBundleURL: sourceBundleURL,
                sourceBundleName: sourceBundleName,
                desiredBundleName: desiredBundleName,
                sourceBundleChromosomes: sourceBundleChromosomes,
                sourceAnnotationTracks: sourceAnnotationTracks,
                sourceVariantTracks: sourceVariantTracks,
                sampleFilter: sampleFilter,
                isConcatenated: isConcatenated,
                // The name was picked at the start, so a run that overlaps this one may publish it first.
                publishesUnderNextFreeName: true,
                commandContext: context
            ),
            progressHandler: progressHandler
        )
    }

    private static func extractionProvenanceArguments(
        result: LungfishCore.ExtractionResult,
        bundleURL: URL,
        sourceBundleURL: URL?,
        sourceBundleName: String?,
        desiredBundleName: String?,
        sampleFilter: Set<String>?,
        isConcatenated: Bool
    ) -> [String] {
        var argv = [
            LungfishAppIdentity.recordedToolName,
            "sequence",
            "extract-bundle",
        ]
        if let sourceBundleURL {
            argv += ["--source-bundle", sourceBundleURL.path]
        }
        if let sourceBundleName, !sourceBundleName.isEmpty {
            argv += ["--source-name", sourceBundleName]
        }
        argv += [
            "--chromosome", result.chromosome,
            "--start", String(result.effectiveStart),
            "--end", String(result.effectiveEnd),
        ]
        if result.isReverseComplement {
            argv.append("--reverse-complement")
        }
        if isConcatenated {
            argv.append("--concatenate-exons")
        }
        if let desiredBundleName, !desiredBundleName.isEmpty {
            argv += ["--name", desiredBundleName]
        }
        if let sampleFilter, !sampleFilter.isEmpty {
            argv += ["--samples", sampleFilter.sorted().joined(separator: ",")]
        }
        argv += ["--output", bundleURL.path]
        return argv
    }

    /// The defaults the record of a region bundle names, which `extract sequence --bundle` names too.
    package static let extractionDefaultOptions: [String: ParameterValue] = [
        "reverse_complement": .boolean(false),
        "concatenate_exons": .boolean(false),
        "sample_filter": .array([]),
    ]

    /// The options the record of a region bundle names as given. `extract sequence --bundle` writes the
    /// same ones, so the two routes record one run alike (2.11 A48 M2, BIO 4).
    package static func extractionExplicitOptions(
        result: LungfishCore.ExtractionResult,
        sourceBundleURL: URL?,
        sourceBundleName: String?,
        desiredBundleName: String?,
        sampleFilter: Set<String>?,
        isConcatenated: Bool
    ) -> [String: ParameterValue] {
        [
            "operation": .string("sequence-extraction"),
            "source_name": .string(result.sourceName),
            "source_bundle": sourceBundleURL.map(ParameterValue.file) ?? .null,
            "source_bundle_name": sourceBundleName.map(ParameterValue.string) ?? .null,
            "bundle_name": desiredBundleName.map(ParameterValue.string) ?? .string(result.sourceName),
            "reverse_complement": .boolean(result.isReverseComplement),
            "concatenate_exons": .boolean(isConcatenated),
            "sample_filter": .array((sampleFilter ?? []).sorted().map { .string($0) }),
        ]
    }

    package static func extractionResolvedOptions(
        result: LungfishCore.ExtractionResult,
        bundleURL: URL,
        sourceBundleURL: URL?,
        sourceBundleName: String?,
        desiredBundleName: String?,
        sampleFilter: Set<String>?,
        isConcatenated: Bool
    ) -> [String: ParameterValue] {
        [
            "operation": .string("sequence-extraction"),
            "source_name": .string(result.sourceName),
            "source_bundle": sourceBundleURL.map(ParameterValue.file) ?? .null,
            "source_bundle_name": sourceBundleName.map(ParameterValue.string) ?? .null,
            "bundle_name": desiredBundleName.map(ParameterValue.string) ?? .string(result.sourceName),
            "output_bundle": .file(bundleURL),
            "chromosome": .string(result.chromosome),
            "start": .integer(result.effectiveStart),
            "end": .integer(result.effectiveEnd),
            "coordinate_system": .string("0-based half-open"),
            "reverse_complement": .boolean(result.isReverseComplement),
            "concatenate_exons": .boolean(isConcatenated),
            "sample_filter": .array((sampleFilter ?? []).sorted().map { .string($0) }),
        ]
    }

    /// The `lungfish-cli` argv after the executable that builds the region bundle the viewer
    /// asks for, `extract sequence --bundle` with `--format json` (2.11 A48 M2). The region
    /// lists a feature's parts in their stored order, 1-based and inclusive, so the command
    /// extracts what the viewer's request extracts. A name the person typed is passed as one
    /// `--option=value` word, so a name that starts with a hyphen stays a value, and each
    /// sample is one `--samples` word, so a name may hold a comma. `--next-free-name` keeps a
    /// bundle that another run published under the name while this one built (Fix 6, SC5).
    package static func cliArguments(
        source: ExtractionRequest.Source,
        flank5Prime: Int,
        flank3Prime: Int,
        reverseComplement: Bool,
        concatenateExons: Bool,
        sourceBundleURL: URL,
        bundleName: String?,
        sampleFilter: Set<String>?,
        outputBundleURL: URL,
        nextFreeName: Bool = true
    ) -> [String] {
        let (region, feature) = regionAndFeatureArguments(source, chromosomeWithoutName: "")
        var arguments = ["extract", "sequence", sourceBundleURL.path, region, "--bundle"] + feature
        if reverseComplement { arguments.append("--reverse-complement") }
        if concatenateExons { arguments.append("--concatenate-exons") }
        if flank5Prime != 0 { arguments += ["--flank-5", String(flank5Prime)] }
        if flank3Prime != 0 { arguments += ["--flank-3", String(flank3Prime)] }
        if let bundleName, !bundleName.isEmpty { arguments.append("--name=\(bundleName)") }
        if let sampleFilter {
            arguments += sampleFilter.isEmpty ? ["--no-samples"] : sampleFilter.sorted().map { "--samples=\($0)" }
        }
        arguments += ["--output", outputBundleURL.path]
        if nextFreeName { arguments.append("--next-free-name") }
        return arguments + ["--format", "json"]
    }

    /// The `lungfish-cli` argv after the executable that builds the region bundle a viewer with no
    /// reference bundle asks for, `extract sequence <fasta> <region> -o <name>.lungfishref` with
    /// `--format json` (2.12 lane 12.12, A48-GAP). `inputURL` is the FASTA the viewer staged of the
    /// sequence it shows, named `sequenceName`, which also names a feature that names no sequence.
    /// `sourceDocumentURL` is the file the viewer shows, which the record names. The name goes as one
    /// `--name=value` word, a blank one included, so the record keeps the name the person gave, as the
    /// in-process route did, and the folder is `outputBundleURL`'s. An empty name, which the sheet never
    /// gives and no option can carry, goes as none, so the record names the source name the folder took.
    package static func cliFASTAArguments(
        source: ExtractionRequest.Source,
        flank5Prime: Int,
        flank3Prime: Int,
        reverseComplement: Bool,
        concatenateExons: Bool,
        inputURL: URL,
        sequenceName: String,
        sourceDocumentURL: URL?,
        bundleName: String?,
        outputBundleURL: URL
    ) -> [String] {
        let (region, feature) = regionAndFeatureArguments(source, chromosomeWithoutName: sequenceName)
        var arguments = ["extract", "sequence", inputURL.path, region] + feature
        if reverseComplement { arguments.append("--reverse-complement") }
        if concatenateExons { arguments.append("--concatenate-exons") }
        if flank5Prime != 0 { arguments += ["--flank-5", String(flank5Prime)] }
        if flank3Prime != 0 { arguments += ["--flank-3", String(flank3Prime)] }
        if let bundleName, !bundleName.isEmpty { arguments.append("--name=\(bundleName)") }
        if let sourceDocumentURL { arguments += ["--source-document", sourceDocumentURL.path] }
        return arguments + ["--output", outputBundleURL.path, "--next-free-name", "--format", "json"]
    }

    /// The region word, its parts 1-based and inclusive in their stored order, and the feature's
    /// options. A feature that names no sequence takes `chromosomeWithoutName`.
    private static func regionAndFeatureArguments(
        _ source: ExtractionRequest.Source,
        chromosomeWithoutName: String
    ) -> (region: String, feature: [String]) {
        let chromosome: String
        let intervals: [(start: Int, end: Int)]
        var feature: [String] = []
        switch source {
        case .region(let name, let start, let end):
            chromosome = name
            intervals = [(start, end)]
        case .annotation(let annotation):
            chromosome = annotation.chromosome ?? chromosomeWithoutName
            intervals = annotation.intervals.map { ($0.start, $0.end) }
            feature = ["--feature-name=\(annotation.name)", "--feature-type", annotation.type.rawValue]
            if annotation.strand != .unknown {
                feature += ["--strand", annotation.strand.rawValue]
            }
        }
        return (chromosome + ":" + intervals.map { "\($0.start + 1)-\($0.end)" }.joined(separator: ","), feature)
    }
}

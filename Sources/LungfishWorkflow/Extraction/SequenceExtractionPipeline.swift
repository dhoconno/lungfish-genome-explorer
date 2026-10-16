// SequenceExtractionPipeline.swift - Background bundle creation from extracted sequences
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

/// Builds a `.lungfishref` bundle from the viewer's extracted sequence and records the run as
/// `lungfish-gui sequence extract-bundle`. It names the bundle and the command, and
/// ``SequenceExtractionBundleBuilder`` builds it, with the source bundle's annotation and variant
/// tracks and the sample filter when the run keeps them, and writes its one record (2.11 A48 M1).
public final class SequenceExtractionPipeline: Sendable {

    public typealias SourceAnnotationTrack = SequenceExtractionSourceAnnotationTrack
    public typealias SourceVariantTrack = SequenceExtractionSourceVariantTrack

    public init() {}

    /// Creates a `.lungfishref` bundle from an extraction result.
    ///
    /// - Parameters:
    ///   - result: The extraction result containing the nucleotide sequence.
    ///   - outputDirectory: Where to create the bundle.
    ///   - sourceBundleURL: Optional source bundle for metadata inheritance.
    ///   - progressHandler: Optional progress callback (fraction, message).
    /// - Returns: URL of the created `.lungfishref` bundle.
    public func buildBundle(
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
            defaultOptions: [
                "reverse_complement": .boolean(false),
                "concatenate_exons": .boolean(false),
                "sample_filter": .array([]),
            ],
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
            "lungfish-gui",
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

    private static func extractionExplicitOptions(
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

    private static func extractionResolvedOptions(
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
}

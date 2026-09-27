// MappingResultLayoutScaffold.swift - A finished mapping run, before its layout is published
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// A `.lungfish` project holding a source reference bundle, a FASTQ bundle
/// the reads "came from", and an `Analyses/<tool>-<timestamp>/` directory
/// that looks exactly like the mapper left it: sorted BAM + BAI,
/// `mapping-result.json`, `mapping-provenance.json`, and the canonical
/// provenance envelope. What is missing is the layout the window adds
/// afterwards (reference copy, attached track, rewritten sidecars), so a
/// test can run that step through either surface and compare.
public struct MappingResultLayoutScaffold: Sendable {
    public let viewerScaffold: MappingViewerScaffold
    public let projectRootURL: URL
    public let sourceBundleURL: URL
    public let fastqBundleURL: URL
    public let analysisDirectoryURL: URL
    public let result: MappingResult
    public let request: MappingRunRequest

    /// Builds the scaffold. `fixtureBAMURL` must have a `.bai` beside it.
    public static func make(
        fixtureBAMURL: URL,
        tool: MappingTool = .minimap2,
        sampleName: String = "sample",
        outputTrackName: String? = nil
    ) throws -> MappingResultLayoutScaffold {
        let viewerScaffold = try MappingViewerScaffold.make(payloadKind: .plainFASTA)
        let projectRoot = viewerScaffold.projectRootURL
        let fileManager = FileManager.default

        // The reads bundle the analysis history is recorded in.
        let fastqBundleURL = projectRoot
            .appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent("\(sampleName).lungfishfastq", isDirectory: true)
        try fileManager.createDirectory(at: fastqBundleURL, withIntermediateDirectories: true)
        let readsURL = fastqBundleURL.appendingPathComponent("\(sampleName).fastq")
        try Data("@r1\nACGT\n+\nIIII\n".utf8).write(to: readsURL)

        // The same Analyses/<tool>-<timestamp>/ folder the window creates.
        let analysisDirectoryURL = try MappingResultLayoutService.createAnalysisDirectory(tool: tool, in: projectRoot)
        let bamURL = analysisDirectoryURL.appendingPathComponent("\(sampleName).sorted.bam")
        let baiURL = bamURL.appendingPathExtension("bai")
        try fileManager.copyItem(at: fixtureBAMURL, to: bamURL)
        try fileManager.copyItem(at: fixtureBAMURL.appendingPathExtension("bai"), to: baiURL)

        let referenceFASTAURL = viewerScaffold.sourceBundleURL.appendingPathComponent("genome/sequence.fa")
        let request = MappingRunRequest(
            tool: tool,
            modeID: MappingMode.defaultShortRead.rawValue,
            inputFASTQURLs: [readsURL],
            originalInputFASTQURLs: [readsURL],
            referenceFASTAURL: referenceFASTAURL,
            sourceReferenceBundleURL: viewerScaffold.sourceBundleURL,
            projectURL: projectRoot,
            outputDirectory: analysisDirectoryURL,
            sampleName: sampleName,
            threads: 1,
            inputLayout: .singleEnd,
            outputTrackName: outputTrackName
        )
        let result = MappingResult(
            mapper: tool,
            modeID: request.modeID,
            sourceReferenceBundleURL: viewerScaffold.sourceBundleURL,
            bamURL: bamURL,
            baiURL: baiURL,
            totalReads: 1,
            mappedReads: 1,
            unmappedReads: 0,
            wallClockSeconds: 1,
            contigs: []
        )
        try result.save(to: analysisDirectoryURL)
        try MappingProvenance.build(
            request: request,
            result: result,
            mapperInvocation: MappingCommandInvocation(label: tool.displayName, argv: [tool.executableName, "-a"]),
            normalizationInvocations: [],
            mapperVersion: "test",
            samtoolsVersion: "test",
            exitStatus: 0
        ).save(to: analysisDirectoryURL)
        try writeCanonicalEnvelope(analysisDirectoryURL: analysisDirectoryURL, bamURL: bamURL, baiURL: baiURL)

        return MappingResultLayoutScaffold(
            viewerScaffold: viewerScaffold,
            projectRootURL: projectRoot,
            sourceBundleURL: viewerScaffold.sourceBundleURL,
            fastqBundleURL: fastqBundleURL,
            analysisDirectoryURL: analysisDirectoryURL,
            result: result,
            request: request
        )
    }

    public func cleanUp() {
        viewerScaffold.cleanUp()
    }

    /// Every path under `directory`, relative to it and sorted, with the
    /// run-specific parts masked: the random `aln_<8 hex>` track ID becomes
    /// `aln_*` and the timestamped analysis folder name becomes
    /// `<tool>-<timestamp>`. Two runs of the same layout compare equal.
    public static func normalizedLayout(of directory: URL, tool: MappingTool) throws -> [String] {
        let root = directory.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return []
        }
        var paths: [String] = []
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root.path + "/") else { continue }
            paths.append(normalize(String(path.dropFirst(root.path.count + 1)), tool: tool))
        }
        return paths.sorted()
    }

    public static func normalize(_ relativePath: String, tool: MappingTool) -> String {
        var normalized = relativePath
        if let regex = try? NSRegularExpression(pattern: "aln_[0-9A-Fa-f]{8}") {
            normalized = regex.stringByReplacingMatches(
                in: normalized,
                range: NSRange(normalized.startIndex..., in: normalized),
                withTemplate: "aln_*"
            )
        }
        if let regex = try? NSRegularExpression(
            pattern: "\(NSRegularExpression.escapedPattern(for: tool.rawValue))-\\d{4}-\\d{2}-\\d{2}T\\d{2}-\\d{2}-\\d{2}(-\\d+)?"
        ) {
            normalized = regex.stringByReplacingMatches(
                in: normalized,
                range: NSRange(normalized.startIndex..., in: normalized),
                withTemplate: "\(tool.rawValue)-<timestamp>"
            )
        }
        return normalized
    }

    private static func writeCanonicalEnvelope(analysisDirectoryURL: URL, bamURL: URL, baiURL: URL) throws {
        let mappingResultURL = analysisDirectoryURL.appendingPathComponent("mapping-result.json")
        let mappingProvenanceURL = analysisDirectoryURL.appendingPathComponent(MappingProvenance.filename)
        let descriptors = try [
            ProvenanceFileDescriptor.file(url: bamURL, format: .bam, role: .output),
            ProvenanceFileDescriptor.file(url: baiURL, role: .index),
            ProvenanceFileDescriptor.file(url: mappingResultURL, format: .json, role: .output),
            ProvenanceFileDescriptor.file(url: mappingProvenanceURL, format: .json, role: .output),
        ]
        try ProvenanceWriter(signingProvider: nil).write(
            ProvenanceEnvelope(
                workflowName: "lungfish map",
                toolName: "minimap2",
                toolVersion: "test",
                argv: ["minimap2", "-a"],
                files: descriptors,
                outputs: descriptors,
                steps: [
                    ProvenanceStep(
                        toolName: "minimap2",
                        toolVersion: "test",
                        argv: ["minimap2", "-a"],
                        outputs: descriptors,
                        exitStatus: 0
                    ),
                ],
                exitStatus: 0
            ),
            to: analysisDirectoryURL
        )
    }
}

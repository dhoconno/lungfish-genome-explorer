import Foundation
import LungfishCore
import LungfishWorkflow

enum AppUITestMappingBackend {
    static func writeResult(for request: MappingRunRequest) throws -> MappingResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: request.outputDirectory,
            withIntermediateDirectories: true
        )

        let bamURL = request.outputDirectory.appendingPathComponent("\(request.sampleName).sorted.bam")
        let baiURL = request.outputDirectory.appendingPathComponent("\(request.sampleName).sorted.bam.bai")

        if !fileManager.fileExists(atPath: bamURL.path) {
            try Data().write(to: bamURL)
        }
        if !fileManager.fileExists(atPath: baiURL.path) {
            try Data().write(to: baiURL)
        }

        let contigName = referenceContigName(for: request.referenceFASTAURL) ?? "ref"
        let contigLength = referenceContigLength(for: request.referenceFASTAURL) ?? 30000
        let viewerBundleURL = synthesizedViewerBundleURL(
            from: request.referenceFASTAURL,
            outputDirectory: request.outputDirectory
        ) ?? request.sourceReferenceBundleURL
        let totalReads = 200
        let mappedReads = 190
        let unmappedReads = totalReads - mappedReads

        let contig = MappingContigSummary(
            contigName: contigName,
            contigLength: contigLength,
            mappedReads: mappedReads,
            mappedReadPercent: Double(mappedReads) / Double(totalReads) * 100,
            meanDepth: 22.5,
            coverageBreadth: 0.95,
            medianMAPQ: 60,
            meanIdentity: 99.0
        )

        let result = MappingResult(
            mapper: request.tool,
            modeID: request.modeID,
            sourceReferenceBundleURL: request.sourceReferenceBundleURL,
            viewerBundleURL: viewerBundleURL,
            bamURL: bamURL,
            baiURL: baiURL,
            totalReads: totalReads,
            mappedReads: mappedReads,
            unmappedReads: unmappedReads,
            wallClockSeconds: 0.5,
            contigs: [contig]
        )
        try result.save(to: request.outputDirectory)
        let command = try ManagedMappingPipeline.buildCommand(for: request)
        let provenance = MappingProvenance.build(
            request: request,
            result: result,
            mapperInvocation: MappingCommandInvocation(
                label: request.tool.displayName,
                argv: [command.executable] + command.arguments
            ),
            normalizationInvocations: MappingProvenance.normalizationInvocations(
                rawAlignmentURL: bamURL,
                outputDirectory: request.outputDirectory,
                sampleName: request.sampleName,
                threads: request.threads,
                minimumMappingQuality: request.minimumMappingQuality,
                includeSecondary: request.includeSecondary,
                includeSupplementary: request.includeSupplementary
            ),
            mapperVersion: "ui-test-deterministic",
            samtoolsVersion: "ui-test-deterministic"
        )
        try provenance.save(to: request.outputDirectory)
        return result
    }

    private static func referenceContigName(for referenceURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: referenceURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let firstHeader = text
            .split(separator: "\n")
            .first { $0.hasPrefix(">") }
        guard let header = firstHeader else { return nil }
        let trimmed = String(header.dropFirst())
            .split(whereSeparator: { $0.isWhitespace })
            .first
            .map(String.init)
        return trimmed
    }

    private static func referenceContigLength(for referenceURL: URL) -> Int? {
        guard let raw = try? String(contentsOf: referenceURL, encoding: .utf8) else { return nil }
        var total = 0
        var inRecord = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(">") {
                if inRecord { break }
                inRecord = true
                continue
            }
            if inRecord {
                total += line.count
            }
        }
        return total > 0 ? total : nil
    }

    private static func synthesizedViewerBundleURL(
        from referenceURL: URL,
        outputDirectory: URL
    ) -> URL? {
        guard let sequence = referenceSequenceInfo(for: referenceURL) else { return nil }

        let bundleName = referenceURL.deletingPathExtension().lastPathComponent.isEmpty
            ? "viewer-bundle"
            : referenceURL.deletingPathExtension().lastPathComponent
        let bundleDirectory = outputDirectory.appendingPathComponent("viewer-bundle", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)

            let fastaURL = bundleDirectory.appendingPathComponent("reference.fa")
            let fastaText = ">\(sequence.name)\n\(sequence.sequence)\n"
            try fastaText.write(to: fastaURL, atomically: true, encoding: .utf8)

            let sequenceOffset = ("\(sequence.name)\n" as NSString).length
            let chromosome = ChromosomeInfo(
                name: sequence.name,
                length: Int64(sequence.sequence.utf8.count),
                offset: Int64(sequenceOffset),
                lineBases: max(1, sequence.sequence.utf8.count),
                lineWidth: max(2, sequence.sequence.utf8.count + 1),
                aliases: [],
                isPrimary: true,
                isMitochondrial: false,
                fastaDescription: nil
            )
            let source = SourceInfo(
                organism: bundleName,
                assembly: bundleName,
                database: "UI Test",
                sourceURL: referenceURL,
                downloadDate: Date(),
                notes: "Deterministic viewer bundle synthesized for UI tests"
            )
            let manifest = BundleManifest(
                name: bundleName,
                identifier: "org.lungfish.ui-test.\(bundleName.replacingOccurrences(of: " ", with: "-").lowercased())",
                source: source,
                genome: GenomeInfo(
                    path: "reference.fa",
                    indexPath: "reference.fa.fai",
                    totalLength: Int64(sequence.sequence.utf8.count),
                    chromosomes: [chromosome]
                )
            )
            try manifest.save(to: bundleDirectory)

            let faiURL = bundleDirectory.appendingPathComponent("reference.fa.fai")
            let faiLine = "\(sequence.name)\t\(sequence.sequence.utf8.count)\t\(sequenceOffset)\t\(sequence.sequence.utf8.count)\t\(sequence.sequence.utf8.count + 1)\n"
            try faiLine.write(to: faiURL, atomically: true, encoding: .utf8)

            return bundleDirectory
        } catch {
            return nil
        }
    }

    private static func referenceSequenceInfo(for referenceURL: URL) -> (name: String, sequence: String)? {
        guard let raw = try? String(contentsOf: referenceURL, encoding: .utf8) else { return nil }
        var currentName: String?
        var sequenceLines: [String] = []

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(">") {
                if let currentName, !sequenceLines.isEmpty {
                    return (currentName, sequenceLines.joined())
                }
                currentName = String(line.dropFirst())
                    .split(whereSeparator: { $0.isWhitespace })
                    .first
                    .map(String.init)
                continue
            }
            if currentName != nil {
                sequenceLines.append(String(line.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }

        guard let currentName, !sequenceLines.isEmpty else { return nil }
        return (currentName, sequenceLines.joined())
    }
}

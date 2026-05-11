import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct AppUITestPrimerTrimResult: Sendable {
    let trackID: String
    let trackName: String
    let bamURL: URL
    let indexURL: URL
    let provenanceSidecarURL: URL
}

enum AppUITestPrimerTrimBackend {
    enum BackendError: Error, LocalizedError, Sendable {
        case missingAlignmentTrack(String)
        case missingSourceArtifact(URL)

        var errorDescription: String? {
            switch self {
            case .missingAlignmentTrack(let trackID):
                return "UI test primer trim source alignment track was not found: \(trackID)"
            case .missingSourceArtifact(let url):
                return "UI test primer trim source artifact is missing: \(url.path)"
            }
        }
    }

    static func writeResult(
        bundleURL: URL,
        alignmentTrackID: String,
        scheme: PrimerSchemeBundle,
        outputTrackName: String,
        cliArguments: [String],
        minReadLength: Int,
        minQuality: Int,
        slidingWindow: Int,
        primerOffset: Int
    ) throws -> AppUITestPrimerTrimResult {
        let fileManager = FileManager.default
        let manifest = try BundleManifest.load(from: bundleURL)
        guard let sourceTrack = manifest.alignments.first(where: { $0.id == alignmentTrackID }) else {
            throw BackendError.missingAlignmentTrack(alignmentTrackID)
        }

        let sourceBAMURL = bundleURL.appendingPathComponent(sourceTrack.sourcePath)
        let sourceIndexURL = bundleURL.appendingPathComponent(sourceTrack.indexPath)
        for artifactURL in [sourceBAMURL, sourceIndexURL] {
            guard fileManager.fileExists(atPath: artifactURL.path) else {
                throw BackendError.missingSourceArtifact(artifactURL)
            }
        }

        let trackID = nextTrackID(existingIDs: Set(manifest.alignments.map(\.id)))
        let relativeDirectory = "alignments/primer-trimmed"
        let relativeBAMPath = "\(relativeDirectory)/\(trackID).bam"
        let relativeIndexPath = "\(relativeDirectory)/\(trackID).bam.bai"
        let outputDirectoryURL = bundleURL.appendingPathComponent(relativeDirectory, isDirectory: true)
        let outputBAMURL = bundleURL.appendingPathComponent(relativeBAMPath)
        let outputIndexURL = bundleURL.appendingPathComponent(relativeIndexPath)
        let provenanceSidecarURL = PrimerTrimProvenanceLoader.sidecarURL(forBAMAt: outputBAMURL)

        try fileManager.createDirectory(at: outputDirectoryURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceBAMURL, to: outputBAMURL)
        try fileManager.copyItem(at: sourceIndexURL, to: outputIndexURL)

        let provenance = BAMPrimerTrimProvenance(
            operation: "primer-trim",
            primerScheme: BAMPrimerTrimProvenance.PrimerSchemeRef(
                bundleName: scheme.manifest.name,
                bundleSource: scheme.manifest.source ?? "ui-test-fixture",
                bundleVersion: scheme.manifest.version,
                canonicalAccession: scheme.manifest.canonicalAccession
            ),
            sourceBAMRelativePath: sourceTrack.sourcePath,
            ivarVersion: "ui-test-deterministic",
            ivarTrimArgs: [
                "trim",
                "-b", scheme.bedURL.path,
                "-i", sourceBAMURL.path,
                "-p", outputBAMURL.deletingPathExtension().path,
                "-q", String(minQuality),
                "-m", String(minReadLength),
                "-s", String(slidingWindow),
                "-x", String(primerOffset),
                "-e"
            ],
            timestamp: Date(),
            workflowName: "lungfish bam primer-trim",
            command: ["lungfish-cli"] + cliArguments,
            resolvedOptions: [
                "alignment_track": alignmentTrackID,
                "bundle": bundleURL.path,
                "format": "json",
                "ivar_min_length": String(minReadLength),
                "ivar_min_quality": String(minQuality),
                "ivar_primer_offset": String(primerOffset),
                "ivar_sliding_window": String(slidingWindow),
                "name": outputTrackName,
                "no_progress": "true",
                "scheme": scheme.url.path
            ],
            inputFiles: [
                ProvenanceRecorder.fileRecord(url: sourceBAMURL, format: .bam, role: .input),
                ProvenanceRecorder.fileRecord(url: sourceIndexURL, role: .index),
                ProvenanceRecorder.fileRecord(url: scheme.bedURL, format: .bed, role: .reference)
            ],
            outputFiles: [
                ProvenanceRecorder.fileRecord(url: outputBAMURL, format: .bam, role: .output),
                ProvenanceRecorder.fileRecord(url: outputIndexURL, role: .index)
            ],
            runtimeIdentity: [
                "backend": "ui-test-deterministic",
                "pack": "variant-calling"
            ],
            steps: [
                StepExecution(
                    toolName: "ui-test-primer-trim",
                    toolVersion: "deterministic",
                    command: ["lungfish-cli"] + cliArguments,
                    inputs: [
                        ProvenanceRecorder.fileRecord(url: sourceBAMURL, format: .bam, role: .input),
                        ProvenanceRecorder.fileRecord(url: sourceIndexURL, role: .index),
                        ProvenanceRecorder.fileRecord(url: scheme.bedURL, format: .bed, role: .reference)
                    ],
                    outputs: [
                        ProvenanceRecorder.fileRecord(url: outputBAMURL, format: .bam, role: .output),
                        ProvenanceRecorder.fileRecord(url: outputIndexURL, role: .index)
                    ],
                    exitCode: 0,
                    wallTime: 0.1,
                    stderr: "",
                    endTime: Date()
                )
            ],
            wallTimeSeconds: 0.1,
            exitStatus: 0,
            stderr: ""
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(provenance).write(to: provenanceSidecarURL, options: .atomic)

        let outputRecord = ProvenanceRecorder.fileRecord(url: outputBAMURL, format: .bam, role: .output)
        let track = AlignmentTrackInfo(
            id: trackID,
            name: outputTrackName,
            format: .bam,
            sourcePath: relativeBAMPath,
            indexPath: relativeIndexPath,
            checksumSHA256: outputRecord.sha256,
            fileSizeBytes: outputRecord.sizeBytes.map(Int64.init)
        )
        try manifest.addingAlignmentTrack(track).save(to: bundleURL)

        return AppUITestPrimerTrimResult(
            trackID: trackID,
            trackName: outputTrackName,
            bamURL: outputBAMURL,
            indexURL: outputIndexURL,
            provenanceSidecarURL: provenanceSidecarURL
        )
    }

    private static func nextTrackID(existingIDs: Set<String>) -> String {
        let base = "aln-primer-trimmed"
        if !existingIDs.contains(base) { return base }

        var index = 2
        while existingIDs.contains("\(base)-\(index)") {
            index += 1
        }
        return "\(base)-\(index)"
    }
}

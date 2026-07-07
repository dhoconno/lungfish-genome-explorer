import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum MSAExtractionAnnotationProvenance {
    static let sidecarFilename = "msa-extraction-annotations-provenance.json"

    @discardableResult
    static func write(
        bundleURL: URL,
        sourceAlignmentBundleURL: URL?,
        sourceFASTAURL: URL,
        sourceAnnotationURL: URL,
        annotationResult: ReferenceBundleAnnotationImportResult,
        startedAt: Date,
        completedAt: Date = Date()
    ) throws -> URL {
        let sidecarURL = bundleURL
            .appendingPathComponent("annotations", isDirectory: true)
            .appendingPathComponent(sidecarFilename)
        let argv = [
            "lungfish-gui",
            "msa",
            "extract-annotated-bundle",
            "--source-fasta", sourceFASTAURL.path,
            "--source-annotations", sourceAnnotationURL.path,
            "--output", bundleURL.path,
        ]
        let inputDescriptors = try inputDescriptors(
            sourceAlignmentBundleURL: sourceAlignmentBundleURL,
            sourceFASTAURL: sourceFASTAURL,
            sourceAnnotationURL: sourceAnnotationURL
        )
        let outputDescriptors = try outputDescriptors(
            bundleURL: bundleURL,
            annotationTrack: annotationResult.track,
            sidecarURL: sidecarURL
        )
        let bundleDescriptor = ProvenanceFileDescriptor(fileRecord: ProvenanceRecorder.fileOrDirectoryRecord(
            url: bundleURL,
            format: .unknown,
            role: .output
        ))
        let step = ProvenanceStep(
            toolName: "lungfish-gui msa extract annotated bundle",
            toolVersion: LungfishAppVersion.short,
            argv: argv,
            inputs: inputDescriptors,
            outputs: [bundleDescriptor] + outputDescriptors,
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            stderr: nil,
            startedAt: startedAt,
            completedAt: completedAt
        )
        var builder = ProvenanceRunBuilder(
            workflowName: "msa-selection-reference-bundle-extraction",
            workflowVersion: LungfishAppVersion.short,
            toolName: "lungfish-gui msa extract annotated bundle",
            toolVersion: LungfishAppVersion.short
        )
        .argv(argv)
        .durableReplayArgv(argv)
        .options(
            explicit: [
                "source_alignment_bundle": sourceAlignmentBundleURL.map(ParameterValue.file) ?? .null,
                "source_fasta": .file(sourceFASTAURL),
                "source_annotations": .file(sourceAnnotationURL),
                "output_bundle": .file(bundleURL),
                "output_annotation_track_id": .string(annotationResult.track.id),
                "output_annotation_track_name": .string(annotationResult.track.name),
                "feature_count": .integer(annotationResult.featureCount),
            ],
            defaults: [
                "source_alignment_bundle": .null,
            ],
            resolved: [
                "source_alignment_bundle": sourceAlignmentBundleURL.map(ParameterValue.file) ?? .null,
                "source_fasta": .file(sourceFASTAURL),
                "source_annotations": .file(sourceAnnotationURL),
                "output_bundle": .file(bundleURL),
                "output_annotation_track_id": .string(annotationResult.track.id),
                "output_annotation_track_name": .string(annotationResult.track.name),
                "feature_count": .integer(annotationResult.featureCount),
            ]
        )
        .runtime(ProvenanceRuntimeIdentity())
        if let sourceAlignmentBundleURL {
            builder = try builder.input(ProvenanceFileDescriptor(fileRecord: ProvenanceRecorder.fileOrDirectoryRecord(
                url: sourceAlignmentBundleURL,
                format: .unknown,
                role: .input
            )))
        }
        builder = try builder.input(sourceFASTAURL, format: .fasta, role: .input)
        builder = try builder.input(sourceAnnotationURL, format: .bed, role: .input)
        builder = try builder.output(bundleDescriptor)
        let envelope = try builder
            .step(step)
            .complete(exitStatus: 0, stderr: nil, startedAt: startedAt, endedAt: completedAt)

        return try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: sidecarURL)
    }

    private static func inputDescriptors(
        sourceAlignmentBundleURL: URL?,
        sourceFASTAURL: URL,
        sourceAnnotationURL: URL
    ) throws -> [ProvenanceFileDescriptor] {
        var descriptors: [ProvenanceFileDescriptor] = []
        if let sourceAlignmentBundleURL {
            descriptors.append(ProvenanceFileDescriptor(fileRecord: ProvenanceRecorder.fileOrDirectoryRecord(
                url: sourceAlignmentBundleURL,
                format: .unknown,
                role: .input
            )))
        }
        descriptors.append(try ProvenanceFileDescriptor.file(url: sourceFASTAURL, format: .fasta, role: .input))
        descriptors.append(try ProvenanceFileDescriptor.file(url: sourceAnnotationURL, format: .bed, role: .input))
        return descriptors
    }

    private static func outputDescriptors(
        bundleURL: URL,
        annotationTrack: AnnotationTrackInfo,
        sidecarURL: URL
    ) throws -> [ProvenanceFileDescriptor] {
        let sidecarPath = sidecarURL.standardizedFileURL.path
        let manifestURL = bundleURL.appendingPathComponent(BundleManifest.filename)
        var urls = [manifestURL]
        let databasePath = annotationTrack.databasePath ?? annotationTrack.path
        urls.append(bundleURL.appendingPathComponent(databasePath))
        urls.append(contentsOf: payloadFiles(in: bundleURL, excluding: sidecarPath))

        var seen: Set<String> = []
        return try urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted,
                  FileManager.default.fileExists(atPath: standardized.path) else {
                return nil
            }
            return try ProvenanceFileDescriptor.file(
                url: standardized,
                format: format(for: standardized),
                role: .output
            )
        }.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }

    private static func payloadFiles(in bundleURL: URL, excluding sidecarPath: String) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: bundleURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            guard standardized.path != sidecarPath,
                  standardized.lastPathComponent != ProvenanceRecorder.provenanceFilename,
                  !standardized.lastPathComponent.contains(".lungfish-provenance.json"),
                  (try? standardized.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            urls.append(standardized)
        }
        return urls
    }

    private static func format(for url: URL) -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "json":
            return .json
        case "fa", "fasta", "fna", "fa.gz", "fasta.gz":
            return .fasta
        case "bed":
            return .bed
        case "db", "sqlite", "sqlite3":
            return .unknown
        default:
            return .unknown
        }
    }

}

import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

struct SampleMetadataBundleImportResult {
    let store: SampleMetadataStore
    let metadataURL: URL?
    let provenanceURL: URL?
}

struct SampleMetadataBundleImportService {
    func importMetadata(
        data: Data,
        sourceURL: URL,
        scanResult: MetadataColumnScanResult,
        sampleColumnIndex: Int,
        knownSampleIds: Set<String>,
        bundleURL: URL?
    ) throws -> SampleMetadataBundleImportResult {
        let store = SampleMetadataStore(
            scanResult: scanResult,
            sampleColumnIndex: sampleColumnIndex,
            knownSampleIds: knownSampleIds
        )

        guard let bundleURL else {
            return SampleMetadataBundleImportResult(
                store: store,
                metadataURL: nil,
                provenanceURL: nil
            )
        }

        let startedAt = Date()
        let metadataURL = bundleURL.appendingPathComponent("metadata/sample_metadata.tsv")
        let sampleColumnName = scanResult.candidates
            .first(where: { $0.index == sampleColumnIndex })?
            .name ?? "Column \(sampleColumnIndex + 1)"

        var builder = ProvenanceRunBuilder(
            workflowName: "Sample metadata import",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish Genome Explorer",
            toolVersion: WorkflowRun.currentAppVersion
        )
        .argv([
            "lungfish-gui",
            "import-sample-metadata",
            "--metadata", sourceURL.path,
            "--bundle", bundleURL.path,
            "--sample-column-index", "\(sampleColumnIndex)",
        ])
        .durableReplayArgv([
            "lungfish-gui",
            "import-sample-metadata",
            "--metadata", sourceURL.path,
            "--bundle", bundleURL.path,
            "--sample-column", sampleColumnName,
        ])
        .options(
            explicit: [
                "metadata": .file(sourceURL),
                "bundle": .file(bundleURL),
                "sampleColumnIndex": .integer(sampleColumnIndex),
                "sampleColumnName": .string(sampleColumnName),
            ],
            defaults: [
                "destination": .string("metadata/sample_metadata.tsv"),
            ],
            resolved: [
                "knownSampleCount": .integer(knownSampleIds.count),
                "matchedSampleCount": .integer(store.matchedSampleIds.count),
                "unmatchedMetadataRowCount": .integer(store.unmatchedRecords.count),
                "totalMetadataRows": .integer(scanResult.totalRows),
            ]
        )
        .runtime(ProvenanceRuntimeIdentity())

        builder = try builder.input(sourceURL, format: .text, role: .input)
        for contextURL in ResultBundleSampleMetadataResolver.sampleMetadataContextFiles(in: bundleURL) {
            builder = try builder.input(contextURL, format: format(for: contextURL), role: .input)
        }

        try store.persist(originalData: data, to: bundleURL)
        builder = try builder.output(metadataURL, format: .text, role: .output)

        let envelope = try builder.complete(
            exitStatus: 0,
            startedAt: startedAt,
            endedAt: Date()
        )
        let provenanceURL = try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
        store.wireAutosave(bundleURL: bundleURL)

        return SampleMetadataBundleImportResult(
            store: store,
            metadataURL: metadataURL,
            provenanceURL: provenanceURL
        )
    }

    private func format(for url: URL) -> FileFormat {
        switch url.pathExtension.lowercased() {
        case "json":
            return .json
        case "fa", "fasta", "fna":
            return .fasta
        default:
            return .text
        }
    }
}

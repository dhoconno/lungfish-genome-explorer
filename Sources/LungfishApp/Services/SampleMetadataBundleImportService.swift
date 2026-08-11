import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

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
        identityIndex: SampleIdentityIndex? = nil,
        bundleURL: URL?
    ) throws -> SampleMetadataBundleImportResult {
        let acceptedIdentifiers = identityIndex.map {
            Set($0.metadataIdentifierMappings.keys)
        } ?? knownSampleIds
        let store = try SampleMetadataStore(
            scanResult: scanResult,
            sampleColumnIndex: sampleColumnIndex,
            knownSampleIds: acceptedIdentifiers
        )
        if let identityIndex {
            rekey(store, using: identityIndex)
        }

        guard let bundleURL else {
            return SampleMetadataBundleImportResult(
                store: store,
                metadataURL: nil,
                provenanceURL: nil
            )
        }

        let startedAt = Date()
        let metadataURL = bundleURL.appendingPathComponent("metadata/sample_metadata.tsv")
        let editJournalURL = bundleURL.appendingPathComponent("metadata/sample_metadata_edits.json")
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
                "editJournalDestination": .string("metadata/sample_metadata_edits.json"),
            ],
            resolved: [
                "sourceFormat": .string(scanResult.delimiter == "\t" ? "tsv" : "csv"),
                "sourceDelimiter": .string(scanResult.delimiter == "\t" ? "tab" : "comma"),
                "validationPolicy": .string("trimmed-normalized-identifiers"),
                "knownSampleCount": .integer(knownSampleIds.count),
                "canonicalAliasMap": .dictionary(
                    identityIndex?.metadataIdentifierMappings.mapValues(ParameterValue.string) ?? [:]
                ),
                "readGroupMap": .dictionary(
                    identityIndex?.readGroupMappings.mapValues(ParameterValue.string) ?? [:]
                ),
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

        let snapshot = try ProvenancePublicationSnapshot(
            urls: sampleMetadataPublicationArtifacts(bundleURL: bundleURL, metadataURL: metadataURL),
            backupNamePrefix: "lungfish-sample-metadata-import"
        )
        defer { snapshot.discard() }
        do {
            try store.persist(originalData: data, to: bundleURL)
            builder = try builder.output(metadataURL, format: .text, role: .output)
            builder = try builder.output(editJournalURL, format: .json, role: .output)

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
        } catch {
            try snapshot.restore()
            throw error
        }
    }

    private func rekey(_ store: SampleMetadataStore, using identityIndex: SampleIdentityIndex) {
        var canonicalRecords: [String: [String: String]] = [:]
        for identifier in store.records.keys.sorted() {
            guard let canonicalID = identityIndex.canonicalSampleID(forMetadataIdentifier: identifier),
                  let record = store.records[identifier]
            else { continue }
            if canonicalRecords[canonicalID] == nil {
                canonicalRecords[canonicalID] = record
            }
        }
        store.records = canonicalRecords
        store.matchedSampleIds = Set(canonicalRecords.keys)
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

    private func sampleMetadataPublicationArtifacts(bundleURL: URL, metadataURL: URL) -> [URL] {
        let metadataDirectory = metadataURL.deletingLastPathComponent()
        return [metadataDirectory]
            + ProvenancePublicationArtifacts.bundleRootArtifacts(for: bundleURL)
    }
}

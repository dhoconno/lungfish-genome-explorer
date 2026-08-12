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

enum SampleMetadataBundleImportError: Error, LocalizedError, Equatable {
    case duplicateCanonicalIdentity(String)
    case identityInputOutsideFinalResult(String)

    var errorDescription: String? {
        switch self {
        case .duplicateCanonicalIdentity(let sampleID):
            return "Multiple metadata rows resolve to sample \(sampleID)."
        case .identityInputOutsideFinalResult(let path):
            return "A BAM sample-identity input is outside the final result: \(path)."
        }
    }
}

struct SampleMetadataBundleImportService {
    func importMetadata(
        data: Data,
        sourceURL: URL,
        scanResult: MetadataColumnScanResult,
        sampleColumnIndex: Int,
        knownSampleIds: Set<String>,
        identityIndex: SampleIdentityIndex? = nil,
        identityInputURLs: [URL] = [],
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
            try rekey(store, using: identityIndex)
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
                "trackReadGroupMap": .dictionary(
                    identityIndex?.trackReadGroupMappings.mapValues(ParameterValue.string) ?? [:]
                ),
                "matchedSampleCount": .integer(store.matchedSampleIds.count),
                "unmatchedMetadataRowCount": .integer(store.unmatchedRecords.count),
                "ambiguousIdentityCount": .integer(0),
                "totalMetadataRows": .integer(scanResult.totalRows),
            ]
        )
        .runtime(ProvenanceRuntimeIdentity())

        builder = try builder.input(sourceURL, format: .text, role: .input)
        for contextURL in ResultBundleSampleMetadataResolver.sampleMetadataContextFiles(in: bundleURL) {
            builder = try builder.input(contextURL, format: format(for: contextURL), role: .input)
        }
        let resolvedBundleRoot = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        for identityInputURL in identityInputURLs.map({
            $0.standardizedFileURL.resolvingSymlinksInPath()
        }) {
            guard identityInputURL.pathComponents.count > resolvedBundleRoot.pathComponents.count,
                  identityInputURL.pathComponents.starts(with: resolvedBundleRoot.pathComponents)
            else {
                throw SampleMetadataBundleImportError.identityInputOutsideFinalResult(identityInputURL.path)
            }
            builder = try builder.input(
                identityInputURL,
                format: format(for: identityInputURL),
                role: role(for: identityInputURL)
            )
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
            SampleMetadataEditPersistenceService().wire(store: store, bundleURL: bundleURL)

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

    private func rekey(_ store: SampleMetadataStore, using identityIndex: SampleIdentityIndex) throws {
        var canonicalRecords: [String: [String: String]] = [:]
        for identifier in store.records.keys.sorted() {
            guard let canonicalID = identityIndex.canonicalSampleID(forMetadataIdentifier: identifier),
                  let record = store.records[identifier]
            else { continue }
            guard canonicalRecords[canonicalID] == nil else {
                throw SampleMetadataBundleImportError.duplicateCanonicalIdentity(canonicalID)
            }
            canonicalRecords[canonicalID] = record
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
        case "bam":
            return .bam
        case "cram":
            return .cram
        case "sam":
            return .sam
        case "sqlite", "db":
            return .sqlite
        case "bai", "csi", "fai", "gzi":
            return .unknown
        default:
            return .text
        }
    }

    private func role(for url: URL) -> FileRole {
        switch url.pathExtension.lowercased() {
        case "bai", "csi", "fai", "gzi":
            return .index
        default:
            return .input
        }
    }

    private func sampleMetadataPublicationArtifacts(bundleURL: URL, metadataURL: URL) -> [URL] {
        let metadataDirectory = metadataURL.deletingLastPathComponent()
        return [metadataDirectory]
            + ProvenancePublicationArtifacts.bundleRootArtifacts(for: bundleURL)
    }
}

/// Publishes each Inspector metadata edit together with a refreshed canonical
/// provenance envelope. The journal and provenance are one rollback unit, so
/// a failed provenance write never leaves an unrecorded scientific mutation.
struct SampleMetadataEditPersistenceService {
    private let fileManager: FileManager
    private let writeProvenance: (
        ProvenanceEnvelope,
        URL,
        @escaping @Sendable (ProvenanceWriterMutation) throws -> Void
    ) throws -> URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.writeProvenance = { envelope, bundleURL, mutationObserver in
            try ProvenanceWriter(
                publicationMutationDidOccur: mutationObserver,
                signingProvider: nil
            ).write(envelope, to: bundleURL)
        }
    }

    init(
        fileManager: FileManager = .default,
        writeProvenance: @escaping (ProvenanceEnvelope, URL) throws -> URL
    ) {
        self.fileManager = fileManager
        self.writeProvenance = { envelope, bundleURL, _ in
            try writeProvenance(envelope, bundleURL)
        }
    }

    func wire(store: SampleMetadataStore, bundleURL rawBundleURL: URL) {
        let bundleURL = rawBundleURL.standardizedFileURL
        store.wireAutosave(bundleURL: bundleURL) { journalURL, data, edit in
            try persist(
                journalData: data,
                edit: edit,
                journalURL: journalURL,
                bundleURL: bundleURL
            )
        }
    }

    private func persist(
        journalData: Data,
        edit: MetadataEdit,
        journalURL: URL,
        bundleURL: URL
    ) throws {
        let startedAt = Date()
        guard let existingEnvelope = try ProvenanceEnvelopeReader.load(from: bundleURL) else {
            throw SampleMetadataEditPersistenceError.missingCanonicalProvenance(bundleURL.path)
        }
        let metadataURL = bundleURL.appendingPathComponent("metadata/sample_metadata.tsv")
        guard fileManager.fileExists(atPath: metadataURL.path) else {
            throw SampleMetadataEditPersistenceError.missingImportedMetadata(metadataURL.path)
        }

        var inputs = [
            try ProvenanceFileDescriptor.file(url: metadataURL, format: .text, role: .input),
        ]
        if fileManager.fileExists(atPath: journalURL.path) {
            inputs.append(try ProvenanceFileDescriptor.file(
                url: journalURL,
                format: .json,
                role: .input
            ))
        }

        let snapshot = try ProvenancePublicationSnapshot(
            urls: [journalURL] + ProvenancePublicationArtifacts.bundleRootArtifacts(for: bundleURL),
            backupNamePrefix: "lungfish-sample-metadata-edit"
        )
        defer { snapshot.discard() }
        let tracker = try SampleMetadataRollbackWitnessTracker(snapshot: snapshot)
        let stagedJournalURL = journalURL.deletingLastPathComponent().appendingPathComponent(
            ".\(journalURL.lastPathComponent).edit-candidate-\(UUID().uuidString)"
        )
        var displacedJournalURL: URL?
        defer {
            try? fileManager.removeItem(at: stagedJournalURL)
            if let displacedJournalURL {
                try? fileManager.removeItem(at: displacedJournalURL)
            }
        }
        do {
            try fileManager.createDirectory(
                at: journalURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try journalData.write(to: stagedJournalURL, options: .atomic)
            let publication = try snapshot.publishReplacement(
                from: stagedJournalURL,
                to: journalURL,
                replacingExisting: fileManager.fileExists(atPath: journalURL.path),
                witness: tracker.currentWitness
            )
            tracker.replaceWitness(publication.witness)
            displacedJournalURL = publication.displacedURL
            let output = try ProvenanceFileDescriptor.file(
                url: journalURL,
                format: .json,
                role: .output
            )
            let completedAt = Date()
            let argv = [
                "lungfish-gui", "edit-sample-metadata",
                "--bundle", bundleURL.path,
                "--sample", edit.sampleId,
                "--column", edit.columnName,
                "--new-value", edit.newValue,
            ]
            let step = ProvenanceStep(
                toolName: "Sample metadata edit",
                toolVersion: WorkflowRun.currentAppVersion,
                argv: argv,
                durableReplayArgv: argv,
                reproducibleCommand: argv.map(shellQuote).joined(separator: " "),
                resolvedOptions: [
                    "bundle": .file(bundleURL),
                    "sample": .string(edit.sampleId),
                    "column": .string(edit.columnName),
                    "oldValue": edit.oldValue.map(ParameterValue.string) ?? .null,
                    "newValue": .string(edit.newValue),
                    "journal": .file(journalURL),
                ],
                runtimeIdentity: ProvenanceRuntimeIdentity(),
                inputs: inputs,
                outputs: [output],
                exitStatus: 0,
                wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
                dependsOn: existingEnvelope.steps.last.map { [$0.id] } ?? [],
                startedAt: startedAt,
                completedAt: completedAt
            )
            let updatedOptions = ProvenanceOptions(
                explicit: existingEnvelope.options.explicit,
                defaults: existingEnvelope.options.defaults,
                resolvedDefaults: existingEnvelope.options.resolvedDefaults.merging([
                    "sampleMetadataEditCount": .integer(existingEnvelope.steps.filter {
                        $0.toolName == "Sample metadata edit"
                    }.count + 1),
                ]) { _, rhs in rhs }
            )
            let updatedEnvelope = ProvenanceEnvelope(
                schemaVersion: existingEnvelope.schemaVersion,
                id: existingEnvelope.id,
                createdAt: existingEnvelope.createdAt,
                workflowName: existingEnvelope.workflowName,
                workflowVersion: existingEnvelope.workflowVersion,
                toolName: existingEnvelope.toolName,
                toolVersion: existingEnvelope.toolVersion,
                githubReleaseVersion: existingEnvelope.githubReleaseVersion,
                tool: existingEnvelope.tool,
                argv: existingEnvelope.argv,
                durableReplayArgv: existingEnvelope.durableReplayArgv,
                reproducibleCommand: existingEnvelope.reproducibleCommand,
                options: updatedOptions,
                runtimeIdentity: existingEnvelope.runtimeIdentity,
                files: deduplicatedPreferringLast(existingEnvelope.files + inputs + [output]),
                output: existingEnvelope.output.map {
                    $0.path == journalURL.path && $0.role == .output ? output : $0
                } ?? output,
                outputs: deduplicatedPreferringLast(existingEnvelope.outputs + [output]),
                steps: existingEnvelope.steps + [step],
                wallTimeSeconds: (existingEnvelope.wallTimeSeconds ?? 0) + (step.wallTimeSeconds ?? 0),
                exitStatus: 0,
                stderr: existingEnvelope.stderr,
                signatures: [],
                legacyWorkflowRun: nil
            )
            _ = try writeProvenance(updatedEnvelope, bundleURL, tracker.observe)
        } catch {
            let preserved = try snapshot.restore(ifCurrentMatches: tracker.currentWitness)
            guard preserved.isEmpty else {
                throw SampleMetadataEditPersistenceError.concurrentPublicationPreserved(
                    preserved.map(\.path)
                )
            }
            throw error
        }
    }

    private func deduplicatedPreferringLast(
        _ descriptors: [ProvenanceFileDescriptor]
    ) -> [ProvenanceFileDescriptor] {
        var seen = Set<String>()
        var result: [ProvenanceFileDescriptor] = []
        for descriptor in descriptors.reversed() {
            let key = "\(descriptor.role.rawValue)\u{1F}\(descriptor.path)"
            if seen.insert(key).inserted {
                result.append(descriptor)
            }
        }
        return result.reversed()
    }

    private func shellQuote(_ value: String) -> String {
        if value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "'\"\\$`!&;|<>()[]{}*?")
        )) == nil {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum SampleMetadataEditPersistenceError: Error, LocalizedError, Equatable {
    case missingCanonicalProvenance(String)
    case missingImportedMetadata(String)
    case concurrentPublicationPreserved([String])

    var errorDescription: String? {
        switch self {
        case .missingCanonicalProvenance(let path):
            return "Sample metadata provenance is missing from \(path)."
        case .missingImportedMetadata(let path):
            return "Imported sample metadata is missing at \(path)."
        case .concurrentPublicationPreserved(let paths):
            return "The metadata edit could not be rolled back because newer changes were preserved at: \(paths.joined(separator: ", "))."
        }
    }
}

private final class SampleMetadataRollbackWitnessTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: ProvenancePublicationSnapshot
    private var witness: ProvenancePublicationRollbackWitness

    init(snapshot: ProvenancePublicationSnapshot) throws {
        self.snapshot = snapshot
        self.witness = try snapshot.captureRollbackWitness()
    }

    var currentWitness: ProvenancePublicationRollbackWitness {
        lock.withLock { witness }
    }

    func replaceWitness(_ witness: ProvenancePublicationRollbackWitness) {
        lock.withLock { self.witness = witness }
    }

    func observe(_ mutation: ProvenanceWriterMutation) throws {
        try lock.withLock {
            witness = try snapshot.refreshingRollbackWitness(witness, after: mutation)
        }
    }
}

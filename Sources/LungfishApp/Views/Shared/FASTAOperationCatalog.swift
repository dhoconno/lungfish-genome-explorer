import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum FASTAOperationCatalog {
    enum Error: LocalizedError {
        case emptyInput

        var errorDescription: String? {
            switch self {
            case .emptyInput:
                return "No FASTA records were provided."
            }
        }
    }

    static func availableOperationKinds() -> [FASTQDerivativeOperationKind] {
        FASTQDerivativeOperationKind.allCases.filter(\.supportsFASTA)
    }

    static func availableToolIDs() -> [FASTQOperationToolID] {
        FASTQOperationToolID.allCases.filter(\.supportsFASTA)
    }

    static func inputSequenceFormat(for url: URL) -> SequenceFormat? {
        SequenceInputResolver.inputSequenceFormat(for: url)
    }

    static func createTemporaryInputBundle(
        fastaRecords: [String],
        suggestedName: String,
        projectURL: URL?,
        durableSourceURLs: [URL] = []
    ) throws -> URL {
        guard !fastaRecords.isEmpty else {
            throw Error.emptyInput
        }

        // Selection staging is consumed asynchronously by the sharing picker,
        // reference importer, or operations dialog. Keep it in the app session
        // temp area rather than the project's attested work area: it remains
        // available to the consumer, is removed on app termination, and never
        // appears as an active, undeletable project-storage item.
        let tempRoot = try TempFileManager.shared.createRegisteredTempDirectory(
            prefix: "lungfish-fasta-ops-"
        )
        do {
            let bundleName = sanitizedBundleStem(from: suggestedName)
            let bundleURL = tempRoot.appendingPathComponent(
                "\(bundleName).\(FASTQBundle.directoryExtension)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: bundleURL,
                withIntermediateDirectories: true
            )

            let startedAt = Date()
            let fastaFilename = "selection.fasta"
            let fastaURL = bundleURL.appendingPathComponent(fastaFilename)
            let normalizedFASTA = fastaRecords
                .map(normalizeRecord)
                .joined(separator: "")
            try normalizedFASTA.write(to: fastaURL, atomically: true, encoding: .utf8)

            let statistics = FASTQDatasetStatistics.placeholder(
                readCount: recordCount(in: normalizedFASTA),
                baseCount: baseCount(in: normalizedFASTA)
            )
            let manifest = FASTQDerivedBundleManifest(
            name: bundleName,
            parentBundleRelativePath: ".",
            rootBundleRelativePath: ".",
            rootFASTQFilename: fastaFilename,
            payload: .fullFASTA(fastaFilename: fastaFilename),
            lineage: [],
            operation: FASTQDerivativeOperation(
                kind: .searchText,
                query: "selected-fasta-sequences"
            ),
            cachedStatistics: statistics,
            pairingMode: nil,
            sequenceFormat: .fasta
            )
            try FASTQBundle.saveDerivedManifest(manifest, in: bundleURL)
            try writeRootProvenance(
                to: bundleURL,
                payloadURL: fastaURL,
                normalizedFASTA: normalizedFASTA,
                durableSourceURLs: durableSourceURLs,
                startedAt: startedAt
            )
            return bundleURL
        } catch {
            TempFileManager.shared.unregisterSessionTempDirectory(tempRoot)
            try? FileManager.default.removeItem(at: tempRoot)
            throw error
        }
    }
    private static func sanitizedBundleStem(from suggestedName: String) -> String {
        let trimmed = suggestedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "selected-sequences" : trimmed
    }

    private static func normalizeRecord(_ record: String) -> String {
        var normalized = record
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.hasSuffix("\n") {
            normalized.append("\n")
        }
        return normalized
    }

    private static func recordCount(in fasta: String) -> Int {
        fasta.split(whereSeparator: \.isNewline).filter { $0.hasPrefix(">") }.count
    }

    private static func baseCount(in fasta: String) -> Int64 {
        Int64(
            fasta
                .split(whereSeparator: \.isNewline)
                .filter { !$0.hasPrefix(">") }
                .reduce(into: 0) { $0 += $1.count }
        )
    }

    private static func writeRootProvenance(
        to bundleURL: URL,
        payloadURL: URL,
        normalizedFASTA: String,
        durableSourceURLs: [URL],
        startedAt: Date
    ) throws {
        let completedAt = Date()
        let identifiers = selectedIdentifiers(in: normalizedFASTA)
        // The GUI writes this short-lived selection in process. Record that
        // truthfully, while retaining a real CLI command for durable replay.
        let argv = ["Lungfish Genome Explorer", "fasta-selection-materialization"]
            + durableSourceURLs.flatMap { ["--source", $0.standardizedFileURL.path] }
            + identifiers.flatMap { ["--sequence-id", $0] }
            + ["--output", payloadURL.path]
        let durableReplayArgv: [String]? = durableSourceURLs.count == 1 ? durableSourceURLs.first.map { sourceURL in
            ["lungfish-cli", "extract", "contigs", "--contigs", sourceURL.standardizedFileURL.path]
                + identifiers.flatMap { ["--contig", $0] }
                + ["--output", payloadURL.path]
        } : nil
        let output = try ProvenanceFileDescriptor.file(url: payloadURL, format: .fasta, role: .output)
        let inputs = try durableSourceURLs.map(durableInputDescriptor)
        let resolved: [String: ParameterValue] = [
            "recordCount": .integer(recordCount(in: normalizedFASTA)),
            "baseCount": .integer(Int(baseCount(in: normalizedFASTA))),
            "normalization": .string("LF line endings; one trailing newline per record"),
        ]
        let version = WorkflowRun.currentAppVersion
        let step = ProvenanceStep(
            toolName: "Lungfish.app in-process FASTA selection",
            toolVersion: version,
            argv: argv,
            durableReplayArgv: durableReplayArgv,
            resolvedOptions: resolved,
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            inputs: inputs,
            outputs: [output],
            exitStatus: 0,
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            startedAt: startedAt,
            completedAt: completedAt
        )
        let envelope = ProvenanceEnvelope(
            createdAt: startedAt,
            workflowName: "lungfish app selected fasta materialization",
            workflowVersion: version,
            toolName: "Lungfish.app in-process FASTA selection",
            toolVersion: version,
            tool: ProvenanceToolIdentity(name: "Lungfish.app", version: version, kind: "gui"),
            argv: argv,
            durableReplayArgv: durableReplayArgv,
            options: ProvenanceOptions(
                explicit: [
                    "selectedSequenceIDs": .array(identifiers.map(ParameterValue.string)),
                    "selectedSequenceCount": .integer(identifiers.count),
                    "durableSourcePaths": .array(durableSourceURLs.map { .file($0) }),
                ],
                defaults: ["lineEnding": .string("LF")],
                resolvedDefaults: resolved
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: inputs + [output],
            output: output,
            outputs: [output],
            steps: [step],
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: 0,
            stderr: nil
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
    }

    private static func durableInputDescriptor(_ url: URL) throws -> ProvenanceFileDescriptor {
        let standardizedURL = url.standardizedFileURL
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: standardizedURL)
        let rootProvenance = standardizedURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let upstream = FileManager.default.fileExists(atPath: sidecar.path) ? sidecar.path
            : FileManager.default.fileExists(atPath: rootProvenance.path) ? rootProvenance.path
            : nil
        var isDirectory: ObjCBool = false
        let isDirectorySource = FileManager.default.fileExists(
            atPath: standardizedURL.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
        let record = ProvenanceRecorder.fileOrDirectoryRecord(
            url: standardizedURL,
            format: isDirectorySource ? .unknown : .fasta,
            role: .input
        )
        return ProvenanceFileDescriptor(
            path: record.path,
            checksumSHA256: record.sha256,
            fileSize: record.sizeBytes,
            format: record.format,
            role: record.role,
            originPath: standardizedURL.path,
            sourceProvenancePath: upstream
        )
    }

    /// Counts FASTA records in a file on disk, so the operations dialog can
    /// offer "all N" against "selected M" instead of silently aligning
    /// whatever was staged.
    static func recordCount(in url: URL) throws -> Int {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).reduce(into: 0) { count, line in
            if line.hasPrefix(">") { count += 1 }
        }
    }

    static func selectedIdentifiers(in fasta: String) -> [String] {
        fasta.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix(">") else { return nil }
            return line.dropFirst().split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
    }
}

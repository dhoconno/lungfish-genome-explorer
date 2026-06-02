import Foundation
import LungfishIO

public enum GenotypeWorkbookRevisionError: Error, LocalizedError, Equatable, Sendable {
    case invalidWorkbook(String)
    case missingRevision(String)
    case missingCurrentWorkbook(String)

    public var errorDescription: String? {
        switch self {
        case .invalidWorkbook(let path):
            return "The selected file is not a readable .xlsx workbook: \(path)"
        case .missingRevision(let id):
            return "Workbook revision \(id) does not exist."
        case .missingCurrentWorkbook(let path):
            return "Current workbook does not exist: \(path)"
        }
    }
}

public struct GenotypeWorkbookRevisionService {
    private let fileManager: FileManager
    private let dateProvider: @Sendable () -> Date
    private let userProvider: @Sendable () -> String

    public init(
        fileManager: FileManager = .default,
        dateProvider: @escaping @Sendable () -> Date = Date.init,
        userProvider: @escaping @Sendable () -> String = { NSUserName() }
    ) {
        self.fileManager = fileManager
        self.dateProvider = dateProvider
        self.userProvider = userProvider
    }

    public func ensureCurrentWorkbook(
        in bundleURL: URL
    ) throws -> ONTGenotypeResultBundleManifest {
        let bundle = bundleURL.standardizedFileURL
        let manifest = try ONTGenotypeResultBundle.loadManifest(from: bundle)
        if let currentWorkbookPath = manifest.currentWorkbookPath {
            let currentURL = ONTGenotypeResultBundle.resolvedURL(for: currentWorkbookPath, in: bundle)
            if fileManager.fileExists(atPath: currentURL.path) {
                return manifest
            }
        }

        let primaryURL = try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundle)
        let currentURL = defaultCurrentWorkbookURL(in: bundle)
        try fileManager.createDirectory(
            at: currentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try replaceFile(at: currentURL, withCopyOf: primaryURL)

        let provenancePath = nextProvenancePath(action: "initial-current-copy", in: bundle)
        let revision = try makeRevision(
            role: .initialCurrentCopy,
            path: relativePath(from: bundle, to: currentURL),
            label: "Initial editable workbook",
            sourceFilename: primaryURL.lastPathComponent,
            predecessorID: nil,
            predecessorPath: relativePath(from: bundle, to: primaryURL),
            workbookURL: currentURL,
            provenancePath: provenancePath
        )
        let updated = manifestWithWorkbookFields(
            manifest,
            currentWorkbookPath: relativePath(from: bundle, to: currentURL),
            revisions: (manifest.workbookRevisions ?? []) + [revision]
        )
        try ONTGenotypeResultBundle.writeManifest(updated, to: bundle)
        try writeProvenance(
            action: "initial-current-copy",
            bundleURL: bundle,
            sourceWorkbookURL: primaryURL,
            previousCurrentURL: nil,
            snapshotURL: nil,
            importedSourceURL: nil,
            newCurrentURL: currentURL,
            manifestURL: ONTGenotypeResultBundle.manifestURL(in: bundle),
            provenancePath: provenancePath,
            startedAt: dateProvider()
        )
        return updated
    }

    public func importRevisedWorkbook(
        from sourceURL: URL,
        into bundleURL: URL,
        label: String? = nil
    ) throws -> ONTGenotypeResultBundleManifest {
        let source = sourceURL.standardizedFileURL
        try validateWorkbook(source)

        let bundle = bundleURL.standardizedFileURL
        let originalManifest = try ONTGenotypeResultBundle.loadManifest(from: bundle)
        let originalCurrentData: Data?
        if let originalCurrentPath = originalManifest.currentWorkbookPath {
            originalCurrentData = try? Data(
                contentsOf: ONTGenotypeResultBundle.resolvedURL(for: originalCurrentPath, in: bundle)
            )
        } else {
            originalCurrentData = nil
        }
        let startedAt = dateProvider()
        var manifest = try ensureCurrentWorkbook(in: bundle)
        let currentPath = manifest.currentWorkbookPath ?? defaultCurrentWorkbookRelativePath
        let currentURL = ONTGenotypeResultBundle.resolvedURL(for: currentPath, in: bundle)
        guard fileManager.fileExists(atPath: currentURL.path) else {
            throw GenotypeWorkbookRevisionError.missingCurrentWorkbook(currentURL.path)
        }
        let previousCurrentRevision = latestCurrentWorkbookRevision(in: manifest)
        let provenancePath = nextProvenancePath(action: "import", in: bundle)

        do {
            let currentSHA256 = try ProvenanceFileHasher.sha256(of: currentURL)
            let snapshotRole: ONTGenotypeWorkbookRevisionRole = previousCurrentRevision?.sha256 == currentSHA256
                ? .externalEditSnapshot
                : .externalEditSnapshot
            let snapshotRevision = try snapshotCurrentWorkbook(
                currentURL: currentURL,
                bundleURL: bundle,
                label: previousCurrentRevision?.sha256 == currentSHA256
                    ? "Previous current workbook"
                    : "External workbook edit before import",
                role: snapshotRole,
                predecessor: previousCurrentRevision,
                provenancePath: provenancePath
            )
            try replaceFile(at: currentURL, withCopyOf: source)
            let importedRevision = try makeRevision(
                role: .imported,
                path: currentPath,
                label: normalizedLabel(label, fallback: "Imported workbook"),
                sourceFilename: source.lastPathComponent,
                predecessorID: snapshotRevision.id,
                predecessorPath: snapshotRevision.path,
                workbookURL: currentURL,
                provenancePath: provenancePath
            )
            manifest = manifestWithWorkbookFields(
                manifest,
                currentWorkbookPath: currentPath,
                revisions: (manifest.workbookRevisions ?? []) + [snapshotRevision, importedRevision]
            )
            try ONTGenotypeResultBundle.writeManifest(manifest, to: bundle)
            try writeProvenance(
                action: "import",
                bundleURL: bundle,
                sourceWorkbookURL: try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundle),
                previousCurrentURL: currentURL,
                snapshotURL: ONTGenotypeResultBundle.resolvedURL(for: snapshotRevision.path, in: bundle),
                importedSourceURL: source,
                newCurrentURL: currentURL,
                manifestURL: ONTGenotypeResultBundle.manifestURL(in: bundle),
                provenancePath: provenancePath,
                startedAt: startedAt
            )
            return manifest
        } catch {
            if let originalCurrentData, let originalCurrentPath = originalManifest.currentWorkbookPath {
                let originalCurrentURL = ONTGenotypeResultBundle.resolvedURL(for: originalCurrentPath, in: bundle)
                try? fileManager.createDirectory(
                    at: originalCurrentURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? originalCurrentData.write(to: originalCurrentURL, options: .atomic)
            } else if let originalCurrentData {
                try? originalCurrentData.write(to: currentURL, options: .atomic)
            } else if fileManager.fileExists(atPath: currentURL.path) && originalManifest.currentWorkbookPath == nil {
                try? fileManager.removeItem(at: currentURL)
            }
            try? ONTGenotypeResultBundle.writeManifest(originalManifest, to: bundle)
            throw error
        }
    }

    public func restoreWorkbookRevision(
        id revisionID: String,
        in bundleURL: URL
    ) throws -> ONTGenotypeResultBundleManifest {
        let bundle = bundleURL.standardizedFileURL
        var manifest = try ensureCurrentWorkbook(in: bundle)
        guard let revision = manifest.workbookRevisions?.first(where: { $0.id == revisionID }) else {
            throw GenotypeWorkbookRevisionError.missingRevision(revisionID)
        }
        let sourceURL = ONTGenotypeResultBundle.resolvedURL(for: revision.path, in: bundle)
        try validateWorkbook(sourceURL)
        let currentPath = manifest.currentWorkbookPath ?? defaultCurrentWorkbookRelativePath
        let currentURL = ONTGenotypeResultBundle.resolvedURL(for: currentPath, in: bundle)
        let startedAt = dateProvider()
        let provenancePath = nextProvenancePath(action: "restore", in: bundle)
        let snapshotRevision = try snapshotCurrentWorkbook(
            currentURL: currentURL,
            bundleURL: bundle,
            label: "Previous current workbook before restore",
            role: .externalEditSnapshot,
            predecessor: latestCurrentWorkbookRevision(in: manifest),
            provenancePath: provenancePath
        )
        try replaceFile(at: currentURL, withCopyOf: sourceURL)
        let restoredRevision = try makeRevision(
            role: .restored,
            path: currentPath,
            label: "Restored \(revision.label)",
            sourceFilename: sourceURL.lastPathComponent,
            predecessorID: snapshotRevision.id,
            predecessorPath: snapshotRevision.path,
            workbookURL: currentURL,
            provenancePath: provenancePath
        )
        manifest = manifestWithWorkbookFields(
            manifest,
            currentWorkbookPath: currentPath,
            revisions: (manifest.workbookRevisions ?? []) + [snapshotRevision, restoredRevision]
        )
        try ONTGenotypeResultBundle.writeManifest(manifest, to: bundle)
        try writeProvenance(
            action: "restore",
            bundleURL: bundle,
            sourceWorkbookURL: try ONTGenotypeResultBundle.primaryWorkbookURL(for: bundle),
            previousCurrentURL: currentURL,
            snapshotURL: ONTGenotypeResultBundle.resolvedURL(for: snapshotRevision.path, in: bundle),
            importedSourceURL: sourceURL,
            newCurrentURL: currentURL,
            manifestURL: ONTGenotypeResultBundle.manifestURL(in: bundle),
            provenancePath: provenancePath,
            startedAt: startedAt
        )
        return manifest
    }

    private var defaultCurrentWorkbookRelativePath: String {
        "artifacts/workbooks/current.xlsx"
    }

    private func defaultCurrentWorkbookURL(in bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent("artifacts/workbooks", isDirectory: true)
            .appendingPathComponent("current.xlsx")
    }

    private func snapshotCurrentWorkbook(
        currentURL: URL,
        bundleURL: URL,
        label: String,
        role: ONTGenotypeWorkbookRevisionRole,
        predecessor: ONTGenotypeWorkbookRevision?,
        provenancePath: String
    ) throws -> ONTGenotypeWorkbookRevision {
        let snapshotURL = revisionsDirectory(in: bundleURL)
            .appendingPathComponent("\(timestampSlug())-\(safeFilenameStem(label))-\(UUID().uuidString.prefix(8)).xlsx")
        try fileManager.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: currentURL, to: snapshotURL)
        return try makeRevision(
            role: role,
            path: relativePath(from: bundleURL, to: snapshotURL),
            label: label,
            sourceFilename: currentURL.lastPathComponent,
            predecessorID: predecessor?.id,
            predecessorPath: predecessor?.path,
            workbookURL: snapshotURL,
            provenancePath: provenancePath
        )
    }

    private func makeRevision(
        role: ONTGenotypeWorkbookRevisionRole,
        path: String,
        label: String,
        sourceFilename: String?,
        predecessorID: String?,
        predecessorPath: String?,
        workbookURL: URL,
        provenancePath: String?
    ) throws -> ONTGenotypeWorkbookRevision {
        ONTGenotypeWorkbookRevision(
            id: "\(role.rawValue)-\(UUID().uuidString)",
            role: role,
            path: path,
            label: label,
            sourceFilename: sourceFilename,
            createdAt: ISO8601DateFormatter().string(from: dateProvider()),
            user: userProvider(),
            predecessorID: predecessorID,
            predecessorPath: predecessorPath,
            sha256: try ProvenanceFileHasher.sha256(of: workbookURL),
            sizeBytes: Int64(try ProvenanceFileHasher.fileSize(of: workbookURL)),
            provenancePath: provenancePath
        )
    }

    private func writeProvenance(
        action: String,
        bundleURL: URL,
        sourceWorkbookURL: URL,
        previousCurrentURL: URL?,
        snapshotURL: URL?,
        importedSourceURL: URL?,
        newCurrentURL: URL,
        manifestURL: URL,
        provenancePath: String,
        startedAt: Date
    ) throws {
        let completedAt = dateProvider()
        let inputURLs = [sourceWorkbookURL, previousCurrentURL, importedSourceURL].compactMap { $0 }
        let outputURLs = [snapshotURL, newCurrentURL, manifestURL].compactMap { $0 }
        let inputs = try inputURLs.map { try ProvenanceFileDescriptor.file(url: $0, role: .input) }
        let outputs = try outputURLs.map { try ProvenanceFileDescriptor.file(url: $0, role: .output) }
        let provenanceURL = ONTGenotypeResultBundle.resolvedURL(for: provenancePath, in: bundleURL)
        let provenanceDescriptor = ProvenanceFileDescriptor(path: provenanceURL.path, role: .log)
        let argv = [
            "Lungfish.app",
            "genotype-workbook",
            action,
            "--bundle", bundleURL.path,
            "--current-workbook", newCurrentURL.path,
        ]
        let envelope = ProvenanceEnvelope(
            createdAt: completedAt,
            workflowName: "Genotype Workbook Revision",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: "Lungfish.app",
            toolVersion: WorkflowRun.currentAppVersion,
            tool: ProvenanceToolIdentity(name: "Lungfish.app", version: WorkflowRun.currentAppVersion, kind: "app"),
            argv: argv,
            durableReplayArgv: argv,
            options: ProvenanceOptions(
                explicit: [
                    "action": .string(action),
                    "bundle": .file(bundleURL),
                    "currentWorkbook": .file(newCurrentURL),
                ],
                resolvedDefaults: [
                    "currentWorkbookPath": .string(defaultCurrentWorkbookRelativePath),
                    "historyDirectory": .string("artifacts/workbooks/revisions"),
                ]
            ),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: inputs + outputs + [provenanceDescriptor],
            output: ProvenanceFileDescriptor(path: bundleURL.path, role: .output),
            outputs: outputs + [provenanceDescriptor],
            steps: [
                ProvenanceStep(
                    toolName: "Lungfish.app genotype workbook \(action)",
                    toolVersion: WorkflowRun.currentAppVersion,
                    argv: argv,
                    inputs: inputs,
                    outputs: outputs,
                    exitStatus: 0,
                    wallTimeSeconds: completedAt.timeIntervalSince(startedAt)
                )
            ],
            wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
            exitStatus: 0
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: provenanceURL)
    }

    private func validateWorkbook(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "xlsx",
              let handle = try? FileHandle(forReadingFrom: url) else {
            throw GenotypeWorkbookRevisionError.invalidWorkbook(url.path)
        }
        defer { try? handle.close() }
        let magic = handle.readData(ofLength: 4)
        guard magic == Data([0x50, 0x4b, 0x03, 0x04])
            || magic == Data([0x50, 0x4b, 0x05, 0x06])
            || magic == Data([0x50, 0x4b, 0x07, 0x08]) else {
            throw GenotypeWorkbookRevisionError.invalidWorkbook(url.path)
        }
    }

    private func replaceFile(at destinationURL: URL, withCopyOf sourceURL: URL) throws {
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }
        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    private func manifestWithWorkbookFields(
        _ manifest: ONTGenotypeResultBundleManifest,
        currentWorkbookPath: String,
        revisions: [ONTGenotypeWorkbookRevision]
    ) -> ONTGenotypeResultBundleManifest {
        ONTGenotypeResultBundleManifest(
            schemaVersion: manifest.schemaVersion,
            kind: manifest.kind,
            outputName: manifest.outputName,
            analysisName: manifest.analysisName,
            primaryWorkbookPath: manifest.primaryWorkbookPath,
            currentWorkbookPath: currentWorkbookPath,
            workbookRevisions: revisions,
            longSummaryCSVPath: manifest.longSummaryCSVPath,
            sampleSummaryCSVPath: manifest.sampleSummaryCSVPath,
            statsJSONPath: manifest.statsJSONPath,
            provenancePath: manifest.provenancePath,
            haplotypeAnalysisPath: manifest.haplotypeAnalysisPath,
            haplotypeDefinitionSetID: manifest.haplotypeDefinitionSetID,
            haplotypeAssayID: manifest.haplotypeAssayID,
            createdAt: manifest.createdAt
        )
    }

    private func latestCurrentWorkbookRevision(
        in manifest: ONTGenotypeResultBundleManifest
    ) -> ONTGenotypeWorkbookRevision? {
        guard let currentPath = manifest.currentWorkbookPath else { return nil }
        return manifest.workbookRevisions?.last { $0.path == currentPath }
    }

    private func revisionsDirectory(in bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent("artifacts/workbooks/revisions", isDirectory: true)
    }

    private func nextProvenancePath(action: String, in bundleURL: URL) -> String {
        let url = bundleURL
            .appendingPathComponent("artifacts/workbooks/provenance", isDirectory: true)
            .appendingPathComponent("\(timestampSlug())-\(safeFilenameStem(action))-\(UUID().uuidString.prefix(8)).lungfish-provenance.json")
        return relativePath(from: bundleURL, to: url)
    }

    private func timestampSlug() -> String {
        ISO8601DateFormatter()
            .string(from: dateProvider())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "-")
    }

    private func normalizedLabel(_ label: String?, fallback: String) -> String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func safeFilenameStem(_ value: String) -> String {
        let sanitized = value.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        let collapsed = String(sanitized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "workbook" : collapsed
    }

    private func relativePath(from directoryURL: URL, to fileURL: URL) -> String {
        let directoryPath = directoryURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        if filePath.hasPrefix(prefix) {
            return String(filePath.dropFirst(prefix.count))
        }
        return filePath
    }
}

import Foundation
import LungfishIO
import LungfishWorkflow

public typealias ApplicationExportImportProgress = @Sendable (Double, String) -> Void
public typealias ApplicationExportReferenceImporter = @Sendable (URL, URL, String) async throws -> ReferenceBundleImportResult
public typealias ApplicationExportMSAImporter = @Sendable (URL, URL) throws -> URL
public typealias ApplicationExportTreeImporter = @Sendable (URL, URL) throws -> URL

public struct ApplicationExportImportCollectionService: Sendable {
    public static let `default` = ApplicationExportImportCollectionService()

    private let scanner: ApplicationExportScanner
    private let archiveTool: GeneiousArchiveTool
    private let referenceImporter: ApplicationExportReferenceImporter
    private let msaImporter: ApplicationExportMSAImporter
    private let treeImporter: ApplicationExportTreeImporter

    public init(
        scanner: ApplicationExportScanner = ApplicationExportScanner(),
        archiveTool: GeneiousArchiveTool = GeneiousArchiveTool(),
        referenceImporter: @escaping ApplicationExportReferenceImporter = { sourceURL, outputDirectory, preferredName in
            try await ReferenceBundleImportService.importAsReferenceBundleViaCLI(
                sourceURL: sourceURL,
                outputDirectory: outputDirectory,
                preferredBundleName: preferredName
            )
        },
        msaImporter: @escaping ApplicationExportMSAImporter = { sourceURL, bundleURL in
            try MultipleSequenceAlignmentBundle.importAlignment(from: sourceURL, to: bundleURL).url
        },
        treeImporter: @escaping ApplicationExportTreeImporter = { sourceURL, bundleURL in
            try PhylogeneticTreeBundleImporter.importTree(from: sourceURL, to: bundleURL).url
        }
    ) {
        self.scanner = scanner
        self.archiveTool = archiveTool
        self.referenceImporter = referenceImporter
        self.msaImporter = msaImporter
        self.treeImporter = treeImporter
    }

    public func importApplicationExport(
        sourceURL: URL,
        projectURL: URL,
        kind: ApplicationExportKind,
        options: ApplicationExportImportOptions = .default,
        progress: ApplicationExportImportProgress? = nil
    ) async throws -> ApplicationExportImportResult {
        let startedAt = Date()
        let tempRunURL = try createProjectTempRunDirectory(projectURL: projectURL)
        defer { try? FileManager.default.removeItem(at: tempRunURL) }

        progress?(0.02, "Scanning \(kind.displayName) export...")
        let scannedInventory = try await scanner.scan(
            sourceURL: sourceURL,
            kind: kind,
            temporaryDirectory: tempRunURL.appendingPathComponent("scan", isDirectory: true)
        )

        let collectionURL = try createCollectionFolder(
            sourceURL: sourceURL,
            projectURL: projectURL,
            kind: kind,
            options: options
        )
        let bundlesURL = collectionURL.appendingPathComponent("LGE Bundles", isDirectory: true)
        let artifactsURL = collectionURL.appendingPathComponent("Binary Artifacts", isDirectory: true)
        let rawSourceURL = collectionURL.appendingPathComponent("Source", isDirectory: true)
        let effectivePreserveRawSource = options.preserveRawSource && !kind.importsNativeBundlesOnly
        let effectivePreserveUnsupportedArtifacts = options.preserveUnsupportedArtifacts && !kind.importsNativeBundlesOnly
        try FileManager.default.createDirectory(at: bundlesURL, withIntermediateDirectories: true)
        if effectivePreserveUnsupportedArtifacts {
            try FileManager.default.createDirectory(at: artifactsURL, withIntermediateDirectories: true)
        }
        if effectivePreserveRawSource {
            try FileManager.default.createDirectory(at: rawSourceURL, withIntermediateDirectories: true)
        }

        var sourceCopyOutputs: [URL] = []
        if effectivePreserveRawSource {
            progress?(0.12, "Preserving original \(kind.displayName) source...")
            sourceCopyOutputs.append(try preserveRawSource(sourceURL: sourceURL, destinationDirectory: rawSourceURL))
        }

        let materialized = try materializeSourceIfNeeded(
            sourceURL: sourceURL,
            sourceKind: scannedInventory.sourceKind,
            tempRunURL: tempRunURL
        )
        defer { materialized.cleanup() }

        var nativeBundleURLs: [URL] = []
        var preservedArtifactURLs: [URL] = []
        var warnings = scannedInventory.warnings
        var processedItems: [ApplicationExportImportItem] = []

        let totalItems = max(scannedInventory.items.count, 1)
        for (index, item) in scannedInventory.items.enumerated() {
            progress?(0.18 + (Double(index) / Double(totalItems)) * 0.64, "Processing \(item.sourceRelativePath)...")
            let sourceFileURL = sourceFileURL(for: item, sourceURL: sourceURL, materializedSource: materialized)
            var destination: String?
            warnings.append(contentsOf: item.warnings)

            if item.kind == .standaloneReferenceSequence && options.importStandaloneReferences {
                let preferredName = Self.sanitizedBaseName(
                    URL(fileURLWithPath: item.sourceRelativePath).deletingPathExtension().lastPathComponent
                )
                let result = try await referenceImporter(sourceFileURL, bundlesURL, preferredName)
                nativeBundleURLs.append(result.bundleURL)
                destination = relativePath(from: collectionURL, to: result.bundleURL)
            } else if item.kind == .multipleSequenceAlignment {
                let preferredName = Self.sanitizedBaseName(
                    URL(fileURLWithPath: item.sourceRelativePath).deletingPathExtension().lastPathComponent
                )
                let bundleURL = uniqueBundleURL(
                    in: bundlesURL,
                    preferredName: preferredName,
                    pathExtension: MultipleSequenceAlignmentBundle.directoryExtension
                )
                do {
                    let importedURL = try msaImporter(sourceFileURL, bundleURL)
                    nativeBundleURLs.append(importedURL)
                    destination = relativePath(from: collectionURL, to: importedURL)
                } catch {
                    appendUnique("\(item.sourceRelativePath) could not be parsed as a native MSA bundle: \(error.localizedDescription)", to: &warnings)
                }
            } else if item.kind == .phylogeneticTree {
                let preferredName = Self.sanitizedBaseName(
                    URL(fileURLWithPath: item.sourceRelativePath).deletingPathExtension().lastPathComponent
                )
                let bundleURL = uniqueBundleURL(
                    in: bundlesURL,
                    preferredName: preferredName,
                    pathExtension: "lungfishtree"
                )
                do {
                    let importedURL = try treeImporter(sourceFileURL, bundleURL)
                    nativeBundleURLs.append(importedURL)
                    destination = relativePath(from: collectionURL, to: importedURL)
                } catch {
                    appendUnique("\(item.sourceRelativePath) could not be parsed as a native tree bundle: \(error.localizedDescription)", to: &warnings)
                }
            } else if effectivePreserveUnsupportedArtifacts {
                let artifactURL = artifactsURL.appendingPathComponent(item.sourceRelativePath)
                try copyReplacingExistingItem(from: sourceFileURL, to: artifactURL)
                preservedArtifactURLs.append(artifactURL)
                destination = relativePath(from: collectionURL, to: artifactURL)
                appendUnique(warning(forPreservedItem: item), to: &warnings)
            } else {
                appendUnique(warning(forSkippedItem: item), to: &warnings)
            }

            processedItems.append(item.copy(lgeDestination: destination))
        }

        let inventory = ApplicationExportImportInventory(
            sourceURL: scannedInventory.sourceURL,
            sourceKind: scannedInventory.sourceKind,
            sourceName: scannedInventory.sourceName,
            applicationKind: scannedInventory.applicationKind,
            createdAt: scannedInventory.createdAt,
            items: processedItems,
            warnings: uniqueSorted(warnings)
        )

        progress?(0.86, "Writing \(kind.displayName) inventory...")
        let inventoryURL = collectionURL.appendingPathComponent("inventory.json")
        try writeJSON(inventory, to: inventoryURL)

        progress?(0.9, "Writing \(kind.displayName) import report...")
        let reportURL = collectionURL.appendingPathComponent("import-report.md")
        try writeReport(
            inventory: inventory,
            nativeBundleURLs: nativeBundleURLs,
            preservedArtifactURLs: preservedArtifactURLs,
            warnings: inventory.warnings,
            to: reportURL
        )

        progress?(0.94, "Writing \(kind.displayName) import provenance...")
        let provenanceURL = collectionURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let provenance = makeProvenance(
            sourceURL: sourceURL,
            projectURL: projectURL,
            collectionURL: collectionURL,
            inventoryURL: inventoryURL,
            reportURL: reportURL,
            provenanceURL: provenanceURL,
            rawSourceOutputs: sourceCopyOutputs,
            preservedArtifactURLs: preservedArtifactURLs,
            nativeBundleURLs: nativeBundleURLs,
            options: options,
            effectivePreserveRawSource: effectivePreserveRawSource,
            effectivePreserveUnsupportedArtifacts: effectivePreserveUnsupportedArtifacts,
            applicationKind: kind,
            sourceKind: scannedInventory.sourceKind,
            tempRunURL: tempRunURL,
            startedAt: startedAt
        )
        try writeJSON(provenance, to: provenanceURL)

        progress?(1.0, "\(kind.displayName) import complete.")
        return ApplicationExportImportResult(
            collectionURL: collectionURL,
            inventoryURL: inventoryURL,
            reportURL: reportURL,
            provenanceURL: provenanceURL,
            nativeBundleURLs: nativeBundleURLs,
            preservedArtifactURLs: preservedArtifactURLs,
            warnings: inventory.warnings
        )
    }

    private func materializeSourceIfNeeded(
        sourceURL: URL,
        sourceKind: ApplicationExportImportSourceKind,
        tempRunURL: URL
    ) throws -> MaterializedApplicationExportSource {
        switch sourceKind {
        case .archive:
            let tempRoot = tempRunURL.appendingPathComponent("archive", isDirectory: true)
            try archiveTool.extract(archiveURL: sourceURL, to: tempRoot)
            return MaterializedApplicationExportSource(rootURL: tempRoot, cleanupURL: nil)
        case .folder:
            return MaterializedApplicationExportSource(rootURL: sourceURL, cleanupURL: nil)
        case .file:
            return MaterializedApplicationExportSource(rootURL: sourceURL, cleanupURL: nil)
        }
    }

    private func createProjectTempRunDirectory(projectURL: URL) throws -> URL {
        try ProjectTempDirectory.create(
            prefix: "application-export-import-",
            contextURL: projectURL,
            policy: .requireProjectContext
        )
    }

    private func sourceFileURL(
        for item: ApplicationExportImportItem,
        sourceURL: URL,
        materializedSource: MaterializedApplicationExportSource
    ) -> URL {
        if isDirectory(materializedSource.rootURL) {
            return materializedSource.rootURL.appendingPathComponent(item.sourceRelativePath)
        }
        return sourceURL
    }

    private func createCollectionFolder(
        sourceURL: URL,
        projectURL: URL,
        kind: ApplicationExportKind,
        options: ApplicationExportImportOptions
    ) throws -> URL {
        let importsRoot = projectURL.appendingPathComponent("Application Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: importsRoot, withIntermediateDirectories: true)

        let baseSourceName = options.collectionName ?? Self.defaultCollectionBaseName(for: sourceURL)
        let sanitizedBase = Self.sanitizedBaseName(baseSourceName)
        let collectionBase = "\(sanitizedBase.isEmpty ? kind.displayName : sanitizedBase) \(kind.collectionSuffix) Import"
        var candidate = importsRoot.appendingPathComponent(collectionBase, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = importsRoot.appendingPathComponent("\(collectionBase) \(index)", isDirectory: true)
            index += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }

    private func preserveRawSource(sourceURL: URL, destinationDirectory: URL) throws -> URL {
        let destination = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: isDirectory(sourceURL))
        try copyReplacingExistingItem(from: sourceURL, to: destination)
        return destination
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func copyReplacingExistingItem(from sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    private func warning(forPreservedItem item: ApplicationExportImportItem) -> String {
        switch item.kind {
        case .standaloneReferenceSequence:
            return "\(item.sourceRelativePath) is a standalone reference sequence but reference import was disabled; preserved as a binary artifact."
        case .annotationTrack, .variantTrack, .alignmentTrack, .fastq, .signalTrack, .multipleSequenceAlignment,
             .phylogeneticTree, .treeOrAlignment, .phylogeneticsArtifact, .platformMetadata, .report:
            return "\(item.sourceRelativePath) is recognized as \(item.kind.rawValue) but is not auto-routed in the application export baseline; preserved as a binary artifact."
        case .nativeProject:
            return "\(item.sourceRelativePath) contains native application project data that is preserved but not decoded in the no-vendor-app baseline."
        case .binaryArtifact, .unsupported:
            return "\(item.sourceRelativePath) is not supported directly by LGE; preserved as a binary artifact."
        }
    }

    private func warning(forSkippedItem item: ApplicationExportImportItem) -> String {
        switch item.kind {
        case .multipleSequenceAlignment, .phylogeneticTree:
            return "\(item.sourceRelativePath) was recognized as \(item.kind.rawValue) but was not imported."
        case .unsupported, .binaryArtifact:
            return "\(item.sourceRelativePath) is not supported directly by LGE and was skipped."
        default:
            return "\(item.sourceRelativePath) is recognized as \(item.kind.rawValue) but is not imported by this native-only operation."
        }
    }

    private func writeReport(
        inventory: ApplicationExportImportInventory,
        nativeBundleURLs: [URL],
        preservedArtifactURLs: [URL],
        warnings: [String],
        to reportURL: URL
    ) throws {
        let counts = Dictionary(grouping: inventory.items, by: \.kind)
            .mapValues(\.count)
            .sorted { $0.key.rawValue < $1.key.rawValue }
        var lines: [String] = [
            "# \(inventory.applicationKind.displayName) Import Report",
            "",
            "- Source: \(inventory.sourceURL.path)",
            "- Source kind: \(inventory.sourceKind.rawValue)",
            "- Application export: \(inventory.applicationKind.displayName)",
            "- Items: \(inventory.items.count)",
            "",
            "## Counts",
            "",
        ]
        lines += counts.map { "- \($0.key.rawValue): \($0.value)" }
        lines += ["", "## Native bundles", ""]
        lines += nativeBundleURLs.isEmpty ? ["- None"] : nativeBundleURLs.map { "- \($0.path)" }
        lines += ["", "## Preserved artifacts", ""]
        lines += preservedArtifactURLs.isEmpty ? ["- None"] : preservedArtifactURLs.map { "- \($0.path)" }
        lines += ["", "## Warnings", ""]
        lines += warnings.isEmpty ? ["- None"] : warnings.map { "- \($0)" }
        try (lines.joined(separator: "\n") + "\n").write(to: reportURL, atomically: true, encoding: .utf8)
    }

    private func makeProvenance(
        sourceURL: URL,
        projectURL: URL,
        collectionURL: URL,
        inventoryURL: URL,
        reportURL: URL,
        provenanceURL: URL,
        rawSourceOutputs: [URL],
        preservedArtifactURLs: [URL],
        nativeBundleURLs: [URL],
        options: ApplicationExportImportOptions,
        effectivePreserveRawSource: Bool,
        effectivePreserveUnsupportedArtifacts: Bool,
        applicationKind: ApplicationExportKind,
        sourceKind: ApplicationExportImportSourceKind,
        tempRunURL: URL,
        startedAt: Date
    ) -> WorkflowRun {
        let scanStarted = startedAt
        let preserveStarted = Date()
        let referenceStarted = Date()
        let completedAt = Date()
        let sourceRecord = ProvenanceRecorder.fileRecord(url: sourceURL, format: .unknown, role: .input)
        let inventoryRecord = ProvenanceRecorder.fileRecord(url: inventoryURL, format: .json, role: .output)
        let reportRecord = ProvenanceRecorder.fileRecord(url: reportURL, format: .text, role: .report)
        let provenanceRecord = FileRecord(path: provenanceURL.path, sha256: nil, sizeBytes: nil, format: .json, role: .output)
        let rawSourceRecords = rawSourceOutputs.map { ProvenanceRecorder.fileRecord(url: $0, format: .unknown, role: .output) }
        let artifactRecords = preservedArtifactURLs.map { ProvenanceRecorder.fileRecord(url: $0, format: .unknown, role: .output) }
        let bundleRecords = nativeBundleURLs.map { ProvenanceRecorder.fileRecord(url: $0, format: .unknown, role: .output) }

        let scanStep = StepExecution(
            toolName: "Application Export Import",
            toolVersion: WorkflowRun.currentAppVersion,
            command: [
                "lungfish", "import", "application-export", applicationKind.cliArgument, sourceURL.path,
                "--project", projectURL.path,
                "--collection", collectionURL.path,
            ],
            inputs: [sourceRecord],
            outputs: [inventoryRecord, reportRecord],
            exitCode: 0,
            wallTime: preserveStarted.timeIntervalSince(scanStarted),
            startTime: scanStarted,
            endTime: preserveStarted
        )

        let preserveCommand: [String]
        let preserveToolName: String
        let preserveToolVersion: String
        if sourceKind == .archive {
            preserveToolName = "unzip"
            preserveToolVersion = Self.unzipVersion()
            preserveCommand = [
                "/usr/bin/unzip", "-qq", sourceURL.path,
                "-d", tempRunURL.appendingPathComponent("archive", isDirectory: true).path,
            ]
        } else {
            preserveToolName = "Application Export Import"
            preserveToolVersion = WorkflowRun.currentAppVersion
            preserveCommand = ["copy", sourceURL.path, collectionURL.path]
        }
        let preserveStep = StepExecution(
            toolName: preserveToolName,
            toolVersion: preserveToolVersion,
            command: preserveCommand,
            inputs: [sourceRecord],
            outputs: rawSourceRecords + artifactRecords,
            exitCode: 0,
            wallTime: referenceStarted.timeIntervalSince(preserveStarted),
            dependsOn: [scanStep.id],
            startTime: preserveStarted,
            endTime: referenceStarted
        )

        let referenceStep = StepExecution(
            toolName: "Application Export Native Bundle Import",
            toolVersion: WorkflowRun.currentAppVersion,
            command: [
                "lungfish", "import", "application-export", applicationKind.cliArgument,
                "--application-export-source", sourceURL.path,
                "--output-dir", collectionURL.appendingPathComponent("LGE Bundles", isDirectory: true).path,
            ],
            inputs: [sourceRecord],
            outputs: bundleRecords + [provenanceRecord],
            exitCode: 0,
            wallTime: completedAt.timeIntervalSince(referenceStarted),
            dependsOn: [preserveStep.id],
            startTime: referenceStarted,
            endTime: completedAt
        )

        return WorkflowRun(
            name: "Application Export Import",
            startTime: startedAt,
            endTime: completedAt,
            status: .completed,
            steps: [scanStep, preserveStep, referenceStep],
            parameters: [
                "applicationExportKind": .string(applicationKind.cardID),
                "source": .file(sourceURL),
                "project": .file(projectURL),
                "collection": .file(collectionURL),
                "sourceKind": .string(sourceKind.rawValue),
                "preserveRawSource": .boolean(options.preserveRawSource),
                "effectivePreserveRawSource": .boolean(effectivePreserveRawSource),
                "importStandaloneReferences": .boolean(options.importStandaloneReferences),
                "preserveUnsupportedArtifacts": .boolean(options.preserveUnsupportedArtifacts),
                "effectivePreserveUnsupportedArtifacts": .boolean(effectivePreserveUnsupportedArtifacts),
                "collectionName": options.collectionName.map(ParameterValue.string) ?? .null,
                "temporaryDirectory": .file(tempRunURL),
            ]
        )
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func appendUnique(_ value: String, to values: inout [String]) {
        guard !values.contains(value) else { return }
        values.append(value)
    }

    private func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private func relativePath(from rootURL: URL, to fileURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return fileURL.lastPathComponent }
        return String(filePath.dropFirst(prefix.count))
    }

    private func uniqueBundleURL(in outputDirectory: URL, preferredName: String, pathExtension: String) -> URL {
        var candidate = outputDirectory.appendingPathComponent("\(preferredName).\(pathExtension)", isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = outputDirectory.appendingPathComponent("\(preferredName) \(index).\(pathExtension)", isDirectory: true)
            index += 1
        }
        return candidate
    }

    private static func defaultCollectionBaseName(for sourceURL: URL) -> String {
        if ["qza", "qzv", "zip"].contains(sourceURL.pathExtension.lowercased()) {
            return sourceURL.deletingPathExtension().lastPathComponent
        }
        return sourceURL.lastPathComponent
    }

    private static func sanitizedBaseName(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: " -_")
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        let collapsed = String(scalars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? "Application Export" : collapsed
    }

    private static func unzipVersion() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-v"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return text.split(separator: "\n").first.map(String.init) ?? "system"
        } catch {
            return "system"
        }
    }
}

private struct MaterializedApplicationExportSource {
    let rootURL: URL
    let cleanupURL: URL?

    func cleanup() {
        if let cleanupURL {
            try? FileManager.default.removeItem(at: cleanupURL)
        }
    }
}

private extension ApplicationExportImportItem {
    func copy(lgeDestination: String?) -> ApplicationExportImportItem {
        ApplicationExportImportItem(
            id: id,
            sourceRelativePath: sourceRelativePath,
            stagedRelativePath: stagedRelativePath,
            kind: kind,
            lgeDestination: lgeDestination,
            sizeBytes: sizeBytes,
            sha256: sha256,
            warnings: warnings
        )
    }
}

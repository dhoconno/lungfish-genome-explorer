import Foundation
import LungfishWorkflow

public typealias GeneiousImportProgress = @Sendable (Double, String) -> Void
public typealias GeneiousReferenceImporter = @Sendable (URL, URL, String) async throws -> ReferenceBundleImportResult

public struct GeneiousImportCollectionService: Sendable {
    public static let `default` = GeneiousImportCollectionService()

    private let scanner: GeneiousImportScanner
    private let archiveTool: GeneiousArchiveTool
    private let referenceImporter: GeneiousReferenceImporter

    public init(
        scanner: GeneiousImportScanner = GeneiousImportScanner(),
        archiveTool: GeneiousArchiveTool = GeneiousArchiveTool(),
        referenceImporter: @escaping GeneiousReferenceImporter = { sourceURL, outputDirectory, preferredName in
            try await ReferenceBundleImportService.importAsReferenceBundleViaCLI(
                sourceURL: sourceURL,
                outputDirectory: outputDirectory,
                preferredBundleName: preferredName
            )
        }
    ) {
        self.scanner = scanner
        self.archiveTool = archiveTool
        self.referenceImporter = referenceImporter
    }

    public func importGeneiousExport(
        sourceURL: URL,
        projectURL: URL,
        options: GeneiousImportOptions = .default,
        progress: GeneiousImportProgress? = nil
    ) async throws -> GeneiousImportResult {
        let startedAt = Date()
        progress?(0.02, "Scanning Geneious export...")
        let scannedInventory = try await scanner.scan(sourceURL: sourceURL)

        let collectionURL = try createCollectionFolder(
            sourceURL: sourceURL,
            projectURL: projectURL,
            options: options
        )
        let bundlesURL = collectionURL.appendingPathComponent("LGE Bundles", isDirectory: true)
        let artifactsURL = collectionURL.appendingPathComponent("Binary Artifacts", isDirectory: true)
        let rawSourceURL = collectionURL.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: bundlesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifactsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rawSourceURL, withIntermediateDirectories: true)

        var sourceCopyOutputs: [URL] = []
        if options.preserveRawSource {
            progress?(0.12, "Preserving original Geneious source...")
            let copied = try preserveRawSource(sourceURL: sourceURL, destinationDirectory: rawSourceURL)
            sourceCopyOutputs.append(copied)
        }

        let materialized = try materializeSourceIfNeeded(sourceURL: sourceURL, sourceKind: scannedInventory.sourceKind)
        defer { materialized.cleanup() }

        var nativeBundleURLs: [URL] = []
        var preservedArtifactURLs: [URL] = []
        var decodedFASTAURLs: [URL] = []
        var warnings = scannedInventory.warnings
        var processedItems: [GeneiousImportItem] = []
        var decodedDestinations: [String: String] = [:]

        progress?(0.16, "Decoding Geneious sequence payloads...")
        let decodedSequenceSets = try GeneiousPackedSequenceExtractor()
            .extractSequenceSets(rootURL: materialized.rootURL)
        if !decodedSequenceSets.isEmpty {
            let decodedFASTARoot = collectionURL.appendingPathComponent("Decoded FASTA", isDirectory: true)
            try FileManager.default.createDirectory(at: decodedFASTARoot, withIntermediateDirectories: true)
            for (index, sequenceSet) in decodedSequenceSets.enumerated() {
                progress?(
                    0.18 + (Double(index) / Double(max(decodedSequenceSets.count, 1))) * 0.10,
                    "Decoding \(sequenceSet.documentName)..."
                )
                let preferredName = Self.sanitizedBaseName(sequenceSet.documentName)
                let fastaURL = try writeDecodedFASTA(
                    sequenceSet,
                    preferredName: preferredName,
                    outputDirectory: decodedFASTARoot
                )
                decodedFASTAURLs.append(fastaURL)
                let result = try await referenceImporter(fastaURL, bundlesURL, preferredName)
                nativeBundleURLs.append(result.bundleURL)
                let destination = relativePath(from: collectionURL, to: result.bundleURL)
                decodedDestinations[sequenceSet.documentRelativePath] = destination
                for sidecarPath in sequenceSet.decodedSidecarPaths {
                    decodedDestinations[sidecarPath] = destination
                }
                warnings.append(contentsOf: sequenceSet.warnings)
                if !sequenceSet.annotationSidecarPaths.isEmpty || sequenceSet.hasInlineAnnotations {
                    appendUnique(
                        "\(sequenceSet.documentRelativePath) contains Geneious sequence annotations that are not yet translated to LGE annotation tracks.",
                        to: &warnings
                    )
                }
            }
        }

        let totalItems = max(scannedInventory.items.count, 1)
        for (index, item) in scannedInventory.items.enumerated() {
            progress?(0.28 + (Double(index) / Double(totalItems)) * 0.54, "Processing \(item.sourceRelativePath)...")
            let sourceFileURL = sourceFileURL(for: item, sourceURL: sourceURL, materializedSource: materialized)
            var destination: String?

            if let decodedDestination = decodedDestinations[item.sourceRelativePath] {
                processedItems.append(item.copy(lgeDestination: decodedDestination, warnings: []))
                continue
            }

            if item.kind == .standaloneReferenceSequence && options.importStandaloneReferences {
                warnings.append(contentsOf: item.warnings)
                let preferredName = Self.sanitizedBaseName(
                    URL(fileURLWithPath: item.sourceRelativePath).deletingPathExtension().lastPathComponent
                )
                let result = try await referenceImporter(sourceFileURL, bundlesURL, preferredName)
                nativeBundleURLs.append(result.bundleURL)
                destination = relativePath(from: collectionURL, to: result.bundleURL)
            } else if options.preserveUnsupportedArtifacts {
                warnings.append(contentsOf: item.warnings)
                let artifactURL = artifactsURL.appendingPathComponent(item.sourceRelativePath)
                try copyReplacingExistingItem(from: sourceFileURL, to: artifactURL)
                preservedArtifactURLs.append(artifactURL)
                destination = relativePath(from: collectionURL, to: artifactURL)
                appendUnique(warning(forPreservedItem: item), to: &warnings)
            }

            processedItems.append(item.copy(lgeDestination: destination))
        }

        let inventory = GeneiousImportInventory(
            sourceURL: scannedInventory.sourceURL,
            sourceKind: scannedInventory.sourceKind,
            sourceName: scannedInventory.sourceName,
            createdAt: scannedInventory.createdAt,
            geneiousVersion: scannedInventory.geneiousVersion,
            geneiousMinimumVersion: scannedInventory.geneiousMinimumVersion,
            items: processedItems,
            documentClasses: scannedInventory.documentClasses,
            unresolvedURNs: scannedInventory.unresolvedURNs,
            warnings: uniqueSorted(warnings)
        )

        progress?(0.86, "Writing Geneious inventory...")
        let inventoryURL = collectionURL.appendingPathComponent("inventory.json")
        try writeJSON(inventory, to: inventoryURL)

        progress?(0.9, "Writing Geneious import report...")
        let reportURL = collectionURL.appendingPathComponent("import-report.md")
        try writeReport(
            inventory: inventory,
            nativeBundleURLs: nativeBundleURLs,
            preservedArtifactURLs: preservedArtifactURLs,
            warnings: inventory.warnings,
            to: reportURL
        )

        progress?(0.94, "Writing Geneious import provenance...")
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
            decodedFASTAURLs: decodedFASTAURLs,
            nativeBundleURLs: nativeBundleURLs,
            options: options,
            sourceKind: scannedInventory.sourceKind,
            startedAt: startedAt
        )
        try writeJSON(provenance, to: provenanceURL)

        progress?(1.0, "Geneious import complete.")
        return GeneiousImportResult(
            collectionURL: collectionURL,
            inventoryURL: inventoryURL,
            reportURL: reportURL,
            provenanceURL: provenanceURL,
            nativeBundleURLs: nativeBundleURLs,
            preservedArtifactURLs: preservedArtifactURLs,
            warnings: inventory.warnings
        )
    }

    private func materializeSourceIfNeeded(sourceURL: URL, sourceKind: GeneiousImportSourceKind) throws -> MaterializedGeneiousSource {
        switch sourceKind {
        case .geneiousArchive:
            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("geneious-import-\(UUID().uuidString)", isDirectory: true)
            try archiveTool.extract(archiveURL: sourceURL, to: tempRoot)
            return MaterializedGeneiousSource(rootURL: tempRoot, cleanupURL: tempRoot)
        case .folder:
            return MaterializedGeneiousSource(rootURL: sourceURL, cleanupURL: nil)
        case .file:
            return MaterializedGeneiousSource(rootURL: sourceURL, cleanupURL: nil)
        }
    }

    private func sourceFileURL(
        for item: GeneiousImportItem,
        sourceURL: URL,
        materializedSource: MaterializedGeneiousSource
    ) -> URL {
        if isDirectory(materializedSource.rootURL) {
            return materializedSource.rootURL.appendingPathComponent(item.sourceRelativePath)
        }
        return sourceURL
    }

    private func createCollectionFolder(
        sourceURL: URL,
        projectURL: URL,
        options: GeneiousImportOptions
    ) throws -> URL {
        let importsRoot = projectURL.appendingPathComponent("Geneious Imports", isDirectory: true)
        try FileManager.default.createDirectory(at: importsRoot, withIntermediateDirectories: true)

        let baseSourceName = options.collectionName ?? Self.defaultCollectionBaseName(for: sourceURL)
        let sanitizedBase = Self.sanitizedBaseName(baseSourceName)
        let collectionBase = "\(sanitizedBase.isEmpty ? "Geneious Export" : sanitizedBase) Geneious Import"
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

    private func writeDecodedFASTA(
        _ sequenceSet: GeneiousDecodedSequenceSet,
        preferredName: String,
        outputDirectory: URL
    ) throws -> URL {
        let fastaURL = try uniqueFileURL(
            baseName: preferredName.isEmpty ? "Geneious Sequences" : preferredName,
            extension: "fasta",
            in: outputDirectory
        )
        var text = ""
        for record in sequenceSet.records {
            text += ">\(Self.fastaEscapedHeader(record.name))\n"
            text += Self.wrapFASTASequence(record.sequence)
            text += "\n"
        }
        try text.write(to: fastaURL, atomically: true, encoding: .utf8)
        return fastaURL
    }

    private func uniqueFileURL(baseName: String, extension fileExtension: String, in directory: URL) throws -> URL {
        var candidate = directory.appendingPathComponent("\(Self.sanitizedBaseName(baseName)).\(fileExtension)")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(Self.sanitizedBaseName(baseName)) \(index).\(fileExtension)")
            index += 1
        }
        return candidate
    }

    private func warning(forPreservedItem item: GeneiousImportItem) -> String {
        switch item.kind {
        case .geneiousXML, .geneiousSidecar:
            return "\(item.sourceRelativePath) contains native Geneious data that is preserved but not decoded in the no-Geneious baseline."
        case .annotationTrack, .variantTrack, .alignmentTrack, .fastq, .signalTrack, .treeOrAlignment, .report:
            return "\(item.sourceRelativePath) is recognized as \(item.kind.rawValue) but is not auto-routed in the no-Geneious baseline; preserved as a binary artifact."
        case .standaloneReferenceSequence:
            return "\(item.sourceRelativePath) is a standalone reference sequence but reference import was disabled; preserved as a binary artifact."
        case .binaryArtifact, .unsupported:
            return "\(item.sourceRelativePath) is not supported directly by LGE; preserved as a binary artifact."
        }
    }

    private func writeReport(
        inventory: GeneiousImportInventory,
        nativeBundleURLs: [URL],
        preservedArtifactURLs: [URL],
        warnings: [String],
        to reportURL: URL
    ) throws {
        let counts = Dictionary(grouping: inventory.items, by: \.kind)
            .mapValues(\.count)
            .sorted { $0.key.rawValue < $1.key.rawValue }
        var lines: [String] = [
            "# Geneious Import Report",
            "",
            "- Source: \(inventory.sourceURL.path)",
            "- Source kind: \(inventory.sourceKind.rawValue)",
            "- Geneious version: \(inventory.geneiousVersion ?? "unknown")",
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
        decodedFASTAURLs: [URL],
        nativeBundleURLs: [URL],
        options: GeneiousImportOptions,
        sourceKind: GeneiousImportSourceKind,
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
        let decodedFASTARecords = decodedFASTAURLs.map { ProvenanceRecorder.fileRecord(url: $0, format: .fasta, role: .output) }
        let bundleRecords = nativeBundleURLs.map { ProvenanceRecorder.fileRecord(url: $0, format: .unknown, role: .output) }

        let scanStep = StepExecution(
            toolName: "Geneious Import",
            toolVersion: WorkflowRun.currentAppVersion,
            command: [
                "lungfish", "import", "geneious", sourceURL.path,
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
        if sourceKind == .geneiousArchive {
            preserveToolName = "unzip"
            preserveToolVersion = Self.unzipVersion()
            preserveCommand = ["/usr/bin/unzip", "-qq", sourceURL.path, "-d", collectionURL.path]
        } else {
            preserveToolName = "Geneious Import"
            preserveToolVersion = WorkflowRun.currentAppVersion
            preserveCommand = ["copy", sourceURL.path, collectionURL.path]
        }
        let preserveStep = StepExecution(
            toolName: preserveToolName,
            toolVersion: preserveToolVersion,
            command: preserveCommand,
            inputs: [sourceRecord],
            outputs: rawSourceRecords + artifactRecords + decodedFASTARecords,
            exitCode: 0,
            wallTime: referenceStarted.timeIntervalSince(preserveStarted),
            dependsOn: [scanStep.id],
            startTime: preserveStarted,
            endTime: referenceStarted
        )

        let referenceStep = StepExecution(
            toolName: "ReferenceBundleImportService",
            toolVersion: WorkflowRun.currentAppVersion,
            command: [
                "lungfish", "import", "fasta",
                "--geneious-source", sourceURL.path,
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
            name: "Geneious Import",
            startTime: startedAt,
            endTime: completedAt,
            status: .completed,
            steps: [scanStep, preserveStep, referenceStep],
            parameters: [
                "source": .file(sourceURL),
                "project": .file(projectURL),
                "collection": .file(collectionURL),
                "sourceKind": .string(sourceKind.rawValue),
                "preserveRawSource": .boolean(options.preserveRawSource),
                "importStandaloneReferences": .boolean(options.importStandaloneReferences),
                "preserveUnsupportedArtifacts": .boolean(options.preserveUnsupportedArtifacts),
                "collectionName": options.collectionName.map(ParameterValue.string) ?? .null,
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

    private static func defaultCollectionBaseName(for sourceURL: URL) -> String {
        if sourceURL.pathExtension.lowercased() == "geneious" {
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
        return collapsed.isEmpty ? "Geneious Export" : collapsed
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

    private static func fastaEscapedHeader(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return sanitized.isEmpty ? "Geneious Sequence" : sanitized
    }

    private static func wrapFASTASequence(_ sequence: String, width: Int = 80) -> String {
        guard !sequence.isEmpty else { return "" }
        var lines: [String] = []
        var index = sequence.startIndex
        while index < sequence.endIndex {
            let end = sequence.index(index, offsetBy: width, limitedBy: sequence.endIndex) ?? sequence.endIndex
            lines.append(String(sequence[index..<end]))
            index = end
        }
        return lines.joined(separator: "\n")
    }
}

private struct MaterializedGeneiousSource {
    let rootURL: URL
    let cleanupURL: URL?

    func cleanup() {
        if let cleanupURL {
            try? FileManager.default.removeItem(at: cleanupURL)
        }
    }
}

private extension GeneiousImportItem {
    func copy(lgeDestination: String?, warnings: [String]? = nil) -> GeneiousImportItem {
        GeneiousImportItem(
            id: id,
            sourceRelativePath: sourceRelativePath,
            stagedRelativePath: stagedRelativePath,
            kind: kind,
            lgeDestination: lgeDestination,
            sizeBytes: sizeBytes,
            sha256: sha256,
            geneiousDocumentClass: geneiousDocumentClass,
            geneiousDocumentName: geneiousDocumentName,
            warnings: warnings ?? self.warnings
        )
    }
}

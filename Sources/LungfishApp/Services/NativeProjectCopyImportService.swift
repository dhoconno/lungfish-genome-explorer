import Foundation
import LungfishCore
import LungfishWorkflow

/// Publishes opaque native documents with a receipt for the bytes actually copied.
/// Archives remain archives; directory payloads keep their existing layout.
enum NativeProjectCopyImportService {
    static func copy(from source: URL, to destination: URL, replaceExisting: Bool = false) throws -> URL {
        let fm = FileManager.default
        let source = source.standardizedFileURL
        let destination = destination.standardizedFileURL
        let sourcePath = source.resolvingSymlinksInPath().path
        let destinationPath = destination.resolvingSymlinksInPath().path
        guard sourcePath != destinationPath, !sourcePath.hasPrefix(destinationPath + "/"),
              !destinationPath.hasPrefix(sourcePath + "/") else { throw CocoaError(.fileWriteFileExists) }
        guard !["lungfish", "lungfishflowpkg"].contains(source.pathExtension.lowercased()) else {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "Open projects with Open Project and register workflow packages with Link Workflow."])
        }
        guard replaceExisting || !fm.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let isDirectory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let scientific = source.pathExtension.lowercased().hasPrefix("lungfish")
            || GenericAttachmentPolicy.scientificFormatDescription(forFilename: source.lastPathComponent) != nil
        let sourceSidecar = isDirectory ? source.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
            : ProvenanceRecorder.fileSidecarURL(for: source)
        let hasSourceProvenance = fm.fileExists(atPath: sourceSidecar.path)
        let writesReceipt = scientific || hasSourceProvenance
        let artifacts = [destination] + ((!isDirectory && writesReceipt) ? ProvenancePublicationArtifacts.fileSidecarArtifacts(for: destination) : [])
        let publication = try ScientificFilePublicationTransaction(protectedURLs: artifacts,
            fileDestinations: isDirectory ? [] : artifacts)
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".native-copy-\(UUID())")
        defer { try? fm.removeItem(at: staged) }
        let startedAt = Date()
        do {
            let sourceFiles = try payloadFiles(in: source, isDirectory: isDirectory)
            let inputs = try sourceFiles.map { try ProvenanceFileDescriptor.file(url: $0, role: .input) }
            try fm.copyItem(at: source, to: staged)
            try materializeFileLinks(in: staged, isDirectory: isDirectory)
            let outputs = try zip(sourceFiles, inputs).map { original, input -> ProvenanceFileDescriptor in
                let relative = try (isDirectory ? relativePath(of: original, within: source) : "")
                let stagedFile = isDirectory ? staged.appendingPathComponent(relative) : staged
                let copied = try ProvenanceFileDescriptor.file(url: stagedFile, role: .output)
                guard copied.checksumSHA256 == input.checksumSHA256, copied.fileSize == input.fileSize else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Source changed while copying \(original.path)."])
                }
                return ProvenanceFileDescriptor(path: isDirectory ? destination.appendingPathComponent(relative).path : destination.path,
                    checksumSHA256: copied.checksumSHA256, fileSize: copied.fileSize, role: .output, originPath: original.path)
            }
            try publication.publish(stagedURL: staged, to: destination, replacingExisting: replaceExisting)
            if writesReceipt {
                let completedAt = Date()
                let argv = ["Lungfish.app", "import-native", source.path, "--output", destination.path]
                let resolved: [String: ParameterValue] = ["source": .file(source), "destination": .file(destination),
                    "replaceExisting": .boolean(replaceExisting), "copyMode": .string(isDirectory ? "directory-copy" : "opaque-file-copy")]
                let step = ProvenanceStep(toolName: "lungfish-app", toolVersion: WorkflowRun.currentAppVersion,
                    argv: argv, resolvedOptions: resolved, runtimeIdentity: ProvenanceRuntimeIdentity(),
                    inputs: inputs, outputs: outputs, exitStatus: 0, wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
                    startedAt: startedAt, completedAt: completedAt)
                let writer = ProvenanceWriter(publicationMutationDidOccur: { try publication.observe($0) }, signingProvider: nil)
                if hasSourceProvenance {
                    if isDirectory {
                        try GUIImportedProvenanceRehydrator.rehydrateRelocatedImportedCopy(from: source, to: destination,
                            provenanceWriter: writer, requireCLIProvenance: false, importStep: step)
                    } else {
                        try GUIImportedProvenanceRehydrator.rehydrateImportedFileSidecar(from: source, to: destination,
                            provenanceWriter: writer, requireCLIProvenance: false, importStep: step)
                    }
                } else {
                    let receipt = ProvenanceEnvelope(createdAt: startedAt, workflowName: "Native document import",
                        toolName: "lungfish-app", toolVersion: WorkflowRun.currentAppVersion, argv: argv,
                        options: ProvenanceOptions(explicit: ["source": .file(source), "destination": .file(destination)],
                            defaults: ["replaceExisting": .boolean(false)], resolvedDefaults: resolved),
                        files: inputs + outputs, output: outputs.first, outputs: outputs, steps: [step],
                        wallTimeSeconds: completedAt.timeIntervalSince(startedAt), exitStatus: 0)
                    if isDirectory { try writer.write(receipt, to: destination) }
                    else { try writer.write(receipt, toSidecar: ProvenanceRecorder.fileSidecarURL(for: destination)) }
                }
            }
            publication.commit()
            return destination
        } catch {
            try publication.rollback(after: error)
        }
    }

    private static func relativePath(of file: URL, within root: URL) throws -> String {
        // Directory enumeration may expand /var to /private/var. Compare path
        // components after resolving the parent, while retaining a link's name.
        let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let components = file.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(file.lastPathComponent).standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents), components.count > rootComponents.count else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func payloadFiles(in root: URL, isDirectory: Bool) throws -> [URL] {
        guard isDirectory else { return [root] }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, error in
                enumerationError = error; return false
            }) else { throw CocoaError(.fileReadUnknown) }
        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            let relative = try relativePath(of: url, within: root)
            if relative == ProvenanceWriter.bundleProvenanceDirectoryName {
                enumerator.skipDescendants(); continue
            }
            if url.lastPathComponent.contains("lungfish-provenance") { continue }
            let resolved = url.resolvingSymlinksInPath()
            if try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files.append(url) }
        }
        if let enumerationError { throw enumerationError }
        return files.sorted { $0.path < $1.path }
    }

    private static func materializeFileLinks(in root: URL, isDirectory: Bool) throws {
        let fm = FileManager.default
        let candidates: [URL]
        if isDirectory {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { throw CocoaError(.fileReadUnknown) }
            candidates = enumerator.compactMap { $0 as? URL }
        } else { candidates = [root] }
        for url in candidates where try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
            let target = url.resolvingSymlinksInPath()
            guard try target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "Import requires a concrete directory; directory links are unsupported at \(url.path)."])
            }
            try fm.removeItem(at: url)
            try fm.copyItem(at: target, to: url)
        }
    }
}

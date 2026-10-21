import Foundation
import LungfishCore

/// The command a native copy's receipt names (Phase 2.12 lane 12.18, BIO ruling on F4). Without one the receipt
/// names the app's `Lungfish.app import-native`, which side A of the cross-project copy and the FASTQ import's
/// native path keep.
package struct NativeCopyReceiptIdentity: Sendable, Equatable {
    package var workflowName: String
    package var toolName: String
    package var argv: [String]
    package var durableReplayArgv: [String]?
    package var explicitOptions: [String: ParameterValue]
    package var defaultOptions: [String: ParameterValue]
    /// The resolved options. The service adds `destination`, `replaceExisting` and `copyMode` to a supplied receipt.
    package var resolvedOptions: [String: ParameterValue]

    package init(
        workflowName: String,
        toolName: String,
        argv: [String],
        durableReplayArgv: [String]?,
        explicitOptions: [String: ParameterValue],
        defaultOptions: [String: ParameterValue],
        resolvedOptions: [String: ParameterValue]
    ) {
        self.workflowName = workflowName
        self.toolName = toolName
        self.argv = argv
        self.durableReplayArgv = durableReplayArgv
        self.explicitOptions = explicitOptions
        self.defaultOptions = defaultOptions
        self.resolvedOptions = resolvedOptions
    }

    /// The app's receipt, `Lungfish.app import-native` with tool `lungfish-app` and no replay words.
    static func appImportNative(
        source: URL, destination: URL, replaceExisting: Bool, copyMode: ParameterValue, sourceProjectURL: URL?
    ) -> NativeCopyReceiptIdentity {
        var argv = [LungfishAppIdentity.recordedToolName, "import-native", source.path, "--output", destination.path]
        var resolved: [String: ParameterValue] = ["source": .file(source), "destination": .file(destination),
            "replaceExisting": .boolean(replaceExisting), "copyMode": copyMode]
        if let sourceProjectURL {
            argv += ["--source-project", sourceProjectURL.path]
            resolved["sourceProject"] = .file(sourceProjectURL)
        }
        return NativeCopyReceiptIdentity(
            workflowName: "Native document import", toolName: LungfishAppIdentity.recordedToolName, argv: argv, durableReplayArgv: nil,
            explicitOptions: ["source": .file(source), "destination": .file(destination)],
            defaultOptions: ["replaceExisting": .boolean(false)], resolvedOptions: resolved
        )
    }
}

/// Publishes opaque native documents with a receipt for the bytes actually copied.
/// Archives remain archives; directory payloads keep their existing layout.
package enum NativeProjectCopyImportService {
    /// - Parameter sourceProjectURL: the project the item is being copied out
    ///   of, when known. It is recorded in the copy receipt so a copied item
    ///   remembers where it came from.
    /// - Parameter receipt: the command the receipt names. Nil names the app's `import-native`.
    /// - Parameter checkCancellation: called between the chunks of both hashes, of each source file and of each
    ///   copied file, once before the copy, and between the chunks of the hashes that the rehydration of an item's own
    ///   provenance record makes after the copy is published. A throw stops the copy, removes its `.native-copy-`
    ///   folder, rolls back a published item and publishes nothing (2.13 row COPY-CANCEL-CHECKS). The one copy call
    ///   itself takes no check.
    package static func copy(
        from source: URL, to destination: URL, replaceExisting: Bool = false, sourceProjectURL: URL? = nil,
        receipt: NativeCopyReceiptIdentity? = nil, checkCancellation: () throws -> Void = {}
    ) throws -> URL {
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
        let runClock = ProvenanceRunClock()
        let startedAt = runClock.startedAt
        do {
            let sourceFiles = try payloadFiles(in: source, isDirectory: isDirectory)
            let inputs = try sourceFiles.map { try descriptor(of: $0, role: .input, checkCancellation: checkCancellation) }
            try checkCancellation()
            try fm.copyItem(at: source, to: staged)
            try materializeFileLinks(in: staged, isDirectory: isDirectory)
            let outputs = try zip(sourceFiles, inputs).map { original, input -> ProvenanceFileDescriptor in
                let relative = try (isDirectory ? relativePath(of: original, within: source) : "")
                let stagedFile = isDirectory ? staged.appendingPathComponent(relative) : staged
                let copied = try descriptor(of: stagedFile, role: .output, checkCancellation: checkCancellation)
                guard copied.checksumSHA256 == input.checksumSHA256, copied.fileSize == input.fileSize else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Source changed while copying \(original.path)."])
                }
                return ProvenanceFileDescriptor(path: isDirectory ? destination.appendingPathComponent(relative).path : destination.path,
                    checksumSHA256: copied.checksumSHA256, fileSize: copied.fileSize, role: .output, originPath: original.path)
            }
            try publication.publish(stagedURL: staged, to: destination, replacingExisting: replaceExisting)
            if writesReceipt {
                let completedAt = runClock.now
                let copyMode = ParameterValue.string(isDirectory ? "directory-copy" : "opaque-file-copy")
                var identity = receipt ?? .appImportNative(source: source, destination: destination,
                    replaceExisting: replaceExisting, copyMode: copyMode, sourceProjectURL: sourceProjectURL)
                if receipt != nil {
                    identity.resolvedOptions["destination"] = .file(destination)
                    identity.resolvedOptions["replaceExisting"] = .boolean(replaceExisting)
                    identity.resolvedOptions["copyMode"] = copyMode
                }
                let step = ProvenanceStep(toolName: identity.toolName, toolVersion: WorkflowRun.currentAppVersion,
                    argv: identity.argv, durableReplayArgv: identity.durableReplayArgv,
                    resolvedOptions: identity.resolvedOptions, runtimeIdentity: ProvenanceRuntimeIdentity(),
                    inputs: inputs, outputs: outputs, exitStatus: 0, wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
                    startedAt: startedAt, completedAt: completedAt)
                let writer = ProvenanceWriter(publicationMutationDidOccur: { try publication.observe($0) }, signingProvider: nil)
                if hasSourceProvenance {
                    if isDirectory {
                        try GUIImportedProvenanceRehydrator.rehydrateRelocatedImportedCopy(from: source, to: destination,
                            provenanceWriter: writer, requireCLIProvenance: false, importStep: step,
                            cancellationCheck: checkCancellation)
                    } else {
                        try GUIImportedProvenanceRehydrator.rehydrateImportedFileSidecar(from: source, to: destination,
                            provenanceWriter: writer, requireCLIProvenance: false, importStep: step,
                            cancellationCheck: checkCancellation)
                    }
                } else {
                    let receipt = ProvenanceEnvelope(createdAt: startedAt, workflowName: identity.workflowName,
                        toolName: identity.toolName, toolVersion: WorkflowRun.currentAppVersion, argv: identity.argv,
                        durableReplayArgv: identity.durableReplayArgv,
                        options: ProvenanceOptions(explicit: identity.explicitOptions,
                            defaults: identity.defaultOptions, resolvedDefaults: identity.resolvedOptions),
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

    /// The descriptor `ProvenanceFileDescriptor.file(url:role:)` builds, with `checkCancellation` between the chunks
    /// of the hash.
    private static func descriptor(
        of url: URL, role: FileRole, checkCancellation: () throws -> Void
    ) throws -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(path: url.path,
            checksumSHA256: try ProvenanceFileHasher.sha256(of: url, cancellationCheck: checkCancellation),
            fileSize: try ProvenanceFileHasher.fileSize(of: url), role: role)
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

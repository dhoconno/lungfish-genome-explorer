import CryptoKit
import Darwin
import Foundation
import LungfishIO

struct FullLengthONTMHCFASTQMaterializationResult: Sendable, Equatable {
    let outputURL: URL
    let step: ProvenanceStep
}

enum FullLengthONTMHCFASTQMaterializer {
    private struct FileIdentity: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int
        let modificationNanoseconds: Int
        let changeSeconds: Int
        let changeNanoseconds: Int

        init(_ information: stat) {
            device = UInt64(information.st_dev)
            inode = UInt64(information.st_ino)
            size = information.st_size
            modificationSeconds = information.st_mtimespec.tv_sec
            modificationNanoseconds = information.st_mtimespec.tv_nsec
            changeSeconds = information.st_ctimespec.tv_sec
            changeNanoseconds = information.st_ctimespec.tv_nsec
        }
    }

    private struct ValidatedPayload: Sendable {
        let url: URL
        let trustedRootURL: URL
        let identity: FileIdentity
        let sourceProvenanceURL: URL?
    }

    private struct ValidatedInput: Sendable {
        let bundleURL: URL?
        let manifestURL: URL?
        let payloads: [ValidatedPayload]
        let metadataDescriptors: [ProvenanceFileDescriptor]
    }

    @discardableResult
    static func materializePlainFASTQ(
        inputURL: URL,
        outputURL: URL,
        logicalOutputURL: URL? = nil,
        beforePayloadRead: ((URL) throws -> Void)? = nil,
        afterFirstSourceChunkRead: ((URL) throws -> Void)? = nil
    ) throws -> FullLengthONTMHCFASTQMaterializationResult {
        let startedAt = Date()
        try Task.checkCancellation()
        let input = try validatedInput(for: inputURL)
        let logicalOutputURL = (logicalOutputURL ?? outputURL).standardizedFileURL
        var argv = [
            "lungfish-internal", "materialize-full-length-mhc-fastq",
        ]
        if let bundleURL = input.bundleURL {
            argv += ["--bundle", bundleURL.path]
        } else {
            argv += ["--input", input.payloads[0].url.path]
        }
        if let manifestURL = input.manifestURL {
            argv += ["--manifest", manifestURL.path]
        }
        for payload in input.payloads {
            argv += ["--payload", payload.url.path]
        }
        argv += ["--output", logicalOutputURL.path]

        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try Task.checkCancellation()
            guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
                throw FullLengthONTMHCGenotypingError.reportFailed(
                    "Could not create materialized FASTQ at \(outputURL.path)."
                )
            }
            let output = try FileHandle(forWritingTo: outputURL)
            defer { try? output.close() }
            let snapshotDirectory = outputURL.deletingLastPathComponent().appendingPathComponent(
                ".\(outputURL.lastPathComponent).source-snapshots-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: snapshotDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: snapshotDirectory) }

            var previousChunkEndedWithNewline = true
            var payloadDescriptors: [ProvenanceFileDescriptor] = []
            for (index, payload) in input.payloads.enumerated() {
                try Task.checkCancellation()
                try beforePayloadRead?(payload.url)
                let snapshotURL = snapshotDirectory.appendingPathComponent(
                    String(format: "%04d-%@", index, payload.url.lastPathComponent)
                )
                let payloadDescriptor = try snapshotPayload(
                    payload,
                    to: snapshotURL,
                    afterFirstSourceChunkRead: afterFirstSourceChunkRead
                )
                payloadDescriptors.append(payloadDescriptor)
                if !previousChunkEndedWithNewline {
                    try output.write(contentsOf: Data([0x0a]))
                    previousChunkEndedWithNewline = true
                }
                try snapshotURL.forEachChunkAutoDecompressing { chunk in
                    try Task.checkCancellation()
                    guard !chunk.isEmpty else { return }
                    try output.write(contentsOf: chunk)
                    previousChunkEndedWithNewline = chunk.last == 0x0a || chunk.last == 0x0d
                }
            }
            try output.synchronize()
            try Task.checkCancellation()
            let outputFingerprint = try fingerprintRegularFile(
                outputURL,
                trustedRootURL: outputURL.deletingLastPathComponent(),
                role: "materialized FASTQ"
            )
            let outputDescriptor = ProvenanceFileDescriptor(
                path: logicalOutputURL.path,
                checksumSHA256: outputFingerprint.checksum,
                fileSize: outputFingerprint.size,
                format: .fastq,
                role: .output,
                originPath: outputURL.standardizedFileURL.path == logicalOutputURL.path
                    ? nil
                    : outputURL.standardizedFileURL.path
            )
            let completedAt = Date()
            return FullLengthONTMHCFASTQMaterializationResult(
                outputURL: outputURL.standardizedFileURL,
                step: ProvenanceStep(
                    toolName: "lungfish-internal materialize-full-length-mhc-fastq",
                    toolVersion: WorkflowRun.currentAppVersion,
                    argv: argv,
                    durableReplayArgv: argv,
                    reproducibleCommand: argv.map(shellEscape).joined(separator: " "),
                    resolvedOptions: [
                        "inputKind": .string(input.bundleURL == nil ? "plain-fastq" : "lungfishfastq-bundle"),
                        "payloadCount": .integer(input.payloads.count),
                        "manifestPresent": .boolean(input.manifestURL != nil),
                        "compressionHandling": .string("extension-directed-streaming-auto-decompression"),
                        "pathValidation": .string("component-wise-openat-o_nofollow-stable-descriptor-snapshot"),
                    ],
                    runtimeIdentity: ProvenanceRuntimeIdentity(),
                    inputs: input.metadataDescriptors + payloadDescriptors,
                    outputs: [outputDescriptor],
                    exitStatus: 0,
                    wallTimeSeconds: completedAt.timeIntervalSince(startedAt),
                    startedAt: startedAt,
                    completedAt: completedAt
                )
            )
        } catch {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
            throw error
        }
    }

    static func provenanceSourceDescriptors(for inputURL: URL) throws -> [ProvenanceFileDescriptor] {
        let input = try validatedInput(for: inputURL)
        let payloadDescriptors = try input.payloads.map { payload in
            let fingerprint = try fingerprintStableRegularFile(
                payload.url,
                trustedRootURL: payload.trustedRootURL,
                expectedIdentity: payload.identity,
                role: "FASTQ scientific payload"
            )
            return ProvenanceFileDescriptor(
                path: payload.url.path,
                checksumSHA256: fingerprint.checksum,
                fileSize: fingerprint.size,
                format: .fastq,
                role: .input,
                sourceProvenancePath: payload.sourceProvenanceURL?.path
            )
        }
        return input.metadataDescriptors + payloadDescriptors
    }

    private static func validatedInput(for inputURL: URL) throws -> ValidatedInput {
        let standardized = inputURL.standardizedFileURL
        if FASTQBundle.isBundleURL(standardized) {
            let safety = FullLengthONTMHCAlignmentSafety()
            try safety.requireDirectoryNoFollow(standardized, role: "FASTQ bundle")
            let manifestURL: URL?
            let sourceManifestURL = standardized.appendingPathComponent(FASTQSourceFileManifest.filename)
            if FASTQSourceFileManifest.exists(in: standardized) {
                manifestURL = sourceManifestURL
            } else if FASTQBundle.isDerivedBundle(standardized) {
                manifestURL = FASTQBundle.derivedManifestURL(in: standardized)
            } else {
                manifestURL = nil
            }
            guard let payloadURLs = FASTQBundle.resolveAllFASTQURLs(for: standardized),
                  !payloadURLs.isEmpty else {
                throw FullLengthONTMHCGenotypingError.invalidFASTQ(standardized.path)
            }
            let rootProvenanceURL = sourceProvenanceURL(for: standardized)
            let payloads = try payloadURLs.map { payloadURL in
                try validatedPayload(
                    payloadURL,
                    trustedRootURL: standardized,
                    sourceProvenanceURL: sourceProvenanceURL(for: payloadURL) ?? rootProvenanceURL
                )
            }
            var metadataDescriptors: [ProvenanceFileDescriptor] = []
            if let manifestURL {
                let fingerprint = try fingerprintRegularFile(
                    manifestURL,
                    trustedRootURL: standardized,
                    role: "FASTQ bundle manifest"
                )
                metadataDescriptors.append(ProvenanceFileDescriptor(
                    path: manifestURL.standardizedFileURL.path,
                    checksumSHA256: fingerprint.checksum,
                    fileSize: fingerprint.size,
                    format: .json,
                    role: .input,
                    sourceProvenancePath: rootProvenanceURL?.path
                ))
            }
            let provenanceURLs = ([rootProvenanceURL] + payloads.map(\.sourceProvenanceURL))
                .compactMap { $0 }
            var seenProvenance = Set<String>()
            for provenanceURL in provenanceURLs where seenProvenance.insert(provenanceURL.path).inserted {
                let fingerprint = try fingerprintRegularFile(
                    provenanceURL,
                    trustedRootURL: standardized,
                    role: "FASTQ upstream provenance"
                )
                metadataDescriptors.append(ProvenanceFileDescriptor(
                    path: provenanceURL.path,
                    checksumSHA256: fingerprint.checksum,
                    fileSize: fingerprint.size,
                    format: .json,
                    role: .input
                ))
            }
            return ValidatedInput(
                bundleURL: standardized,
                manifestURL: manifestURL,
                payloads: payloads,
                metadataDescriptors: metadataDescriptors
            )
        }

        guard let resolved = SequenceInputResolver.resolvePrimarySequenceURL(for: standardized),
              (SequenceInputResolver.inputSequenceFormat(for: standardized) ?? SequenceFormat.from(url: resolved)) == .fastq else {
            throw FullLengthONTMHCGenotypingError.invalidFASTQ(standardized.path)
        }
        let payloadURL = resolved.standardizedFileURL
        return ValidatedInput(
            bundleURL: nil,
            manifestURL: nil,
            payloads: [try validatedPayload(
                payloadURL,
                trustedRootURL: payloadURL.deletingLastPathComponent(),
                sourceProvenanceURL: sourceProvenanceURL(for: payloadURL)
            )],
            metadataDescriptors: []
        )
    }

    private static func validatedPayload(
        _ url: URL,
        trustedRootURL: URL,
        sourceProvenanceURL: URL?
    ) throws -> ValidatedPayload {
        let descriptor = try FullLengthONTMHCAlignmentSafety().openRegularFileNoFollow(
            url,
            within: trustedRootURL,
            role: "FASTQ scientific payload"
        )
        defer { Darwin.close(descriptor) }
        return ValidatedPayload(
            url: url.standardizedFileURL,
            trustedRootURL: trustedRootURL.standardizedFileURL,
            identity: try fileIdentity(descriptor, role: "FASTQ scientific payload"),
            sourceProvenanceURL: sourceProvenanceURL?.standardizedFileURL
        )
    }

    private static func sourceProvenanceURL(for url: URL) -> URL? {
        ProvenanceRecorder.findProvenanceEnvelope(for: url)?.sidecarURL.standardizedFileURL
    }

    private static func snapshotPayload(
        _ payload: ValidatedPayload,
        to snapshotURL: URL,
        afterFirstSourceChunkRead: ((URL) throws -> Void)?
    ) throws -> ProvenanceFileDescriptor {
        let sourceDescriptor = try FullLengthONTMHCAlignmentSafety().openRegularFileNoFollow(
            payload.url,
            within: payload.trustedRootURL,
            role: "FASTQ scientific payload"
        )
        defer { Darwin.close(sourceDescriptor) }
        let openedIdentity = try fileIdentity(sourceDescriptor, role: "FASTQ scientific payload")
        guard openedIdentity == payload.identity else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "FASTQ payload changed after validation: \(payload.url.path)"
            )
        }
        guard FileManager.default.createFile(atPath: snapshotURL.path, contents: nil) else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Could not create immutable FASTQ source snapshot for \(payload.url.path)."
            )
        }
        let snapshot = try FileHandle(forWritingTo: snapshotURL)
        defer { try? snapshot.close() }
        var hasher = SHA256()
        var copiedSize: UInt64 = 0
        let chunkSize = 1_048_576
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var invokedMutationHook = false
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(sourceDescriptor, &buffer, chunkSize)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let chunk = Data(buffer[0..<count])
            hasher.update(data: chunk)
            copiedSize += UInt64(count)
            try snapshot.write(contentsOf: chunk)
            if !invokedMutationHook {
                invokedMutationHook = true
                try afterFirstSourceChunkRead?(payload.url)
            }
        }
        try snapshot.synchronize()
        let completedIdentity = try fileIdentity(sourceDescriptor, role: "FASTQ scientific payload")
        guard completedIdentity == openedIdentity,
              openedIdentity.size >= 0,
              copiedSize == UInt64(openedIdentity.size) else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "FASTQ payload changed while it was being snapshotted: \(payload.url.path)"
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: snapshotURL.path
        )
        return ProvenanceFileDescriptor(
            path: payload.url.path,
            checksumSHA256: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            fileSize: copiedSize,
            format: .fastq,
            role: .input,
            sourceProvenancePath: payload.sourceProvenanceURL?.path
        )
    }

    private static func fileIdentity(_ descriptor: Int32, role: String) throws -> FileIdentity {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw FullLengthONTMHCGenotypingError.reportFailed(
                "Could not inspect \(role): \(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO).localizedDescription)"
            )
        }
        return FileIdentity(information)
    }

    private static func fingerprintRegularFile(
        _ url: URL,
        trustedRootURL: URL,
        role: String
    ) throws -> (checksum: String, size: UInt64) {
        let descriptor = try FullLengthONTMHCAlignmentSafety().openRegularFileNoFollow(
            url,
            within: trustedRootURL,
            role: role
        )
        defer { Darwin.close(descriptor) }
        let initialIdentity = try fileIdentity(descriptor, role: role)
        var hasher = SHA256()
        var size: UInt64 = 0
        let chunkSize = 1_048_576
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, chunkSize)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            hasher.update(data: Data(buffer[0..<count]))
            size += UInt64(count)
        }
        let completedIdentity = try fileIdentity(descriptor, role: role)
        guard completedIdentity == initialIdentity,
              initialIdentity.size >= 0,
              size == UInt64(initialIdentity.size) else {
            throw FullLengthONTMHCGenotypingError.reportFailed("\(role) changed while it was read: \(url.path)")
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }

    private static func fingerprintStableRegularFile(
        _ url: URL,
        trustedRootURL: URL,
        expectedIdentity: FileIdentity,
        role: String
    ) throws -> (checksum: String, size: UInt64) {
        let observedDescriptor = try FullLengthONTMHCAlignmentSafety().openRegularFileNoFollow(
            url,
            within: trustedRootURL,
            role: role
        )
        defer { Darwin.close(observedDescriptor) }
        guard try fileIdentity(observedDescriptor, role: role) == expectedIdentity else {
            throw FullLengthONTMHCGenotypingError.reportFailed("\(role) changed after validation: \(url.path)")
        }
        var hasher = SHA256()
        var size: UInt64 = 0
        let chunkSize = 1_048_576
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(observedDescriptor, &buffer, chunkSize)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            hasher.update(data: Data(buffer[0..<count]))
            size += UInt64(count)
        }
        guard try fileIdentity(observedDescriptor, role: role) == expectedIdentity,
              expectedIdentity.size >= 0,
              size == UInt64(expectedIdentity.size) else {
            throw FullLengthONTMHCGenotypingError.reportFailed("\(role) changed while it was read: \(url.path)")
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }

    private static func shellEscape(_ value: String) -> String {
        if value.allSatisfy({ $0.isLetter || $0.isNumber || "-._/:=".contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

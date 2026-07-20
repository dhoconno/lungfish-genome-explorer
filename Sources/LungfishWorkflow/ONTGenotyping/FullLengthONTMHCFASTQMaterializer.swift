import CryptoKit
import Darwin
import Foundation
import LungfishIO

struct FullLengthONTMHCFASTQMaterializationResult: Sendable, Equatable {
    let outputURL: URL
    let step: ProvenanceStep
}

enum FullLengthONTMHCFASTQMaterializer {
    private struct ValidatedInput: Sendable {
        let bundleURL: URL?
        let manifestURL: URL?
        let payloadURLs: [URL]
        let descriptors: [ProvenanceFileDescriptor]
    }

    @discardableResult
    static func materializePlainFASTQ(
        inputURL: URL,
        outputURL: URL,
        logicalOutputURL: URL? = nil
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
            argv += ["--input", input.payloadURLs[0].path]
        }
        if let manifestURL = input.manifestURL {
            argv += ["--manifest", manifestURL.path]
        }
        for payloadURL in input.payloadURLs {
            argv += ["--payload", payloadURL.path]
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

            var previousChunkEndedWithNewline = true
            for inputFile in input.payloadURLs {
                try Task.checkCancellation()
                if !previousChunkEndedWithNewline {
                    try output.write(contentsOf: Data([0x0a]))
                    previousChunkEndedWithNewline = true
                }
                try inputFile.forEachChunkAutoDecompressing { chunk in
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
                        "payloadCount": .integer(input.payloadURLs.count),
                        "manifestPresent": .boolean(input.manifestURL != nil),
                        "compressionHandling": .string("extension-directed-streaming-auto-decompression"),
                        "pathValidation": .string("component-wise-openat-o_nofollow-regular-files"),
                    ],
                    runtimeIdentity: ProvenanceRuntimeIdentity(),
                    inputs: input.descriptors,
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
        try validatedInput(for: inputURL).descriptors
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
            let componentURLs = [manifestURL].compactMap { $0 } + payloadURLs
            let descriptors = try componentURLs.map { componentURL in
                let fingerprint = try fingerprintRegularFile(
                    componentURL,
                    trustedRootURL: standardized,
                    role: componentURL == manifestURL ? "FASTQ bundle manifest" : "FASTQ bundle scientific payload"
                )
                return ProvenanceFileDescriptor(
                    path: componentURL.standardizedFileURL.path,
                    checksumSHA256: fingerprint.checksum,
                    fileSize: fingerprint.size,
                    format: componentURL == manifestURL ? .json : .fastq,
                    role: .input
                )
            }
            return ValidatedInput(
                bundleURL: standardized,
                manifestURL: manifestURL,
                payloadURLs: payloadURLs.map(\.standardizedFileURL),
                descriptors: descriptors
            )
        }

        guard let resolved = SequenceInputResolver.resolvePrimarySequenceURL(for: standardized),
              (SequenceInputResolver.inputSequenceFormat(for: standardized) ?? SequenceFormat.from(url: resolved)) == .fastq else {
            throw FullLengthONTMHCGenotypingError.invalidFASTQ(standardized.path)
        }
        let payloadURL = resolved.standardizedFileURL
        let fingerprint = try fingerprintRegularFile(
            payloadURL,
            trustedRootURL: payloadURL.deletingLastPathComponent(),
            role: "FASTQ input"
        )
        return ValidatedInput(
            bundleURL: nil,
            manifestURL: nil,
            payloadURLs: [payloadURL],
            descriptors: [ProvenanceFileDescriptor(
                path: payloadURL.path,
                checksumSHA256: fingerprint.checksum,
                fileSize: fingerprint.size,
                format: .fastq,
                role: .input
            )]
        )
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
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }

    private static func shellEscape(_ value: String) -> String {
        if value.allSatisfy({ $0.isLetter || $0.isNumber || "-._/:=".contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

extension GenotypeWorkbookHaplotypeProjectionMode: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument)
    }
}

struct FastqUpdateCurrentWorkbookAttestation {
    let inputFingerprint: GenotypeCurrentWorkbookInputFingerprint?
    let syncIntent: GenotypeCurrentWorkbookSyncIntent?
}

struct FastqUpdateCurrentWorkbookCallInputs {
    let mutationCalls: [GenotypeWorkbookHaplotypeCall]
    let mutationIncludedLoci: [String]
    let fingerprintInputs: GenotypeWorkbookFingerprintInputs?
}

private struct FastqUpdateCurrentWorkbookImmutableJSONInput {
    let data: Data
    let descriptor: ProvenanceFileDescriptor
}

struct FastqUpdateCurrentWorkbookSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update-current-workbook",
        abstract: "Apply genotype haplotype review edits to a .lungfishgenotype current.xlsx workbook",
        discussion: """
            Updates artifacts/workbooks/current.xlsx inside a .lungfishgenotype bundle
            from a displayed/effective haplotype-call JSON snapshot and the bundle's
            annotations.json audit sidecar.
            """
    )

    @Argument(help: "Input .lungfishgenotype bundle")
    var bundle: String

    @Option(name: .customLong("calls-json"), help: "JSON array of displayed/effective haplotype calls")
    var callsJSON: String

    @Option(name: .customLong("annotations"), help: "Annotation sidecar to write Overrides and Audit Log worksheets; defaults to bundle annotations.json when present")
    var annotations: String?

    @Option(name: .customLong("included-locus"), help: "Haplotype locus included in the displayed call snapshot; repeat for multiple loci")
    var includedLocus: [String] = []

    @Flag(name: .customLong("annotation-only"), help: "Apply annotations while preserving the manifest-attested scientific workbook projection")
    var annotationOnly = false

    @Option(
        name: .customLong("haplotype-projection-mode"),
        help:
            "Typed haplotype source: haplotyped or manual-genotype-only"
    )
    var haplotypeProjectionMode:
        GenotypeWorkbookHaplotypeProjectionMode = .haplotyped

    @Option(name: .customLong("input-fingerprint"), help: "Lowercase SHA-256 fingerprint of the immutable current-workbook inputs")
    var inputFingerprint: String?

    @Option(name: .customLong("input-fingerprint-schema"), help: "Schema version for --input-fingerprint")
    var inputFingerprintSchema: Int?

    @Option(name: .customLong("reviewable-row-catalog-path"), help: "Manifest-relative path attested by --input-fingerprint")
    var reviewableRowCatalogPath: String?

    @Option(name: .customLong("reviewable-row-catalog-size"), help: "Byte size attested for the reviewable-row catalog")
    var reviewableRowCatalogSize: UInt64?

    @Option(name: .customLong("reviewable-row-catalog-sha256"), help: "SHA-256 attested for the reviewable-row catalog")
    var reviewableRowCatalogSHA256: String?

    @Option(name: .customLong("reviewable-row-catalog-schema"), help: "Document schema version attested for the reviewable-row catalog")
    var reviewableRowCatalogSchema: Int?

    @Option(name: .customLong("sync-intent"), help: "Synchronization intent: automatic-idle, bundle-switch, or update-and-view")
    var syncIntent: String?

    // Semantic validation intentionally runs after the bundle-bound attempt
    // receipt begins. ArgumentParser still validates syntax and typed values.
    mutating func validate() throws {}

    func run() async throws {
        let argv = CommandLine.arguments
        let context = try beginAttempt(
            argv: argv,
            recorder: .init()
        )
        defer {
            assert(
                context.attempt.isFinalized
                    || context.attempt.hasPublicationFailure,
                "Valid-bundle workbook update attempt escaped without a terminal publication attempt."
            )
        }
        do {
            FileHandle.standardError.write(
                Data("[ 10%] Resolving managed openpyxl runtime.\n".utf8)
            )
            let pythonURL = try await CondaManager.shared.toolPath(
                name: "python",
                environment: "openpyxl"
            )
            try recordManagedPythonRuntime(
                context.attempt,
                pythonExecutableURL: pythonURL
            )
            let attestation = try validatedAttestation()
            try recordResolvedAttemptOptions(
                context.attempt,
                bundleURL: context.bundleURL,
                attestation: attestation
            )
            let payload = try executeResolved(
                pythonExecutableURL: pythonURL,
                workbookAttestationRootURL: nil,
                bundleURL: context.bundleURL,
                attestation: attestation,
                attempt: context.attempt,
                revisionService: nil
            )
            try emitAndFinalize(payload, attempt: context.attempt)
        } catch {
            if context.attempt.isFinalized
                || context.attempt.hasPublicationFailure {
                throw error
            }
            try finalizeFailure(error, attempt: context.attempt)
        }
    }

    @discardableResult
    func runResolved(
        pythonExecutableURL: URL,
        workbookAttestationRootURL: URL?,
        argvProvider: (@Sendable () -> [String])? = nil,
        attemptRecorder: GenotypeWorkbookUpdateAttemptRecorder = .init(),
        revisionService: GenotypeWorkbookRevisionService? = nil
    ) throws -> FastqUpdateCurrentWorkbookPayload {
        let context = try beginAttempt(
            argv: argvProvider?() ?? legacyResolvedArgv(),
            recorder: attemptRecorder
        )
        defer {
            assert(
                context.attempt.isFinalized
                    || context.attempt.hasPublicationFailure,
                "Valid-bundle workbook update attempt escaped without a terminal publication attempt."
            )
        }
        do {
            try recordManagedPythonRuntime(
                context.attempt,
                pythonExecutableURL: pythonExecutableURL
            )
            let attestation = try validatedAttestation()
            try recordResolvedAttemptOptions(
                context.attempt,
                bundleURL: context.bundleURL,
                attestation: attestation
            )
            let payload = try executeResolved(
                pythonExecutableURL: pythonExecutableURL,
                workbookAttestationRootURL: workbookAttestationRootURL,
                bundleURL: context.bundleURL,
                attestation: attestation,
                attempt: context.attempt,
                revisionService: revisionService
            )
            try emitAndFinalize(payload, attempt: context.attempt)
            return payload
        } catch {
            if context.attempt.isFinalized
                || context.attempt.hasPublicationFailure {
                throw error
            }
            try finalizeFailure(error, attempt: context.attempt)
        }
    }

    private func executeResolved(
        pythonExecutableURL: URL,
        workbookAttestationRootURL: URL?,
        bundleURL: URL,
        attestation: FastqUpdateCurrentWorkbookAttestation,
        attempt: GenotypeWorkbookUpdateAttemptHandle,
        revisionService: GenotypeWorkbookRevisionService?
    ) throws -> FastqUpdateCurrentWorkbookPayload {
        let callsURL = URL(fileURLWithPath: callsJSON).standardizedFileURL
        let annotationURL = resolvedAnnotationURL(bundleURL: bundleURL)
        if annotations == nil, let annotationURL {
            try attempt.recordAttemptedInputPaths([annotationURL.path])
        }
        let callsInput = try immutableJSONInput(at: callsURL)
        try attempt.recordInput(callsInput.descriptor)
        let annotationInput = try annotationURL.map {
            try immutableJSONInput(at: $0)
        }
        if let annotationInput {
            try attempt.recordInput(annotationInput.descriptor)
        }

        FileHandle.standardError.write(Data("[ 35%] Loading displayed haplotype call snapshot.\n".utf8))
        let calls = try JSONDecoder().decode(
            [GenotypeWorkbookHaplotypeCall].self,
            from: callsInput.data
        )
        let callInputs = workbookCallInputs(displayedCalls: calls)
        let provenanceContext = try provenanceContext(
            argv: attemptArgv(attempt),
            callsInput: callsInput,
            annotationInput: annotationInput,
            attestation: attestation
        )
        FileHandle.standardError.write(Data("[ 55%] Applying haplotype edits to current.xlsx.\n".utf8))
        let service = revisionService ?? GenotypeWorkbookRevisionService(
            pythonExecutableURL: pythonExecutableURL,
            workbookAttestationRootURL: workbookAttestationRootURL
        )
        let outcome = try service.applyHaplotypeOverridesWithOutcome(
            callInputs.mutationCalls,
            annotationSidecarURL: annotationURL,
            into: bundleURL,
            annotationOnly: annotationOnly,
            includedLoci: callInputs.mutationIncludedLoci,
            fingerprintInputs: callInputs.fingerprintInputs,
            provenanceContext: provenanceContext,
            projectionMode: haplotypeProjectionMode,
            attempt: attempt
        )
        return FastqUpdateCurrentWorkbookPayload(
            bundlePath: bundleURL.path,
            currentWorkbookPath: try ONTGenotypeResultBundle.currentWorkbookURL(for: bundleURL).path,
            manifestPath: ONTGenotypeResultBundle.manifestURL(in: bundleURL).path,
            cleanupPending: outcome.cleanupPendingWarning != nil,
            warning: outcome.cleanupPendingWarning
        )
    }

    private func emitAndFinalize(
        _ payload: FastqUpdateCurrentWorkbookPayload,
        attempt: GenotypeWorkbookUpdateAttemptHandle
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payloadData = try encoder.encode(payload)
        try attempt.finalize(
            exitStatus: 0,
            cleanupPendingWarning: payload.warning
        )
        if let warning = payload.warning {
            FileHandle.standardError.write(
                Data("[100%] \(warning)\n".utf8)
            )
        } else {
            FileHandle.standardError.write(
                Data("[100%] Updated current.xlsx\n".utf8)
            )
        }
        FileHandle.standardOutput.write(payloadData)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private func beginAttempt(
        argv: [String],
        recorder: GenotypeWorkbookUpdateAttemptRecorder
    ) throws -> (
        bundleURL: URL,
        attempt: GenotypeWorkbookUpdateAttemptHandle
    ) {
        let bundleURL = URL(
            fileURLWithPath: bundle,
            isDirectory: true
        ).standardizedFileURL
        guard ONTGenotypeResultBundle.isBundleURL(bundleURL) else {
            throw ValidationError(
                "Expected a .lungfishgenotype bundle: \(bundle)"
            )
        }
        return (
            bundleURL,
            try recorder.begin(
                bundleURL: bundleURL,
                argv: argv,
                attemptedInputPaths: [callsJSON]
                    + [annotations].compactMap { $0 }
            )
        )
    }

    private func legacyResolvedArgv() -> [String] {
        let bundleURL = URL(
            fileURLWithPath: bundle,
            isDirectory: true
        ).standardizedFileURL
        let callsURL = URL(fileURLWithPath: callsJSON).standardizedFileURL
        return [CLICommandIdentity.executableName, "fastq"] + cliArguments(
            bundleURL: bundleURL,
            callsURL: callsURL,
            annotationURL: resolvedAnnotationURL(bundleURL: bundleURL)
        )
    }

    private func recordResolvedAttemptOptions(
        _ attempt: GenotypeWorkbookUpdateAttemptHandle,
        bundleURL: URL,
        attestation: FastqUpdateCurrentWorkbookAttestation
    ) throws {
        try attempt.recordResolvedOptions([
            "bundle": bundleURL.path,
            "callsJSON": URL(fileURLWithPath: callsJSON)
                .standardizedFileURL.path,
            "annotations":
                resolvedAnnotationURL(bundleURL: bundleURL)?.path ?? "none",
            "annotationOnly": String(annotationOnly),
            "haplotypeProjectionMode": haplotypeProjectionMode.rawValue,
            "includedLoci": includedLocus.joined(separator: ","),
            "inputFingerprint":
                attestation.inputFingerprint?.sha256 ?? "none",
            "inputFingerprintSchema":
                attestation.inputFingerprint.map {
                    String($0.schemaVersion)
                } ?? "none",
            "reviewableRowCatalogPath":
                reviewableRowCatalogPath ?? "none",
            "reviewableRowCatalogSize":
                reviewableRowCatalogSize.map(String.init) ?? "none",
            "reviewableRowCatalogSHA256":
                reviewableRowCatalogSHA256 ?? "none",
            "reviewableRowCatalogSchema":
                reviewableRowCatalogSchema.map(String.init) ?? "none",
            "syncIntent": attestation.syncIntent?.rawValue ?? "none",
        ])
    }

    private func recordManagedPythonRuntime(
        _ attempt: GenotypeWorkbookUpdateAttemptHandle,
        pythonExecutableURL: URL
    ) throws {
        var identity = [
            "pythonExecutable": pythonExecutableURL.standardizedFileURL.path,
            "condaEnvironment": "openpyxl",
            "condaPrefix": pythonExecutableURL.deletingLastPathComponent()
                .deletingLastPathComponent().path,
        ]
        do {
            identity.merge(
                try GenotypeWorkbookManagedRuntimeProbe.probe(
                    pythonExecutableURL: pythonExecutableURL
                )
            ) { _, probed in probed }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            identity["runtimeVersionProbe"] =
                "failed (\(errorText(error)))"
        }
        try attempt.recordRuntimeIdentity(identity)
    }

    private func finalizeFailure(
        _ primaryError: Error,
        attempt: GenotypeWorkbookUpdateAttemptHandle
    ) throws -> Never {
        let primaryText = errorText(primaryError)
        do {
            try attempt.finalize(
                exitStatus: 1,
                stderr: primaryText
            )
        } catch {
            throw ValidationError(
                "\(primaryText)\nWorkbook update attempt provenance also failed: \(errorText(error))"
            )
        }
        throw primaryError
    }

    private func errorText(_ error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription,
           !description.isEmpty {
            return description
        }
        return String(describing: error)
    }

    private func attemptArgv(
        _ attempt: GenotypeWorkbookUpdateAttemptHandle
    ) -> [String] {
        // The scientific revision provenance and the command-attempt receipt
        // must describe the same exact invocation. The handle intentionally
        // does not expose mutable state, so retain argv through its receipt
        // contract by reading the command's production/test provider once.
        attempt.recordedArgv
    }

    func workbookCallInputs(
        displayedCalls: [GenotypeWorkbookHaplotypeCall]
    ) -> FastqUpdateCurrentWorkbookCallInputs {
        if annotationOnly {
            return FastqUpdateCurrentWorkbookCallInputs(
                mutationCalls: [],
                mutationIncludedLoci: [],
                fingerprintInputs: GenotypeWorkbookFingerprintInputs(
                    calls: displayedCalls,
                    includedLoci: includedLocus,
                    haplotypeProjectionMode:
                        haplotypeProjectionMode
                )
            )
        }
        return FastqUpdateCurrentWorkbookCallInputs(
            mutationCalls: displayedCalls,
            mutationIncludedLoci: includedLocus,
            fingerprintInputs: nil
        )
    }

    func validatedAttestation() throws -> FastqUpdateCurrentWorkbookAttestation {
        let fingerprint: GenotypeCurrentWorkbookInputFingerprint?
        switch (inputFingerprint, inputFingerprintSchema) {
        case (nil, nil):
            guard reviewableRowCatalogPath == nil,
                  reviewableRowCatalogSize == nil,
                  reviewableRowCatalogSHA256 == nil,
                  reviewableRowCatalogSchema == nil else {
                throw ValidationError(
                    "Reviewable-row catalog attestation options require --input-fingerprint and --input-fingerprint-schema."
                )
            }
            fingerprint = nil
        case (.some, nil), (nil, .some):
            throw ValidationError(
                "--input-fingerprint and --input-fingerprint-schema must be supplied together."
            )
        case (.some(let digest), .some(let schemaVersion)):
            do {
                fingerprint = try GenotypeCurrentWorkbookInputFingerprint(
                    schemaVersion: schemaVersion,
                    sha256: digest,
                    reviewableRowCatalogPath: reviewableRowCatalogPath,
                    reviewableRowCatalogSize: reviewableRowCatalogSize,
                    reviewableRowCatalogSHA256: reviewableRowCatalogSHA256,
                    reviewableRowCatalogSchemaVersion:
                        reviewableRowCatalogSchema
                )
            } catch {
                throw ValidationError(error.localizedDescription)
            }
        }

        let intent: GenotypeCurrentWorkbookSyncIntent?
        if let syncIntent {
            guard let parsed = GenotypeCurrentWorkbookSyncIntent(rawValue: syncIntent) else {
                throw ValidationError(
                    "Unknown --sync-intent '\(syncIntent)'. Expected automatic-idle, bundle-switch, or update-and-view."
                )
            }
            intent = parsed
        } else {
            intent = nil
        }
        return FastqUpdateCurrentWorkbookAttestation(
            inputFingerprint: fingerprint,
            syncIntent: intent
        )
    }

    private func resolvedAnnotationURL(bundleURL: URL) -> URL? {
        if let annotations {
            return URL(fileURLWithPath: annotations).standardizedFileURL
        }
        let defaultURL = bundleURL.appendingPathComponent(GenotypeAnnotationSidecar.filename)
        return FileManager.default.fileExists(atPath: defaultURL.path) ? defaultURL : nil
    }

    func cliArguments(bundleURL: URL, callsURL: URL, annotationURL: URL?) -> [String] {
        var arguments = [
            "update-current-workbook",
            bundleURL.path,
            "--calls-json",
            callsURL.path,
            "--haplotype-projection-mode",
            haplotypeProjectionMode.rawValue,
        ]
        if let annotationURL {
            arguments += ["--annotations", annotationURL.path]
        }
        if annotationOnly {
            arguments.append("--annotation-only")
        }
        if let inputFingerprint, let inputFingerprintSchema {
            arguments += [
                "--input-fingerprint", inputFingerprint,
                "--input-fingerprint-schema", String(inputFingerprintSchema),
            ]
            if let reviewableRowCatalogPath,
               let reviewableRowCatalogSize,
               let reviewableRowCatalogSHA256,
               let reviewableRowCatalogSchema {
                arguments += [
                    "--reviewable-row-catalog-path",
                    reviewableRowCatalogPath,
                    "--reviewable-row-catalog-size",
                    String(reviewableRowCatalogSize),
                    "--reviewable-row-catalog-sha256",
                    reviewableRowCatalogSHA256,
                    "--reviewable-row-catalog-schema",
                    String(reviewableRowCatalogSchema),
                ]
            }
        }
        if let syncIntent {
            arguments += ["--sync-intent", syncIntent]
        }
        for locus in includedLocus {
            arguments += ["--included-locus", locus]
        }
        return arguments
    }

    func provenanceContext(
        argv: [String],
        callsURL: URL,
        annotationURL: URL?,
        attestation: FastqUpdateCurrentWorkbookAttestation,
        immutableInputReadObserver:
            (@Sendable (URL, Int) throws -> Void)? = nil
    ) throws -> GenotypeWorkbookRevisionProvenanceContext {
        let callsInput = try immutableJSONInput(
            at: callsURL.standardizedFileURL,
            readObserver: immutableInputReadObserver
        )
        let annotationInput = try annotationURL.map {
            try immutableJSONInput(
                at: $0.standardizedFileURL,
                readObserver: immutableInputReadObserver
            )
        }
        return try provenanceContext(
            argv: argv,
            callsInput: callsInput,
            annotationInput: annotationInput,
            attestation: attestation
        )
    }

    private func provenanceContext(
        argv: [String],
        callsInput: FastqUpdateCurrentWorkbookImmutableJSONInput,
        annotationInput: FastqUpdateCurrentWorkbookImmutableJSONInput?,
        attestation: FastqUpdateCurrentWorkbookAttestation
    ) throws -> GenotypeWorkbookRevisionProvenanceContext {
        let descriptors = [callsInput.descriptor] + [annotationInput?.descriptor].compactMap { $0 }
        return GenotypeWorkbookRevisionProvenanceContext(
            toolName: "\(CLICommandIdentity.executableName) fastq update-current-workbook",
            toolKind: "cli",
            argv: argv,
            cliInputDescriptors: descriptors,
            inputFingerprint: attestation.inputFingerprint,
            syncIntent: attestation.syncIntent
        )
    }

    private func immutableJSONInput(
        at url: URL,
        readObserver: (@Sendable (URL, Int) throws -> Void)? = nil
    ) throws -> FastqUpdateCurrentWorkbookImmutableJSONInput {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw immutableInputPOSIXError(operation: "open", url: url)
        }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0 else {
            throw immutableInputPOSIXError(operation: "inspect", url: url)
        }
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw ValidationError(
                "Current-workbook immutable input is not a regular file: \(url.path)"
            )
        }

        var data = Data()
        if before.st_size > 0, before.st_size <= Int.max {
            data.reserveCapacity(Int(before.st_size))
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var chunkIndex = 0
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw immutableInputPOSIXError(operation: "read", url: url)
            }
            guard count > 0 else { break }
            data.append(buffer, count: count)
            chunkIndex += 1
            try readObserver?(url, chunkIndex)
        }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              sameImmutableInputMetadata(before, after),
              Int64(data.count) == after.st_size else {
            throw ValidationError(
                "Current-workbook immutable input changed while it was being read: \(url.path)"
            )
        }
        let checksum = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        try verifyImmutableJSONInput(
            at: url,
            expectedSize: UInt64(data.count),
            expectedChecksum: checksum
        )
        return FastqUpdateCurrentWorkbookImmutableJSONInput(
            data: data,
            descriptor: ProvenanceFileDescriptor(
                path: url.path,
                checksumSHA256: checksum,
                fileSize: UInt64(data.count),
                format: .json,
                role: .input
            )
        )
    }

    private func verifyImmutableJSONInput(
        at url: URL,
        expectedSize: UInt64,
        expectedChecksum: String
    ) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw immutableInputPOSIXError(operation: "reopen", url: url)
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG else {
            throw immutableInputPOSIXError(operation: "reinspect", url: url)
        }
        var hasher = SHA256()
        var byteCount: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw immutableInputPOSIXError(operation: "reread", url: url)
            }
            guard count > 0 else { break }
            byteCount += UInt64(count)
            hasher.update(data: Data(buffer[0..<count]))
        }
        var after = stat()
        let checksum = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        guard Darwin.fstat(descriptor, &after) == 0,
              sameImmutableInputMetadata(before, after),
              byteCount == expectedSize,
              checksum == expectedChecksum else {
            throw ValidationError(
                "Current-workbook immutable input changed while it was being read: \(url.path)"
            )
        }
    }

    private func sameImmutableInputMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private func immutableInputPOSIXError(operation: String, url: URL) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Could not \(operation) current-workbook immutable input \(url.path) without following links: \(String(cString: strerror(code)))",
            ]
        )
    }
}

struct FastqUpdateCurrentWorkbookPayload: Codable, Equatable {
    let bundlePath: String
    let currentWorkbookPath: String
    let manifestPath: String
    let cleanupPending: Bool
    let warning: String?
}

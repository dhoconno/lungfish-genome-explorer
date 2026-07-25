import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishWorkflow

@MainActor
final class GenotypeCurrentWorkbookUpdateExecutionService {
    private let operationCenter: OperationCenter
    private let processRunner: LocalWorkflowCLIProcessRunning
    private let fileManager: FileManager

    init(
        operationCenter: OperationCenter = .shared,
        processRunner: LocalWorkflowCLIProcessRunning = ProcessLocalWorkflowCLIProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.operationCenter = operationCenter
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    @discardableResult
    func run(
        bundleURL: URL,
        calls: [GenotypeWorkbookHaplotypeCall],
        includedLoci: [String] = [],
        annotationSidecarURL: URL?,
        annotationSidecarData: Data? = nil,
        annotationOnly: Bool = false,
        inputFingerprint: GenotypeCurrentWorkbookInputFingerprint? = nil,
        syncIntent: GenotypeCurrentWorkbookSyncIntent? = nil,
        routeContext: OperationRouteContext? = nil
    ) async throws -> URL {
        let bundle = bundleURL.standardizedFileURL
        let snapshot = try writeInputSnapshot(
            calls: calls,
            annotationSidecarData: annotationSidecarData,
            annotationSidecarURL: annotationSidecarURL,
            bundleURL: bundle
        )
        let arguments = cliArguments(
            bundleURL: bundle,
            callsURL: snapshot.callsURL,
            includedLoci: includedLoci,
            annotationSidecarURL: snapshot.annotationSidecarURL,
            annotationOnly: annotationOnly,
            inputFingerprint: inputFingerprint,
            syncIntent: syncIntent
        )
        let cliCommand = ViralReconWorkflowCommandPreview.build(
            executableName: CLICommandIdentity.executableName,
            arguments: arguments
        )
        let operationID = operationCenter.start(
            title: "Update current.xlsx",
            detail: "Preparing current.xlsx update",
            operationType: .fastqOperation,
            targetBundleURL: bundle,
            cliCommand: cliCommand,
            routeContext: routeContext
        )
        operationCenter.log(id: operationID, level: .info, message: cliCommand)
        operationCenter.log(
            id: operationID,
            level: .info,
            message: "Calls snapshot: \(snapshot.callsURL.path)"
        )
        if !includedLoci.isEmpty {
            operationCenter.log(id: operationID, level: .info, message: "Included loci: \(includedLoci.joined(separator: ", "))")
        }
        if let annotationSidecarURL = snapshot.annotationSidecarURL {
            operationCenter.log(id: operationID, level: .info, message: "Annotations: \(annotationSidecarURL.path)")
        }

        do {
            let result = try await processRunner.runLungfishCLI(
                arguments: arguments,
                workingDirectory: bundle,
                outputHandler: { [operationCenter] output in
                    Self.recordProcessOutput(output, operationID: operationID, operationCenter: operationCenter)
                }
            )
            if !result.didStreamOutput {
                Self.logProcessOutput(result, operationID: operationID, operationCenter: operationCenter)
            }
            if result.exitCode != 0 {
                let detail = "current.xlsx update failed with exit code \(result.exitCode)"
                operationCenter.log(id: operationID, level: .error, message: detail)
                _ = operationCenter.fail(
                    id: operationID,
                    detail: detail,
                    errorMessage: "current.xlsx update failed",
                    errorDetail: failureDiagnostics(result: result, cliCommand: cliCommand)
                )
                throw LocalWorkflowExecutionError.nonZeroExit(result.exitCode)
            }
            let currentWorkbookURL = Self.currentWorkbookURL(for: bundle)
            _ = operationCenter.complete(
                id: operationID,
                detail: "Updated current.xlsx",
                outputURLs: [currentWorkbookURL]
            )
            return currentWorkbookURL
        } catch {
            if operationCenter.items.first(where: { $0.id == operationID })?.state == .running {
                _ = operationCenter.fail(
                    id: operationID,
                    detail: "current.xlsx update failed",
                    errorMessage: "current.xlsx update failed",
                    errorDetail: String(describing: error)
                )
            }
            throw error
        }
    }

    private struct InputSnapshot {
        let callsURL: URL
        let annotationSidecarURL: URL?
    }

    private func writeInputSnapshot(
        calls: [GenotypeWorkbookHaplotypeCall],
        annotationSidecarData: Data?,
        annotationSidecarURL: URL?,
        bundleURL: URL
    ) throws -> InputSnapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let callsData = try encoder.encode(calls)
        let retainedAnnotationData: Data?
        if let annotationSidecarData {
            retainedAnnotationData = annotationSidecarData
        } else if let annotationSidecarURL,
                  fileManager.fileExists(atPath: annotationSidecarURL.path) {
            retainedAnnotationData = try readRegularFileNoFollow(
                at: annotationSidecarURL.standardizedFileURL
            )
        } else {
            retainedAnnotationData = nil
        }

        let rootDescriptor = Darwin.open(
            bundleURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard rootDescriptor >= 0 else {
            throw posixError(
                operation: "Open genotype bundle for current-workbook input snapshot",
                path: bundleURL.path
            )
        }
        defer { Darwin.close(rootDescriptor) }

        var ownedDirectoryDescriptors: [Int32] = []
        defer {
            for descriptor in ownedDirectoryDescriptors.reversed() {
                Darwin.close(descriptor)
            }
        }
        var parentDescriptor = rootDescriptor
        var displayDirectoryURL = bundleURL
        for component in ["artifacts", "workbooks", "updates"] {
            displayDirectoryURL.appendPathComponent(component, isDirectory: true)
            let descriptor = try openOrCreateDirectoryNoFollow(
                named: component,
                parentDescriptor: parentDescriptor,
                displayPath: displayDirectoryURL.path
            )
            ownedDirectoryDescriptors.append(descriptor)
            parentDescriptor = descriptor
        }

        let snapshotDirectoryName =
            "\(timestampSlug())-current-workbook-inputs-\(UUID().uuidString)"
        let snapshotDescriptor = try createDirectoryNoFollow(
            named: snapshotDirectoryName,
            parentDescriptor: parentDescriptor,
            displayPath: bundleURL
                .appendingPathComponent("artifacts/workbooks/updates")
                .appendingPathComponent(snapshotDirectoryName)
                .path
        )
        ownedDirectoryDescriptors.append(snapshotDescriptor)

        let callsName = "displayed-haplotype-calls.json"
        let annotationName = GenotypeAnnotationSidecar.filename
        var snapshotComplete = false
        defer {
            if !snapshotComplete {
                callsName.withCString {
                    _ = Darwin.unlinkat(snapshotDescriptor, $0, 0)
                }
                annotationName.withCString {
                    _ = Darwin.unlinkat(snapshotDescriptor, $0, 0)
                }
                snapshotDirectoryName.withCString {
                    _ = Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
                }
            }
        }
        try writeNewRegularFileNoFollow(
            callsData,
            named: callsName,
            directoryDescriptor: snapshotDescriptor,
            displayPath: displayDirectoryURL
                .appendingPathComponent(snapshotDirectoryName, isDirectory: true)
                .appendingPathComponent(callsName)
                .path
        )
        if let retainedAnnotationData {
            try writeNewRegularFileNoFollow(
                retainedAnnotationData,
                named: annotationName,
                directoryDescriptor: snapshotDescriptor,
                displayPath: displayDirectoryURL
                    .appendingPathComponent(snapshotDirectoryName, isDirectory: true)
                    .appendingPathComponent(annotationName)
                    .path
            )
        }
        guard Darwin.fsync(snapshotDescriptor) == 0 else {
            throw posixError(
                operation: "Sync current-workbook input snapshot directory",
                path: snapshotDirectoryName
            )
        }
        guard Darwin.fsync(parentDescriptor) == 0 else {
            throw posixError(
                operation: "Sync current-workbook updates directory",
                path: snapshotDirectoryName
            )
        }
        snapshotComplete = true

        let snapshotDirectoryURL = bundleURL
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("workbooks", isDirectory: true)
            .appendingPathComponent("updates", isDirectory: true)
            .appendingPathComponent(snapshotDirectoryName, isDirectory: true)
        return InputSnapshot(
            callsURL: snapshotDirectoryURL.appendingPathComponent(callsName),
            annotationSidecarURL: retainedAnnotationData == nil
                ? nil
                : snapshotDirectoryURL.appendingPathComponent(annotationName)
        )
    }

    private func openOrCreateDirectoryNoFollow(
        named name: String,
        parentDescriptor: Int32,
        displayPath: String
    ) throws -> Int32 {
        var descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        if descriptor < 0, errno == ENOENT {
            let creationResult = name.withCString {
                Darwin.mkdirat(parentDescriptor, $0, S_IRWXU)
            }
            if creationResult != 0, errno != EEXIST {
                throw posixError(
                    operation: "Create current-workbook snapshot directory",
                    path: displayPath
                )
            }
            descriptor = name.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
        }
        guard descriptor >= 0 else {
            throw posixError(
                operation: "Open current-workbook snapshot directory",
                path: displayPath
            )
        }
        return descriptor
    }

    private func createDirectoryNoFollow(
        named name: String,
        parentDescriptor: Int32,
        displayPath: String
    ) throws -> Int32 {
        let creationResult = name.withCString {
            Darwin.mkdirat(parentDescriptor, $0, S_IRWXU)
        }
        guard creationResult == 0 else {
            throw posixError(
                operation: "Create current-workbook input snapshot",
                path: displayPath
            )
        }
        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else {
            throw posixError(
                operation: "Open current-workbook input snapshot",
                path: displayPath
            )
        }
        return descriptor
    }

    private func writeNewRegularFileNoFollow(
        _ data: Data,
        named name: String,
        directoryDescriptor: Int32,
        displayPath: String
    ) throws {
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw posixError(
                operation: "Create current-workbook input snapshot file",
                path: displayPath
            )
        }
        defer { Darwin.close(descriptor) }

        try data.withUnsafeBytes { bytes in
            guard var address = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, address, remaining)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw posixError(
                        operation: "Write current-workbook input snapshot file",
                        path: displayPath
                    )
                }
                remaining -= written
                address = address.advanced(by: written)
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError(
                operation: "Sync current-workbook input snapshot file",
                path: displayPath
            )
        }
    }

    private func readRegularFileNoFollow(at url: URL) throws -> Data {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw posixError(
                operation: "Open annotation sidecar for snapshot",
                path: url.path
            )
        }
        defer { Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG else {
            throw posixError(
                operation: "Validate annotation sidecar for snapshot",
                path: url.path
            )
        }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else {
                throw posixError(
                    operation: "Read annotation sidecar for snapshot",
                    path: url.path
                )
            }
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }

    private func posixError(operation: String, path: String) -> NSError {
        let code = errno
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [
                NSLocalizedDescriptionKey:
                    "\(operation) failed for \(path): \(String(cString: strerror(code)))",
            ]
        )
    }

    private func cliArguments(
        bundleURL: URL,
        callsURL: URL,
        includedLoci: [String],
        annotationSidecarURL: URL?,
        annotationOnly: Bool,
        inputFingerprint: GenotypeCurrentWorkbookInputFingerprint?,
        syncIntent: GenotypeCurrentWorkbookSyncIntent?
    ) -> [String] {
        var arguments = [
            "fastq",
            "update-current-workbook",
            bundleURL.path,
            "--calls-json",
            callsURL.path,
        ]
        for locus in includedLoci {
            arguments += ["--included-locus", locus]
        }
        if let annotationSidecarURL {
            arguments += ["--annotations", annotationSidecarURL.standardizedFileURL.path]
        }
        if annotationOnly {
            arguments.append("--annotation-only")
        }
        if let inputFingerprint {
            arguments += [
                "--input-fingerprint", inputFingerprint.sha256,
                "--input-fingerprint-schema", String(inputFingerprint.schemaVersion),
            ]
        }
        if let syncIntent {
            arguments += ["--sync-intent", syncIntent.rawValue]
        }
        return arguments
    }

    private func timestampSlug() -> String {
        ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private static func currentWorkbookURL(for bundleURL: URL) -> URL {
        if let manifestURL = try? ONTGenotypeResultBundle.currentWorkbookURL(for: bundleURL) {
            return manifestURL
        }
        return bundleURL
            .appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent("workbooks", isDirectory: true)
            .appendingPathComponent("current.xlsx")
    }

    private static func logProcessOutput(
        _ result: LocalWorkflowCLIProcessResult,
        operationID: UUID,
        operationCenter: OperationCenter
    ) {
        for line in result.standardOutput.split(whereSeparator: \.isNewline) {
            recordProcessOutput(.standardOutput(String(line)), operationID: operationID, operationCenter: operationCenter)
        }
        for line in result.standardError.split(whereSeparator: \.isNewline) {
            recordProcessOutput(.standardError(String(line)), operationID: operationID, operationCenter: operationCenter)
        }
    }

    private static func recordProcessOutput(
        _ output: ViralReconWorkflowProcessOutput,
        operationID: UUID,
        operationCenter: OperationCenter
    ) {
        switch output {
        case .standardOutput(let line):
            operationCenter.log(id: operationID, level: .info, message: line)
        case .standardError(let line):
            if let progress = parseCLIProgressLine(line) {
                _ = operationCenter.updateWithLog(
                    id: operationID,
                    progress: progress.fraction,
                    detail: progress.message
                )
            } else {
                operationCenter.log(id: operationID, level: .warning, message: line)
            }
        }
    }

    private static func parseCLIProgressLine(_ line: String) -> (fraction: Double, message: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "[",
              let closingBracket = trimmed.firstIndex(of: "]") else {
            return nil
        }
        let percentRange = trimmed.index(after: trimmed.startIndex)..<closingBracket
        let percentText = trimmed[percentRange]
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let percent = Double(percentText) else {
            return nil
        }
        let messageStart = trimmed.index(after: closingBracket)
        let message = trimmed[messageStart...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (max(0, min(1, percent / 100)), message.isEmpty ? trimmed : message)
    }

    private func failureDiagnostics(
        result: LocalWorkflowCLIProcessResult,
        cliCommand: String
    ) -> String {
        var parts = [
            "lungfish-cli exited with exit code \(result.exitCode).",
            "",
            "CLI command:",
            cliCommand,
        ]
        let stderr = tail(result.standardError)
        if !stderr.isEmpty {
            parts += ["", "stderr:", stderr]
        }
        let stdout = tail(result.standardOutput)
        if !stdout.isEmpty {
            parts += ["", "stdout:", stdout]
        }
        return parts.joined(separator: "\n")
    }

    private func tail(_ text: String, lineLimit: Int = 80) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count > lineLimit else { return trimmed }
        return lines.suffix(lineLimit).joined(separator: "\n")
    }
}

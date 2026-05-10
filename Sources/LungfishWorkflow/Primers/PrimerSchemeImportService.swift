import Foundation
import LungfishIO

public struct PrimerSchemeImportRequest: Sendable {
    public let bedURL: URL
    public let fastaURL: URL?
    public let attachments: [URL]
    public let outputURL: URL
    public let projectURL: URL?
    public let displayName: String?
    public let canonicalAccession: String?
    public let equivalentAccessions: [String]
    public let argv: [String]
    public let workflowName: String
    public let toolVersion: String

    public init(
        bedURL: URL,
        fastaURL: URL?,
        attachments: [URL],
        outputURL: URL,
        projectURL: URL?,
        displayName: String?,
        canonicalAccession: String?,
        equivalentAccessions: [String],
        argv: [String],
        workflowName: String,
        toolVersion: String
    ) {
        self.bedURL = bedURL
        self.fastaURL = fastaURL
        self.attachments = attachments
        self.outputURL = outputURL
        self.projectURL = projectURL
        self.displayName = displayName
        self.canonicalAccession = canonicalAccession
        self.equivalentAccessions = equivalentAccessions
        self.argv = argv
        self.workflowName = workflowName
        self.toolVersion = toolVersion
    }
}

public struct PrimerSchemeImportResult: Sendable {
    public let bundleURL: URL
}

public enum PrimerSchemeImportError: Error, LocalizedError, Sendable {
    case emptyName
    case missingBED(URL)
    case missingFASTA(URL)
    case unreadableBED(String)
    case emptyCanonicalAccession
    case bundleAlreadyExists(URL)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Give the primer scheme a file-safe output name ending in .lungfishprimers."
        case .missingBED(let url):
            return "Primer BED file not found: \(url.path)"
        case .missingFASTA(let url):
            return "Primer FASTA file not found: \(url.path)"
        case .unreadableBED(let reason):
            return "Could not read the primer BED: \(reason)"
        case .emptyCanonicalAccession:
            return "Could not infer a reference accession from the BED. Pass --reference-accession explicitly."
        case .bundleAlreadyExists(let url):
            return "A primer scheme bundle already exists at \(url.path)."
        case .writeFailed(let reason):
            return "Failed to write the primer-scheme bundle: \(reason)"
        }
    }
}

public enum PrimerSchemeImportService {
    @discardableResult
    public static func importBundle(request: PrimerSchemeImportRequest) throws -> PrimerSchemeImportResult {
        let started = Date()
        let fm = FileManager.default
        guard fm.fileExists(atPath: request.bedURL.path) else {
            throw PrimerSchemeImportError.missingBED(request.bedURL)
        }
        if let fastaURL = request.fastaURL, !fm.fileExists(atPath: fastaURL.path) {
            throw PrimerSchemeImportError.missingFASTA(fastaURL)
        }

        let parsedBED: ParsedBED
        do {
            parsedBED = try parseBED(request.bedURL)
        } catch let error as PrimerSchemeImportError {
            throw error
        } catch {
            throw PrimerSchemeImportError.unreadableBED(error.localizedDescription)
        }

        let bundleURL = try resolvedBundleURL(outputURL: request.outputURL, projectURL: request.projectURL)
        let safeName = bundleURL.deletingPathExtension().lastPathComponent
        guard !safeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PrimerSchemeImportError.emptyName
        }
        guard !fm.fileExists(atPath: bundleURL.path) else {
            throw PrimerSchemeImportError.bundleAlreadyExists(bundleURL)
        }

        let canonical = (request.canonicalAccession?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? parsedBED.inferredReferenceAccession
        guard let canonical, !canonical.isEmpty else {
            throw PrimerSchemeImportError.emptyCanonicalAccession
        }

        do {
            try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            try fm.copyItem(at: request.bedURL, to: bundleURL.appendingPathComponent("primers.bed"))
            if let fastaURL = request.fastaURL {
                try fm.copyItem(at: fastaURL, to: bundleURL.appendingPathComponent("primers.fasta"))
            }
            if !request.attachments.isEmpty {
                let attachmentsDir = bundleURL.appendingPathComponent("attachments", isDirectory: true)
                try fm.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
                for attachment in request.attachments {
                    try fm.copyItem(at: attachment, to: attachmentsDir.appendingPathComponent(attachment.lastPathComponent))
                }
            }

            let references = referenceAccessions(
                canonical: canonical,
                equivalents: request.equivalentAccessions
            )
            let manifest = PrimerSchemeManifest(
                schemaVersion: 1,
                name: safeName,
                displayName: request.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? safeName,
                description: nil,
                organism: nil,
                referenceAccessions: references,
                primerCount: parsedBED.primerCount,
                ampliconCount: parsedBED.ampliconCount,
                source: "imported",
                sourceURL: nil,
                version: nil,
                created: started,
                imported: Date(),
                attachments: request.attachments.isEmpty
                    ? nil
                    : request.attachments.map { .init(path: "attachments/\($0.lastPathComponent)", description: nil) }
            )
            try writeJSON(manifest, to: bundleURL.appendingPathComponent("manifest.json"))
            try writeMarkdownProvenance(
                request: request,
                bundleURL: bundleURL,
                canonicalAccession: canonical,
                started: started
            )
            try writeWorkflowProvenance(
                request: request,
                bundleURL: bundleURL,
                canonicalAccession: canonical,
                started: started
            )
        } catch let error as PrimerSchemeImportError {
            throw error
        } catch {
            try? fm.removeItem(at: bundleURL)
            throw PrimerSchemeImportError.writeFailed(error.localizedDescription)
        }

        return PrimerSchemeImportResult(bundleURL: bundleURL)
    }

    public static func parseCounts(bedURL: URL) throws -> (primerCount: Int, ampliconCount: Int) {
        let parsed = try parseBED(bedURL)
        return (parsed.primerCount, parsed.ampliconCount)
    }

    private static func resolvedBundleURL(outputURL: URL, projectURL: URL?) throws -> URL {
        let output = outputURL.pathExtension == "lungfishprimers"
            ? outputURL
            : outputURL.appendingPathExtension("lungfishprimers")

        if let projectURL {
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .standardizedFileURL
            let parent = output.deletingLastPathComponent().standardizedFileURL
            if parent == cwd {
                let folder = try PrimerSchemesFolder.ensureFolder(in: projectURL)
                return folder.appendingPathComponent(output.lastPathComponent, isDirectory: true)
            }
        }

        if output.path.hasPrefix("/") {
            return output.standardizedFileURL
        }

        if let projectURL {
            let folder = try PrimerSchemesFolder.ensureFolder(in: projectURL)
            return folder.appendingPathComponent(output.lastPathComponent, isDirectory: true)
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(output.path, isDirectory: true)
            .standardizedFileURL
    }

    private static func referenceAccessions(
        canonical: String,
        equivalents: [String]
    ) -> [PrimerSchemeManifest.ReferenceAccession] {
        let cleanedEquivalents = equivalents
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != canonical }
        return [.init(accession: canonical, canonical: true, equivalent: false)]
            + cleanedEquivalents.map { .init(accession: $0, canonical: false, equivalent: true) }
    }

    private static func parseBED(_ bedURL: URL) throws -> ParsedBED {
        let content: String
        do {
            content = try String(contentsOf: bedURL, encoding: .utf8)
        } catch {
            throw PrimerSchemeImportError.unreadableBED(error.localizedDescription)
        }
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }
        var ampliconNames = Set<String>()
        var inferredReference: String?

        for line in lines {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if inferredReference == nil, let chrom = columns.first?.trimmingCharacters(in: .whitespacesAndNewlines), !chrom.isEmpty {
                inferredReference = chrom
            }
            guard columns.count >= 4 else { continue }
            ampliconNames.insert(normalizedAmpliconName(columns[3]))
        }

        return ParsedBED(
            primerCount: lines.count,
            ampliconCount: ampliconNames.count,
            inferredReferenceAccession: inferredReference
        )
    }

    private static func normalizedAmpliconName(_ raw: String) -> String {
        var name = raw
        if name.hasSuffix("_LEFT") {
            name = String(name.dropLast("_LEFT".count))
        } else if name.hasSuffix("_RIGHT") {
            name = String(name.dropLast("_RIGHT".count))
        }
        if let dashIndex = name.lastIndex(of: "-"),
           name.distance(from: dashIndex, to: name.endIndex) <= 3,
           name[name.index(after: dashIndex)...].allSatisfy(\.isNumber) {
            name = String(name[..<dashIndex])
        }
        return name
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func writeMarkdownProvenance(
        request: PrimerSchemeImportRequest,
        bundleURL: URL,
        canonicalAccession: String,
        started: Date
    ) throws {
        let command = request.argv.map(shellEscape).joined(separator: " ")
        let text = """
        # PROVENANCE

        Workflow: \(request.workflowName)
        Version: \(request.toolVersion)
        Command: \(command)
        Started: \(ISO8601DateFormatter().string(from: started))
        BED source: \(request.bedURL.path)
        FASTA source: \(request.fastaURL?.path ?? "not provided")
        Output bundle: \(bundleURL.path)
        Reference accession: \(canonicalAccession)
        Exit status: 0
        """
        try text.write(to: bundleURL.appendingPathComponent("PROVENANCE.md"), atomically: true, encoding: .utf8)
    }

    private static func writeWorkflowProvenance(
        request: PrimerSchemeImportRequest,
        bundleURL: URL,
        canonicalAccession: String,
        started: Date
    ) throws {
        let now = Date()
        let outputURLs = [
            bundleURL.appendingPathComponent("manifest.json"),
            bundleURL.appendingPathComponent("primers.bed"),
            request.fastaURL == nil ? nil : bundleURL.appendingPathComponent("primers.fasta"),
            bundleURL.appendingPathComponent("PROVENANCE.md"),
        ].compactMap { $0 }
        let inputURLs = [request.bedURL, request.fastaURL].compactMap { $0 } + request.attachments
        let step = StepExecution(
            toolName: request.workflowName,
            toolVersion: request.toolVersion,
            command: request.argv,
            inputs: inputURLs.map { ProvenanceRecorder.fileRecord(url: $0, role: .input) },
            outputs: outputURLs.map { ProvenanceRecorder.fileRecord(url: $0, role: .output) },
            exitCode: 0,
            wallTime: now.timeIntervalSince(started),
            stderr: nil,
            startTime: started,
            endTime: now
        )
        var run = WorkflowRun(
            name: request.workflowName,
            startTime: started,
            endTime: now,
            status: .completed,
            parameters: [
                "bed": .file(request.bedURL),
                "fasta": request.fastaURL.map(ParameterValue.file) ?? .null,
                "output": .file(bundleURL),
                "project": request.projectURL.map(ParameterValue.file) ?? .null,
                "referenceAccession": .string(canonicalAccession),
                "displayName": .string(request.displayName?.nilIfEmpty ?? bundleURL.deletingPathExtension().lastPathComponent),
                "fastaIncluded": .boolean(request.fastaURL != nil),
                "attachmentCount": .integer(request.attachments.count),
            ]
        )
        run.steps = [step]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(run).write(
            to: bundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            options: .atomic
        )
    }

    private static func shellEscape(_ argument: String) -> String {
        if argument.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./:-=")
        if argument.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct ParsedBED {
    let primerCount: Int
    let ampliconCount: Int
    let inferredReferenceAccession: String?
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

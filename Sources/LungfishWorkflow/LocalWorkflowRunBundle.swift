import Foundation

public struct LocalWorkflowInputBinding: Codable, Sendable, Equatable {
    public let path: String
    public let sha256: String?
    public let sizeBytes: UInt64?
    public let role: FileRole

    public init(url: URL, role: FileRole = .input) {
        let record = ProvenanceRecorder.fileRecord(url: url.standardizedFileURL, role: role)
        self.path = record.path
        self.sha256 = record.sha256
        self.sizeBytes = record.sizeBytes
        self.role = record.role
    }
}

public struct LocalWorkflowRunStatusEvent: Codable, Sendable, Equatable {
    public let status: NFCoreRunExecutionStatus
    public let timestamp: Date

    public init(status: NFCoreRunExecutionStatus, timestamp: Date = Date()) {
        self.status = status
        self.timestamp = timestamp
    }
}

public struct LocalWorkflowProcessLaunch: Sendable, Equatable {
    public let executableName: String
    public let arguments: [String]
    public let workingDirectory: URL

    public init(executableName: String, arguments: [String], workingDirectory: URL) {
        self.executableName = executableName
        self.arguments = arguments
        self.workingDirectory = workingDirectory.standardizedFileURL
    }
}

public struct LocalWorkflowRunBundleManifest: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let workflowName: String
    public let workflowDisplayName: String
    public let workflowPath: String
    public let engine: WorkflowEngineType
    public let appVersion: String?
    public let appBuildVersion: String?
    public let params: [String: String]
    public let inputBindings: [LocalWorkflowInputBinding]
    public let outputDirectoryName: String
    public let commandPreview: String
    public let resume: Bool
    public let workDirectoryPath: String?
    public let executionStatus: NFCoreRunExecutionStatus
    public let statusHistory: [LocalWorkflowRunStatusEvent]
    public let startedAt: Date?
    public let completedAt: Date?
    public let exitCode: Int32?
    public let stdoutLogPath: String?
    public let stderrLogPath: String?
    public let createdAt: Date

    public init(
        request: LocalWorkflowRunRequest,
        executionStatus: NFCoreRunExecutionStatus = .prepared,
        statusHistory: [LocalWorkflowRunStatusEvent]? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        exitCode: Int32? = nil,
        stdoutLogPath: String? = "logs/stdout.log",
        stderrLogPath: String? = "logs/stderr.log",
        createdAt: Date = Date()
    ) {
        self.schemaVersion = Self.schemaVersion
        self.workflowName = request.workflowName
        self.workflowDisplayName = request.workflowDisplayName
        self.workflowPath = request.workflowURL.path
        self.engine = request.engine
        self.appVersion = Self.hostAppVersion
        self.appBuildVersion = Self.hostAppBuildVersion
        self.params = request.effectiveParams
        self.inputBindings = request.inputURLs.map { LocalWorkflowInputBinding(url: $0) }
        self.outputDirectoryName = request.outputDirectory.lastPathComponent
        self.commandPreview = request.commandPreview
        self.resume = request.resume
        self.workDirectoryPath = request.workDirectory?.path
        self.executionStatus = executionStatus
        self.statusHistory = statusHistory ?? [LocalWorkflowRunStatusEvent(status: executionStatus, timestamp: createdAt)]
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.exitCode = exitCode
        self.stdoutLogPath = stdoutLogPath
        self.stderrLogPath = stderrLogPath
        self.createdAt = createdAt
    }

    private static var hostAppVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private static var hostAppBuildVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
}

public enum LocalWorkflowRunBundleStore {
    public static let directoryExtension = NFCoreRunBundleStore.directoryExtension
    private static let manifestFilename = "manifest.json"

    public static func write(_ manifest: LocalWorkflowRunBundleManifest, to bundleURL: URL) throws {
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try createSubdirectory("logs", in: bundleURL)
        try createSubdirectory("reports", in: bundleURL)
        try createSubdirectory("outputs", in: bundleURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: bundleURL.appendingPathComponent(manifestFilename), options: .atomic)
    }

    public static func read(from bundleURL: URL) throws -> LocalWorkflowRunBundleManifest {
        let data = try Data(contentsOf: bundleURL.appendingPathComponent(manifestFilename))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LocalWorkflowRunBundleManifest.self, from: data)
    }

    private static func createSubdirectory(_ name: String, in bundleURL: URL) throws {
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true
        )
    }
}

public struct LocalWorkflowRunRequest: Sendable, Codable, Equatable {
    public let workflowURL: URL
    public let engine: WorkflowEngineType
    public let inputURLs: [URL]
    public let outputDirectory: URL
    public let params: [String: String]
    public let resume: Bool
    public let workDirectory: URL?
    public let cpus: Int?
    public let memory: String?

    public var workflowName: String {
        let stem = workflowURL.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? workflowURL.lastPathComponent : stem
    }

    public var workflowDisplayName: String {
        "Local \(engine.displayName) workflow"
    }

    public var effectiveParams: [String: String] {
        var merged = engineParameters
        switch engine {
        case .snakemake:
            merged["cores"] = cpus.map(String.init) ?? "all"
        default:
            if let cpus {
                merged["cpus"] = String(cpus)
            }
        }
        if let memory {
            merged["memory"] = memory
        }
        return merged
    }

    private var engineParameters: [String: String] {
        var merged = params
        if !inputURLs.isEmpty {
            merged["input"] = inputURLs.map(\.path).joined(separator: ",")
        }
        merged["outdir"] = outputDirectory.path
        return merged
    }

    public var processLaunch: LocalWorkflowProcessLaunch {
        switch engine {
        case .nextflow:
            var arguments = ["run", workflowURL.path]
            if resume {
                arguments.append("-resume")
            }
            if let workDirectory {
                arguments += ["-work-dir", workDirectory.path]
            }
            for key in engineParameters.keys.sorted() {
                guard let value = engineParameters[key], !value.isEmpty else { continue }
                arguments += ["--\(key)", value]
            }
            return LocalWorkflowProcessLaunch(
                executableName: "nextflow",
                arguments: arguments,
                workingDirectory: outputDirectory
            )
        case .snakemake:
            var arguments = [
                "--snakefile", workflowURL.path,
                "--directory", outputDirectory.path,
                "--cores", cpus.map(String.init) ?? "all",
            ]
            let configValues = engineParameters.keys.sorted().compactMap { key -> String? in
                guard let value = engineParameters[key], !value.isEmpty else { return nil }
                return "\(key)=\(value)"
            }
            if !configValues.isEmpty {
                arguments.append("--config")
                arguments.append(contentsOf: configValues)
            }
            return LocalWorkflowProcessLaunch(
                executableName: "snakemake",
                arguments: arguments,
                workingDirectory: outputDirectory
            )
        default:
            return LocalWorkflowProcessLaunch(
                executableName: engine.executableName,
                arguments: [workflowURL.path],
                workingDirectory: outputDirectory
            )
        }
    }

    public var commandPreview: String {
        let launch = processLaunch
        return ([launch.executableName] + launch.arguments).map(shellEscape).joined(separator: " ")
    }

    public init(
        workflowURL: URL,
        engine: WorkflowEngineType? = nil,
        inputURLs: [URL] = [],
        outputDirectory: URL,
        params: [String: String] = [:],
        resume: Bool = false,
        workDirectory: URL? = nil,
        cpus: Int? = nil,
        memory: String? = nil
    ) {
        let standardizedWorkflow = workflowURL.standardizedFileURL
        self.workflowURL = standardizedWorkflow
        self.engine = engine ?? WorkflowDefinition.detectEngineType(from: standardizedWorkflow)
        self.inputURLs = inputURLs.map(\.standardizedFileURL)
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.params = params
        self.resume = resume
        self.workDirectory = workDirectory?.standardizedFileURL
        self.cpus = cpus
        self.memory = memory
    }

    public func manifest(
        createdAt: Date = Date(),
        executionStatus: NFCoreRunExecutionStatus = .prepared,
        statusHistory: [LocalWorkflowRunStatusEvent]? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        exitCode: Int32? = nil,
        stdoutLogPath: String? = "logs/stdout.log",
        stderrLogPath: String? = "logs/stderr.log"
    ) -> LocalWorkflowRunBundleManifest {
        LocalWorkflowRunBundleManifest(
            request: self,
            executionStatus: executionStatus,
            statusHistory: statusHistory,
            startedAt: startedAt,
            completedAt: completedAt,
            exitCode: exitCode,
            stdoutLogPath: stdoutLogPath,
            stderrLogPath: stderrLogPath,
            createdAt: createdAt
        )
    }

    public func cliArguments(bundlePath: URL, prepareOnly: Bool = false) -> [String] {
        var args = [
            "workflow",
            "run",
            workflowURL.path,
            "--results-dir",
            outputDirectory.path,
            "--bundle-path",
            bundlePath.path,
        ]
        for inputURL in inputURLs {
            args += ["--input", inputURL.path]
        }
        for key in params.keys.sorted() {
            guard let value = params[key], !value.isEmpty else { continue }
            args += ["--param", "\(key)=\(value)"]
        }
        if resume {
            args.append("--resume")
        }
        if let workDirectory {
            args += ["--workdir", workDirectory.path]
        }
        if let cpus {
            args += ["--cpus", String(cpus)]
        }
        if let memory {
            args += ["--memory", memory]
        }
        if prepareOnly {
            args.append("--prepare-only")
        }
        return args
    }
}

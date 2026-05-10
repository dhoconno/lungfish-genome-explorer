import Foundation

public enum NFCoreExecutor: String, Codable, Sendable, Equatable {
    case docker
    case conda
    case local
}

public enum NFCoreRunExecutionStatus: String, Codable, Sendable, Equatable {
    case prepared
    case running
    case completed
    case failed
    case cancelled
}

public struct NFCoreRunBundleManifest: Codable, Sendable, Equatable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let workflowName: String
    public let workflowDisplayName: String
    public let workflowDescription: String
    public let version: String
    public let workflowPinnedVersion: String?
    public let appVersion: String?
    public let appBuildVersion: String?
    public let executor: NFCoreExecutor
    public let params: [String: String]
    public let outputDirectoryName: String
    public let resultSurfaces: [NFCoreResultSurface]
    public let adapterIDs: [String]
    public let commandPreview: String
    public let resume: Bool
    public let workDirectoryPath: String?
    public let executionStatus: NFCoreRunExecutionStatus
    public let startedAt: Date?
    public let completedAt: Date?
    public let exitCode: Int32?
    public let stdoutLogPath: String?
    public let stderrLogPath: String?
    public let createdAt: Date

    public init(
        workflow: NFCoreSupportedWorkflow,
        version: String,
        executor: NFCoreExecutor,
        params: [String: String],
        outputDirectoryName: String,
        workflowPinnedVersion: String? = nil,
        appVersion: String? = nil,
        appBuildVersion: String? = nil,
        resume: Bool = false,
        workDirectory: URL? = nil,
        executionStatus: NFCoreRunExecutionStatus = .prepared,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        exitCode: Int32? = nil,
        stdoutLogPath: String? = nil,
        stderrLogPath: String? = nil,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = Self.schemaVersion
        self.workflowName = workflow.name
        self.workflowDisplayName = workflow.fullName
        self.workflowDescription = workflow.description
        self.version = version
        self.workflowPinnedVersion = workflowPinnedVersion ?? workflow.pinnedVersion
        self.appVersion = appVersion ?? Self.hostAppVersion
        self.appBuildVersion = appBuildVersion ?? Self.hostAppBuildVersion
        self.executor = executor
        self.params = params
        self.outputDirectoryName = outputDirectoryName
        self.resultSurfaces = workflow.resultSurfaces
        self.adapterIDs = workflow.supportedAdapterIDs
        self.commandPreview = NFCoreRunCommandBuilder.commandPreview(
            workflow: workflow,
            version: version,
            executor: executor,
            resume: resume,
            workDirectory: workDirectory,
            params: params
        )
        self.resume = resume
        self.workDirectoryPath = workDirectory?.standardizedFileURL.path
        self.executionStatus = executionStatus
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.exitCode = exitCode
        self.stdoutLogPath = stdoutLogPath
        self.stderrLogPath = stderrLogPath
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case workflowName
        case workflowDisplayName
        case workflowDescription
        case version
        case workflowPinnedVersion
        case appVersion
        case appBuildVersion
        case executor
        case params
        case outputDirectoryName
        case resultSurfaces
        case adapterIDs
        case commandPreview
        case resume
        case workDirectoryPath
        case executionStatus
        case startedAt
        case completedAt
        case exitCode
        case stdoutLogPath
        case stderrLogPath
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        workflowName = try container.decode(String.self, forKey: .workflowName)
        workflowDisplayName = try container.decode(String.self, forKey: .workflowDisplayName)
        workflowDescription = try container.decode(String.self, forKey: .workflowDescription)
        version = try container.decode(String.self, forKey: .version)
        workflowPinnedVersion = try container.decodeIfPresent(String.self, forKey: .workflowPinnedVersion)
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
        appBuildVersion = try container.decodeIfPresent(String.self, forKey: .appBuildVersion)
        executor = try container.decode(NFCoreExecutor.self, forKey: .executor)
        params = try container.decode([String: String].self, forKey: .params)
        outputDirectoryName = try container.decode(String.self, forKey: .outputDirectoryName)
        resultSurfaces = try container.decode([NFCoreResultSurface].self, forKey: .resultSurfaces)
        adapterIDs = try container.decode([String].self, forKey: .adapterIDs)
        commandPreview = try container.decode(String.self, forKey: .commandPreview)
        resume = try container.decodeIfPresent(Bool.self, forKey: .resume) ?? commandPreview.contains("-resume")
        workDirectoryPath = try container.decodeIfPresent(String.self, forKey: .workDirectoryPath)
        executionStatus = try container.decodeIfPresent(NFCoreRunExecutionStatus.self, forKey: .executionStatus) ?? .prepared
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        stdoutLogPath = try container.decodeIfPresent(String.self, forKey: .stdoutLogPath)
        stderrLogPath = try container.decodeIfPresent(String.self, forKey: .stderrLogPath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    private static var hostAppVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private static var hostAppBuildVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
}

public enum NFCoreRunCommandBuilder {
    public static func commandPreview(
        workflow: NFCoreSupportedWorkflow,
        version: String,
        executor: NFCoreExecutor,
        resume: Bool = false,
        workDirectory: URL? = nil,
        params: [String: String]
    ) -> String {
        var parts = ["nextflow", "run", workflow.fullName]
        if !version.isEmpty {
            parts += ["-r", version]
        }
        if resume {
            parts.append("-resume")
        }
        if let workDirectory {
            parts.append("-work-dir")
            parts.append(shellEscape(workDirectory.path))
        }
        parts += ["-profile", executor.rawValue]
        for key in params.keys.sorted() {
            guard let value = params[key], !value.isEmpty else { continue }
            parts.append("--\(key)")
            parts.append(shellEscape(value))
        }
        return parts.joined(separator: " ")
    }
}

public enum NFCoreRunBundleStore {
    public static let directoryExtension = "lungfishrun"
    private static let manifestFilename = "manifest.json"

    public static func write(_ manifest: NFCoreRunBundleManifest, to bundleURL: URL) throws {
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

    public static func read(from bundleURL: URL) throws -> NFCoreRunBundleManifest {
        let data = try Data(contentsOf: bundleURL.appendingPathComponent(manifestFilename))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NFCoreRunBundleManifest.self, from: data)
    }

    private static func createSubdirectory(_ name: String, in bundleURL: URL) throws {
        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent(name, isDirectory: true),
            withIntermediateDirectories: true
        )
    }
}

public protocol NFCoreResultAdapter: Sendable {
    var id: String { get }
    var supportedSurfaces: [NFCoreResultSurface] { get }
    func canImport(manifest: NFCoreRunBundleManifest, outputDirectory: URL) -> Bool
}

public struct GenericNFCoreReportAdapter: NFCoreResultAdapter {
    public let id = "generic-report"
    public let supportedSurfaces: [NFCoreResultSurface] = [.reports]

    public init() {}

    public func canImport(manifest: NFCoreRunBundleManifest, outputDirectory: URL) -> Bool {
        manifest.adapterIDs.contains(id)
            || manifest.resultSurfaces.contains(.reports)
            || FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("multiqc_report.html").path)
    }
}

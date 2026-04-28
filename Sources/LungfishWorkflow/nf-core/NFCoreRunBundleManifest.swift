import Foundation

public enum NFCoreExecutor: String, Codable, Sendable, Equatable {
    case docker
    case conda
    case local
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
        self.createdAt = createdAt
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
            parts.append(shellEscaped(workDirectory.path))
        }
        parts += ["-profile", executor.rawValue]
        for key in params.keys.sorted() {
            guard let value = params[key], !value.isEmpty else { continue }
            parts.append("--\(key)")
            parts.append(shellEscaped(value))
        }
        return parts.joined(separator: " ")
    }

    private static func shellEscaped(_ value: String) -> String {
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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

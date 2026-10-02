import CryptoKit
import Foundation
import LungfishCore
import SQLite3

public struct PhylogeneticTreeProvenance: Codable, Sendable, Equatable {
    public struct ToolIdentity: Codable, Sendable, Equatable {
        public let name: String
        public let version: String
        public let kind: String?
    }

    public struct Options: Codable, Sendable, Equatable {
        public let explicit: [String: String]
        public let defaults: [String: String]
        public let resolvedDefaults: [String: String]
    }

    public struct RuntimeIdentity: Codable, Sendable, Equatable {
        public let appVersion: String
        public let executablePath: String
        public let processIdentifier: Int
        public let operatingSystemVersion: String
        public let architecture: String
        public let gitRevision: String?
        public let user: String?
        public let pluginPack: String?
        public let operatingSystem: String
        public let swiftRuntime: String
        public let condaEnvironment: String?
        public let condaPrefix: String?
        public let containerImage: String?
        public let containerDigest: String?

        public static var current: RuntimeIdentity {
            let environment = ProcessInfo.processInfo.environment
            return RuntimeIdentity(
                appVersion: PhylogeneticTreeBundleImporter.toolVersion,
                executablePath: Bundle.main.executablePath ?? CommandLine.arguments.first ?? "unknown",
                processIdentifier: Int(ProcessInfo.processInfo.processIdentifier),
                operatingSystemVersion: Self.currentHostOS,
                architecture: Self.currentArchitecture,
                gitRevision: nil,
                user: nil,  // Records in a project do not name the account.
                pluginPack: nil,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                swiftRuntime: "swift",
                condaEnvironment: environment["CONDA_DEFAULT_ENV"],
                condaPrefix: environment["CONDA_PREFIX"],
                containerImage: nil,
                containerDigest: nil
            )
        }

        private static var currentArchitecture: String {
            #if arch(arm64)
            return "arm64"
            #elseif arch(x86_64)
            return "x86_64"
            #else
            return "unknown"
            #endif
        }

        private static var currentHostOS: String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            return "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(currentArchitecture))"
        }

    }

    public struct FileRecord: Codable, Sendable, Equatable {
        public let path: String
        public let sha256: String
        public let checksumSHA256: String
        public let fileSizeBytes: Int64
        public let fileSize: UInt64
        public let role: String?

        public init(path: String, sha256: String, fileSizeBytes: Int64, role: String? = nil) {
            self.path = path
            self.sha256 = sha256
            checksumSHA256 = sha256
            self.fileSizeBytes = fileSizeBytes
            fileSize = UInt64(max(fileSizeBytes, 0))
            self.role = role
        }
    }

    public struct Step: Codable, Sendable, Equatable {
        public let id: UUID
        public let toolName: String
        public let toolVersion: String
        public let argv: [String]
        public let durableReplayArgv: [String]?
        public let reproducibleCommand: String
        public let inputs: [FileRecord]
        public let outputs: [FileRecord]
        public let exitStatus: Int
        public let wallTimeSeconds: TimeInterval
        public let stderr: String?
        public let dependsOn: [UUID]
        public let startedAt: Date
        public let completedAt: Date
    }

    public let schemaVersion: Int
    public let id: UUID
    public let createdAt: Date
    public let workflowName: String
    public let workflowVersion: String
    public let toolName: String
    public let toolVersion: String
    public let tool: ToolIdentity
    public let argv: [String]
    public let durableReplayArgv: [String]?
    public let reproducibleCommand: String
    public let command: String
    public let options: Options
    public let runtime: RuntimeIdentity
    public let runtimeIdentity: RuntimeIdentity
    public let files: [FileRecord]
    public let input: FileRecord
    public let output: FileRecord
    public let outputs: [FileRecord]
    public let steps: [Step]
    public let checksums: [String: String]
    public let fileSizes: [String: Int64]
    public let exitStatus: Int
    public let wallTimeSeconds: TimeInterval
    public let warnings: [String]
    public let stderr: String?
    public let signatures: [String]

    public init(
        toolName: String,
        toolVersion: String,
        createdAt: Date = Date(),
        argv: [String],
        durableReplayArgv: [String]? = nil,
        command: String,
        options: [String: String],
        runtime: RuntimeIdentity,
        input: FileRecord,
        output: FileRecord,
        checksums: [String: String],
        fileSizes: [String: Int64],
        exitStatus: Int,
        wallTimeSeconds: TimeInterval,
        warnings: [String],
        stderr: String?
    ) {
        schemaVersion = 1
        id = UUID()
        self.createdAt = createdAt
        workflowName = toolName
        workflowVersion = toolVersion
        self.toolName = toolName
        self.toolVersion = toolVersion
        tool = ToolIdentity(name: toolName, version: toolVersion, kind: CLICommandIdentity.executableName)
        self.argv = argv
        self.durableReplayArgv = durableReplayArgv
        reproducibleCommand = command
        self.command = command
        self.options = Options(
            explicit: [:],
            defaults: [
                "primaryTree": "first",
                "normalizeComments": "true",
                "writeSQLiteIndex": "true"
            ],
            resolvedDefaults: options
        )
        self.runtime = runtime
        runtimeIdentity = runtime
        self.input = FileRecord(
            path: input.path,
            sha256: input.sha256,
            fileSizeBytes: input.fileSizeBytes,
            role: "input"
        )
        self.output = FileRecord(
            path: output.path,
            sha256: output.sha256,
            fileSizeBytes: output.fileSizeBytes,
            role: "output"
        )
        let payloadOutputs = checksums.keys.sorted().map { path in
            FileRecord(
                path: path,
                sha256: checksums[path] ?? "",
                fileSizeBytes: fileSizes[path] ?? 0,
                role: "output"
            )
        }
        files = [self.input, self.output] + payloadOutputs
        outputs = [self.output] + payloadOutputs
        self.checksums = checksums
        self.fileSizes = fileSizes
        self.exitStatus = exitStatus
        self.wallTimeSeconds = wallTimeSeconds
        self.warnings = warnings
        self.stderr = stderr
        steps = [
            Step(
                id: UUID(),
                toolName: toolName,
                toolVersion: toolVersion,
                argv: argv,
                durableReplayArgv: durableReplayArgv,
                reproducibleCommand: command,
                inputs: [self.input],
                outputs: outputs,
                exitStatus: exitStatus,
                wallTimeSeconds: wallTimeSeconds,
                stderr: stderr,
                dependsOn: [],
                startedAt: createdAt,
                completedAt: createdAt.addingTimeInterval(wallTimeSeconds)
            )
        ]
        signatures = []
    }
}

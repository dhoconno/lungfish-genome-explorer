import Foundation
import LungfishCore

public enum NFCoreRunPresentationMode: Sendable, Codable, Equatable {
    case genericReport
    case customAdapter(String)
}

public struct NFCoreRunRequest: Sendable, Codable, Equatable {
    public let workflow: NFCoreSupportedWorkflow
    public let version: String
    public let executor: NFCoreExecutor
    public let inputURLs: [URL]
    public let outputDirectory: URL
    public let expectedOutputURLs: [URL]
    public let params: [String: String]
    public let resume: Bool
    public let workDirectory: URL?
    public let presentationMode: NFCoreRunPresentationMode

    public var displayTitle: String {
        "Run \(workflow.fullName)"
    }

    public var effectiveParams: [String: String] {
        var merged = params
        if !inputURLs.isEmpty {
            merged["input"] = inputURLs.map(\.path).joined(separator: ",")
        }
        merged["outdir"] = outputDirectory.path
        for parameter in Self.unsupportedStepParameters(forWorkflow: workflow.name) {
            merged[parameter] = "true"
        }
        return merged
    }

    /// Steps a pipeline cannot run on this platform, forced off wherever the
    /// command is built.
    ///
    /// Lungfish ships for Apple Silicon only. viralrecon pins Freyja to an
    /// amd64-only container whose bootstrap workers are killed under Rosetta,
    /// which fails the whole run after every other output has been written.
    /// Freyja itself is fine here: Lungfish runs it natively from the
    /// wastewater-surveillance pack, where bioconda ships an arm64 build. Only
    /// this pipeline's containerised copy is unusable.
    static func unsupportedStepParameters(forWorkflow workflowName: String) -> [String] {
        guard workflowName == "viralrecon" else { return [] }
        return ["skip_freyja", "skip_freyja_boot"]
    }

    /// Executors that reach a working pipeline run.
    ///
    /// Only Docker does. The executor is passed straight through as
    /// `-profile`, and viralrecon 3.0.0 defines no `local` profile, so that
    /// value aborts before any work happens. `conda` names a real profile but
    /// Lungfish never enables Nextflow's conda support for this workflow, so it
    /// can only succeed by accident on a user-provisioned machine.
    ///
    /// The cases remain in `NFCoreExecutor` because saved run bundles may record
    /// them and removing the cases would break decoding.
    public enum UnsupportedExecutorError: Error, LocalizedError, Equatable {
        case unsupported(NFCoreExecutor)

        public var errorDescription: String? {
            switch self {
            case .unsupported(let executor):
                return "The \(executor.rawValue) executor is not supported. Use Docker."
            }
        }
    }

    public func validateExecutorSupported() throws {
        guard executor == .docker else {
            throw UnsupportedExecutorError.unsupported(executor)
        }
    }

    /// Environment overrides the engine needs for the requested pipeline release.
    public var launchEnvironment: [String: String] {
        workflow.launchEnvironment(forVersion: version)
    }

    public var nextflowArguments: [String] {
        var args = ["run", workflow.fullName]
        if !version.isEmpty {
            args += ["-r", version]
        }
        if resume {
            args.append("-resume")
        }
        if let workDirectory {
            args += ["-work-dir", workDirectory.path]
        }
        args += ["-profile", executor.rawValue]

        for key in effectiveParams.keys.sorted() {
            guard let value = effectiveParams[key], !value.isEmpty else { continue }
            args += ["--\(key)", value]
        }
        return args
    }

    public var commandPreview: String {
        NFCoreRunCommandBuilder.commandPreview(
            workflow: workflow,
            version: version,
            executor: executor,
            resume: resume,
            workDirectory: workDirectory,
            params: effectiveParams
        )
    }

    public func cliArguments(bundlePath: URL, prepareOnly: Bool = false) -> [String] {
        var args = [
            "workflow",
            "run",
            workflow.fullName,
            "--executor",
            executor.rawValue,
            "--results-dir",
            outputDirectory.path,
            "--bundle-path",
            bundlePath.path,
        ]
        if !version.isEmpty {
            args += ["--version", version]
        }
        for inputURL in inputURLs {
            args += ["--input", inputURL.path]
        }
        for outputURL in expectedOutputURLs {
            args += ["--expected-output", outputURL.path]
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
        if prepareOnly {
            args.append("--prepare-only")
        }
        return args
    }

    public func cliCommandPreview(bundlePath: URL, executableName: String = CLICommandIdentity.executableName) -> String {
        ([executableName] + cliArguments(bundlePath: bundlePath)).map(shellEscape).joined(separator: " ")
    }

    public init(
        workflow: NFCoreSupportedWorkflow,
        version: String,
        executor: NFCoreExecutor,
        inputURLs: [URL],
        outputDirectory: URL,
        expectedOutputURLs: [URL] = [],
        params: [String: String] = [:],
        resume: Bool = false,
        workDirectory: URL? = nil,
        presentationMode: NFCoreRunPresentationMode = .genericReport
    ) {
        self.workflow = workflow
        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        self.version = trimmedVersion.isEmpty ? workflow.pinnedVersion : trimmedVersion
        self.executor = executor
        self.inputURLs = inputURLs.map(\.standardizedFileURL)
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.expectedOutputURLs = expectedOutputURLs.map(\.standardizedFileURL)
        self.params = params
        self.resume = resume
        self.workDirectory = workDirectory?.standardizedFileURL
        self.presentationMode = presentationMode
    }

    public func manifest(
        createdAt: Date = Date(),
        executionStatus: NFCoreRunExecutionStatus = .prepared,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        exitCode: Int32? = nil,
        stdoutLogPath: String? = nil,
        stderrLogPath: String? = nil
    ) -> NFCoreRunBundleManifest {
        NFCoreRunBundleManifest(
            workflow: workflow,
            version: version,
            executor: executor,
            params: effectiveParams,
            outputDirectoryName: outputDirectory.lastPathComponent,
            workflowPinnedVersion: workflow.pinnedVersion,
            workflowGithubReleaseVersion: version,
            resume: resume,
            workDirectory: workDirectory,
            executionStatus: executionStatus,
            startedAt: startedAt,
            completedAt: completedAt,
            exitCode: exitCode,
            stdoutLogPath: stdoutLogPath,
            stderrLogPath: stderrLogPath,
            createdAt: createdAt
        )
    }

}

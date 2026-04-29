import Foundation

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
        return merged
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

    public func cliCommandPreview(bundlePath: URL, executableName: String = "lungfish-cli") -> String {
        ([executableName] + cliArguments(bundlePath: bundlePath)).map(shellEscape).joined(separator: " ")
    }

    public init(
        workflow: NFCoreSupportedWorkflow,
        version: String,
        executor: NFCoreExecutor,
        inputURLs: [URL],
        outputDirectory: URL,
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
        self.params = params
        self.resume = resume
        self.workDirectory = workDirectory?.standardizedFileURL
        self.presentationMode = presentationMode
    }

    public func manifest(createdAt: Date = Date()) -> NFCoreRunBundleManifest {
        NFCoreRunBundleManifest(
            workflow: workflow,
            version: version,
            executor: executor,
            params: effectiveParams,
            outputDirectoryName: outputDirectory.lastPathComponent,
            workflowPinnedVersion: workflow.pinnedVersion,
            resume: resume,
            workDirectory: workDirectory,
            createdAt: createdAt
        )
    }

}

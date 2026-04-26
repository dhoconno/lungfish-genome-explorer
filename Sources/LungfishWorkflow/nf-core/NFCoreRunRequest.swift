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
            params: effectiveParams
        )
    }

    public init(
        workflow: NFCoreSupportedWorkflow,
        version: String,
        executor: NFCoreExecutor,
        inputURLs: [URL],
        outputDirectory: URL,
        params: [String: String] = [:],
        presentationMode: NFCoreRunPresentationMode = .genericReport
    ) {
        self.workflow = workflow
        self.version = version
        self.executor = executor
        self.inputURLs = inputURLs.map(\.standardizedFileURL)
        self.outputDirectory = outputDirectory.standardizedFileURL
        self.params = params
        self.presentationMode = presentationMode
    }

    public func manifest(createdAt: Date = Date()) -> NFCoreRunBundleManifest {
        NFCoreRunBundleManifest(
            workflow: workflow,
            version: version,
            executor: executor,
            params: effectiveParams,
            outputDirectoryName: outputDirectory.lastPathComponent,
            createdAt: createdAt
        )
    }
}

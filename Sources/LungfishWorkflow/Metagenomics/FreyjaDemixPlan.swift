import Foundation

public struct FreyjaDemixConfiguration: Sendable, Equatable {
    public let variantsURL: URL
    public let depthsURL: URL
    public let outputDirectory: URL
    public let sampleName: String?
    public let extraArguments: [String]

    public init(
        variantsURL: URL,
        depthsURL: URL,
        outputDirectory: URL,
        sampleName: String? = nil,
        extraArguments: [String] = []
    ) {
        self.variantsURL = variantsURL
        self.depthsURL = depthsURL
        self.outputDirectory = outputDirectory
        self.sampleName = sampleName
        self.extraArguments = extraArguments
    }
}

public struct FreyjaDemixPlan: Sendable, Codable, Equatable {
    public let workflowName: String
    public let workflowVersion: String
    public let command: [String]
    public let shellCommand: String
    public let inputs: [FileRecord]
    public let outputs: [FileRecord]
    public let options: [String: String]
    public let resolvedDefaults: [String: String]
    public let runtimeIdentity: String
    public let packID: String
    public let toolVersion: String

    public init(
        configuration: FreyjaDemixConfiguration,
        toolVersion: String,
        runtimeIdentity: String,
        workflowVersion: String = WorkflowRun.currentAppVersion
    ) {
        let demixURL = configuration.outputDirectory.appendingPathComponent("freyja-demix.tsv")
        var command = [
            "freyja", "demix",
            configuration.variantsURL.path,
            configuration.depthsURL.path,
            "--output", demixURL.path,
        ]
        if let sampleName = configuration.sampleName,
           !sampleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            command += ["--sample", sampleName]
        }
        command += configuration.extraArguments

        self.workflowName = "lungfish freyja demix"
        self.workflowVersion = workflowVersion
        self.command = command
        self.shellCommand = command.map(shellEscape).joined(separator: " ")
        self.inputs = [
            ProvenanceRecorder.fileRecord(url: configuration.variantsURL, format: .text, role: .input),
            ProvenanceRecorder.fileRecord(url: configuration.depthsURL, format: .text, role: .input),
        ]
        self.outputs = [
            ProvenanceRecorder.fileRecord(url: demixURL, format: .text, role: .output),
        ]
        self.options = [
            "sampleName": configuration.sampleName ?? "",
            "extraArguments": jsonArrayString(configuration.extraArguments),
        ]
        self.resolvedDefaults = [
            "sampleName": "",
            "extraArguments": "[]",
        ]
        self.runtimeIdentity = runtimeIdentity
        self.packID = "wastewater-surveillance"
        self.toolVersion = toolVersion
    }
}

private func jsonArrayString(_ values: [String]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: values),
          let string = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return string
}

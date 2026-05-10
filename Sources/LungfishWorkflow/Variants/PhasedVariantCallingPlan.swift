import Foundation

public struct PhasedVariantCommand: Sendable, Codable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let environment: String

    public init(executable: String, arguments: [String], environment: String) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    public var shellCommand: String {
        ([executable] + arguments).map(shellEscape).joined(separator: " ")
    }
}

public struct PhasedVariantRuntimeIdentity: Sendable, Codable, Equatable {
    public let gatkCondaEnvironment: String
    public let whatsHapCondaEnvironment: String
    public let containerImage: String?
    public let containerDigest: String?

    public init(
        gatkCondaEnvironment: String,
        whatsHapCondaEnvironment: String,
        containerImage: String? = nil,
        containerDigest: String? = nil
    ) {
        self.gatkCondaEnvironment = gatkCondaEnvironment
        self.whatsHapCondaEnvironment = whatsHapCondaEnvironment
        self.containerImage = containerImage
        self.containerDigest = containerDigest
    }
}

public struct PhasedVariantCallingConfiguration: Sendable, Equatable {
    public let referenceFASTAURL: URL
    public let inputBAMURL: URL
    public let outputVCFURL: URL
    public let outputDirectory: URL
    public let threads: Int
    public let sampleName: String?
    public let extraGATKArguments: [String]
    public let extraWhatsHapArguments: [String]

    public init(
        referenceFASTAURL: URL,
        inputBAMURL: URL,
        outputVCFURL: URL,
        outputDirectory: URL,
        threads: Int = 1,
        sampleName: String? = nil,
        extraGATKArguments: [String] = [],
        extraWhatsHapArguments: [String] = []
    ) {
        self.referenceFASTAURL = referenceFASTAURL
        self.inputBAMURL = inputBAMURL
        self.outputVCFURL = outputVCFURL
        self.outputDirectory = outputDirectory
        self.threads = max(1, threads)
        self.sampleName = sampleName
        self.extraGATKArguments = extraGATKArguments
        self.extraWhatsHapArguments = extraWhatsHapArguments
    }
}

public struct PhasedVariantCallingPlan: Sendable, Codable, Equatable {
    public let workflowName: String
    public let workflowVersion: String
    public let commands: [PhasedVariantCommand]
    public let shellCommands: [String]
    public let inputs: [FileRecord]
    public let outputs: [FileRecord]
    public let options: [String: String]
    public let resolvedDefaults: [String: String]
    public let runtimeIdentity: PhasedVariantRuntimeIdentity
    public let packIDs: [String]
    public let toolVersions: [String: String]

    public init(
        configuration: PhasedVariantCallingConfiguration,
        gatkVersion: String,
        whatsHapVersion: String,
        runtimeIdentity: PhasedVariantRuntimeIdentity,
        workflowVersion: String = WorkflowRun.currentAppVersion
    ) {
        let unphasedVCFURL = configuration.outputDirectory
            .appendingPathComponent("gatk-unphased.vcf.gz")
        let gatkArguments = [
            "HaplotypeCaller",
            "-R", configuration.referenceFASTAURL.path,
            "-I", configuration.inputBAMURL.path,
            "-O", unphasedVCFURL.path,
            "-ERC", "NONE",
            "--native-pair-hmm-threads", String(configuration.threads),
        ] + configuration.extraGATKArguments

        var whatshapArguments = [
            "phase",
            "--reference", configuration.referenceFASTAURL.path,
            "-o", configuration.outputVCFURL.path,
        ]
        if let sampleName = configuration.sampleName,
           !sampleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            whatshapArguments += ["--sample", sampleName]
        }
        whatshapArguments += configuration.extraWhatsHapArguments
        whatshapArguments += [unphasedVCFURL.path, configuration.inputBAMURL.path]

        self.workflowName = "lungfish variants phase"
        self.workflowVersion = workflowVersion
        self.commands = [
            PhasedVariantCommand(executable: "gatk", arguments: gatkArguments, environment: "gatk-core"),
            PhasedVariantCommand(executable: "whatshap", arguments: whatshapArguments, environment: "phasing"),
        ]
        self.shellCommands = commands.map(\.shellCommand)
        self.inputs = [
            ProvenanceRecorder.fileRecord(url: configuration.referenceFASTAURL, format: .fasta, role: .reference),
            ProvenanceRecorder.fileRecord(url: configuration.inputBAMURL, format: .bam, role: .input),
        ]
        self.outputs = [
            ProvenanceRecorder.fileRecord(url: unphasedVCFURL, format: .vcf, role: .output),
            ProvenanceRecorder.fileRecord(url: configuration.outputVCFURL, format: .vcf, role: .output),
        ]
        self.options = [
            "threads": String(configuration.threads),
            "sampleName": configuration.sampleName ?? "",
            "extraGATKArguments": jsonArrayString(configuration.extraGATKArguments),
            "extraWhatsHapArguments": jsonArrayString(configuration.extraWhatsHapArguments),
        ]
        self.resolvedDefaults = [
            "emitReferenceConfidence": "NONE",
            "threads": "1",
            "sampleName": "",
            "extraGATKArguments": "[]",
            "extraWhatsHapArguments": "[]",
        ]
        self.runtimeIdentity = runtimeIdentity
        self.packIDs = ["gatk-core", "phasing"]
        self.toolVersions = [
            "gatk": gatkVersion,
            "whatshap": whatsHapVersion,
        ]
    }
}

private func jsonArrayString(_ values: [String]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: values),
          let string = String(data: data, encoding: .utf8) else {
        return "[]"
    }
    return string
}

import Foundation

struct Primer3RunInvocation: Sendable {
    let executableURL: URL?
    let inputURL: URL
    let outputURL: URL
    let workingDirectory: URL
}

struct Primer3RunReceipt: Sendable {
    let argv: [String]
    let stdout: String
    let stderr: String
    let exitStatus: Int32
    let version: String
    let runtimeIdentity: ProvenanceRuntimeIdentity
    let startedAt: Date
    let endedAt: Date
}

typealias Primer3DesignRunner = @Sendable (Primer3RunInvocation) async throws -> Primer3RunReceipt

enum Primer3NativeRunner {
    static func run(_ invocation: Primer3RunInvocation) async throws -> Primer3RunReceipt {
        let manager = CondaManager.shared
        let executable: URL
        if let override = invocation.executableURL { executable = override }
        else { executable = try await manager.toolPath(name: "primer3_core", environment: "primer3") }
        let runtime = invocation.executableURL == nil
            ? ProvenanceRuntimeIdentity(executablePath: executable.path, condaEnvironment: "primer3", condaPrefix: (await manager.environmentURL(named: "primer3")).path, pluginPack: "pcr-primer-design")
            : ProvenanceRuntimeIdentity(executablePath: executable.path, condaEnvironment: nil, condaPrefix: nil, pluginPack: nil)
        let nativeRunner = NativeToolRunner()
        let about = try await nativeRunner.runProcess(executableURL: executable, arguments: ["--about"], workingDirectory: invocation.workingDirectory, timeout: 30, toolName: "Primer3 version probe")
        guard about.exitCode == 0, let version = parseVersion(about.combinedOutput) else { throw Primer3DesignError.versionUnavailable }
        try Task.checkCancellation()
        let arguments = arguments(inputURL: invocation.inputURL, outputURL: invocation.outputURL)
        let started = Date()
        let result = try await nativeRunner.runProcess(executableURL: executable, arguments: arguments, workingDirectory: invocation.workingDirectory, toolName: "Primer3")
        return Primer3RunReceipt(argv: result.arguments, stdout: result.stdout, stderr: result.stderr, exitStatus: result.exitCode, version: version, runtimeIdentity: runtime, startedAt: started, endedAt: Date())
    }

    static func parseVersion(_ output: String) -> String? {
        guard output.lowercased().contains("primer3") || output.lowercased().contains("libprimer3") else { return nil }
        guard let range = output.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    static func arguments(inputURL: URL, outputURL: URL) -> [String] {
        ["--output=\(outputURL.path)", inputURL.path]
    }
}

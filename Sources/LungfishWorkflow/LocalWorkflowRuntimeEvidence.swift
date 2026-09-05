import Foundation

/// The selected executable and narrowly relevant resolved environment at launch time.
public struct LocalWorkflowRuntimeEvidence: Codable, Equatable, Sendable {
    public let executable: FileRecord
    public let environment: [String: String]

    public init(executable: FileRecord, environment: [String: String]) {
        self.executable = executable
        self.environment = environment
    }

    public static func capture(afterRepair launch: WorkflowEngineLaunch) -> Self? {
        guard let url = launch.resolvedExecutableURL() else { return nil }
        let record = ProvenanceRecorder.fileRecord(url: url, role: .input)
        guard record.sha256 != nil, record.sizeBytes != nil else { return nil }
        let keys: Set<String> = ["PATH", "HOME", "MAMBA_ROOT_PREFIX", "JAVA_HOME", "NXF_HOME", "NXF_ANSI_LOG"]
        return Self(executable: record, environment: launch.environment.filter { keys.contains($0.key) })
    }
}

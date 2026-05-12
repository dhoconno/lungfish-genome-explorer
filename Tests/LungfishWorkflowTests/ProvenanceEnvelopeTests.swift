import Foundation
import Testing
@testable import LungfishWorkflow

@Suite("Canonical Provenance Envelope")
struct ProvenanceEnvelopeTests {
    @Test("canonical envelope encodes documented top-level fields and compatibility aliases")
    func canonicalEncodingIncludesDocumentedFields() throws {
        let envelope = ProvenanceEnvelope.fixture(
            workflowName: "fastq.trim.fastp",
            toolName: "fastp",
            toolVersion: "0.24.1",
            argv: ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"],
            inputPath: "reads.fastq",
            outputPath: "trimmed.fastq"
        )

        let data = try ProvenanceJSON.encoder.encode(envelope)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["id"] as? String == envelope.id.uuidString)
        #expect(json["createdAt"] as? String == "1970-01-01T00:00:00Z")
        #expect(json["workflowName"] as? String == "fastq.trim.fastp")
        #expect(json["workflowVersion"] as? String == "fixture-workflow-version")
        #expect(json["toolName"] as? String == "fastp")
        #expect(json["toolVersion"] as? String == "0.24.1")
        #expect(json["tool"] is [String: Any])
        #expect(json["argv"] as? [String] == ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"])
        #expect(json["reproducibleCommand"] as? String == "fastp -i reads.fastq -o trimmed.fastq")
        #expect(json["options"] is [String: Any])
        #expect(json["runtimeIdentity"] is [String: Any])
        #expect(json["files"] is [[String: Any]])
        #expect(json["output"] is [String: Any])
        #expect(json["outputs"] is [[String: Any]])
        #expect(json["steps"] is [[String: Any]])
        #expect(json["wallTimeSeconds"] as? Double == 1.25)
        #expect(json["exitStatus"] as? Int == 0)
        #expect(json["stderr"] as? String == "fixture stderr")
        #expect(json["signatures"] is [[String: Any]])
        #expect(json["legacyWorkflowRun"] is [String: Any])

        let output = try #require(json["output"] as? [String: Any])
        #expect(output["checksumSHA256"] as? String == String(repeating: "b", count: 64))
        #expect(output["sha256"] as? String == String(repeating: "b", count: 64))
        #expect(output["fileSize"] as? Int == 22)
        #expect(output["sizeBytes"] as? Int == 22)
    }

    @Test("file descriptor decodes legacy checksum and size aliases into canonical fields")
    func fileDescriptorDecodesLegacyAliases() throws {
        let data = Data("""
        {
          "path": "legacy.fastq",
          "sha256": "\(String(repeating: "c", count: 64))",
          "sizeBytes": 42,
          "format": "fastq",
          "role": "input"
        }
        """.utf8)

        let decoded = try ProvenanceJSON.decoder.decode(ProvenanceFileDescriptor.self, from: data)

        #expect(decoded.path == "legacy.fastq")
        #expect(decoded.checksumSHA256 == String(repeating: "c", count: 64))
        #expect(decoded.fileSize == 42)
        #expect(decoded.format == .fastq)
        #expect(decoded.role == .input)
    }

    @Test("legacy WorkflowRun sidecar decodes through canonical reader")
    func legacyWorkflowRunDecodesThroughEnvelopeReader() throws {
        let legacy = WorkflowRun(
            name: "legacy fastq trim",
            startTime: Date(timeIntervalSince1970: 100),
            endTime: Date(timeIntervalSince1970: 103),
            status: .completed,
            steps: [
                StepExecution(
                    toolName: "fastp",
                    toolVersion: "0.23.4",
                    command: ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"],
                    inputs: [FileRecord(path: "reads.fastq", sha256: String(repeating: "a", count: 64), sizeBytes: 12, format: .fastq)],
                    outputs: [FileRecord(path: "trimmed.fastq", sha256: String(repeating: "b", count: 64), sizeBytes: 22, format: .fastq, role: .output)],
                    exitCode: 0,
                    wallTime: 3
                )
            ]
        )

        let data = try ProvenanceJSON.encoder.encode(legacy)
        let decoded = try ProvenanceEnvelopeReader.decode(data)

        #expect(decoded.workflowName == "legacy fastq trim")
        #expect(decoded.toolName == "fastp")
        #expect(decoded.toolVersion == "0.23.4")
        #expect(decoded.argv == ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"])
        #expect(decoded.output?.path == "trimmed.fastq")
        #expect(decoded.outputs.first?.checksumSHA256 == String(repeating: "b", count: 64))
    }
}

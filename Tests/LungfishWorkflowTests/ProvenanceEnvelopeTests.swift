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
        let tool = try #require(json["tool"] as? [String: Any])
        #expect(tool["version"] as? String == "0.24.1")
        #expect(json["argv"] as? [String] == ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"])
        #expect(json["reproducibleCommand"] as? String == "fastp -i reads.fastq -o trimmed.fastq")
        #expect(json["options"] is [String: Any])
        let runtimeIdentity = try #require(json["runtimeIdentity"] as? [String: Any])
        #expect((runtimeIdentity["appVersion"] as? String)?.isEmpty == false)
        #expect((runtimeIdentity["executablePath"] as? String)?.isEmpty == false)
        #expect(runtimeIdentity["processIdentifier"] is Int)
        #expect((runtimeIdentity["operatingSystemVersion"] as? String)?.isEmpty == false)
        #expect((runtimeIdentity["architecture"] as? String)?.isEmpty == false)
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

    @Test("primitive canonical sidecar decodes through compatibility reader")
    func primitiveCanonicalSidecarDecodesThroughEnvelopeReader() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "createdAt": "2026-05-10T23:19:32Z",
          "workflowName": "analysis-fixture-provenance-historical-backfill",
          "toolName": "write-analysis-fixture-provenance.py",
          "toolVersion": "0.4.0-alpha.12",
          "tool": {
            "name": "write-analysis-fixture-provenance.py",
            "version": "0.4.0-alpha.12"
          },
          "argv": ["scripts/testing/write-analysis-fixture-provenance.py"],
          "reproducibleCommand": "scripts/testing/write-analysis-fixture-provenance.py",
          "runtimeIdentity": {
            "executablePath": "/usr/bin/python3",
            "gitRevision": "06d97a401e825b16cbaabade40d462875484789d",
            "operatingSystemVersion": "macOS-26.4.1-arm64-arm-64bit",
            "processIdentifier": 38076
          },
          "options": {
            "fixtureToolName": "kraken2",
            "inputPaths": [],
            "outputDirectory": "Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00",
            "resolvedDefaults": {
              "backfillMode": "historical-fixture-sidecar-only",
              "overwriteExistingSidecar": false
            },
            "userVisibleOptions": {
              "fixtureDirectory": "Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00",
              "tool": "kraken2"
            }
          },
          "files": [
            {
              "checksumSHA256": "\(String(repeating: "a", count: 64))",
              "fileSize": 707,
              "path": "classification-result.json"
            }
          ],
          "output": {
            "checksumSHA256": "\(String(repeating: "b", count: 64))",
            "fileSize": 1440,
            "path": "Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00"
          },
          "exitStatus": 0,
          "wallTimeSeconds": 0
        }
        """.utf8)

        let decoded = try ProvenanceEnvelopeReader.decode(data)

        #expect(decoded.workflowName == "analysis-fixture-provenance-historical-backfill")
        #expect(decoded.workflowVersion.isEmpty == false)
        #expect(decoded.toolName == "write-analysis-fixture-provenance.py")
        #expect(decoded.outputs.map(\.path) == ["Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00"])
        #expect(decoded.outputs.first?.role == .output)
        #expect(decoded.options.explicit["tool"]?.stringValue == "kraken2")
        #expect(decoded.options.explicit["fixtureToolName"]?.stringValue == "kraken2")
        #expect(decoded.options.resolvedDefaults["overwriteExistingSidecar"]?.booleanValue == false)
    }

    @Test("legacy multi-step canonical output prefers terminal final output")
    func legacyMultiStepCanonicalOutputPrefersTerminalFinalOutput() throws {
        let intermediate = FileRecord(
            path: "trimmed.fastq",
            sha256: String(repeating: "b", count: 64),
            sizeBytes: 22,
            format: .fastq,
            role: .output
        )
        let finalOutput = FileRecord(
            path: "aligned.bam",
            sha256: String(repeating: "c", count: 64),
            sizeBytes: 44,
            format: .bam,
            role: .output
        )
        let legacy = WorkflowRun(
            name: "legacy two-step workflow",
            startTime: Date(timeIntervalSince1970: 120),
            endTime: Date(timeIntervalSince1970: 126),
            status: .completed,
            steps: [
                StepExecution(
                    toolName: "fastp",
                    toolVersion: "0.24.1",
                    command: ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"],
                    inputs: [FileRecord(path: "reads.fastq", role: .input)],
                    outputs: [intermediate],
                    exitCode: 0,
                    wallTime: 2
                ),
                StepExecution(
                    toolName: "minimap2",
                    toolVersion: "2.28",
                    command: ["minimap2", "reference.fasta", "trimmed.fastq", "-o", "aligned.bam"],
                    inputs: [
                        FileRecord(path: "reference.fasta", role: .reference),
                        FileRecord(path: "trimmed.fastq", role: .input)
                    ],
                    outputs: [finalOutput],
                    exitCode: 0,
                    wallTime: 4
                )
            ]
        )

        let envelope = legacy.canonicalEnvelope()

        #expect(envelope.output?.path == "aligned.bam")
        #expect(envelope.output?.checksumSHA256 == String(repeating: "c", count: 64))
    }

    @Test("legacy failed multi-step run reports failed canonical top-level outcome")
    func legacyFailedMultiStepRunReportsFailedTopLevelOutcome() throws {
        let legacy = WorkflowRun(
            name: "legacy failed workflow",
            startTime: Date(timeIntervalSince1970: 200),
            endTime: Date(timeIntervalSince1970: 205),
            status: .failed,
            steps: [
                StepExecution(
                    toolName: "fastp",
                    toolVersion: "0.24.1",
                    command: ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"],
                    inputs: [FileRecord(path: "reads.fastq", role: .input)],
                    outputs: [FileRecord(path: "trimmed.fastq", role: .output)],
                    exitCode: 0,
                    wallTime: 1,
                    stderr: "first step succeeded"
                ),
                StepExecution(
                    toolName: "minimap2",
                    toolVersion: "2.28",
                    command: ["minimap2", "reference.fasta", "trimmed.fastq"],
                    inputs: [FileRecord(path: "trimmed.fastq", role: .input)],
                    outputs: [FileRecord(path: "aligned.sam", role: .output)],
                    exitCode: 2,
                    wallTime: 4,
                    stderr: "later step failed"
                )
            ]
        )

        let decoded = legacy.canonicalEnvelope()

        #expect(decoded.exitStatus == 2)
        #expect(decoded.stderr == "later step failed")
    }

    @Test("legacy failed run without nonzero step exit emits nonzero canonical failure")
    func legacyFailedRunWithoutNonzeroStepExitEmitsNonzeroCanonicalFailure() throws {
        let legacy = WorkflowRun(
            name: "legacy failed workflow with zero exits",
            startTime: Date(timeIntervalSince1970: 220),
            endTime: Date(timeIntervalSince1970: 225),
            status: .failed,
            steps: [
                StepExecution(
                    toolName: "fastp",
                    toolVersion: "0.24.1",
                    command: ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"],
                    inputs: [FileRecord(path: "reads.fastq", role: .input)],
                    outputs: [FileRecord(path: "trimmed.fastq", role: .output)],
                    exitCode: 0,
                    wallTime: 1
                ),
                StepExecution(
                    toolName: "minimap2",
                    toolVersion: "2.28",
                    command: ["minimap2", "reference.fasta", "trimmed.fastq"],
                    inputs: [FileRecord(path: "trimmed.fastq", role: .input)],
                    outputs: [FileRecord(path: "aligned.sam", role: .output)],
                    exitCode: 0,
                    wallTime: 4,
                    stderr: "workflow failed after final status aggregation"
                )
            ]
        )

        let decoded = legacy.canonicalEnvelope()

        #expect(decoded.exitStatus == 1)
        #expect(decoded.stderr == "workflow failed after final status aggregation")
    }

    @Test("canonical envelope with singular output converts to legacy output")
    func canonicalSingularOutputConvertsToLegacyOutput() throws {
        let output = ProvenanceFileDescriptor(
            path: "single-output.fastq",
            checksumSHA256: String(repeating: "e", count: 64),
            fileSize: 64,
            format: .fastq,
            role: .output
        )
        let envelope = ProvenanceEnvelope(
            workflowName: "canonical single output",
            toolName: "lungfish-cli",
            argv: ["lungfish-cli", "export"],
            files: [
                ProvenanceFileDescriptor(path: "input.fastq", role: .input),
                output
            ],
            output: output,
            outputs: [],
            steps: [],
            exitStatus: 0
        )

        let legacy = envelope.legacyWorkflowRun()

        #expect(legacy.steps.count == 1)
        #expect(legacy.steps.first?.outputs.count == 1)
        #expect(legacy.steps.first?.outputs.first?.path == "single-output.fastq")
        #expect(legacy.steps.first?.outputs.first?.sha256 == String(repeating: "e", count: 64))

        let data = try ProvenanceJSON.encoder.encode(envelope)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tool = try #require(json["tool"] as? [String: Any])

        #expect((json["workflowVersion"] as? String)?.isEmpty == false)
        #expect((json["toolVersion"] as? String)?.isEmpty == false)
        #expect((tool["version"] as? String)?.isEmpty == false)
    }

    @Test("canonical envelope merges top-level output into final legacy step")
    func canonicalEnvelopeMergesTopLevelOutputIntoFinalLegacyStep() throws {
        let output = ProvenanceFileDescriptor(
            path: "top-level-output.fastq",
            checksumSHA256: String(repeating: "f", count: 64),
            fileSize: 77,
            format: .fastq,
            role: .output
        )
        let envelope = ProvenanceEnvelope(
            workflowName: "canonical step output merge",
            workflowVersion: "workflow-1",
            toolName: "lungfish-cli",
            toolVersion: "1.0.0",
            argv: ["lungfish-cli", "export"],
            files: [output],
            output: output,
            outputs: [],
            steps: [
                ProvenanceStep(
                    toolName: "lungfish-cli",
                    toolVersion: "1.0.0",
                    argv: ["lungfish-cli", "export"],
                    outputs: []
                )
            ],
            exitStatus: 0
        )

        let legacy = envelope.legacyWorkflowRun()

        #expect(legacy.steps.count == 1)
        #expect(legacy.steps.first?.outputs.count == 1)
        #expect(legacy.steps.first?.outputs.first?.path == "top-level-output.fastq")
        #expect(legacy.steps.first?.outputs.first?.sha256 == String(repeating: "f", count: 64))
    }

    @Test("runtime identity initializer normalizes blank required fields")
    func runtimeIdentityInitializerNormalizesBlankRequiredFields() throws {
        let runtimeIdentity = ProvenanceRuntimeIdentity(
            appVersion: "  ",
            executablePath: "",
            processIdentifier: 123,
            operatingSystemVersion: "\n",
            architecture: "\t"
        )
        let data = try ProvenanceJSON.encoder.encode(runtimeIdentity)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect((json["appVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        #expect((json["executablePath"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        #expect(json["processIdentifier"] as? Int == 123)
        #expect((json["operatingSystemVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        #expect((json["architecture"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    @Test("malformed canonical JSON missing versions rehydrates required identity fields")
    func malformedCanonicalJSONMissingVersionsRehydratesRequiredIdentityFields() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "id": "00000000-0000-0000-0000-000000000001",
          "createdAt": "1970-01-01T00:00:00Z",
          "workflowName": "malformed.workflow",
          "toolName": "malformed-tool",
          "tool": {
            "name": "malformed-tool",
            "kind": "cli"
          },
          "argv": ["malformed-tool"],
          "reproducibleCommand": "malformed-tool",
          "options": {
            "explicit": {},
            "defaults": {},
            "resolvedDefaults": {}
          },
          "runtimeIdentity": {},
          "files": [],
          "outputs": [],
          "steps": [
            {
              "id": "00000000-0000-0000-0000-000000000002",
              "toolName": "malformed-tool",
              "argv": ["malformed-tool"],
              "reproducibleCommand": "malformed-tool",
              "inputs": [],
              "outputs": [],
              "dependsOn": []
            }
          ],
          "signatures": []
        }
        """.utf8)

        let envelope = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)
        let encoded = try ProvenanceJSON.encoder.encode(envelope)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let tool = try #require(json["tool"] as? [String: Any])
        let steps = try #require(json["steps"] as? [[String: Any]])
        let firstStep = try #require(steps.first)

        #expect((json["workflowVersion"] as? String)?.isEmpty == false)
        #expect((json["toolVersion"] as? String)?.isEmpty == false)
        #expect((tool["version"] as? String)?.isEmpty == false)
        #expect((firstStep["toolVersion"] as? String)?.isEmpty == false)

        let runtimeIdentity = try #require(json["runtimeIdentity"] as? [String: Any])
        #expect((runtimeIdentity["appVersion"] as? String)?.isEmpty == false)
        #expect((runtimeIdentity["executablePath"] as? String)?.isEmpty == false)
        #expect(runtimeIdentity["processIdentifier"] is Int)
        #expect((runtimeIdentity["operatingSystemVersion"] as? String)?.isEmpty == false)
        #expect((runtimeIdentity["architecture"] as? String)?.isEmpty == false)
    }

    @Test("malformed canonical JSON reconciles top-level tool version from tool identity")
    func malformedCanonicalJSONReconcilesTopLevelToolVersionFromToolIdentity() throws {
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data("""
            {
              "schemaVersion": 1,
              "id": "00000000-0000-0000-0000-000000000003",
              "createdAt": "1970-01-01T00:00:00Z",
              "workflowName": "malformed.workflow",
              "workflowVersion": "workflow-1",
              "toolName": "real-tool",
              "tool": {
                "name": "real-tool",
                "version": "9.9.9",
                "kind": "cli"
              },
              "argv": ["real-tool"],
              "reproducibleCommand": "real-tool",
              "options": {"explicit": {}, "defaults": {}, "resolvedDefaults": {}},
              "runtimeIdentity": {},
              "files": [],
              "outputs": [],
              "steps": [],
              "signatures": []
            }
            """.utf8)
        )

        #expect(envelope.toolVersion == "9.9.9")
        #expect(envelope.tool.version == "9.9.9")
    }

    @Test("malformed canonical JSON reconciles tool identity version from top-level version")
    func malformedCanonicalJSONReconcilesToolIdentityVersionFromTopLevelVersion() throws {
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data("""
            {
              "schemaVersion": 1,
              "id": "00000000-0000-0000-0000-000000000004",
              "createdAt": "1970-01-01T00:00:00Z",
              "workflowName": "malformed.workflow",
              "workflowVersion": "workflow-1",
              "toolName": "real-tool",
              "toolVersion": "8.8.8",
              "tool": {
                "name": "real-tool",
                "kind": "cli"
              },
              "argv": ["real-tool"],
              "reproducibleCommand": "real-tool",
              "options": {"explicit": {}, "defaults": {}, "resolvedDefaults": {}},
              "runtimeIdentity": {},
              "files": [],
              "outputs": [],
              "steps": [],
              "signatures": []
            }
            """.utf8)
        )

        #expect(envelope.toolVersion == "8.8.8")
        #expect(envelope.tool.version == "8.8.8")
    }

    @Test("initializer normalizes conflicting nested tool identity to top-level authority")
    func initializerNormalizesConflictingNestedToolIdentity() throws {
        let envelope = ProvenanceEnvelope(
            workflowName: "conflicting.workflow",
            workflowVersion: "workflow-1",
            toolName: "canonical-tool",
            toolVersion: "1.2.3",
            tool: ProvenanceToolIdentity(name: "nested-tool", version: "9.9.9", kind: "cli")
        )

        #expect(envelope.toolName == "canonical-tool")
        #expect(envelope.toolVersion == "1.2.3")
        #expect(envelope.tool.name == "canonical-tool")
        #expect(envelope.tool.version == "1.2.3")
        #expect(envelope.tool.kind == "cli")
    }

    @Test("initializer normalizes blank workflow and tool names")
    func initializerNormalizesBlankWorkflowAndToolNames() throws {
        let envelope = ProvenanceEnvelope(
            workflowName: "  ",
            workflowVersion: "workflow-1",
            toolName: "\n",
            toolVersion: "1.2.3",
            tool: ProvenanceToolIdentity(name: "nested-tool", version: "1.2.3", kind: "cli")
        )

        #expect(envelope.workflowName == "unknown")
        #expect(envelope.toolName == "unknown")
        #expect(envelope.tool.name == "unknown")
        #expect(envelope.tool.version == "1.2.3")
        #expect(envelope.tool.kind == "cli")
    }

    @Test("decoder normalizes conflicting nested tool identity to top-level authority")
    func decoderNormalizesConflictingNestedToolIdentity() throws {
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data("""
            {
              "schemaVersion": 1,
              "id": "00000000-0000-0000-0000-000000000005",
              "createdAt": "1970-01-01T00:00:00Z",
              "workflowName": "conflicting.workflow",
              "workflowVersion": "workflow-1",
              "toolName": "canonical-tool",
              "toolVersion": "1.2.3",
              "tool": {
                "name": "nested-tool",
                "version": "9.9.9",
                "kind": "cli"
              },
              "argv": ["canonical-tool"],
              "reproducibleCommand": "canonical-tool",
              "options": {"explicit": {}, "defaults": {}, "resolvedDefaults": {}},
              "runtimeIdentity": {},
              "files": [],
              "outputs": [],
              "steps": [],
              "signatures": []
            }
            """.utf8)
        )

        #expect(envelope.toolName == "canonical-tool")
        #expect(envelope.toolVersion == "1.2.3")
        #expect(envelope.tool.name == "canonical-tool")
        #expect(envelope.tool.version == "1.2.3")
        #expect(envelope.tool.kind == "cli")
    }

    @Test("decoder normalizes blank top-level names with nested tool fallback")
    func decoderNormalizesBlankTopLevelNamesWithNestedToolFallback() throws {
        let envelope = try ProvenanceJSON.decoder.decode(
            ProvenanceEnvelope.self,
            from: Data("""
            {
              "schemaVersion": 1,
              "id": "00000000-0000-0000-0000-000000000006",
              "createdAt": "1970-01-01T00:00:00Z",
              "workflowName": "  ",
              "workflowVersion": "workflow-1",
              "toolName": "",
              "toolVersion": "1.2.3",
              "tool": {
                "name": "nested-tool",
                "version": "1.2.3",
                "kind": "cli"
              },
              "argv": ["nested-tool"],
              "reproducibleCommand": "nested-tool",
              "options": {"explicit": {}, "defaults": {}, "resolvedDefaults": {}},
              "runtimeIdentity": {},
              "files": [],
              "outputs": [],
              "steps": [],
              "signatures": []
            }
            """.utf8)
        )

        #expect(envelope.workflowName == "unknown")
        #expect(envelope.toolName == "nested-tool")
        #expect(envelope.tool.name == "nested-tool")
        #expect(envelope.tool.version == "1.2.3")
        #expect(envelope.tool.kind == "cli")
    }
}

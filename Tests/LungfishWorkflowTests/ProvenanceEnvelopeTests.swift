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
        #expect(json["name"] as? String == "fastq.trim.fastp")
        #expect(json["status"] as? String == "completed")
        #expect(json["startTime"] as? String == "1970-01-01T00:00:00Z")
        #expect(json["endTime"] as? String == "1970-01-01T00:00:01Z")
        #expect(json["appVersion"] as? String == "Lungfish fixture")
        #expect(json["hostOS"] as? String == "macOS fixture")
        #expect(json["runtime"] is [String: Any])
        #expect(json["parameters"] is [String: Any])
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

        let firstStep = try #require((json["steps"] as? [[String: Any]])?.first)
        #expect(firstStep["command"] as? [String] == ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"])
        #expect(firstStep["exitCode"] as? Int == 0)
        #expect(firstStep["wallTime"] as? Double == 1.25)
        #expect(firstStep["startTime"] as? String == "1970-01-01T00:00:00Z")
        #expect(firstStep["endTime"] as? String == "1970-01-01T00:00:01Z")

        let output = try #require(json["output"] as? [String: Any])
        #expect(output["checksumSHA256"] as? String == String(repeating: "b", count: 64))
        #expect(output["sha256"] as? String == String(repeating: "b", count: 64))
        #expect(output["fileSize"] as? Int == 22)
        #expect(output["sizeBytes"] as? Int == 22)
    }

    @Test("canonical envelope JSON decodes directly as legacy WorkflowRun")
    func canonicalEnvelopeDecodesDirectlyAsWorkflowRun() throws {
        let input = ProvenanceFileDescriptor(
            path: "reads.fastq",
            checksumSHA256: String(repeating: "a", count: 64),
            fileSize: 12,
            format: .fastq,
            role: .input
        )
        let output = ProvenanceFileDescriptor(
            path: "trimmed.fastq",
            checksumSHA256: String(repeating: "b", count: 64),
            fileSize: 22,
            format: .fastq,
            role: .output
        )
        let envelope = ProvenanceEnvelope(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000cafe")!,
            createdAt: Date(timeIntervalSince1970: 100),
            workflowName: "fastq.trim.fastp",
            workflowVersion: "fixture-workflow-version",
            toolName: "fastp",
            toolVersion: "0.24.1",
            argv: ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"],
            options: ProvenanceOptions(explicit: ["cutRight": .boolean(true)]),
            runtimeIdentity: .fixture(),
            files: [input, output],
            output: output,
            outputs: [output],
            steps: [
                ProvenanceStep(
                    toolName: "fastp",
                    toolVersion: "0.24.1",
                    argv: ["fastp", "-i", "reads.fastq", "-o", "trimmed.fastq"],
                    inputs: [input],
                    outputs: [output],
                    exitStatus: 0,
                    wallTimeSeconds: 1.25,
                    startedAt: Date(timeIntervalSince1970: 100),
                    completedAt: Date(timeIntervalSince1970: 101.25)
                )
            ],
            wallTimeSeconds: 1.25,
            exitStatus: 0
        )

        let legacy = try ProvenanceJSON.decoder.decode(
            WorkflowRun.self,
            from: try ProvenanceJSON.encoder.encode(envelope)
        )

        #expect(legacy.name == "fastq.trim.fastp")
        #expect(legacy.status == .completed)
        #expect(legacy.appVersion == "Lungfish fixture")
        #expect(legacy.hostOS == "macOS fixture")
        #expect(legacy.parameters["cutRight"]?.booleanValue == true)
        #expect(legacy.steps.count == 1)
        #expect(legacy.steps.first?.toolName == "fastp")
        #expect(legacy.steps.first?.exitCode == 0)
        #expect(legacy.primaryInputFiles.first?.path == "reads.fastq")
        #expect(legacy.allOutputFiles.first?.path == "trimmed.fastq")
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
        #expect(decoded.outputs.map(\.path) == ["classification-result.json"])
        #expect(decoded.outputs.first?.role == .output)
        #expect(decoded.options.explicit["tool"]?.stringValue == "kraken2")
        #expect(decoded.options.explicit["fixtureToolName"]?.stringValue == "kraken2")
        #expect(decoded.options.resolvedDefaults["overwriteExistingSidecar"]?.booleanValue == false)
    }

    @Test("historical analysis fixture decodes payload files as outputs")
    func historicalAnalysisFixtureFilesDecodeAsOutputs() throws {
        let sidecarURL = URL(fileURLWithPath: "Tests/Fixtures/analyses/kraken2-2026-01-15T11-00-00/.lungfish-provenance.json")
        let decoded = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        let fixtureOutputPaths = Set([
            "classification-result.json",
            "reads.bracken",
            "reads.kraken",
            "reads.kreport",
        ])

        #expect(Set(decoded.outputs.map(\.path)) == fixtureOutputPaths)
        #expect(
            decoded.files
                .filter { fixtureOutputPaths.contains($0.path) }
                .allSatisfy { $0.role == .output }
        )
    }

    @Test("primitive relative files preserve explicit input roles")
    func primitiveRelativeFilesPreserveExplicitInputRoles() throws {
        let data = Data("""
        {
          "createdAt": "2026-01-15T11:00:00Z",
          "workflowName": "legacy fixture",
          "workflowVersion": "1.0",
          "toolName": "legacy-tool",
          "toolVersion": "1.0",
          "argv": ["legacy-tool"],
          "options": {
            "outputDirectory": "/tmp/out"
          },
          "runtimeIdentity": {
            "appVersion": "1.0",
            "executablePath": "/bin/legacy-tool",
            "processIdentifier": 12,
            "operatingSystemVersion": "macOS",
            "architecture": "arm64"
          },
          "output": {
            "path": "/tmp/out",
            "role": "output"
          },
          "files": [
            {
              "path": "payload.fasta",
              "sha256": "\(String(repeating: "a", count: 64))",
              "sizeBytes": 12,
              "format": "fasta"
            },
            {
              "path": "relative-input.txt",
              "sha256": "\(String(repeating: "b", count: 64))",
              "sizeBytes": 8,
              "format": "text",
              "role": "input"
            }
          ]
        }
        """.utf8)

        let decoded = try ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: data)

        #expect(decoded.outputs.map(\.path) == ["payload.fasta"])
        #expect(decoded.files.first { $0.path == "relative-input.txt" }?.role == .input)
    }

    @Test("primitive workflow steps decode as canonical steps")
    func primitiveWorkflowStepsDecodeAsCanonicalSteps() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "createdAt": "2026-05-10T23:19:32Z",
          "workflowName": "alignment-fixture",
          "toolName": "lungfish fixture",
          "toolVersion": "0.4.0-alpha.12",
          "argv": ["python3", "fixture.py"],
          "reproducibleCommand": "python3 fixture.py",
          "runtimeIdentity": {
            "executablePath": "/usr/bin/python3",
            "operatingSystemVersion": "macOS test",
            "processIdentifier": 123
          },
          "files": [],
          "output": {
            "checksumSHA256": "\(String(repeating: "b", count: 64))",
            "fileSize": 1440,
            "path": "project.lungfish"
          },
          "exitStatus": 0,
          "wallTimeSeconds": 2,
          "workflowSteps": [
            {
              "stepName": "generate-input",
              "workflowName": "fixture-generation",
              "toolName": "create_fixture.py",
              "argv": ["python3", "create_fixture.py"],
              "reproducibleCommand": "python3 create_fixture.py",
              "output": "project.lungfish/Inputs/input.fasta"
            },
            {
              "stepName": "align-with-mafft",
              "workflowName": "multiple-sequence-alignment-mafft",
              "toolName": "lungfish align mafft",
              "argv": ["lungfish", "align", "mafft", "input.fasta"],
              "reproducibleCommand": "lungfish align mafft input.fasta",
              "output": "project.lungfish/Alignments/aligned.lungfishmsa"
            }
          ]
        }
        """.utf8)

        let decoded = try ProvenanceEnvelopeReader.decode(data)

        #expect(decoded.steps.map(\.toolName) == ["create_fixture.py", "lungfish align mafft"])
        #expect(decoded.steps.map(\.argv) == [
            ["python3", "create_fixture.py"],
            ["lungfish", "align", "mafft", "input.fasta"]
        ])
        #expect(decoded.steps.last?.outputs.first?.path == "project.lungfish/Alignments/aligned.lungfishmsa")
        #expect(decoded.legacyWorkflowRun().steps.count == 2)
    }

    @Test("primitive external tool invocations decode as canonical steps")
    func primitiveExternalToolInvocationsDecodeAsCanonicalSteps() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "createdAt": "2026-05-10T23:19:32Z",
          "workflowName": "mafft-alignment",
          "toolName": "lungfish align mafft",
          "toolVersion": "0.4.0-alpha.12",
          "argv": ["lungfish", "align", "mafft", "input.fasta"],
          "reproducibleCommand": "lungfish align mafft input.fasta",
          "runtimeIdentity": {
            "executablePath": "/usr/local/bin/lungfish",
            "operatingSystemVersion": "macOS test",
            "processIdentifier": 123
          },
          "files": [],
          "output": {
            "checksumSHA256": "\(String(repeating: "b", count: 64))",
            "fileSize": 1440,
            "path": "aligned.lungfishmsa"
          },
          "exitStatus": 0,
          "wallTimeSeconds": 2,
          "externalToolInvocations": [
            {
              "name": "mafft",
              "version": "7.526",
              "argv": ["mafft", "--auto", "alignment/input.unaligned.fasta"],
              "reproducibleCommand": "mafft --auto alignment/input.unaligned.fasta > alignment/primary.aligned.fasta",
              "exitStatus": 0,
              "stderr": "mafft stderr",
              "wallTimeSeconds": 1.5
            }
          ]
        }
        """.utf8)

        let decoded = try ProvenanceEnvelopeReader.decode(data)

        #expect(decoded.steps.count == 1)
        #expect(decoded.steps.first?.toolName == "mafft")
        #expect(decoded.steps.first?.toolVersion == "7.526")
        #expect(decoded.steps.first?.argv == ["mafft", "--auto", "alignment/input.unaligned.fasta"])
        #expect(decoded.steps.first?.reproducibleCommand == "mafft --auto alignment/input.unaligned.fasta > alignment/primary.aligned.fasta")
        #expect(decoded.steps.first?.stderr == "mafft stderr")
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

    @Test("reader adapts MSA provenance with keyed file maps")
    func readerAdaptsMSAProvenanceWithKeyedFileMaps() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "createdAt": "2026-05-12T18:41:18Z",
          "workflowName": "multiple-sequence-alignment-mafft",
          "toolName": "lungfish align mafft",
          "toolVersion": "0.1.0",
          "argv": ["lungfish", "align", "mafft", "input.lungfishref", "--output", "aligned.lungfishmsa"],
          "reproducibleCommand": "lungfish align mafft input.lungfishref --output aligned.lungfishmsa",
          "runtimeIdentity": {
            "executablePath": "/Applications/Lungfish.app/Contents/MacOS/lungfish-cli",
            "operatingSystemVersion": "macOS test",
            "processIdentifier": 42
          },
          "input": {
            "checksumSHA256": "\(String(repeating: "a", count: 64))",
            "fileSize": 20,
            "path": "/project/aligned.lungfishmsa/alignment/source.original"
          },
          "inputFiles": [
            {
              "checksumSHA256": "\(String(repeating: "b", count: 64))",
              "fileSize": 10,
              "path": "/project/input.lungfishref"
            }
          ],
          "files": {
            "alignment/primary.aligned.fasta": {
              "checksumSHA256": "\(String(repeating: "c", count: 64))",
              "fileSize": 30,
              "path": "/project/aligned.lungfishmsa/alignment/primary.aligned.fasta"
            }
          },
          "output": {
            "checksumSHA256": "\(String(repeating: "d", count: 64))",
            "fileSize": 40,
            "path": "/project/aligned.lungfishmsa"
          },
          "externalToolInvocations": [
            {
              "name": "mafft",
              "version": "7.526",
              "argv": ["mafft", "--auto", "/project/aligned.lungfishmsa/alignment/input.unaligned.fasta"],
              "reproducibleCommand": "mafft --auto input > output",
              "exitStatus": 0,
              "wallTimeSeconds": 1.5
            }
          ],
          "exitStatus": 0,
          "wallTimeSeconds": 2.0
        }
        """.utf8)

        let decoded = try ProvenanceEnvelopeReader.decode(data)

        #expect(decoded.workflowName == "multiple-sequence-alignment-mafft")
        #expect(decoded.output?.path == "/project/aligned.lungfishmsa")
        #expect(decoded.outputs.map(\.path).contains("/project/aligned.lungfishmsa"))
        #expect(decoded.files.map(\.path).contains("/project/aligned.lungfishmsa/alignment/primary.aligned.fasta"))
        #expect(decoded.steps.contains { $0.toolName == "mafft" })
        #expect(decoded.steps.first?.inputs.map(\.path).contains("/project/input.lungfishref") == true)
        #expect(decoded.steps.first?.outputs.map(\.path).contains("/project/aligned.lungfishmsa") == true)
    }

    @Test("reader adapts tree provenance without canonical createdAt")
    func readerAdaptsTreeProvenanceWithoutCreatedAt() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "workflowName": "phylogenetic-tree-infer-iqtree",
          "toolName": "lungfish tree infer iqtree",
          "toolVersion": "0.4.0-alpha.13",
          "argv": ["lungfish", "tree", "infer", "iqtree", "aligned.lungfishmsa"],
          "command": "lungfish tree infer iqtree aligned.lungfishmsa",
          "runtimeIdentity": {
            "executablePath": "/usr/local/bin/lungfish-cli",
            "operatingSystemVersion": "macOS test"
          },
          "input": {
            "path": "/project/aligned.lungfishmsa",
            "sha256": "\(String(repeating: "e", count: 64))",
            "fileSizeBytes": 100
          },
          "output": {
            "path": "/project/tree.lungfishtree",
            "sha256": "\(String(repeating: "f", count: 64))",
            "fileSizeBytes": 200
          },
          "checksums": {
            "manifest.json": "\(String(repeating: "1", count: 64))",
            "tree/primary.nwk": "\(String(repeating: "2", count: 64))"
          },
          "fileSizes": {
            "manifest.json": 12,
            "tree/primary.nwk": 34
          },
          "externalTool": {
            "toolName": "iqtree2",
            "toolVersion": "2.3.6",
            "argv": ["iqtree2", "-s", "input.aligned.fasta"],
            "reproducibleCommand": "iqtree2 -s input.aligned.fasta",
            "exitStatus": 0,
            "wallTimeSeconds": 3.0
          },
          "exitStatus": 0,
          "wallTimeSeconds": 4.0
        }
        """.utf8)

        let decoded = try ProvenanceEnvelopeReader.decode(data)

        #expect(decoded.workflowName == "phylogenetic-tree-infer-iqtree")
        #expect(decoded.output?.path == "/project/tree.lungfishtree")
        #expect(decoded.files.map(\.path).contains("tree/primary.nwk"))
        #expect(decoded.steps.contains { $0.toolName == "iqtree2" })
        #expect(decoded.steps.first?.inputs.map(\.path).contains("/project/aligned.lungfishmsa") == true)
        #expect(decoded.steps.first?.outputs.map(\.path).contains("/project/tree.lungfishtree") == true)
        #expect(decoded.runtimeIdentity.operatingSystemVersion == "macOS test")
    }

    @Test("primitive sidecar without createdAt uses stable sidecar modification date")
    func primitiveSidecarWithoutCreatedAtUsesStableSidecarModificationDate() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lungfish-primitive-createdat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sidecarURL = root.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try Data("""
        {
          "schemaVersion": 1,
          "workflowName": "phylogenetic-tree-infer-iqtree",
          "toolName": "lungfish tree infer iqtree",
          "toolVersion": "0.4.0-alpha.13",
          "command": "lungfish tree infer iqtree aligned.lungfishmsa",
          "output": {
            "path": "/project/tree.lungfishtree",
            "sha256": "\(String(repeating: "f", count: 64))",
            "fileSizeBytes": 200
          }
        }
        """.utf8).write(to: sidecarURL, options: .atomic)
        let fixtureModificationDate = Date(timeIntervalSince1970: 1_777_777_777)
        try FileManager.default.setAttributes(
            [.modificationDate: fixtureModificationDate],
            ofItemAtPath: sidecarURL.path
        )

        let firstDecode = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))
        let secondDecode = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: sidecarURL))

        #expect(firstDecode.createdAt == fixtureModificationDate)
        #expect(secondDecode.createdAt == fixtureModificationDate)
        #expect(firstDecode.legacyWorkflowRun().startTime == fixtureModificationDate)
        #expect(secondDecode.legacyWorkflowRun().startTime == fixtureModificationDate)
    }

    @Test("reader preserves primitive tree import payload and metadata keys")
    func readerPreservesPrimitiveTreeImportPayloadAndMetadataKeys() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "toolName": "lungfish import tree",
          "toolVersion": "0.4.0-alpha.13",
          "argv": ["lungfish", "import", "tree", "tree.nwk"],
          "command": "lungfish import tree tree.nwk",
          "input": {
            "path": "/project/tree.nwk",
            "sha256": "\(String(repeating: "a", count: 64))",
            "fileSizeBytes": 100
          },
          "inputTreeFile": {
            "path": "/project/Tree.lungfishtree/tree/primary.nwk",
            "sha256": "\(String(repeating: "b", count: 64))",
            "fileSizeBytes": 120
          },
          "output": {
            "path": "/project/Tree.lungfishtree",
            "sha256": "\(String(repeating: "c", count: 64))",
            "fileSizeBytes": 400
          },
          "metadataFile": {
            "path": "/project/metadata.tsv",
            "sha256": "\(String(repeating: "d", count: 64))",
            "fileSizeBytes": 80
          },
          "checksums": {
            "tree/primary.nwk": "\(String(repeating: "e", count: 64))"
          },
          "fileSizes": {
            "tree/primary.nwk": 50
          },
          "exitStatus": 0,
          "wallTimeSeconds": 1.5
        }
        """.utf8)

        let decoded = try ProvenanceEnvelopeReader.decode(data)

        #expect(decoded.workflowName == "phylogenetic-tree-import")
        #expect(decoded.files.filter { $0.role == .input }.map(\.path).contains("/project/Tree.lungfishtree/tree/primary.nwk"))
        #expect(decoded.outputs.map(\.path).contains("/project/metadata.tsv"))
        #expect(decoded.files.map(\.path).contains("tree/primary.nwk"))
        #expect(decoded.createdAt == Date(timeIntervalSince1970: 0))
    }

    @Test("primitive provenance logs decode the latest entries record")
    func primitiveProvenanceLogEntriesDecodeLatestRecord() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "entries": [
            {
              "workflowName": "older annotation import",
              "workflowVersion": "0.4.0-alpha.12",
              "toolName": "Lungfish Genome Explorer",
              "toolVersion": "0.4.0-alpha.12",
              "argv": ["Lungfish.app", "annotation-import"],
              "options": { "trackID": "old" },
              "inputPaths": ["/project/old.gff3"],
              "outputPaths": ["/project/Reference.lungfishref/annotations/old.db"],
              "inputFileInfo": [
                { "path": "/project/old.gff3", "sha256": "\(String(repeating: "a", count: 64))", "sizeBytes": 10 }
              ],
              "outputFileInfo": [
                { "path": "/project/Reference.lungfishref/annotations/old.db", "sha256": "\(String(repeating: "b", count: 64))", "sizeBytes": 20 }
              ],
              "runtime": { "appVersion": "0.4.0-alpha.12" },
              "exitStatus": 0,
              "wallTimeSeconds": 0.4,
              "recordedAt": "2026-05-11T12:00:00Z"
            },
            {
              "workflowName": "lungfish annotation track import",
              "workflowVersion": "0.4.0-alpha.13",
              "toolName": "Lungfish Genome Explorer",
              "toolVersion": "0.4.0-alpha.13",
              "argv": ["Lungfish.app", "annotation-import", "--track-id", "genes"],
              "options": { "trackID": "genes" },
              "inputPaths": ["/project/genes.gff3"],
              "outputPaths": ["/project/Reference.lungfishref/annotations/genes.db"],
              "inputFileInfo": [
                { "path": "/project/genes.gff3", "sha256": "\(String(repeating: "c", count: 64))", "sizeBytes": 30 }
              ],
              "outputFileInfo": [
                { "path": "/project/Reference.lungfishref/annotations/genes.db", "sha256": "\(String(repeating: "d", count: 64))", "sizeBytes": 40 }
              ],
              "runtime": { "appVersion": "0.4.0-alpha.13" },
              "exitStatus": 0,
              "wallTimeSeconds": 0.5,
              "recordedAt": "2026-05-12T12:00:00Z"
            }
          ]
        }
        """.utf8)

        let decoded = try ProvenanceEnvelopeReader.decode(data)
        let expectedCreatedAt = try #require(ISO8601DateFormatter().date(from: "2026-05-12T12:00:00Z"))

        #expect(decoded.workflowName == "lungfish annotation track import")
        #expect(decoded.createdAt == expectedCreatedAt)
        #expect(decoded.files.filter { $0.role == .input }.map(\.path) == ["/project/genes.gff3"])
        #expect(decoded.outputs.map(\.path) == ["/project/Reference.lungfishref/annotations/genes.db"])
        #expect(decoded.files.contains { $0.path == "/project/genes.gff3" && $0.checksumSHA256 == String(repeating: "c", count: 64) })
        #expect(decoded.files.contains { $0.path == "/project/Reference.lungfishref/annotations/genes.db" && $0.fileSize == 40 })
    }

    @Test("primitive MSA extraction annotation sidecar decodes output bundle path")
    func primitiveMSAExtractionAnnotationSidecarDecodesOutputBundlePath() throws {
        let data = Data("""
        {
          "schemaVersion": 1,
          "workflowName": "msa-selection-reference-bundle-extraction",
          "toolName": "lungfish-gui msa extract annotated bundle",
          "toolVersion": "debug",
          "argv": [
            "lungfish-gui",
            "msa",
            "extract-annotated-bundle",
            "--output",
            "/project/Extracted.lungfishref"
          ],
          "inputPaths": ["/project/Aligned.lungfishmsa"],
          "stagedInputPaths": ["/tmp/source.fasta", "/tmp/annotations.bed"],
          "outputBundlePath": "/project/Extracted.lungfishref",
          "createdAt": "2026-05-12T12:00:00Z",
          "exitStatus": 0
        }
        """.utf8)

        let decoded = try ProvenanceEnvelopeReader.decode(data)

        #expect(decoded.workflowName == "msa-selection-reference-bundle-extraction")
        #expect(decoded.outputs.map(\.path) == ["/project/Extracted.lungfishref"])
        #expect(decoded.files.filter { $0.role == .input }.map(\.path).contains("/project/Aligned.lungfishmsa"))
        #expect(decoded.files.filter { $0.role == .input }.map(\.path).contains("/tmp/source.fasta"))
    }

    @Test("recorder resolves operation-specific bundle provenance sidecars")
    func recorderResolvesOperationSpecificBundleProvenanceSidecars() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lungfish-operation-provenance-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let msaBundleURL = root.appendingPathComponent("Aligned.lungfishmsa", isDirectory: true)
        let metadataURL = msaBundleURL.appendingPathComponent("metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        let annotationSidecarURL = metadataURL.appendingPathComponent("annotation-edit-provenance.json")
        try ProvenanceJSON.encoder.encode(
            ProvenanceEnvelope.fixture(
                workflowName: "multiple-sequence-alignment-import",
                outputPath: msaBundleURL.path
            )
        ).write(to: msaBundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename), options: .atomic)
        try Data("""
        {
          "schemaVersion": 1,
          "workflowName": "multiple-sequence-alignment-annotation-edit",
          "toolName": "lungfish-gui msa annotation edit",
          "toolVersion": "0.4.0-alpha.13",
          "argv": ["lungfish-gui", "msa", "annotate"],
          "reproducibleCommand": "lungfish-gui msa annotate",
          "createdAt": "2026-05-12T18:41:18Z",
          "input": { "path": "\(msaBundleURL.path)" },
          "output": { "path": "\(metadataURL.appendingPathComponent("annotations.sqlite").path)" },
          "files": {
            "metadata/annotations.json": { "path": "\(metadataURL.appendingPathComponent("annotations.json").path)" }
          },
          "exitStatus": 0,
          "wallTimeSeconds": 0.5
        }
        """.utf8).write(to: annotationSidecarURL, options: .atomic)

        let fastqBundleURL = root.appendingPathComponent("Extracted.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: fastqBundleURL, withIntermediateDirectories: true)
        let extractionSidecarURL = fastqBundleURL.appendingPathComponent("extraction-metadata.json")
        try Data("""
        {
          "sourceDescription": "BAM read extraction",
          "toolName": "samtools view",
          "extractionDate": "2026-05-11T12:00:00Z",
          "parameters": {
            "region": "MN908947:1-1000"
          }
        }
        """.utf8).write(to: extractionSidecarURL, options: .atomic)

        let referenceBundleURL = root.appendingPathComponent("Reference.lungfishref", isDirectory: true)
        let annotationsURL = referenceBundleURL.appendingPathComponent("annotations", isDirectory: true)
        let alignmentsURL = referenceBundleURL.appendingPathComponent("alignments/mapped", isDirectory: true)
        try FileManager.default.createDirectory(at: annotationsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: alignmentsURL, withIntermediateDirectories: true)
        try ProvenanceJSON.encoder.encode(
            ProvenanceEnvelope.fixture(
                workflowName: "reference-bundle-import",
                outputPath: referenceBundleURL.path
            )
        ).write(to: referenceBundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename), options: .atomic)
        let manualAnnotationSidecarURL = annotationsURL.appendingPathComponent("manual-annotation-provenance.json")
        try Data("""
        {
          "schemaVersion": 1,
          "entries": [
            {
              "workflowName": "lungfish manual annotation",
              "workflowVersion": "0.4.0-alpha.13",
              "argv": ["Lungfish.app", "manual-annotation"],
              "options": { "trackID": "manual_annotations" },
              "inputPaths": ["\(referenceBundleURL.path)"],
              "outputPaths": ["\(annotationsURL.appendingPathComponent("manual_annotations.db").path)"],
              "recordedAt": "2026-05-12T12:00:00Z",
              "exitStatus": 0,
              "wallTimeSeconds": 0.1
            }
          ]
        }
        """.utf8).write(to: manualAnnotationSidecarURL, options: .atomic)

        let annotationImportSidecarURL = annotationsURL.appendingPathComponent("genes-import-provenance.json")
        try Data("""
        {
          "schemaVersion": 1,
          "entries": [
            {
              "workflowName": "lungfish annotation track import",
              "workflowVersion": "0.4.0-alpha.13",
              "toolName": "Lungfish Genome Explorer",
              "toolVersion": "0.4.0-alpha.13",
              "argv": ["Lungfish.app", "annotation-import"],
              "options": { "trackID": "genes" },
              "inputPaths": ["/project/genes.gff3"],
              "outputPaths": ["\(annotationsURL.appendingPathComponent("genes.db").path)"],
              "recordedAt": "2026-05-12T12:30:00Z",
              "exitStatus": 0,
              "wallTimeSeconds": 0.2
            }
          ]
        }
        """.utf8).write(to: annotationImportSidecarURL, options: .atomic)

        let primerTrimBAMURL = alignmentsURL.appendingPathComponent("sample.trimmed.bam")
        try Data().write(to: primerTrimBAMURL, options: .atomic)
        let primerTrimSidecarURL = alignmentsURL.appendingPathComponent("sample.trimmed.primer-trim-provenance.json")
        try Data("""
        {
          "workflowName": "lungfish bam primer-trim",
          "toolName": "ivar trim",
          "toolVersion": "1.4.4",
          "argv": ["ivar", "trim"],
          "outputFiles": [{ "path": "\(primerTrimBAMURL.path)" }],
          "recordedAt": "2026-05-12T13:00:00Z",
          "exitStatus": 0
        }
        """.utf8).write(to: primerTrimSidecarURL, options: .atomic)

        let adoptedBAMURL = alignmentsURL.appendingPathComponent("sample.adopted.bam")
        try Data().write(to: adoptedBAMURL, options: .atomic)
        let adoptedSidecarURL = alignmentsURL.appendingPathComponent("sample.adopted.adopt-mapping-provenance.json")
        try Data("""
        {
          "workflowName": "lungfish bam adopt-mapping",
          "toolName": "lungfish-cli",
          "toolVersion": "0.4.0-alpha.13",
          "argv": ["lungfish-cli", "bam", "adopt-mapping"],
          "outputFiles": [{ "path": "\(adoptedBAMURL.path)" }],
          "recordedAt": "2026-05-12T13:30:00Z",
          "exitStatus": 0
        }
        """.utf8).write(to: adoptedSidecarURL, options: .atomic)

        let extractedReferenceBundleURL = root.appendingPathComponent("Extracted.lungfishref", isDirectory: true)
        let extractedAnnotationsURL = extractedReferenceBundleURL.appendingPathComponent("annotations", isDirectory: true)
        try FileManager.default.createDirectory(at: extractedAnnotationsURL, withIntermediateDirectories: true)
        try ProvenanceJSON.encoder.encode(
            ProvenanceEnvelope.fixture(
                workflowName: "reference-bundle-import",
                outputPath: extractedReferenceBundleURL.path
            )
        ).write(
            to: extractedReferenceBundleURL.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            options: .atomic
        )
        let msaExtractionSidecarURL = extractedAnnotationsURL.appendingPathComponent(
            "msa-extraction-annotations-provenance.json"
        )
        try Data("""
        {
          "schemaVersion": 1,
          "workflowName": "msa-selection-reference-bundle-extraction",
          "toolName": "lungfish-gui msa extract annotated bundle",
          "toolVersion": "debug",
          "argv": ["lungfish-gui", "msa", "extract-annotated-bundle"],
          "inputPaths": ["\(msaBundleURL.path)"],
          "stagedInputPaths": ["/tmp/source.fasta", "/tmp/annotations.bed"],
          "outputBundlePath": "\(extractedReferenceBundleURL.path)",
          "createdAt": "2026-05-12T14:00:00Z",
          "exitStatus": 0
        }
        """.utf8).write(to: msaExtractionSidecarURL, options: .atomic)

        let resolvedAnnotation = try #require(ProvenanceRecorder.findProvenanceEnvelope(for: msaBundleURL))
        let resolvedExtraction = try #require(ProvenanceRecorder.findProvenanceEnvelope(for: fastqBundleURL))
        let resolvedReferenceBundle = try #require(ProvenanceRecorder.findProvenanceEnvelope(for: referenceBundleURL))
        let resolvedPrimerTrim = try #require(ProvenanceRecorder.findProvenanceEnvelope(for: primerTrimBAMURL))
        let resolvedAdopted = try #require(ProvenanceRecorder.findProvenanceEnvelope(for: adoptedBAMURL))
        let resolvedMSAExtraction = try #require(
            ProvenanceRecorder.findProvenanceEnvelope(for: extractedReferenceBundleURL)
        )
        let expectedExtractionDate = try #require(ISO8601DateFormatter().date(from: "2026-05-11T12:00:00Z"))

        #expect(resolvedAnnotation.sidecarURL.path.hasSuffix("metadata/annotation-edit-provenance.json"))
        #expect(resolvedAnnotation.envelope.workflowName == "multiple-sequence-alignment-annotation-edit")
        #expect(resolvedExtraction.sidecarURL.path.hasSuffix("extraction-metadata.json"))
        #expect(resolvedExtraction.envelope.workflowName == "read-extraction")
        #expect(resolvedExtraction.envelope.createdAt == expectedExtractionDate)
        #expect(resolvedExtraction.envelope.output?.path == fastqBundleURL.path)
        #expect(resolvedReferenceBundle.sidecarURL.path.hasSuffix("annotations/manual-annotation-provenance.json"))
        #expect(resolvedReferenceBundle.envelope.workflowName == "lungfish manual annotation")
        #expect(resolvedPrimerTrim.sidecarURL.path.hasSuffix("sample.trimmed.primer-trim-provenance.json"))
        #expect(resolvedPrimerTrim.envelope.workflowName == "lungfish bam primer-trim")
        #expect(resolvedAdopted.sidecarURL.path.hasSuffix("sample.adopted.adopt-mapping-provenance.json"))
        #expect(resolvedAdopted.envelope.workflowName == "lungfish bam adopt-mapping")
        #expect(resolvedMSAExtraction.sidecarURL.path.hasSuffix("annotations/msa-extraction-annotations-provenance.json"))
        #expect(resolvedMSAExtraction.envelope.output?.path == extractedReferenceBundleURL.path)
    }

    @Test("recorder resolves assembly provenance stored under assembly directory")
    func recorderResolvesAssemblyProvenanceStoredUnderAssemblyDirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lungfish-assembly-provenance-\(UUID().uuidString)", isDirectory: true)
        let bundleURL = root.appendingPathComponent("assembly-output.lungfishref", isDirectory: true)
        let assemblyURL = bundleURL.appendingPathComponent("assembly", isDirectory: true)
        try FileManager.default.createDirectory(at: assemblyURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("""
        {
          "assembler": "SPAdes",
          "assembler_version": "4.0.0",
          "execution_backend": "micromamba",
          "managed_environment": "spades",
          "host_os": "macOS test",
          "host_architecture": "arm64",
          "lungfish_version": "Lungfish test",
          "assembly_date": "2026-05-12T18:41:18Z",
          "wall_time_seconds": 12.5,
          "command_line": "spades.py -1 reads_1.fastq -2 reads_2.fastq -o assembly",
          "parameters": {
            "mode": "isolate",
            "k_mer_sizes": "auto",
            "memory_gb": 16,
            "threads": 8,
            "skip_error_correction": false,
            "min_contig_length": 500,
            "extraArgs": "",
            "advanced_arguments": []
          },
          "inputs": [
            {
              "filename": "reads_1.fastq",
              "original_path": "/project/reads_1.fastq",
              "sha256": "\(String(repeating: "a", count: 64))",
              "size_bytes": 100
            }
          ]
        }
        """.utf8).write(to: assemblyURL.appendingPathComponent("provenance.json"), options: .atomic)

        let resolved = try #require(ProvenanceRecorder.findProvenanceEnvelope(for: bundleURL))

        #expect(resolved.sidecarURL.path.hasSuffix("assembly/provenance.json"))
        #expect(resolved.envelope.workflowName == "assembly.spades")
        #expect(resolved.envelope.output?.path == bundleURL.path)
        #expect(resolved.envelope.files.map(\.path).contains("/project/reads_1.fastq"))
        #expect(resolved.envelope.steps.first?.toolName == "SPAdes")
    }
}

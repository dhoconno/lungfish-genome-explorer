import Foundation
import Testing
@testable import LungfishWorkflow

@Suite("Scientific Provenance Policy")
struct ScientificProvenancePolicyTests {
    @Test("policy distinguishes data-writing, metadata-only, and inspect-only workflows")
    func policyDistinguishesWorkflowKinds() throws {
        let fastq = try #require(ScientificProvenancePolicy.cliCommand("fastq"))
        #expect(fastq.workflowKind == .dataWriting)
        #expect(fastq.createsOrModifiesScientificData)
        #expect(fastq.requiresProvenance)
        #expect(fastq.outputPathExpectation == .finalStoredPayload)

        let metadata = try #require(ScientificProvenancePolicy.cliCommand("metadata"))
        #expect(metadata.workflowKind == .dataWriting)
        #expect(metadata.createsOrModifiesScientificData)
        #expect(metadata.requiresProvenance)
        #expect(metadata.outputPathExpectation == .finalStoredPayload)

        let provenance = try #require(ScientificProvenancePolicy.cliCommand("provenance"))
        #expect(provenance.workflowKind == .metadataOnly)
        #expect(!provenance.createsOrModifiesScientificData)
        #expect(provenance.requiresProvenance)
        #expect(provenance.writer == "ProvenanceExporter")

        let analyze = try #require(ScientificProvenancePolicy.cliCommand("analyze"))
        #expect(analyze.workflowKind == .inspectOnly)
        #expect(!analyze.createsOrModifiesScientificData)
        #expect(!analyze.requiresProvenance)
        #expect(analyze.writer.isEmpty)
        #expect(analyze.outputPathExpectation == .none)

        let ops = try #require(ScientificProvenancePolicy.cliCommand("ops"))
        #expect(ops.workflowKind == .inspectOnly)
        #expect(!ops.requiresProvenance)
        #expect(ops.outputPathExpectation == .none)
    }

    @Test("native tools all have provenance policy entries")
    func nativeToolsHavePolicyEntries() {
        let toolNames = Set(NativeTool.allCases.map(\.rawValue))
        let policyNames = Set(ScientificProvenancePolicy.nativeToolPolicies.keys)
        let missing = toolNames.subtracting(policyNames).sorted()
        let stale = policyNames.subtracting(toolNames).sorted()

        #expect(
            missing.isEmpty,
            "Missing native tool provenance policies: \(missing.joined(separator: ", "))"
        )
        #expect(
            stale.isEmpty,
            "Native provenance policy references removed tools: \(stale.joined(separator: ", "))"
        )
    }

    @Test("native tool policies require concrete writer ownership")
    func nativeToolPoliciesRequireConcreteWriterOwnership() throws {
        let incomplete = NativeTool.allCases.compactMap { tool -> String? in
            guard let policy = ScientificProvenancePolicy.nativeTool(tool),
                  policy.workflowKind == .dataWriting,
                  policy.outputPathExpectation == .finalStoredPayload,
                  policy.createsOrModifiesScientificData,
                  policy.requiresProvenance,
                  !policy.writer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return tool.rawValue
            }
            return nil
        }

        #expect(
            incomplete.isEmpty,
            "Incomplete native tool provenance policies: \(incomplete.joined(separator: ", "))"
        )
    }

    @Test("data-writing policies declare concrete final-output provenance writers")
    func dataWritingPoliciesDeclareConcreteFinalOutputWriters() {
        let policies = Array(ScientificProvenancePolicy.cliCommandPolicies.values)
            + Array(ScientificProvenancePolicy.nativeToolPolicies.values)
        let incomplete = policies.compactMap { policy -> String? in
            guard policy.workflowKind == .dataWriting else { return nil }
            guard policy.createsOrModifiesScientificData,
                  policy.requiresProvenance,
                  policy.outputPathExpectation == .finalStoredPayload,
                  !policy.writer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return policy.id
            }
            return nil
        }.sorted()

        #expect(
            incomplete.isEmpty,
            "Data-writing policies missing concrete final-output provenance writers: \(incomplete.joined(separator: ", "))"
        )
    }

    @Test("top-level commands with persisted writing subcommands remain data-writing policies")
    func topLevelCommandsWithPersistedWritingSubcommandsRemainDataWriting() {
        let commandsWithPersistedWritingSubcommands = [
            // metadata set/import persist metadata.csv and samples.csv into final bundles/folders.
            "metadata"
        ]
        let loosened = commandsWithPersistedWritingSubcommands.compactMap { command -> String? in
            guard let policy = ScientificProvenancePolicy.cliCommand(command),
                  policy.workflowKind == .dataWriting,
                  policy.createsOrModifiesScientificData,
                  policy.requiresProvenance,
                  policy.outputPathExpectation == .finalStoredPayload,
                  !policy.writer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return command
            }
            return nil
        }

        #expect(
            loosened.isEmpty,
            "Top-level commands with persisted writing subcommands must remain data-writing policies: \(loosened.joined(separator: ", "))"
        )
    }

    @Test("non-data-writing policies do not claim scientific payload mutation")
    func nonDataWritingPoliciesDoNotClaimScientificPayloadMutation() {
        let policies = Array(ScientificProvenancePolicy.cliCommandPolicies.values)
            + Array(ScientificProvenancePolicy.nativeToolPolicies.values)
        let invalid = policies.compactMap { policy -> String? in
            guard policy.workflowKind != .dataWriting else { return nil }
            guard !policy.createsOrModifiesScientificData else { return policy.id }
            if policy.workflowKind == .inspectOnly {
                guard !policy.requiresProvenance,
                      policy.writer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      policy.outputPathExpectation == .none else {
                    return policy.id
                }
            }
            return nil
        }.sorted()

        #expect(
            invalid.isEmpty,
            "Non-data-writing policies incorrectly claim payload mutation or provenance writing: \(invalid.joined(separator: ", "))"
        )
    }

    @Test("final bundle fixture provenance records final stored payload paths")
    func finalBundleFixtureProvenanceRecordsFinalStoredPayloadPaths() throws {
        let alignPolicy = try #require(ScientificProvenancePolicy.cliCommand("align"))
        #expect(alignPolicy.workflowKind == .dataWriting)
        #expect(alignPolicy.outputPathExpectation == .finalStoredPayload)

        let finalBundleRelativePath = [
            "Tests",
            "Fixtures",
            "alignment",
            "sarscov2-mafft-e2e.lungfish",
            "Multiple Sequence Alignments",
            "sars-cov-2-genomes-mafft.lungfishmsa"
        ].joined(separator: "/")
        let provenanceURL = repositoryRoot()
            .appendingPathComponent(finalBundleRelativePath, isDirectory: true)
            .appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let envelope = try ProvenanceEnvelopeReader.decode(Data(contentsOf: provenanceURL))

        #expect(envelope.output?.path == finalBundleRelativePath)
        #expect(envelope.argv.contains(finalBundleRelativePath))
        #expect(envelope.reproducibleCommand.contains(finalBundleRelativePath))
        #expect(!containsTemporaryOrStagingPath(envelope.output?.path ?? ""))
        #expect(!containsTemporaryOrStagingPath(envelope.reproducibleCommand))
        #expect(!containsTemporaryOrStagingPath(try String(contentsOf: provenanceURL, encoding: .utf8)))
    }

    private func repositoryRoot() -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private func containsTemporaryOrStagingPath(_ value: String) -> Bool {
        [
            "/.tmp/",
            "/tmp/",
            "/var/folders/",
            ".staging-",
            "/staging/",
            "materialized-inputs",
            "fastq-derive-",
            "lungfish-orient-"
        ].contains { value.contains($0) }
    }
}

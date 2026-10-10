import Foundation
import Testing
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// Reads every frozen sidecar of the provenance compatibility corpus through the
/// production readers and compares what they say with reviewed expectations.
///
/// The corpus bytes are copied to a temporary project before any code reads them,
/// and the expectations are host-independent facts (see ProvenanceCompatFacts), so
/// the suite gives the same answer on every Mac. A write-side lane that changes
/// what a reader says about old bytes fails here.
@Suite("Provenance compatibility corpus readers")
struct ProvenanceCompatReaderTests {
    /// Whether the strict readers (`loadCanonical`, `decodeCanonical`) accept each case,
    /// pinned by hand from the bytes. A case missing from this table fails the suite.
    /// Bare runs and primitive records are rejected by design, so a sidecar of that shape
    /// in a folder read by a strict site is an error there.
    static let strictAcceptance: [String: Bool] = [
        "s1-cancelled-single-step": true,
        "s1-canonical-envelope-run": true,
        "s1-db-receipt-kraken2-viral": true,
        "s1-recorder-readsetplan": true,
        "s2-analysis-kraken2-fixture": true,
        "s3-gatk-container-bare-run": false,
        "s3-ncbi-fetch-alpha11": false,
        "s3-write-sidecar-bare-run": false,
        "s4-mcm-mhcref-shipped": false,
        "s4-msa-mafft-2026-05": false,
    ]

    @Test("the manifest is intact and every case has reviewed expected facts")
    func manifestIsIntactAndComplete() throws {
        try ProvenanceCompatCorpus.verifyManifest()
        let cases = try ProvenanceCompatCorpus.cases()
        #expect(!cases.isEmpty)
        for item in cases {
            #expect(
                ProvenanceCompatCorpus.expectedFactsData(for: item.id) != nil,
                "case \(item.id) has no expected facts"
            )
            #expect(Self.strictAcceptance[item.id] != nil, "case \(item.id) has no pinned strict acceptance")
        }
        #expect(Set(Self.strictAcceptance.keys).isSubset(of: Set(cases.map(\.id))))
    }

    @Test("facts equal the reviewed expected facts byte for byte", arguments: ProvenanceCompatCorpus.caseIDs())
    func factsEqualExpected(id: String) throws {
        let materialized = try ProvenanceCompatCorpus.materialize(id)
        defer { materialized.cleanup() }
        let facts = try ProvenanceCompatFacts.project(
            sidecar: materialized.sidecar,
            projectRoot: materialized.projectRoot
        )
        let expected = try #require(ProvenanceCompatCorpus.expectedFactsData(for: id), "case \(id) has no expected facts")
        #expect(String(decoding: try facts.canonicalJSON(), as: UTF8.self) == String(decoding: expected, as: UTF8.self))
    }

    @Test("strict acceptance is pinned per case", arguments: ProvenanceCompatCorpus.caseIDs())
    func strictAcceptanceIsPinned(id: String) throws {
        let pinned = try #require(Self.strictAcceptance[id] as Bool?, "case \(id) has no pinned strict acceptance")
        let materialized = try ProvenanceCompatCorpus.materialize(id)
        defer { materialized.cleanup() }

        let strict = try? ProvenanceEnvelopeReader.loadCanonical(fromSidecar: materialized.sidecar)
        #expect((strict != nil) == pinned)
        // The tolerant reader accepts every case, which is why the strict sites are the risk.
        #expect(try ProvenanceEnvelopeReader.load(fromSidecar: materialized.sidecar) != nil)

        let facts = try ProvenanceCompatFacts.project(
            sidecar: materialized.sidecar,
            projectRoot: materialized.projectRoot
        )
        #expect(facts.strictAccepts == pinned)
    }

    @Test("the finder and the lineage resolver return the case's own sidecar", arguments: ProvenanceCompatCorpus.caseIDs())
    func finderReturnsTheSameSidecar(id: String) throws {
        let materialized = try ProvenanceCompatCorpus.materialize(id)
        defer { materialized.cleanup() }
        let selection = try #require(materialized.selection, "case \(id) names no selection")

        let found = try #require(ProvenanceRecorder.findProvenanceEnvelope(for: selection))
        #expect(Self.sameFile(found.sidecarURL, materialized.sidecar))

        let direct = try ProvenanceCompatFacts.project(
            sidecar: materialized.sidecar,
            projectRoot: materialized.projectRoot
        )
        let viaFinder = try ProvenanceCompatFacts.project(
            envelope: found.envelope,
            sidecar: found.sidecarURL,
            projectRoot: materialized.projectRoot
        )
        #expect(viaFinder == direct)

        let lineage = ProvenanceLineageResolver().resolve(
            envelope: found.envelope,
            sidecarURL: found.sidecarURL,
            sourceRootURL: selection
        )
        #expect(lineage.count == 1)
        let last = try #require(lineage.last)
        #expect(last.sidecarURL.map { Self.sameFile($0, materialized.sidecar) } == true)
    }

    @Test("json and shell exports succeed and keep the source bytes", arguments: ProvenanceCompatCorpus.caseIDs())
    func exportsSucceed(id: String) throws {
        let materialized = try ProvenanceCompatCorpus.materialize(id)
        let exportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("provenance-compat-export-\(UUID().uuidString)", isDirectory: true)
        defer {
            materialized.cleanup()
            try? FileManager.default.removeItem(at: exportRoot)
        }
        let envelope = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: materialized.sidecar))
        let sourceBytes = try Data(contentsOf: materialized.sidecar)
        let exporter = ProvenanceExporter(signingProvider: nil)

        let json = try exporter.exportBundle(
            envelope,
            format: .json,
            to: exportRoot.appendingPathComponent("json", isDirectory: true),
            sourceSidecarURL: materialized.sidecar,
            sourceRootURL: materialized.selection
        )
        #expect(json.primaryArtifactURL.lastPathComponent == "provenance.json")
        let exported = try ProvenanceEnvelopeReader.decodeCanonical(Data(contentsOf: json.primaryArtifactURL))
        #expect(exported.workflowName == envelope.workflowName)
        #expect(exported.toolName == envelope.toolName)
        #expect(exported.toolVersion == envelope.toolVersion)
        #expect(exported.argv == envelope.argv)
        #expect(exported.exitStatus == envelope.exitStatus)
        #expect(
            json.copiedSidecarURLs.contains { (try? Data(contentsOf: $0)) == sourceBytes },
            "the export keeps a byte-identical copy of the source sidecar"
        )

        let shell = try exporter.exportBundle(
            envelope,
            format: .shell,
            to: exportRoot.appendingPathComponent("shell", isDirectory: true),
            sourceSidecarURL: materialized.sidecar,
            sourceRootURL: materialized.selection
        )
        #expect(shell.primaryArtifactURL.lastPathComponent == "run.sh")
        let script = try String(contentsOf: shell.primaryArtifactURL, encoding: .utf8)
        #expect(!script.isEmpty)

        // The readers and exporters never write to the case; the corpus on disk is unchanged.
        try ProvenanceCompatCorpus.verifyManifest()
        #expect(try Data(contentsOf: materialized.sidecar) == sourceBytes)
    }

    @Test("the alpha.11 fetch record reads as the bytes say")
    func alpha11FetchRecordHandAsserts() throws {
        let materialized = try ProvenanceCompatCorpus.materialize("s3-ncbi-fetch-alpha11")
        defer { materialized.cleanup() }
        let envelope = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: materialized.sidecar))

        #expect(envelope.workflowName == "ncbi-sequence-fetch")
        #expect(envelope.toolName == "ncbi-efetch")
        #expect(envelope.toolVersion == "NCBI E-utilities API")
        #expect(envelope.exitStatus == 0)
        #expect(Array(envelope.argv.prefix(9)) == [
            "lungfish", "fetch", "ncbi", "MN908947.3", "--db", "nucleotide",
            "--fetch-format", "gff3", "--save-to",
        ])
        #expect(Array(envelope.argv.suffix(2)) == ["--format", "text"])
        #expect(envelope.argv.count == 12)
        #expect(envelope.argv[9].hasSuffix("/MN908947.3.gff3"))

        let recordedOutput = try #require(envelope.outputs.first)
        #expect(recordedOutput.checksumSHA256 == "7edcb9f6c6de7ba570106926e5af55f7e45ed5f8b92b9a33664fb9ca2711ae32")
        #expect(recordedOutput.fileSize == 4040)
        #expect(recordedOutput.role == .output)
        #expect(recordedOutput.path == envelope.argv[9])

        // The payload that sits beside the sidecar in the repository is the file the record names.
        let payload = materialized.sidecar.deletingLastPathComponent().appendingPathComponent("MN908947.3.gff3")
        #expect(try ProvenanceFileHasher.sha256(of: payload) == recordedOutput.checksumSHA256)
        #expect(try ProvenanceFileHasher.fileSize(of: payload) == recordedOutput.fileSize)

        // A bare run is not an envelope, so the strict readers reject it.
        #expect(throws: (any Error).self) {
            try ProvenanceEnvelopeReader.loadCanonical(fromSidecar: materialized.sidecar)
        }
        // The legacy tool name `lungfish` is the executable the GUI import gate recognizes.
        #expect(envelope.argv.first == "lungfish")
        #expect(envelope.legacyWorkflowRun().status == .completed)
    }

    // MARK: Captured writer shapes

    @Test("the cancelled case reads as cancelled although its only step exited 0")
    func cancelledCaseReadsAsCancelledWhileTheLastStepExitedZero() throws {
        let facts = try Self.liveFacts("s1-cancelled-single-step")
        #expect(facts.status == "cancelled")
        #expect(facts.embeddedRunStatus == "cancelled")
        #expect(facts.readStatus == "cancelled")
        #expect(facts.exitStatus == 0)
        #expect(facts.steps.map(\.exitStatus) == [0])
        #expect(facts.steps.first?.peakMemoryBytes == 42_000_000)
        // `ops stats` decodes the file as a run and counts it, but not as completed.
        #expect(facts.opsStats.decodesAsWorkflowRun)
        #expect(facts.opsStats.completedRunCount == 0)
    }

    @Test("the recorder case holds its readSetPlan only in the run parameters")
    func recorderCaseHoldsTheReadSetPlanOnlyInTheRunParameters() throws {
        let facts = try Self.liveFacts("s1-recorder-readsetplan")
        guard case .object(let explicit) = facts.explicitOptions,
              case .object(let runParameters) = facts.legacyRunParameters else {
            Issue.record("options and run parameters must be JSON objects")
            return
        }
        #expect(explicit["readSetPlan"] == nil)
        guard let plan = runParameters["readSetPlan"],
              case .object(let planMembers)? = Self.member(plan, "value"),
              case .object(let reason)? = planMembers["singleReadReason"] else {
            Issue.record("the run parameters must hold the readSetPlan dictionary")
            return
        }
        #expect(reason["value"] == .string("orphan reads run as single reads"))
        #expect(planMembers["runs"] == .object(["type": .string("integer"), "value": .integer(2)]))
        #expect(facts.steps.map(\.toolName) == ["kraken2", "bracken"])
        #expect(facts.steps.map(\.exitStatus) == [0, 0])
        #expect(facts.status == "completed")
    }

    @Test("the GATK container case shows its image and digest on both steps in the legacy views")
    func gatkContainerCaseShowsItsContainerOnBothStepsInTheLegacyViews() throws {
        let facts = try Self.liveFacts("s3-gatk-container-bare-run")
        let image = ProvenanceCompatScenarios.gatkContainerImage
        let digest = ProvenanceCompatScenarios.gatkContainerDigest

        #expect(facts.decodedBy == .workflowRun)
        #expect(!facts.strictAccepts)
        #expect(facts.steps.count == 2)
        // The bytes hold the container identity on each step, with no runtime identity of the step's own.
        #expect(facts.steps.map(\.recorded) == [
            ["containerImage": image, "containerDigest": digest],
            ["containerImage": image, "containerDigest": digest],
        ])
        // The legacy views, which the readers use, show it on both steps.
        for view in [facts.legacyRunSteps, facts.canonicalRunSteps] {
            #expect(view.count == 2)
            #expect(view.map(\.containerImage) == [image, image])
            #expect(view.map(\.containerDigest) == [digest, digest])
            #expect(view.map(\.wallTime) == [21.5, 40.75])
        }
        #expect(facts.steps.map(\.wallTimeSeconds) == [21.5, 40.75])
        #expect(facts.steps.map(\.exitStatus) == [0, 0])
        #expect(facts.steps.map(\.dependsOn) == [[], []])
        // The run parameters name the container too.
        guard case .object(let parameters) = facts.legacyRunParameters else {
            Issue.record("run parameters must be a JSON object")
            return
        }
        #expect(parameters["containerImage"] == .object(["type": .string("string"), "value": .string(image)]))
        #expect(parameters["containerDigest"] == .object(["type": .string("string"), "value": .string(digest)]))
    }

    @Test("the bare-run writer and the canonical-envelope writer agree on every fact but the declared ones")
    func bareRunAndCanonicalEnvelopeAgreeExceptForTheDeclaredFacts() throws {
        let envelope = try Self.liveFacts("s1-canonical-envelope-run")
        let bare = try Self.liveFacts("s3-write-sidecar-bare-run")

        // Facts a migration from writeSidecar to canonicalEnvelope must keep.
        #expect(envelope.argv == bare.argv)
        #expect(envelope.durableReplayArgv == bare.durableReplayArgv)
        #expect(envelope.reproducibleCommand == bare.reproducibleCommand)
        #expect(envelope.workflowName == bare.workflowName)
        #expect(envelope.toolName == bare.toolName)
        #expect(envelope.toolVersion == bare.toolVersion)
        #expect(envelope.exitStatus == bare.exitStatus)
        #expect(envelope.status == bare.status)
        #expect(envelope.readStatus == bare.readStatus)
        #expect(envelope.explicitOptions == bare.explicitOptions)
        #expect(envelope.defaultOptions == bare.defaultOptions)
        #expect(envelope.resolvedDefaultOptions == bare.resolvedDefaultOptions)
        #expect(envelope.legacyRunParameters == bare.legacyRunParameters)
        #expect(envelope.output == bare.output)
        #expect(envelope.outputs == bare.outputs)
        // Steps compare in full, so a lost replay argv, step graph, wall time or container identity shows.
        #expect(envelope.steps == bare.steps)
        #expect(envelope.steps.count == 2)
        #expect(envelope.steps.last?.argv.first?.hasPrefix("<tool-root>/") == true)
        // The run's only replayable command is the second step's durable argv, and the second step depends on the first.
        #expect(envelope.steps[1].durableReplayArgv == bare.steps[1].durableReplayArgv)
        #expect(envelope.steps[1].durableReplayArgv?.first == "lungfish-cli")
        #expect(envelope.steps[1].dependsOn == [0])
        #expect(bare.steps[1].dependsOn == [0])
        #expect(envelope.steps.map(\.wallTimeSeconds) == bare.steps.map(\.wallTimeSeconds))
        #expect(envelope.legacyRunSteps == bare.legacyRunSteps)
        #expect(envelope.canonicalRunSteps == bare.canonicalRunSteps)

        // The declared differences.
        #expect(bare.decodedBy == .workflowRun)
        #expect(envelope.decodedBy == .envelope)
        #expect(!bare.strictAccepts)
        #expect(envelope.strictAccepts)
        #expect(bare.embeddedRunStatus == nil)
        #expect(envelope.embeddedRunStatus == "completed")
        // The envelope keeps the run's exact wall time. The bare file keeps whole-second dates.
        // The run wall times agree within one second and the step wall times agree exactly (above).
        #expect(envelope.wallTimeSeconds == 41.5)
        #expect(bare.wallTimeSeconds == 41)
        if let converted = envelope.wallTimeSeconds, let original = bare.wallTimeSeconds {
            #expect(abs(converted - original) <= 1)
        }
        // A bare run converted in memory lists a file once per step, the envelope read back lists it once.
        // Files compare as a set on path, role, SHA-256 and size.
        #expect(Self.fileKeys(bare.files) == Self.fileKeys(envelope.files))
        #expect(bare.files.count == envelope.files.count + 1)
    }

    // MARK: Helpers

    private static func liveFacts(_ id: String) throws -> ProvenanceCompatFacts {
        let materialized = try ProvenanceCompatCorpus.materialize(id)
        defer { materialized.cleanup() }
        return try ProvenanceCompatFacts.project(sidecar: materialized.sidecar, projectRoot: materialized.projectRoot)
    }

    private static func member(_ value: ProvenanceCompatFacts.Value, _ key: String) -> ProvenanceCompatFacts.Value? {
        guard case .object(let members) = value else { return nil }
        return members[key]
    }

    /// A file identified by path, role, SHA-256 and size, which is how the parity ruling compares files.
    private static func fileKeys(_ files: [ProvenanceCompatFacts.FileFact]) -> Set<String> {
        Set(files.map { file in
            [file.path, file.role, file.sha256 ?? "-", file.size.map(String.init) ?? "-"].joined(separator: "\u{0}")
        })
    }

    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

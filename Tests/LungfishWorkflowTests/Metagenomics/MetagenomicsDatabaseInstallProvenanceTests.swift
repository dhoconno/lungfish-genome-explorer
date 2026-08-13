import Darwin
import Foundation
import Testing
@testable import LungfishWorkflow

@Suite("Metagenomics database installation provenance")
struct MetagenomicsDatabaseInstallProvenanceTests {
    @Test("payload snapshot sorts files, excludes sidecars and has a stable aggregate")
    func payloadSnapshotIsDeterministic() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try write("hello", to: root.appendingPathComponent("z.txt"))
        try write("abc", to: root.appendingPathComponent("a.txt"))
        try write("ignored", to: root.appendingPathComponent(".lungfish-provenance.json"))
        try write("ignored", to: root.appendingPathComponent(".install-transient"))

        let snapshot = try MetagenomicsDatabasePayloadDigester.snapshot(at: root)

        #expect(snapshot.rootURL == root.standardizedFileURL)
        #expect(snapshot.files.map(\.path) == ["a.txt", "z.txt"])
        #expect(snapshot.files.map(\.checksumSHA256) == [
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        ])
        #expect(snapshot.files.map(\.fileSize) == [3, 5])
        #expect(snapshot.totalSizeBytes == 8)
        // SHA-256 of UTF-8 lines with a final LF:
        // a.txt<TAB>ba...15ad<TAB>3<LF>z.txt<TAB>2cf...9824<TAB>5<LF>
        #expect(snapshot.aggregateSHA256 == "a5509e76c42d8474b8c3fa50e18d900ea051c699ecc66119ad10f52b2b9c570a")
    }

    @Test("payload snapshot rejects symbolic links that escape the root")
    func payloadSnapshotRejectsSymbolicLinksOutsideRoot() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.deletingLastPathComponent().appendingPathComponent("outside-(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: target) }
        try write("target", to: target)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )

        #expect(throws: MetagenomicsDatabasePayloadDigestError.unsafePayload(path: link.path)) {
            _ = try MetagenomicsDatabasePayloadDigester.snapshot(at: root)
        }
    }

    @Test("payload snapshot rejects nonregular filesystem entries")
    func payloadSnapshotRejectsNonregularEntries() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("named-pipe")
        #expect(Darwin.mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0)

        #expect(throws: MetagenomicsDatabasePayloadDigestError.unsafePayload(path: fifo.path)) {
            _ = try MetagenomicsDatabasePayloadDigester.snapshot(at: root)
        }
    }

    @Test("success provenance rehydrates staging paths into final payload paths")
    func successProvenanceContainsOnlyFinalPaths() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let final = root.appendingPathComponent("installed", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        try write("payload", to: staging.appendingPathComponent("hash.k2d"))
        let inputURL = root.appendingPathComponent("source.fasta")
        try write(">source\nACGT\n", to: inputURL)
        let input = try ProvenanceFileDescriptor.file(url: inputURL, format: .fasta, role: .input)

        let snapshot = try MetagenomicsDatabasePayloadDigester.snapshot(at: staging)
        let attempt = makeAttempt(staging: staging, final: final, inputs: [input])
        let writer = CanonicalMetagenomicsDatabaseInstallProvenanceWriter(
            now: { Self.fixedDate },
            uuid: { Self.fixedUUID }
        )

        try writer.writeSuccess(attempt, snapshot: snapshot)

        let sidecar = final.appendingPathComponent(".lungfish-provenance.json")
        let envelope = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        let encoded = String(decoding: try Data(contentsOf: sidecar), as: UTF8.self)
        let expectedOutput = final.appendingPathComponent("hash.k2d").path
        let step = try #require(envelope.steps.only)
        let inputFile = try #require(envelope.files.first { $0.role == .input })
        let outputFile = try #require(envelope.files.first { $0.role == .output })

        #expect(envelope.workflowName == "metagenomics.database.install")
        #expect(envelope.workflowVersion == "kraken2-special-v1")
        #expect(envelope.toolName == "kraken2-build")
        #expect(envelope.toolVersion == "2.1.3")
        #expect(envelope.argv == ["kraken2-build", "--db", final.path, "--special", "silva"])
        #expect(envelope.durableReplayArgv == envelope.argv)
        #expect(envelope.options.explicit["threads"] == .integer(4))
        #expect(envelope.options.defaults["kmerLength"] == .integer(35))
        #expect(envelope.options.resolvedDefaults["payloadAggregateSHA256"] == .string(snapshot.aggregateSHA256))
        #expect(envelope.options.resolvedDefaults["intendedFinalPath"] == .string(final.path))
        #expect(envelope.runtimeIdentity.condaEnvironment == "kraken2")
        #expect(envelope.output?.path == expectedOutput)
        #expect(envelope.outputs.map(\.path) == [expectedOutput])
        #expect(envelope.files.map(\.path) == [inputURL.path, expectedOutput])
        #expect(envelope.files.map(\.role) == [.input, .output])
        #expect(inputFile.checksumSHA256 == input.checksumSHA256)
        #expect(inputFile.fileSize == input.fileSize)
        #expect(outputFile.checksumSHA256 == snapshot.files[0].checksumSHA256)
        #expect(outputFile.fileSize == snapshot.files[0].fileSize)
        #expect(envelope.steps.count == 1)
        #expect(step.argv == envelope.argv)
        #expect(step.durableReplayArgv == envelope.argv)
        #expect(step.resolvedOptions["databaseRoot"] == .string(final.path))
        #expect(step.outputs.map(\.path) == [expectedOutput])
        #expect(step.exitStatus == 0)
        #expect(step.wallTimeSeconds == 5)
        #expect(step.stderr == " completed\n")
        #expect(envelope.wallTimeSeconds == 5)
        #expect(envelope.exitStatus == 0)
        #expect(!encoded.contains(staging.path))
    }

    @Test("success provenance rejects incomplete claimed descriptors")
    func successProvenanceRejectsIncompleteDescriptors() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let final = root.appendingPathComponent("installed", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        try write("payload", to: staging.appendingPathComponent("hash.k2d"))
        let snapshot = try MetagenomicsDatabasePayloadDigester.snapshot(at: staging)
        let incompleteInput = ProvenanceFileDescriptor(
            path: root.appendingPathComponent("source.fasta").path,
            fileSize: 12,
            role: .input
        )
        let attempt = makeAttempt(staging: staging, final: final, inputs: [incompleteInput])
        let writer = CanonicalMetagenomicsDatabaseInstallProvenanceWriter()

        #expect(throws: MetagenomicsDatabaseInstallProvenanceError.incompleteFileDescriptor(path: incompleteInput.path)) {
            try writer.writeSuccess(attempt, snapshot: snapshot)
        }
        #expect(!FileManager.default.fileExists(atPath: final.appendingPathComponent(".lungfish-provenance.json").path))
    }

    @Test("failure provenance records the attempted operation without outputs")
    func failureProvenanceDoesNotClaimScientificOutputs() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let final = root.appendingPathComponent("installed", isDirectory: true)
        let history = root.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagedInput = ProvenanceFileDescriptor(
            path: staging.appendingPathComponent("attempted-input.fasta").path,
            checksumSHA256: "input-sha",
            fileSize: 12,
            role: .input
        )
        let attempt = makeAttempt(staging: staging, final: final, inputs: [stagedInput])
        let writer = CanonicalMetagenomicsDatabaseInstallProvenanceWriter(
            now: { Self.fixedDate },
            uuid: { Self.fixedUUID }
        )

        try writer.writeFailure(
            attempt,
            error: MetagenomicsDatabaseInstallFailure.failed(
                exitStatus: 0,
                message: "build failed",
                stderr: "  bad build  "
            ),
            historyDirectory: history
        )

        let databaseHistory = history.appendingPathComponent("kraken2-special-silva", isDirectory: true)
        let receipts = try FileManager.default.contentsOfDirectory(at: databaseHistory, includingPropertiesForKeys: nil)
        let receipt = try #require(receipts.only)
        #expect(receipt.lastPathComponent.hasPrefix("2023-11-14T22:13:20Z-00000000-0000-0000-0000-000000000001"))
        let envelope = try #require(try ProvenanceEnvelopeReader.load(fromSidecar: receipt))
        let rawJSON = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        let step = try #require(envelope.steps.only)

        #expect(envelope.exitStatus == 1)
        #expect(envelope.stderr == "  bad build  ")
        #expect(envelope.workflowName == "metagenomics.database.install")
        let attemptedArgv = ["kraken2-build", "--db", staging.path, "--special", "silva"]
        #expect(envelope.argv == attemptedArgv)
        #expect(envelope.durableReplayArgv == attemptedArgv)
        #expect(envelope.options.explicit["stagingSource"] == .string(staging.path))
        #expect(envelope.options.defaults["workingDirectory"] == .string(staging.path))
        #expect(envelope.options.resolvedDefaults["databaseRoot"] == .string(staging.path))
        #expect(envelope.options.resolvedDefaults["recipeSource"] == .string("kraken2 --db \(staging.path) --special silva"))
        #expect(envelope.options.resolvedDefaults["intendedFinalPath"] == .string(final.path))
        #expect(envelope.output == nil)
        #expect(envelope.outputs.isEmpty)
        #expect(rawJSON["output"] == nil)
        #expect((rawJSON["outputs"] as? [Any])?.isEmpty == true)
        #expect(envelope.files.map(\.path) == [stagedInput.path])
        #expect(envelope.files.allSatisfy { $0.role != .output })
        #expect(envelope.steps.allSatisfy { $0.outputs.isEmpty })
        #expect(envelope.steps.allSatisfy { $0.exitStatus != nil })
        #expect(step.argv == attemptedArgv)
        #expect(step.durableReplayArgv == attemptedArgv)
        #expect(step.resolvedOptions["databaseRoot"] == .string(staging.path))
        #expect(step.inputs.map(\.path) == [stagedInput.path])
        #expect(!envelope.argv.contains { $0.contains(final.path) })
        #expect(!(envelope.durableReplayArgv ?? []).contains { $0.contains(final.path) })
        #expect(!envelope.files.contains { $0.path.contains(final.path) })
        #expect(!envelope.steps.flatMap(\.argv).contains { $0.contains(final.path) })
        #expect(!envelope.steps.flatMap { $0.durableReplayArgv ?? [] }.contains { $0.contains(final.path) })
        #expect(!envelope.steps.flatMap(\.inputs).contains { $0.path.contains(final.path) })
    }

    @Test("failure status maps zero failures and cancellation to conventional statuses")
    func failureStatusMapping() {
        #expect(MetagenomicsDatabaseInstallFailure.failed(exitStatus: 0, message: "x", stderr: "").provenanceExitStatus == 1)
        #expect(MetagenomicsDatabaseInstallFailure.cancelled(message: "x", stderr: "").provenanceExitStatus == 130)
    }

    private static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    private static let fixedUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private func makeAttempt(
        staging: URL,
        final: URL,
        inputs: [ProvenanceFileDescriptor] = []
    ) -> MetagenomicsDatabaseInstallAttempt {
        let output = ProvenanceFileDescriptor(
            path: staging.appendingPathComponent("hash.k2d").path,
            checksumSHA256: "fixture-sha",
            fileSize: 7,
            role: .output
        )
        let evidence = MetagenomicsDatabaseInstallStepEvidence(
            toolName: "kraken2-build",
            toolVersion: "2.1.3",
            argv: ["kraken2-build", "--db", staging.path, "--special", "silva"],
            durableReplayArgv: ["kraken2-build", "--db", staging.path, "--special", "silva"],
            resolvedOptions: ["databaseRoot": .string(staging.path)],
            runtimeIdentity: ProvenanceRuntimeIdentity.fixture(
                executablePath: "/managed/kraken2/bin/kraken2-build",
                condaEnvironment: "kraken2"
            ),
            inputs: inputs,
            outputs: [output],
            exitStatus: 0,
            startedAt: Self.fixedDate,
            completedAt: Self.fixedDate.addingTimeInterval(5),
            stderr: " completed\n"
        )
        return MetagenomicsDatabaseInstallAttempt(
            database: MetagenomicsDatabaseInfo(
                name: "SILVA rRNA",
                tool: "kraken2",
                version: "kraken2-special-v1",
                sizeBytes: 1,
                catalogID: "kraken2-special-silva",
                installationRecipe: .kraken2Special(type: .silva),
                description: "fixture",
                recommendedRAM: 1
            ),
            finalURL: final,
            recipeSource: "kraken2 --db \(staging.path) --special silva",
            explicitOptions: [
                "threads": .integer(4),
                "stagingSource": .string(staging.path),
            ],
            defaultOptions: [
                "kmerLength": .integer(35),
                "workingDirectory": .string(staging.path),
            ],
            resolvedOptions: ["databaseRoot": .string(staging.path)],
            steps: [evidence],
            startedAt: Self.fixedDate,
            completedAt: Self.fixedDate.addingTimeInterval(5)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    private func write(_ string: String, to url: URL) throws {
        try Data(string.utf8).write(to: url)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

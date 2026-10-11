// ProvenanceSchemaVersion2EncoderTests.swift - What a newly written provenance record holds at schema version 2
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Every assertion here reads a record that `ProvenanceWriter` has just written, as raw JSON, so
/// it checks the bytes a reader of any build meets and not only what the Swift model holds.
/// `ProvenanceSchemaVersion2Tests` shows that readers take the same shape, derived from version 1
/// bytes.
final class ProvenanceSchemaVersion2EncoderTests: XCTestCase {

    /// The 14 keys version 1 wrote twice. `status` is canonical and stays.
    static let topLevelAliases = ["name", "startTime", "endTime", "appVersion", "hostOS", "runtime", "parameters"]
    static let stepAliases = ["command", "exitCode", "wallTime", "startTime", "endTime"]
    static let descriptorAliases = ["sha256", "sizeBytes"]

    // MARK: Writing

    /// A record written by `ProvenanceWriter` and the folder that holds it.
    struct WrittenRecord {
        let temporaryRoot: URL
        let sidecar: URL
        let data: Data

        var text: String { String(decoding: data, as: UTF8.self) }

        func json() throws -> [String: Any] {
            try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    /// Writes `envelope` as `.lungfish-provenance.json` into a fresh folder, inside a `.lungfish`
    /// project when `inProject` is true, where the writer rewrites paths for the project.
    static func write(
        _ envelope: ProvenanceEnvelope,
        inProject: Bool = false,
        signingProvider: (any ProvenanceSigningProvider)? = nil
    ) throws -> WrittenRecord {
        let temporaryRoot = try TestTempDirectory.make(prefix: "provenance-v2-encoder")
        let folder = inProject
            ? temporaryRoot.appendingPathComponent("Encoder.lungfish/Analyses/run", isDirectory: true)
            : temporaryRoot.appendingPathComponent("run", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sidecar = folder.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        try ProvenanceWriter(signingProvider: signingProvider).write(envelope, toSidecar: sidecar)
        return WrittenRecord(temporaryRoot: temporaryRoot, sidecar: sidecar, data: try Data(contentsOf: sidecar))
    }

    /// A completed one-step run whose descriptors carry digests and sizes and whose step carries
    /// every field version 1 doubled. It holds no nested run, so a decoded copy can equal it.
    static func completedRun(schemaVersion: Int? = nil) -> ProvenanceEnvelope {
        let input = ProvenanceFileDescriptor(
            path: "/data/reads.fastq",
            checksumSHA256: String(repeating: "a", count: 64),
            fileSize: 12,
            format: .fastq,
            role: .input
        )
        let output = ProvenanceFileDescriptor(
            path: "/data/trimmed.fastq",
            checksumSHA256: String(repeating: "b", count: 64),
            fileSize: 22,
            format: .fastq,
            role: .output
        )
        let step = ProvenanceStep(
            toolName: "fastp",
            toolVersion: "0.24.1",
            argv: ["fastp", "-i", "/data/reads.fastq", "-o", "/data/trimmed.fastq"],
            inputs: [input],
            outputs: [output],
            exitStatus: 0,
            wallTimeSeconds: 2,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_002)
        )
        let options = ProvenanceOptions(explicit: ["threads": .integer(2)])
        let runtime = ProvenanceRuntimeIdentity.fixture()
        if let schemaVersion {
            return ProvenanceEnvelope(
                schemaVersion: schemaVersion,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                workflowName: "fastq.trim.fastp",
                workflowVersion: "fixture-workflow-version",
                toolName: "fastp",
                toolVersion: "0.24.1",
                argv: step.argv,
                options: options,
                runtimeIdentity: runtime,
                files: [input, output],
                output: output,
                outputs: [output],
                steps: [step],
                wallTimeSeconds: 2,
                exitStatus: 0,
                status: .completed
            )
        }
        return ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            workflowName: "fastq.trim.fastp",
            workflowVersion: "fixture-workflow-version",
            toolName: "fastp",
            toolVersion: "0.24.1",
            argv: step.argv,
            options: options,
            runtimeIdentity: runtime,
            files: [input, output],
            output: output,
            outputs: [output],
            steps: [step],
            wallTimeSeconds: 2,
            exitStatus: 0,
            status: .completed
        )
    }

    /// Every descriptor of a raw record: the run's files, output and outputs and each step's inputs
    /// and outputs.
    static func descriptors(of json: [String: Any]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for key in ["files", "outputs"] {
            result += json[key] as? [[String: Any]] ?? []
        }
        if let output = json["output"] as? [String: Any] { result.append(output) }
        for step in json["steps"] as? [[String: Any]] ?? [] {
            result += step["inputs"] as? [[String: Any]] ?? []
            result += step["outputs"] as? [[String: Any]] ?? []
        }
        return result
    }

    // MARK: S3, schema version 2 without the aliases

    func testANewlyWrittenRecordIsVersion2WithoutTheFourteenAliasKeys() throws {
        for inProject in [false, true] {
            let written = try Self.write(Self.completedRun(), inProject: inProject)
            defer { written.cleanup() }
            let json = try written.json()

            XCTAssertEqual(json["schemaVersion"] as? Int, 2, "inProject \(inProject)")
            for key in Self.topLevelAliases {
                XCTAssertNil(json[key], "top-level alias \(key), inProject \(inProject)")
            }
            XCTAssertEqual(json["status"] as? String, "completed", "status is canonical and stays")
            XCTAssertEqual(json["workflowName"] as? String, "fastq.trim.fastp")

            let steps = try XCTUnwrap(json["steps"] as? [[String: Any]])
            XCTAssertEqual(steps.count, 1)
            for step in steps {
                for key in Self.stepAliases {
                    XCTAssertNil(step[key], "step alias \(key), inProject \(inProject)")
                }
                XCTAssertNotNil(step["argv"])
                XCTAssertEqual(step["exitStatus"] as? Int, 0)
                XCTAssertEqual(step["wallTimeSeconds"] as? Double, 2)
                XCTAssertEqual(step["startedAt"] as? String, "2023-11-14T22:13:20Z")
                XCTAssertEqual(step["completedAt"] as? String, "2023-11-14T22:13:22Z")
            }

            let descriptors = Self.descriptors(of: json)
            XCTAssertEqual(descriptors.count, 6, "two files, one output, one in outputs, one step input, one step output")
            for descriptor in descriptors {
                for key in Self.descriptorAliases {
                    XCTAssertNil(descriptor[key], "descriptor alias \(key), inProject \(inProject)")
                }
                XCTAssertEqual((descriptor["checksumSHA256"] as? String)?.count, 64)
                XCTAssertNotNil(descriptor["fileSize"] as? Int)
            }
        }
    }

    /// Rebuild sites copy the schema version of the record they read (`FASTQIngestionService`
    /// passes `existingEnvelope.schemaVersion`). The encoder writes its own version, so a version 1
    /// record rewritten today is version 2 and holds no alias.
    func testARebuiltEnvelopeIsWrittenAtTheEncodersVersionNotTheOneItCopied() throws {
        let rebuilt = Self.completedRun(schemaVersion: 1)
        XCTAssertEqual(rebuilt.schemaVersion, 1)
        let written = try Self.write(rebuilt)
        defer { written.cleanup() }
        let json = try written.json()
        XCTAssertEqual(json["schemaVersion"] as? Int, 2)
        XCTAssertNil(json["startTime"])
        XCTAssertEqual(try ProvenanceEnvelopeReader.decodeCanonical(written.data).schemaVersion, 2)
    }

    /// A writer's envelope reads back equal through the strict reader, so dropping the aliases
    /// loses no fact the model holds.
    func testTheWrittenRecordReadsBackAsTheEnvelopeThatWasWritten() throws {
        let envelope = Self.completedRun()
        XCTAssertEqual(envelope.schemaVersion, 2, "a writer's envelope holds the version it is written at")
        let written = try Self.write(envelope)
        defer { written.cleanup() }
        XCTAssertEqual(try ProvenanceEnvelopeReader.decodeCanonical(written.data), envelope)
    }

    // MARK: S5, slashes without escapes

    /// Raw JSON shows a path as it is typed. Outside a project the writer keeps the paths, and
    /// inside one it writes the placeholders the project rewrite makes.
    func testANewlyWrittenRecordWritesSlashesWithoutEscapes() throws {
        for inProject in [false, true] {
            let written = try Self.write(Self.completedRun(), inProject: inProject)
            defer { written.cleanup() }
            XCTAssertFalse(written.text.contains("\\/"), "inProject \(inProject): \(written.text)")
            let readsPath = inProject ? "<external>/reads.fastq" : "/data/reads.fastq"
            XCTAssertTrue(written.text.contains("\"path\" : \"\(readsPath)\""), "inProject \(inProject): \(written.text)")
        }
    }

    /// A signature covers the parsed record reserialized, not its raw bytes, so a record signed with
    /// unescaped slashes verifies, and the same record with escaped slashes has the same payload.
    func testASignedRecordVerifiesAndItsSignedPayloadIgnoresSlashEscaping() throws {
        let written = try Self.write(
            Self.completedRun(),
            inProject: true,
            signingProvider: LocalProvenanceSigningProvider(privateKey: "unit-test-private-key")
        )
        defer { written.cleanup() }
        XCTAssertFalse(written.text.contains("\\/"))
        XCTAssertNoThrow(try ProvenanceSignatureVerifier.verify(provenanceURL: written.sidecar))

        let object = try JSONSerialization.jsonObject(with: written.data)
        let escaped = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        let unescaped = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertNotEqual(escaped, unescaped)
        let payload = try ProvenanceSigningPayload.data(forProvenanceData: written.data)
        XCTAssertEqual(try ProvenanceSigningPayload.data(forProvenanceData: escaped), payload)
        XCTAssertEqual(try ProvenanceSigningPayload.data(forProvenanceData: unescaped), payload)
    }

    // MARK: V5, no process ID and the writer's executable as <external>/<file name>

    /// The writer's own executable, from the default identity or passed as `argv[0]` the way the
    /// genotype pipelines pass it, is written as `<external>/<file name>`, and no process ID is
    /// written, inside and outside projects.
    func testANewlyWrittenRecordHoldsNoProcessIDAndNamesItsOwnExecutableExternally() throws {
        let ownArgumentZero = try XCTUnwrap(CommandLine.arguments.first)
        let step = ProvenanceStep(
            toolName: "lungfish-cli",
            runtimeIdentity: ProvenanceRuntimeIdentity(executablePath: ownArgumentZero),
            exitStatus: 0
        )
        let envelope = ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            workflowName: "v5.own-executable",
            toolName: "lungfish-cli",
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            steps: [step],
            exitStatus: 0
        )
        let defaultName = URL(fileURLWithPath: ProvenanceRuntimeIdentity.currentExecutablePath).lastPathComponent
        let argumentName = URL(fileURLWithPath: ownArgumentZero).lastPathComponent
        for inProject in [false, true] {
            let written = try Self.write(envelope, inProject: inProject)
            defer { written.cleanup() }
            let json = try written.json()
            let runtime = try XCTUnwrap(json["runtimeIdentity"] as? [String: Any])
            XCTAssertNil(runtime["processIdentifier"], "inProject \(inProject)")
            XCTAssertEqual(runtime["executablePath"] as? String, "<external>/\(defaultName)", "inProject \(inProject)")
            let steps = try XCTUnwrap(json["steps"] as? [[String: Any]])
            let stepRuntime = try XCTUnwrap(steps.first?["runtimeIdentity"] as? [String: Any])
            XCTAssertNil(stepRuntime["processIdentifier"], "inProject \(inProject)")
            XCTAssertEqual(stepRuntime["executablePath"] as? String, "<external>/\(argumentName)", "inProject \(inProject)")
            XCTAssertFalse(written.text.contains("\"processIdentifier\""), "inProject \(inProject)")
        }
    }

    /// An executable a writer names for a tool keeps the path it gave, and the mapper's bare name
    /// stays bare. Only the writer's own executable is replaced.
    func testAToolExecutableAWriterNamesKeepsItsPath() {
        XCTAssertEqual(ProvenanceRuntimeIdentity(executablePath: "/usr/bin/tar").executablePath, "/usr/bin/tar")
        XCTAssertEqual(ProvenanceRuntimeIdentity(executablePath: "minimap2").executablePath, "minimap2")
        XCTAssertEqual(
            ProvenanceRuntimeIdentity(executablePath: "/opt/conda/envs/kraken2/bin/kraken2").executablePath,
            "/opt/conda/envs/kraken2/bin/kraken2"
        )
    }

    /// A reader keeps the process ID and the executable a record holds, and a record rewritten from
    /// it holds no process ID.
    func testARecordRebuiltFromOneThatHeldAProcessIDIsWrittenWithoutIt() throws {
        let first = try Self.write(Self.completedRun())
        defer { first.cleanup() }
        var object = try first.json()
        var runtime = try XCTUnwrap(object["runtimeIdentity"] as? [String: Any])
        runtime["processIdentifier"] = 4242
        object["runtimeIdentity"] = runtime
        let older = try JSONSerialization.data(withJSONObject: object)

        let read = try ProvenanceEnvelopeReader.decodeCanonical(older)
        XCTAssertEqual(read.runtimeIdentity.processIdentifier, 4242, "a reader keeps the process ID a record holds")
        let rewritten = try Self.write(read)
        defer { rewritten.cleanup() }
        let rewrittenRuntime = try XCTUnwrap(try rewritten.json()["runtimeIdentity"] as? [String: Any])
        XCTAssertNil(rewrittenRuntime["processIdentifier"])
        XCTAssertEqual(rewrittenRuntime["executablePath"] as? String, runtime["executablePath"] as? String)
    }

    /// The initializer a reader uses takes no fact from the reading process, and keeps a recorded
    /// executable path as it is, even the running process's own.
    func testTheReadingInitializerTakesNoFactFromTheReadingProcess() {
        let empty = ProvenanceRuntimeIdentity(
            appVersion: nil,
            executablePath: nil,
            processIdentifier: nil,
            operatingSystemVersion: nil,
            architecture: nil,
            user: nil,
            dependencySet: nil
        )
        XCTAssertNil(empty.appVersion)
        XCTAssertNil(empty.executablePath)
        XCTAssertNil(empty.operatingSystemVersion)
        XCTAssertNil(empty.architecture)
        XCTAssertNil(empty.dependencySet)

        let recorded = ProvenanceRuntimeIdentity(
            appVersion: " Lungfish 2026.9.58 ",
            executablePath: CommandLine.arguments.first,
            processIdentifier: 7,
            operatingSystemVersion: "macOS 26.0.0 (arm64)",
            architecture: "arm64",
            user: nil,
            dependencySet: "2026.2"
        )
        XCTAssertEqual(recorded.appVersion, "Lungfish 2026.9.58")
        XCTAssertEqual(recorded.executablePath, CommandLine.arguments.first)
        XCTAssertEqual(recorded.processIdentifier, 7)
    }

    // MARK: The lock identity

    /// The SHA-256 of the bundled lock file's exact bytes.
    static func bundledLockFileSHA256() throws -> String {
        let data = try Data(contentsOf: try ManagedToolLock.resourceURL())
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The lock hash an identity writes, read from its encoded bytes.
    static func writtenLockHash(of identity: ProvenanceRuntimeIdentity) throws -> String? {
        let json = try JSONSerialization.jsonObject(with: ProvenanceJSON.encoder.encode(identity)) as? [String: Any]
        return json?["managedToolLockSHA256"] as? String
    }

    /// A writer that records the bundled lock's dependency set also records the SHA-256 of the lock
    /// file's bytes, at the run and at each step that takes the default dependency set.
    func testANewlyWrittenRecordHoldsTheBundledLockFilesSHA256() throws {
        let expected = try Self.bundledLockFileSHA256()
        let dependencySet = ManagedToolLock.bundled.resolvedDependencySet
        let step = ProvenanceStep(
            toolName: "samtools",
            runtimeIdentity: ProvenanceRuntimeIdentity(
                executablePath: "/opt/conda/envs/samtools/bin/samtools",
                condaEnvironment: "samtools"
            ),
            exitStatus: 0
        )
        let envelope = ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            workflowName: "lock.identity",
            toolName: "lungfish-cli",
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            steps: [step],
            exitStatus: 0
        )
        for inProject in [false, true] {
            let written = try Self.write(envelope, inProject: inProject)
            defer { written.cleanup() }
            let json = try written.json()
            let runtime = try XCTUnwrap(json["runtimeIdentity"] as? [String: Any])
            XCTAssertEqual(runtime["dependencySet"] as? String, dependencySet)
            XCTAssertEqual(runtime["managedToolLockSHA256"] as? String, expected, "inProject \(inProject)")
            let steps = try XCTUnwrap(json["steps"] as? [[String: Any]])
            let stepRuntime = try XCTUnwrap(steps.first?["runtimeIdentity"] as? [String: Any])
            XCTAssertEqual(stepRuntime["managedToolLockSHA256"] as? String, expected, "inProject \(inProject)")
            let read = try ProvenanceEnvelopeReader.decodeCanonical(written.data)
            XCTAssertEqual(try Self.writtenLockHash(of: read.runtimeIdentity), expected, "the hash reads back")
        }
    }

    /// A writer that records no dependency set, or another lock's, records no lock hash, because the
    /// hash names the bundled lock only.
    func testAWriterThatRecordsAnotherDependencySetRecordsNoLockHash() throws {
        for dependencySet in [nil, "1999.1"] as [String?] {
            let identity = ProvenanceRuntimeIdentity(dependencySet: dependencySet)
            XCTAssertNil(try Self.writtenLockHash(of: identity), "dependencySet \(dependencySet ?? "nil")")
        }
    }

    /// No reader fills the lock hash. A record that holds none reads none through the strict reader,
    /// the bare-run reader and the primitive adapter, even when its dependency set is the reading
    /// Mac's.
    func testAReaderNeverFillsTheLockHash() throws {
        let dependencySet = ManagedToolLock.bundled.resolvedDependencySet
        let first = try Self.write(Self.completedRun())
        defer { first.cleanup() }
        var object = try first.json()
        var runtime = try XCTUnwrap(object["runtimeIdentity"] as? [String: Any])
        runtime["managedToolLockSHA256"] = nil
        runtime["dependencySet"] = dependencySet
        object["runtimeIdentity"] = runtime
        let withoutHash = try JSONSerialization.data(withJSONObject: object)
        let strict = try ProvenanceEnvelopeReader.read(withoutHash)
        XCTAssertEqual(strict.shape, .envelope)
        XCTAssertNil(try Self.writtenLockHash(of: strict.envelope.runtimeIdentity))

        // Version 1 refuses a role it does not know, so this record falls to the primitive adapter.
        let primitive: [String: Any] = [
            "workflowName": "older.tool",
            "createdAt": "2026-10-10T00:00:00Z",
            "runtimeIdentity": ["appVersion": "Lungfish 2026.9.58", "dependencySet": dependencySet],
            "files": [["path": "/data/samples.csv", "role": "sampleSheet"]],
        ]
        let adapted = try ProvenanceEnvelopeReader.read(try JSONSerialization.data(withJSONObject: primitive))
        XCTAssertEqual(adapted.shape, .primitive)
        XCTAssertEqual(adapted.envelope.runtimeIdentity.dependencySet, dependencySet)
        XCTAssertNil(try Self.writtenLockHash(of: adapted.envelope.runtimeIdentity))

        let bareRun = try ProvenanceJSON.encoder.encode(WorkflowRun(name: "Bare run", status: .completed))
        let legacy = try ProvenanceEnvelopeReader.read(bareRun)
        XCTAssertEqual(legacy.shape, .workflowRun)
        XCTAssertNil(try Self.writtenLockHash(of: legacy.envelope.runtimeIdentity))
    }

    // MARK: Step fields

    /// A record whose step names the step it ran under, its typed managed tool id and its version
    /// evidence, and whose tool names its typed id, keeps all four through a read and a write.
    func testAStepsParentTypedToolIDAndVersionEvidenceSurviveAReadAndAWrite() throws {
        let first = try Self.write(Self.completedRun())
        defer { first.cleanup() }
        var object = try first.json()
        var steps = try XCTUnwrap(object["steps"] as? [[String: Any]])
        let parentID = try XCTUnwrap(steps[0]["id"] as? String)
        var child = steps[0]
        child["id"] = "00000000-0000-4000-8000-000000000002"
        child["toolName"] = "samtools"
        child["parentStepID"] = parentID
        child["managedToolID"] = "samtools"
        child["toolVersionEvidence"] = ["source": "lockPin", "version": "1.24", "managedToolID": "samtools"]
        steps.append(child)
        object["steps"] = steps
        var tool = try XCTUnwrap(object["tool"] as? [String: Any])
        tool["managedToolID"] = "fastp"
        object["tool"] = tool

        let read = try ProvenanceEnvelopeReader.decodeCanonical(try JSONSerialization.data(withJSONObject: object))
        let rewritten = try Self.write(read)
        defer { rewritten.cleanup() }
        let json = try rewritten.json()
        let writtenChild = try XCTUnwrap((json["steps"] as? [[String: Any]])?.last)
        XCTAssertEqual(writtenChild["parentStepID"] as? String, parentID)
        XCTAssertEqual(writtenChild["managedToolID"] as? String, "samtools")
        let evidence = try XCTUnwrap(writtenChild["toolVersionEvidence"] as? [String: Any])
        XCTAssertEqual(evidence["source"] as? String, "lockPin")
        XCTAssertEqual(evidence["version"] as? String, "1.24")
        XCTAssertEqual(evidence["managedToolID"] as? String, "samtools")
        XCTAssertEqual((json["tool"] as? [String: Any])?["managedToolID"] as? String, "fastp")
    }

    /// The fields are written only when present, so a step and a tool without them hold none of the
    /// keys.
    func testAStepAndAToolWithoutTheNewFieldsWriteNoneOfTheirKeys() throws {
        let written = try Self.write(Self.completedRun())
        defer { written.cleanup() }
        let json = try written.json()
        for step in try XCTUnwrap(json["steps"] as? [[String: Any]]) {
            for key in ["parentStepID", "managedToolID", "toolVersionEvidence"] {
                XCTAssertNil(step[key], key)
            }
        }
        XCTAssertNil((json["tool"] as? [String: Any])?["managedToolID"])
    }

    /// Every kind of evidence encodes to its wire shape and decodes to itself.
    func testEveryKindOfVersionEvidenceRoundTrips() throws {
        let samtools = ManagedToolID(rawValue: "samtools")
        let cases: [(ToolVersionEvidence, [String: String])] = [
            (.observed(version: "2.31", reportedLine: "2.31-r1302"), ["source": "observed", "version": "2.31", "reportedLine": "2.31-r1302"]),
            (.observed(version: "2.31", reportedLine: nil), ["source": "observed", "version": "2.31"]),
            (.lockPin(version: "1.24", id: samtools), ["source": "lockPin", "version": "1.24", "managedToolID": "samtools"]),
            (.unknown(.noProbe), ["source": "unknown", "reason": "noProbe"]),
            (.unknown(.probeFailed), ["source": "unknown", "reason": "probeFailed"]),
            (.unknown(.outputUnparseable), ["source": "unknown", "reason": "outputUnparseable"]),
            (.unknown(.legacySpelling("unresolved")), ["source": "unknown", "reason": "legacySpelling", "recorded": "unresolved"]),
            (.unknown(.recordedProbeError("ERROR: unknown command")), ["source": "unknown", "reason": "recordedProbeError", "recorded": "ERROR: unknown command"]),
            (.unknown(.recordedAppVersion("Lungfish 2026.10.10 (dev)")), ["source": "unknown", "reason": "recordedAppVersion", "recorded": "Lungfish 2026.10.10 (dev)"]),
        ]
        for (evidence, wire) in cases {
            let data = try ProvenanceJSON.encoder.encode(evidence)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: String], wire, "\(evidence)")
            XCTAssertEqual(try ProvenanceJSON.decoder.decode(ToolVersionEvidence.self, from: data), evidence)
        }
    }

    /// Evidence a later build records in a shape this one does not know leaves the step and the
    /// record readable, with the evidence not recorded.
    func testUnreadableVersionEvidenceLeavesTheStepReadable() throws {
        let first = try Self.write(Self.completedRun())
        defer { first.cleanup() }
        var object = try first.json()
        var steps = try XCTUnwrap(object["steps"] as? [[String: Any]])
        steps[0]["toolVersionEvidence"] = ["source": "sourceBuild", "version": "3.1"]
        object["steps"] = steps
        object["schemaVersion"] = 3
        let read = try ProvenanceEnvelopeReader.read(try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(read.shape, .envelope)
        XCTAssertEqual(read.envelope.steps.first?.toolName, "fastp")
        XCTAssertNil(read.envelope.steps.first?.toolVersionEvidence)
    }

    /// A writer that fills the fields through the Swift API writes them, and narrowing a step to some
    /// of its outputs keeps them.
    func testStepFieldsAWriterFillsAreWrittenAndKeptWhenAStepIsNarrowed() throws {
        let parent = ProvenanceStep(toolName: "lungfish import fastq", exitStatus: 0)
        let output = ProvenanceFileDescriptor(path: "/data/out.bam", role: .output)
        let child = ProvenanceStep(
            toolName: "samtools",
            toolVersion: "1.24",
            outputs: [output, ProvenanceFileDescriptor(path: "/data/out.bam.bai", role: .output)],
            exitStatus: 0,
            parentStepID: parent.id,
            managedToolID: ManagedToolID(rawValue: "samtools"),
            toolVersionEvidence: .lockPin(version: "1.24", id: ManagedToolID(rawValue: "samtools"))
        )
        let narrowed = child.withOutputs([output])
        XCTAssertEqual(narrowed.outputs, [output])
        XCTAssertEqual(narrowed.parentStepID, parent.id)
        XCTAssertEqual(narrowed.managedToolID, child.managedToolID)
        XCTAssertEqual(narrowed.toolVersionEvidence, child.toolVersionEvidence)

        let envelope = ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            workflowName: "step.fields",
            toolName: "samtools",
            tool: ProvenanceToolIdentity(name: "samtools", managedToolID: ManagedToolID(rawValue: "samtools")),
            steps: [parent, child],
            exitStatus: 0
        )
        XCTAssertEqual(envelope.tool.managedToolID, ManagedToolID(rawValue: "samtools"))
        let written = try Self.write(envelope)
        defer { written.cleanup() }
        let read = try ProvenanceEnvelopeReader.decodeCanonical(written.data)
        XCTAssertEqual(read.steps.last, child)
        XCTAssertEqual(read.tool.managedToolID, ManagedToolID(rawValue: "samtools"))
    }
}

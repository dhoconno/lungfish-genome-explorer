// ProvenanceSchemaVersion2EncoderTests.swift - What a newly written provenance record holds at schema version 2
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
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
}

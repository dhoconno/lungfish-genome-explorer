// ProvenanceSchemaVersion2Tests.swift - Readers take version 2 and version 3 records with the facts of version 1
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

/// Version 2 drops the 14 alias keys from new records and readers keep every alias (plan
/// decision S3). Lane P3b writes version 2 in wave 3, so these records are derived here from
/// released version 1 bytes: the four version 1 envelopes of the compatibility corpus and every
/// golden envelope record, unmasked. Each reader that decodes a record file must read the
/// derived record with the facts of its source, and a version 3 record with unknown keys must
/// read without an error, because readers accept any version.
final class ProvenanceSchemaVersion2Tests: XCTestCase {

    // MARK: The version 2 transform

    /// What version 2 removes. `status` stays, because it is the canonical status key
    /// (`docs/contracts/RECORDING-PROVENANCE.md`).
    enum SchemaVersion2 {
        static let topLevelAliases = ["name", "startTime", "endTime", "appVersion", "hostOS", "runtime", "parameters"]
        static let stepAliases = ["command", "exitCode", "wallTime", "startTime", "endTime"]
        static let descriptorAliases = ["sha256", "sizeBytes"]

        /// The version 1 record without its alias keys, at `schemaVersion` 2.
        static func derive(fromVersion1 data: Data) throws -> Data {
            var record = try object(data)
            for key in topLevelAliases { record.removeValue(forKey: key) }
            for key in ["files", "outputs"] {
                if let descriptors = record[key] as? [[String: Any]] {
                    record[key] = descriptors.map(strippingDescriptorAliases)
                }
            }
            if let output = record["output"] as? [String: Any] {
                record["output"] = strippingDescriptorAliases(output)
            }
            if let steps = record["steps"] as? [[String: Any]] {
                record["steps"] = steps.map { step -> [String: Any] in
                    var step = step
                    for key in stepAliases { step.removeValue(forKey: key) }
                    for key in ["inputs", "outputs"] {
                        if let descriptors = step[key] as? [[String: Any]] {
                            step[key] = descriptors.map(strippingDescriptorAliases)
                        }
                    }
                    return step
                }
            }
            record["schemaVersion"] = 2
            return try serialized(record)
        }

        /// A version 2 record at `schemaVersion` 3 with a key no reader knows at the top level, in
        /// every step and in every descriptor.
        static func version3(fromVersion2 data: Data) throws -> Data {
            var record = try object(data)
            record["schemaVersion"] = 3
            record["futureRunSummary"] = ["kind": "added-in-version-3", "count": 3]
            func addingDescriptorKey(_ descriptor: [String: Any]) -> [String: Any] {
                var descriptor = descriptor
                descriptor["futureDescriptorField"] = ["digestAlgorithm": "blake3"]
                return descriptor
            }
            for key in ["files", "outputs"] {
                if let descriptors = record[key] as? [[String: Any]] {
                    record[key] = descriptors.map(addingDescriptorKey)
                }
            }
            if let output = record["output"] as? [String: Any] {
                record["output"] = addingDescriptorKey(output)
            }
            if let steps = record["steps"] as? [[String: Any]] {
                record["steps"] = steps.map { step -> [String: Any] in
                    var step = step
                    step["futureStepField"] = ["recorded", "later"]
                    for key in ["inputs", "outputs"] {
                        if let descriptors = step[key] as? [[String: Any]] {
                            step[key] = descriptors.map(addingDescriptorKey)
                        }
                    }
                    return step
                }
            }
            return try serialized(record)
        }

        private static func strippingDescriptorAliases(_ descriptor: [String: Any]) -> [String: Any] {
            var descriptor = descriptor
            for key in descriptorAliases { descriptor.removeValue(forKey: key) }
            return descriptor
        }

        static func object(_ data: Data) throws -> [String: Any] {
            guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.coderReadCorrupt)
            }
            return record
        }

        static func serialized(_ record: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        }
    }

    // MARK: Sources

    /// A released version 1 envelope record and where it sits in a project.
    struct Source {
        let name: String
        let layout: String
        let version1: Data
    }

    /// The version 1 envelope cases of the compatibility corpus.
    static let corpusCaseIDs = [
        "s1-db-receipt-kraken2-viral",
        "s1-cancelled-single-step",
        "s1-recorder-readsetplan",
        "s1-canonical-envelope-run",
    ]

    static func corpusSources() throws -> [Source] {
        try corpusCaseIDs.map { id in
            let materialized = try ProvenanceCompatCorpus.materialize(id)
            defer { materialized.cleanup() }
            let layout = materialized.sidecar.path.replacingOccurrences(of: materialized.projectRoot.path + "/", with: "")
            return Source(name: id, layout: layout, version1: try Data(contentsOf: materialized.sidecar))
        }
    }

    /// Every golden envelope record, with its masks replaced by fixed values that decode. The goldens
    /// are what the current writers produce, so these are the records lane P3b rewrites. Typed
    /// records such as `mapping-provenance.json` keep their own schema and are left out.
    static func goldenSources() throws -> [Source] {
        let root = ProvenanceCompatCorpus.repositoryRoot.appendingPathComponent("Tests/Fixtures/golden", isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var urls: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent.hasSuffix("provenance.json") { urls.append(url) }
        }
        var sources: [Source] = []
        for url in urls.sorted(by: { $0.path < $1.path }) {
            guard let record = try? SchemaVersion2.object(Data(contentsOf: url)),
                  record["runtimeIdentity"] != nil, record["workflowName"] != nil,
                  let unmaskedRecord = unmasked(record) as? [String: Any] else {
                continue
            }
            let version1 = try SchemaVersion2.serialized(unmaskedRecord)
            guard (try? ProvenanceEnvelopeReader.decodeCanonical(version1)) != nil else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let folder = relative.replacingOccurrences(of: "/", with: "--")
            sources.append(Source(
                name: "golden/\(relative)",
                layout: "Analyses/\(folder)/.lungfish-provenance.json",
                version1: version1
            ))
        }
        return sources
    }

    /// Replaces each whole-value golden mask with a fixed value of the type the field holds. Every
    /// date becomes one instant and every duration 0, so the recorded dates and wall times agree.
    static func unmasked(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(unmasked)
        }
        if let array = value as? [Any] {
            return array.map(unmasked)
        }
        guard let text = value as? String, text.hasPrefix("<"), text.hasSuffix(">") else {
            return value
        }
        if text == "<TIMESTAMP>" { return "2026-10-10T00:00:00Z" }
        if text == "<PID>" { return 4242 }
        if text == "<DURATION>" { return 0 }
        if text.hasPrefix("<SIZE-") { return 1024 }
        if text.hasPrefix("<UUID-"), let number = Int(text.dropFirst(6).dropLast()) {
            return String(format: "00000000-0000-4000-8000-%012d", number)
        }
        return value
    }

    static func allSources() throws -> [Source] {
        try corpusSources() + goldenSources()
    }

    // MARK: Projects

    /// A record written into a fresh temporary `.lungfish` project, two folders below the
    /// temporary root so the finder's walk up stays inside it.
    struct PlacedRecord {
        let temporaryRoot: URL
        let projectRoot: URL
        let sidecar: URL
        var selection: URL { sidecar.deletingLastPathComponent() }

        func cleanup() {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    static func place(_ data: Data, at layout: String) throws -> PlacedRecord {
        let temporaryRoot = try TestTempDirectory.make(prefix: "provenance-schema-v2")
        let projectRoot = temporaryRoot
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let sidecar = projectRoot.appendingPathComponent(layout)
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: sidecar)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: sidecar.path
        )
        return PlacedRecord(temporaryRoot: temporaryRoot, projectRoot: projectRoot, sidecar: sidecar)
    }

    static func facts(of data: Data, at layout: String) throws -> ProvenanceCompatFacts {
        let placed = try place(data, at: layout)
        defer { placed.cleanup() }
        return try ProvenanceCompatFacts.project(sidecar: placed.sidecar, projectRoot: placed.projectRoot)
    }

    /// The `recorded` keys that hold a removed alias, which a version 2 record no longer carries.
    static func isRemovedAlias(_ recordedKey: String) -> Bool {
        recordedKey == "appVersion" || recordedKey == "hostOS" || recordedKey.hasPrefix("runtime.")
    }

    // MARK: The transform

    func testTheTransformRemovesTheFourteenAliasKeysAndNothingElse() throws {
        XCTAssertEqual(
            SchemaVersion2.topLevelAliases.count + SchemaVersion2.stepAliases.count + SchemaVersion2.descriptorAliases.count,
            14
        )
        // The 35 golden envelope records are 4 classifier, 27 genotype bundle, 3 genotype export
        // and 1 mapping record, the records the version 2 encoder changes.
        XCTAssertEqual(try Self.goldenSources().count, 35, "every golden envelope record")
        let sources = try Self.allSources()
        for source in sources {
            let version1 = try SchemaVersion2.object(source.version1)
            let version2 = try SchemaVersion2.object(SchemaVersion2.derive(fromVersion1: source.version1))
            XCTAssertEqual(version2["schemaVersion"] as? Int, 2, source.name)
            XCTAssertEqual(
                Set(version2.keys),
                Set(version1.keys).subtracting(SchemaVersion2.topLevelAliases).union(["schemaVersion"]),
                "top-level keys of \(source.name)"
            )
            XCTAssertEqual(version2["status"] as? String, version1["status"] as? String, "status stays in \(source.name)")
            for step in version2["steps"] as? [[String: Any]] ?? [] {
                XCTAssertTrue(Set(step.keys).isDisjoint(with: SchemaVersion2.stepAliases), "step aliases of \(source.name)")
            }
        }
    }

    // MARK: Version 2 through every reader

    /// The tolerant reader, the strict reader, the finder and the legacy views read a version 2
    /// record with the facts of its version 1 source. The facts that name a removed alias differ by
    /// design: whether the bytes decode as a bare `WorkflowRun`, and the recorded alias values.
    /// `ops stats` is compared in its own test.
    func testVersion2RecordsReadWithTheFactsOfTheirVersion1Sources() throws {
        for source in try Self.allSources() {
            let version2 = try SchemaVersion2.derive(fromVersion1: source.version1)
            let version1Facts = try Self.facts(of: source.version1, at: source.layout)
            let placed = try Self.place(version2, at: source.layout)
            defer { placed.cleanup() }

            let version2Facts = try ProvenanceCompatFacts.project(sidecar: placed.sidecar, projectRoot: placed.projectRoot)
            XCTAssertEqual(version2Facts.decodedBy, .envelope, "\(source.name) decodes as an envelope")
            XCTAssertTrue(version2Facts.strictAccepts, "the strict reader accepts \(source.name)")
            XCTAssertFalse(version2Facts.opsStats.decodesAsWorkflowRun, "version 2 of \(source.name) no longer decodes as a run")

            var expected = version1Facts
            expected.recorded = expected.recorded.filter { !Self.isRemovedAlias($0.key) }
            XCTAssertEqual(version2Facts.differences(from: expected, ignoring: [.opsStats]), [], source.name)

            let found = try XCTUnwrap(
                ProvenanceRecorder.findProvenanceEnvelope(for: placed.selection),
                "the finder finds version 2 of \(source.name)"
            )
            XCTAssertEqual(found.sidecarURL.standardizedFileURL, placed.sidecar.standardizedFileURL, source.name)
            let foundFacts = try ProvenanceCompatFacts.project(
                envelope: found.envelope,
                sidecar: found.sidecarURL,
                projectRoot: placed.projectRoot
            )
            XCTAssertEqual(foundFacts.differences(from: version2Facts), [], "finder facts of \(source.name)")
        }
    }

    /// `ops stats` counts a version 2 record as it counts its source. Its total wall time may move
    /// by less than a second, because a version 1 record carries the run's start and end as
    /// whole-second alias dates and version 2 derives them from the canonical fields.
    func testOpsStatsCountsVersion2RecordsLikeTheirVersion1Sources() throws {
        for source in try Self.allSources() {
            let version1Facts = try Self.facts(of: source.version1, at: source.layout)
            let version2Facts = try Self.facts(of: SchemaVersion2.derive(fromVersion1: source.version1), at: source.layout)
            let compare = {
                XCTAssertEqual(
                    version2Facts.opsStats.completedRunCount,
                    version1Facts.opsStats.completedRunCount,
                    "completed runs of version 2 of \(source.name)"
                )
                XCTAssertEqual(version2Facts.opsStats.peakMemoryBytes, version1Facts.opsStats.peakMemoryBytes, source.name)
                XCTAssertEqual(
                    version2Facts.opsStats.totalWallTimeSeconds,
                    version1Facts.opsStats.totalWallTimeSeconds,
                    accuracy: 1,
                    "total wall time of version 2 of \(source.name)"
                )
            }
            // At the base, ops stats counts a source that decodes as a WorkflowRun and drops its version 2.
            if version1Facts.opsStats.decodesAsWorkflowRun, version1Facts.opsStats.completedRunCount > 0 {
                XCTExpectFailure(
                    "ops stats decodes each record as a WorkflowRun and drops version 2 until it reads through ProvenanceEnvelopeReader (step 3)",
                    failingBlock: compare
                )
            } else {
                compare()
            }
        }
    }

    // MARK: Version 3

    /// A record at a later version with keys no reader knows reads without an error and with the
    /// facts of the version 2 record it extends, through the tolerant reader, the strict reader
    /// and the finder.
    func testVersion3RecordWithUnknownKeysReadsThroughEveryReader() throws {
        for source in try Self.corpusSources() {
            let version2 = try SchemaVersion2.derive(fromVersion1: source.version1)
            let version3 = try SchemaVersion2.version3(fromVersion2: version2)
            let version2Facts = try Self.facts(of: version2, at: source.layout)
            let placed = try Self.place(version3, at: source.layout)
            defer { placed.cleanup() }

            let tolerant = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: placed.sidecar))
            XCTAssertEqual(tolerant.schemaVersion, 3, source.name)
            let strict = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(fromSidecar: placed.sidecar))
            XCTAssertEqual(strict.schemaVersion, 3, source.name)
            XCTAssertNotNil(ProvenanceRecorder.findProvenanceEnvelope(for: placed.selection), source.name)

            let version3Facts = try ProvenanceCompatFacts.project(sidecar: placed.sidecar, projectRoot: placed.projectRoot)
            XCTAssertEqual(version3Facts.decodedBy, .envelope, "version 3 of \(source.name) decodes as an envelope")
            XCTAssertEqual(version3Facts.differences(from: version2Facts), [], "version 3 of \(source.name)")
        }
    }

    func testOpsStatsCountsACompletedVersion3Record() throws {
        let source = try XCTUnwrap(try Self.corpusSources().first { $0.name == "s1-db-receipt-kraken2-viral" })
        let version3 = try SchemaVersion2.version3(fromVersion2: SchemaVersion2.derive(fromVersion1: source.version1))
        let placed = try Self.place(version3, at: ".lungfish-provenance.json")
        defer { placed.cleanup() }
        let report = try OperationStatsAggregator().summarize(projectURL: placed.projectRoot)
        XCTAssertEqual(report.sidecarCount, 1)
        XCTExpectFailure("ops stats decodes each record as a WorkflowRun and drops version 3 until step 3") {
            XCTAssertEqual(report.completedRunCount, 1, "ops stats counts the completed version 3 record")
        }
    }
}

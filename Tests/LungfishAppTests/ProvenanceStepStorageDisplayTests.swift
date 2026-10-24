// ProvenanceStepStorageDisplayTests.swift - What the Provenance tab shows of how a storage step wrote its gzip
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishTestSupport
import LungfishWorkflow

/// C4-10. A storage step's record now states which program wrote the stored gzip, the level that took effect and
/// clumpify's group count. The Provenance tab shows each in UX's words for N3's record lines (tally-r2 N3-3 to N3-5)
/// as a line of the step's disclosure after Environment, only when the record holds its field and none as a warning,
/// so a record written before C4 shows as it did.
@MainActor
final class ProvenanceStepStorageDisplayTests: XCTestCase {
    private static let bgzipArguments: ParameterValue = .array(
        ["-c", "-f", "-l", "4", "-@", "2"].map(ParameterValue.string)
    )

    private static func bgzipWriter(version: String, build: String = "", source: String) -> ParameterValue {
        .dictionary([
            "name": .string("bgzip"),
            "tool": .dictionary([
                "id": .string("bgzip"), "version": .string(version), "build": .string(build),
                "path": .string("/env/bin/bgzip"), "versionSource": .string(source),
            ]),
            "arguments": bgzipArguments,
        ])
    }

    private static func display(
        _ tool: String, version: String = "40.02", _ options: [String: ParameterValue],
        chosen: CompressionLevel? = .maximum
    ) -> ProvenanceStepStorageDisplay? {
        ProvenanceStepStorageDisplay(toolName: tool, toolVersion: version, options: options, chosenLevel: chosen)
    }

    // MARK: - Compressed by (N3-3)

    func testCompressedByNamesTheBgzipBBToolsStartedWithItsVersionSourceAndArgv() {
        XCTAssertEqual(
            Self.display("clumpify.sh", ["writer": Self.bgzipWriter(version: "1.21", source: "observed")])?.compressedBy,
            "bgzip 1.21 (read on the Mac that ran the import), started by clumpify.sh as bgzip -c -f -l 4 -@ 2"
        )
        XCTAssertEqual(
            Self.display("reformat.sh", ["writer": Self.bgzipWriter(version: "1.21", source: "imageManifest")])?
                .compressedBy,
            "bgzip 1.21 (from the tool image's manifest), started by reformat.sh as bgzip -c -f -l 4 -@ 2"
        )
        XCTAssertEqual(
            Self.display("clumpify.sh", ["writer": Self.bgzipWriter(version: "", source: "unknown")])?.compressedBy,
            "bgzip, version Not recorded, started by clumpify.sh as bgzip -c -f -l 4 -@ 2"
        )
        // N3-3a's main form, the one with a build, which the adopted node record will use (tally-c4 OQ-5).
        XCTAssertEqual(
            Self.display(
                "clumpify.sh", ["writer": Self.bgzipWriter(version: "1.21", build: "h3a4d415_1", source: "imageManifest")]
            )?.compressedBy,
            "bgzip 1.21 (build h3a4d415_1, from the tool image's manifest), started by clumpify.sh as bgzip -c -f -l 4 -@ 2"
        )
        XCTAssertEqual(
            Self.display(
                "clumpify.sh", ["writer": Self.bgzipWriter(version: "1.21", build: "h3a4d415_1", source: "unknown")]
            )?.compressedBy,
            "bgzip 1.21 (build h3a4d415_1), started by clumpify.sh as bgzip -c -f -l 4 -@ 2"
        )
    }

    func testCompressedByNamesBBToolsOwnWriterAndACompressStepItself() {
        XCTAssertEqual(
            Self.display("clumpify.sh", ["writer": .dictionary(["name": .string("BBTools native BGZF")])])?.compressedBy,
            "BBTools built-in BGZF writer, because no bgzip answered on the step's PATH"
        )
        XCTAssertEqual(
            Self.display("pigz", version: "2.8", ["writer": .dictionary(["name": .string("pigz")])])?.compressedBy,
            "This step (pigz 2.8)"
        )
    }

    // MARK: - Compression level (N3-4)

    func testCompressionLevelSaysWhatBecameOfTheChosenLevel() {
        XCTAssertEqual(
            Self.display("clumpify.sh", ["effectiveCompressionLevel": .integer(4)])?.compressionLevel,
            "4. clumpify.sh always compresses at level 4, so the chosen level (maximum, 9) did not apply."
        )
        XCTAssertEqual(
            Self.display("clumpify.sh", ["effectiveCompressionLevel": .integer(4)], chosen: .balanced)?
                .compressionLevel,
            "4"
        )
        XCTAssertEqual(Self.display("reformat.sh", ["effectiveCompressionLevel": .integer(9)])?.compressionLevel, "9")
        XCTAssertEqual(
            Self.display("bgzip", version: "1.21", ["writer": .dictionary(["name": .string("bgzip")])], chosen: .fast)?
                .compressionLevel,
            "bgzip's default. The chosen level (fast, 1) is not passed to bgzip."
        )
    }

    // MARK: - Clumpify groups (N3-5)

    func testClumpifyGroupsShowsTheCountAndWhatSeveralGroupsMean() {
        XCTAssertEqual(Self.display("clumpify.sh", ["clumpifyGroups": .integer(1)])?.clumpifyGroups, "1")
        XCTAssertEqual(
            Self.display("clumpify.sh", ["clumpifyGroups": .integer(3)])?.clumpifyGroups,
            "3. clumpify.sh split the input into 3 groups to fit its memory, so its reorder option had no effect."
        )
        XCTAssertEqual(
            Self.display("clumpify.sh", ["effectiveCompressionLevel": .integer(4)])?.clumpifyGroups,
            "Not recorded",
            "a clumpify step that records its storage but no groups"
        )
        XCTAssertNil(
            Self.display("reformat.sh", ["effectiveCompressionLevel": .integer(9)])?.clumpifyGroups,
            "groups are a clumpify.sh line only"
        )
    }

    func testAStepWithNoStorageFieldAddsNoLine() {
        XCTAssertNil(Self.display("clumpify.sh", [:]), "a record written before C4")
        XCTAssertNil(Self.display("fastp", ["threads": .integer(2)]))
    }

    // MARK: - The tab

    /// The lines follow Environment in the disclosure's order, and the same step with the record of before C4 copies
    /// as it did, with none of them.
    func testTheCopyTextListsTheStorageLinesAfterEnvironment() async throws {
        let options: [String: ParameterValue] = [
            "writer": Self.bgzipWriter(version: "1.21", source: "observed"),
            "effectiveCompressionLevel": .integer(4),
            "clumpifyGroups": .integer(1),
            "clumpifyMemoryEstimateLine": .string("Memory Estimate:        11 MB"),
            "clumpifyMemoryAvailableLine": .string("Memory Available:       2867 MB"),
        ]
        let storage = ["Compressed by", "Compression level", "Clumpify groups"]

        let model = try await loadedModel(record: try Self.clumpifyRecord(options: options))
        let copy = model.copyableText
        let labels = Self.stepLabels(of: copy)
        XCTAssertEqual(
            labels.filter { ["Command", "Environment", "Inputs"].contains($0) || storage.contains($0) },
            ["Command", "Environment"] + storage + ["Inputs"],
            copy
        )
        XCTAssertTrue(copy.contains(
            "\nCompressed by: bgzip 1.21 (read on the Mac that ran the import), started by clumpify.sh as "
                + "bgzip -c -f -l 4 -@ 2\nCompression level: 4. clumpify.sh always compresses at level 4, so the "
                + "chosen level (maximum, 9) did not apply.\nClumpify groups: 1\n"
        ), copy)
        XCTAssertFalse(copy.contains("Memory Estimate"), "the memory lines stay in the record")

        let older = try await loadedModel(record: try Self.clumpifyRecord(options: [:]))
        XCTAssertEqual(Self.stepLabels(of: older.copyableText), labels.filter { !storage.contains($0) })
    }

    // MARK: - Helpers

    /// The committed `observed-clean-exit` record with its step named `clumpify.sh`, `options` as its resolved options
    /// and the import's chosen level `maximum`.
    private static func clumpifyRecord(options: [String: ParameterValue]) throws -> Data {
        let url = ProvenanceDisplayFixtures.directory
            .appendingPathComponent("Analyses/observed-clean-exit/.lungfish-provenance.json")
        var record = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var steps = try XCTUnwrap(record["steps"] as? [[String: Any]])
        steps[0]["toolName"] = "clumpify.sh"
        steps[0]["resolvedOptions"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(options))
        record["steps"] = steps
        var envelopeOptions = try XCTUnwrap(record["options"] as? [String: Any])
        var explicit = envelopeOptions["explicit"] as? [String: Any] ?? [:]
        explicit["compressionLevel"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ParameterValue.string(CompressionLevel.maximum.rawValue)),
            options: .fragmentsAllowed
        )
        envelopeOptions["explicit"] = explicit
        record["options"] = envelopeOptions
        return try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    }

    /// The label of each unindented line of the first Lineage step in `copy`, as
    /// `ProvenanceStepTerminationDisplayTests` reads them.
    private static func stepLabels(of copy: String) -> [String] {
        guard let section = copy.components(separatedBy: "\n\n").first(where: { $0.hasPrefix("Lineage\n") }) else {
            return []
        }
        return section.components(separatedBy: "\n").dropFirst(2)
            .filter { !$0.hasPrefix(" ") }
            .map { line in line.firstIndex(of: ":").map { String(line[..<$0]) } ?? line }
    }

    /// Writes `record` into a fresh project's analysis folder and loads it through the real lookup.
    private func loadedModel(
        record: Data, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> ProvenanceInspectorViewModel {
        let root = try TestTempDirectory.make(prefix: "provenance-step-storage")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let analysis = root.appendingPathComponent("Storage Records.lungfish/Analyses/clumpify-storage", isDirectory: true)
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        try record.write(to: analysis.appendingPathComponent(".lungfish-provenance.json"), options: .atomic)
        let model = ProvenanceInspectorViewModel()
        model.load(item: ProvenanceInspectableItem(
            url: analysis, sidebarType: .analysisResult, contentMode: .genomics, displayName: "clumpify-storage"
        ))
        let finished = await waitUntil(budget: .lookup) { !model.isLoading }
        XCTAssertTrue(finished, "The provenance lookup did not finish.", file: file, line: line)
        XCTAssertNotNil(model.resolvedEnvelope, "No record was found.", file: file, line: line)
        return model
    }
}

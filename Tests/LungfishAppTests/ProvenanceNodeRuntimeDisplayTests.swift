// ProvenanceNodeRuntimeDisplayTests.swift - The rows an adopted record adds to the Provenance tab (CHTC C4 lane U)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishTestSupport
import LungfishWorkflow

/// C4-13 with UX rulings OQ-1 and OQ-5. An adopted record names where and with what binary its steps ran: once per
/// run in the Runtime section after Dependency Set, and a "Version and build" row on each node step. A row shows only
/// when the record holds its field, none is a warning, and a Mac import or a record written before C4 shows as it did.
/// The tool is generic and HTCondor is one launcher (owner O41), so the words, units and Not recorded rows that belong
/// to HTCondor show only for a record that holds HTCondor's own facts.
@MainActor
final class ProvenanceNodeRuntimeDisplayTests: XCTestCase {
    private static let executorSHA256 = String(repeating: "a", count: 64)
    /// The commit of the executor build, the plan's build pin `lgeCommit`: the `build` of the executor's own tool record.
    private static let executorCommit = "6f3c2d1a9b8e7c6d5e4f3a2b1c0d9e8f7a6b5c4d"
    private static let sif = "lge-c0-tools-c42530259944.sif"
    private static let sifSHA256 = "c425302599447ae0157523299b71ac5c170294537c58c1ca31bdc2bb1cfceb7c"
    private static let parentWalkWords = "Found through each process's parent only. A process that a tool detached from "
        + "its parent is not found and may still be running after the step ended."
    /// The group row of a record that holds HTCondor's facts: its memory and disk gain a unit, so the facts are not all
    /// shown as given.
    private static let launcherWords = "Passed in by the program that started the run, such as HTCondor. Lungfish shows "
        + "them as given, except for the unit it adds to memory and disk, and did not check them."
    /// The group row of a record from another launcher, UX's words of OQ-5: nothing is added to any fact.
    private static let launcherWordsAsGiven = "Passed in by the program that started the run, such as HTCondor. Lungfish "
        + "shows them as given and did not check them."
    private static let runLabels = ["Steps ran on", "Steps ran with", "Leftover processes", "Reported by the launcher"]
    /// What the CHTC submit template passes for a node, cut to four facts: two it asks for and the job's ids.
    private static let htcondorFacts = [
        ProvenanceSiteFact(key: "Machine", value: "e4004.chtc.wisc.edu"), ProvenanceSiteFact(key: "Memory", value: "1024"),
        ProvenanceSiteFact(key: "ClusterId", value: "593367"), ProvenanceSiteFact(key: "ProcId", value: "0"),
    ]

    /// The rows after Dependency Set, in order and once, and none of them on a step. The record holds HTCondor's job
    /// ids, so it shows OQ-5's rows: the slot's labels and units, a Not recorded row for each fact the template asks
    /// for and the record lacks, and the job row.
    func testAdoptedRecordShowsNodeRuntimeRowsOnceAfterDependencySet() async throws {
        let model = try await loadedModel(record: try Self.adoptedRecord())
        let rows = model.runtimeRows.map { "\($0.label): \($0.value)" }
        let start = try XCTUnwrap(model.runtimeRows.firstIndex { $0.label == "Dependency Set" })
        XCTAssertEqual(Array(rows[(start + 1)...]), [
            "Steps ran on: kernel 5.14.0-620.el9.x86_64 (x86_64)",
            "Steps ran with: lungfish-executor build \(Self.executorCommit) (from the plan's pin), SHA-256 \(Self.executorSHA256)",
            "Leftover processes: \(Self.parentWalkWords)",
            "Reported by the launcher: \(Self.launcherWords)",
            "Machine name: e4004.chtc.wisc.edu", "Memory given to the job: 1024 MiB", "HTCondor job: 593367.0",
            "CPU architecture: Not recorded", "CPU microarchitecture: Not recorded", "Operating system: Not recorded",
            "Operating system major version: Not recorded", "Kernel release: Not recorded",
            "CPUs given to the job: Not recorded", "Disk given to the job: Not recorded",
        ])
        XCTAssertTrue(rows.contains("Container Image: \(Self.sif)"), "\(rows)")
        XCTAssertTrue(rows.contains("Container Digest: \(Self.sifSHA256)"), "\(rows)")
        for label in Self.runLabels {
            XCTAssertEqual(model.runtimeRows.filter { $0.label == label }.count, 1, label)
        }
        let steps = try XCTUnwrap(model.lineageRuns.last).steps
        for step in steps {
            let copy = model.stepCopyText(of: step)
            XCTAssertFalse(Self.runLabels.contains { copy.contains("\n\($0):") }, copy)
        }
        XCTAssertTrue(model.warnings.allSatisfy { !Self.runLabels.contains($0.title) }, "none is a warning")
    }

    /// Owner O41: a record from another launcher shows the facts it passed, under their keys and as given. It shows no
    /// Not recorded row for a fact nobody asked it for, no "HTCondor job" row, and no HTCondor label or unit on a
    /// number whose meaning its launcher did not state. The group row keeps UX's words of OQ-5.
    func testRecordFromAnotherLauncherShowsOnlyTheFactsItPassed() async throws {
        let facts = [
            ProvenanceSiteFact(key: "Scheduler", value: "slurm"), ProvenanceSiteFact(key: "Machine", value: "node12"),
            ProvenanceSiteFact(key: "Cpus", value: "8"), ProvenanceSiteFact(key: "Memory", value: "64000"),
            ProvenanceSiteFact(key: "Disk", value: "512"),
        ]
        let model = try await loadedModel(record: try Self.adoptedRecord(siteFacts: facts))
        let rows = model.runtimeRows.map { "\($0.label): \($0.value)" }
        let start = try XCTUnwrap(model.runtimeRows.firstIndex { $0.label == "Reported by the launcher" })
        XCTAssertEqual(Array(rows[start...]), [
            "Reported by the launcher: \(Self.launcherWordsAsGiven)",
            "Scheduler: slurm", "Machine name: node12", "Cpus: 8", "Memory: 64000", "Disk: 512",
        ])
        XCTAssertFalse(model.runtimeRows.contains { $0.value == "Not recorded" }, "\(rows)")
        XCTAssertFalse(model.runtimeRows.contains { $0.label == "HTCondor job" }, "\(rows)")
    }

    /// An `imageManifest` step and the `planPin` counter step, which shows under its title.
    func testAdoptedStepShowsVersionAndBuildWithSource() async throws {
        let model = try await loadedModel(record: try Self.adoptedRecord())
        let steps = try XCTUnwrap(model.lineageRuns.last).steps
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].toolName, "clumpify.sh")
        XCTAssertEqual(steps[0].versionAndBuild, "39.13 (build h3a4d415_1), from the tool image's manifest")
        XCTAssertEqual(steps[1].toolName, "Count Q20 and Q30 bases")
        XCTAssertEqual(steps[1].versionAndBuild, "2026.10.24 (build \(Self.executorCommit)), from the plan's pin")
        XCTAssertTrue(model.stepCopyText(of: steps[1]).hasPrefix("2. Count Q20 and Q30 bases"))
        XCTAssertTrue(
            model.stepCopyText(of: steps[1])
                .contains("\nVersion and build: 2026.10.24 (build \(Self.executorCommit)), from the plan's pin"),
            model.stepCopyText(of: steps[1])
        )
        // One binary, one build: the commit "Steps ran with" names is the build the executor's own step row names.
        let ranWith = try XCTUnwrap(model.runtimeRows.first { $0.label == "Steps ran with" }?.value)
        let rowCommit = try XCTUnwrap(ranWith.components(separatedBy: " build ").dropFirst().first?
            .components(separatedBy: " (from the plan's pin)").first)
        XCTAssertEqual(rowCommit, Self.executorCommit)
        XCTAssertEqual(steps[1].versionAndBuild, "2026.10.24 (build \(rowCommit)), from the plan's pin", ranWith)
    }

    /// A record that states no build gives no build words: the step shows its version and source, and the run row names
    /// the binary and its SHA-256 only (each part left out when not recorded).
    func testNodeStepAndRunRowWithNoRecordedBuildShowNoBuildWords() async throws {
        let model = try await loadedModel(record: try Self.adoptedRecord(counterBuild: "", executorBuild: nil))
        let steps = try XCTUnwrap(model.lineageRuns.last).steps
        XCTAssertEqual(steps[1].versionAndBuild, "2026.10.24, from the plan's pin")
        let ranWith = try XCTUnwrap(model.runtimeRows.first { $0.label == "Steps ran with" }?.value)
        XCTAssertEqual(ranWith, "lungfish-executor, SHA-256 \(Self.executorSHA256)")
    }

    /// A Mac import, whose step states a Mac version source, and the record written before C4 give the same runtime
    /// rows and step lines, with no node row.
    func testMacImportAndPreC4RecordShowNoNodeRuntimeRows() async throws {
        let pre = try await loadedModel(record: try Self.fixtureRecord(mutate: { _ in }))
        let mac = try await loadedModel(record: try Self.fixtureRecord { record in
            var steps = record["steps"] as? [[String: Any]] ?? []
            steps[0]["resolvedOptions"] = try Self.json(
                ProvenanceNodeStepOptions.options(toolID: "clumpify.sh", version: "39.13", build: "", versionSource: "observed")
            )
            record["steps"] = steps
        })
        for model in [pre, mac] {
            XCTAssertEqual(model.runtimeRows.last?.label, "Dependency Set")
            XCTAssertFalse(model.copyableText.contains("Version and build"), model.copyableText)
            XCTAssertTrue(model.runtimeRows.allSatisfy { !Self.runLabels.contains($0.label) })
        }
        XCTAssertEqual(mac.runtimeRows, pre.runtimeRows)
        // Each record lies in its own temporary project, so its paths differ by that folder alone.
        func rooted(_ text: String) -> String {
            text.replacingOccurrences(of: #"provenance-node-runtime-[0-9A-F-]+"#, with: "<root>", options: .regularExpression)
        }
        XCTAssertEqual(rooted(Self.section("Lineage", of: mac.copyableText)), rooted(Self.section("Lineage", of: pre.copyableText)))
        XCTAssertEqual(rooted(Self.section("Runtime", of: mac.copyableText)), rooted(Self.section("Runtime", of: pre.copyableText)))
    }

    /// The Copy text lists the run rows in the Runtime section in screen order, and a step's "Version and build" after
    /// Command and Environment and before Inputs.
    func testAdoptedRecordCopyTextListsNodeRowsInScreenOrder() async throws {
        let model = try await loadedModel(record: try Self.adoptedRecord())
        let runtime = Self.section("Runtime", of: model.copyableText).components(separatedBy: "\n").dropFirst()
        XCTAssertEqual(Array(runtime), model.runtimeRows.map { "\($0.label): \($0.value)" })
        let labels = Self.section("Lineage", of: model.copyableText).components(separatedBy: "\n").dropFirst(2)
            .filter { !$0.hasPrefix(" ") }
            .map { line in line.firstIndex(of: ":").map { String(line[..<$0]) } ?? line }
        let command = try XCTUnwrap(labels.firstIndex(of: "Command"))
        let version = try XCTUnwrap(labels.firstIndex(of: "Version and build"))
        let inputs = try XCTUnwrap(labels.firstIndex(of: "Inputs"))
        XCTAssertLessThan(command, version)
        XCTAssertLessThan(version, inputs)
        if let environment = labels.firstIndex(of: "Environment") { XCTAssertLessThan(environment, version) }
    }

    // MARK: - Helpers

    /// The committed `observed-clean-exit` record as an adopt writes it: the node runtime and site facts in its
    /// runtime identity, the image `staging.json` names, a `clumpify.sh` step from the image's manifest and the
    /// counter step from the plan's pin.
    private static func adoptedRecord(
        counterBuild: String = ProvenanceNodeRuntimeDisplayTests.executorCommit,
        executorBuild: String? = ProvenanceNodeRuntimeDisplayTests.executorCommit,
        siteFacts: [ProvenanceSiteFact] = ProvenanceNodeRuntimeDisplayTests.htcondorFacts
    ) throws -> Data {
        try fixtureRecord { record in
            var runtime = record["runtimeIdentity"] as? [String: Any] ?? [:]
            runtime["containerImage"] = sif
            runtime["containerDigest"] = sifSHA256
            runtime["nodeRuntime"] = try json(ProvenanceNodeRuntime(
                kernelRelease: "5.14.0-620.el9.x86_64", machine: "x86_64", executorBuild: executorBuild,
                executorSHA256: executorSHA256, orphanSweep: "parentWalkOnly"
            ))
            runtime["siteFacts"] = try json(siteFacts)
            record["runtimeIdentity"] = runtime
            var steps = try XCTUnwrap(record["steps"] as? [[String: Any]])
            var counter = steps[0]
            steps[0]["toolName"] = "clumpify.sh"
            steps[0]["resolvedOptions"] = try json(ProvenanceNodeStepOptions.options(
                toolID: "clumpify.sh", version: "39.13", build: "h3a4d415_1", versionSource: "imageManifest"
            ))
            counter["id"] = UUID().uuidString
            counter["toolName"] = "lungfish-executor"
            counter["resolvedOptions"] = try json(ProvenanceNodeStepOptions.options(
                toolID: "lungfish-executor", version: "2026.10.24", build: counterBuild, versionSource: "planPin",
                title: "Count Q20 and Q30 bases"
            ))
            record["steps"] = [steps[0], counter]
        }
    }

    private static func fixtureRecord(mutate: (inout [String: Any]) throws -> Void) throws -> Data {
        let url = ProvenanceDisplayFixtures.directory
            .appendingPathComponent("Analyses/observed-clean-exit/.lungfish-provenance.json")
        var record = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        try mutate(&record)
        return try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
    }

    private static func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
    }

    /// The Copy text section whose first line is `title`.
    private static func section(_ title: String, of copy: String) -> String {
        copy.components(separatedBy: "\n\n").first { $0.hasPrefix(title + "\n") } ?? ""
    }

    /// Writes `record` into a fresh project's analysis folder and loads it through the real lookup.
    private func loadedModel(
        record: Data, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> ProvenanceInspectorViewModel {
        let root = try TestTempDirectory.make(prefix: "provenance-node-runtime")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let analysis = root.appendingPathComponent("Adopted Records.lungfish/Analyses/adopted", isDirectory: true)
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        try record.write(to: analysis.appendingPathComponent(".lungfish-provenance.json"), options: .atomic)
        let model = ProvenanceInspectorViewModel()
        model.load(item: ProvenanceInspectableItem(
            url: analysis, sidebarType: .analysisResult, contentMode: .genomics, displayName: "adopted"
        ))
        let finished = await waitUntil(budget: .lookup) { !model.isLoading }
        XCTAssertTrue(finished, "The provenance lookup did not finish.", file: file, line: line)
        XCTAssertNotNil(model.resolvedEnvelope, "No record was found.", file: file, line: line)
        return model
    }
}

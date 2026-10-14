// ProvenanceEnvelopeRelocationTests.swift - ProvenanceEnvelope.relocated names a moved bundle's files where they now are
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A45, ruling A45-M3 section 3. A CLI that builds a bundle in a staging folder and
// publishes it by rename rewrote the record by encoding it, replacing the staged path in the text and
// decoding it again. That put a second `ProvenanceJSON.encoder` outside the writer and moved the
// `provenance-writers` ratchet from 13 to 14. `relocated(from:to:)` does it on the model, with no
// encoder. The fixture below names the staged folder in all three spellings in every field that holds
// a place, and the encoded text of the result is searched, so a field the relocation misses fails here.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class ProvenanceEnvelopeRelocationTests: XCTestCase {
    private var root: URL!
    private var staged: URL!
    private var final: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lge-relocation-\(UUID().uuidString)", isDirectory: true)
        staged = root.appendingPathComponent(".tmp/fetch-ncbi-staged", isDirectory: true)
        final = root.appendingPathComponent("Downloads/NC_045512.2.lungfishref", isDirectory: true)
        // The folder exists, so the resolved spelling is the one a reader would see.
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The three spellings of the staged folder the record may hold.
    private var spellings: [String] {
        Array(Set([staged.path, staged.resolvingSymlinksInPath().path, "/private" + staged.path]))
    }

    private func descriptor(_ path: String, role: FileRole, origin: String? = nil) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: path, checksumSHA256: String(repeating: "d", count: 64), fileSize: 99, format: .fasta,
            role: role, originPath: origin, sourceProvenancePath: origin.map { $0 + ".provenance.json" })
    }

    /// A record whose every field that can hold a place names the staged folder in each spelling.
    private func stagedRecord(status: RunStatus = .cancelled) -> ProvenanceEnvelope {
        let names = spellings
        let environment = ProvenanceStepObservation.Environment(
            base: .inherited, changed: ["TMPDIR"], values: ["TMPDIR": names[0] + "/tmp"], unset: [],
            pathPrefix: names.map { $0 + "/bin" })
        let observation = ProvenanceStepObservation(
            termination: .exited(code: 0), stop: nil, outputComplete: true, environment: environment,
            stage: .init(index: 0, count: 1))
        let step = ProvenanceStep(
            toolName: "bgzip", toolVersion: "1.22",
            argv: ["bgzip", "-c", names[0] + "/sources/record.fa"],
            durableReplayArgv: ["bgzip", "-c", names[1] + "/sources/record.fa"],
            reproducibleCommand: "bgzip -c \(names[names.count - 1])/sources/record.fa",
            resolvedOptions: [
                "input": .file(URL(fileURLWithPath: names[0] + "/sources/record.fa")),
                "list": .array(names.map { .string($0 + "/x") }),
                "nested": .dictionary(["place": .string(names[0])]),
                "count": .integer(3),
            ],
            inputs: [descriptor(names[0] + "/sources/record.fa", role: .input)],
            outputs: [descriptor(names[0] + "/genome.fa.gz", role: .output, origin: names[0] + "/genome.fa")],
            exitStatus: 0, stderr: "wrote \(names[0])/genome.fa.gz", observation: observation)
        let output = descriptor(names[0] + "/manifest.json", role: .output)
        return ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            workflowName: "lungfish fetch ncbi",
            toolName: "lungfish-cli",
            toolVersion: "2026.10.17",
            argv: ["lungfish-cli", "fetch", "ncbi", "--bundle", "--output-dir", names[0]],
            durableReplayArgv: ["lungfish-cli", "fetch", "ncbi", "--output-dir", names[1]],
            reproducibleCommand: "lungfish-cli fetch ncbi --output-dir \(names[names.count - 1])",
            options: ProvenanceOptions(
                explicit: ["outputDir": .file(URL(fileURLWithPath: names[0]))],
                defaults: ["places": .array(names.map { .string($0) })],
                resolvedDefaults: ["nested": .dictionary(["place": .string(names[1])])]),
            files: [descriptor(names[0] + "/genome.fa.gz", role: .output, origin: names[1] + "/genome.fa")],
            output: output,
            outputs: [descriptor(names[1] + "/genome.fa.gz.fai", role: .output)],
            steps: [step],
            exitStatus: 0,
            stderr: "built in \(names[0])",
            status: status)
    }

    private func text(_ envelope: ProvenanceEnvelope) throws -> String {
        String(decoding: try ProvenanceJSON.encoder.encode(envelope), as: UTF8.self)
    }

    func testARelocatedRecordHoldsNoSpellingOfTheStagedFolder() throws {
        let before = try text(stagedRecord())
        for spelling in spellings {
            XCTAssertTrue(before.contains(spelling), "the fixture must name the staged folder as \(spelling)")
        }
        let relocated = stagedRecord().relocated(from: staged, to: final)
        let after = try text(relocated)
        for spelling in spellings {
            XCTAssertFalse(after.contains(spelling), "the relocated record still names \(spelling)")
        }
        XCTAssertTrue(after.contains(final.path + "/genome.fa.gz"))
        XCTAssertEqual(relocated.argv.last, final.path)
        XCTAssertEqual(relocated.durableReplayArgv?.last, final.path)
        XCTAssertEqual(relocated.steps.first?.observation?.environment?.pathPrefix, [String](repeating: final.path + "/bin", count: spellings.count))
        XCTAssertEqual(relocated.steps.first?.outputs.first?.originPath, final.path + "/genome.fa")
        XCTAssertEqual(
            relocated.steps.first?.resolvedOptions["input"], .file(URL(fileURLWithPath: final.path + "/sources/record.fa")))
    }

    func testARelocationKeepsTheDigestsRolesAndStatusOfTheRecord() throws {
        let record = stagedRecord(status: .cancelled)
        let relocated = record.relocated(from: staged, to: final)
        XCTAssertEqual(relocated.id, record.id)
        XCTAssertEqual(relocated.status, .cancelled)
        XCTAssertEqual(relocated.exitStatus, 0)
        XCTAssertEqual(relocated.createdAt, record.createdAt)
        XCTAssertEqual(relocated.files.map(\.checksumSHA256), record.files.map(\.checksumSHA256))
        XCTAssertEqual(relocated.files.map(\.fileSize), record.files.map(\.fileSize))
        XCTAssertEqual(relocated.outputs.map(\.role), record.outputs.map(\.role))
        XCTAssertEqual(relocated.steps.map(\.id), record.steps.map(\.id))
        XCTAssertEqual(relocated.steps.first?.inputs.map(\.checksumSHA256), record.steps.first?.inputs.map(\.checksumSHA256))
        XCTAssertEqual(relocated.steps.first?.resolvedOptions["count"], .integer(3))
        XCTAssertEqual(relocated.steps.first?.exitStatus, 0)
    }

    func testARecordThatNamesNoPlaceOfTheStagedFolderComesBackEqual() throws {
        let other = root.appendingPathComponent("elsewhere", isDirectory: true)
        let record = stagedRecord().relocated(from: staged, to: final)
        XCTAssertEqual(record.relocated(from: other, to: root.appendingPathComponent("moved")), record)
    }

    func testTheLongestSpellingGoesFirst() {
        let resolved = staged.resolvingSymlinksInPath().path
        let private_ = "/private" + staged.path
        // The plain path is contained in the `/private` one, so only longest first leaves no `/private` prefix.
        let record = ProvenanceEnvelope(
            workflowName: "lungfish fetch ncbi", toolName: "lungfish-cli",
            argv: ["lungfish-cli", private_ + "/a", resolved + "/b", staged.path + "/c"])
        let relocated = record.relocated(from: staged, to: final)
        XCTAssertEqual(relocated.argv, ["lungfish-cli", final.path + "/a", final.path + "/b", final.path + "/c"])
    }

    func testAPlaceThatSharesOnlyAPrefixOfTheStagedNameIsKept() {
        // The staged name is a whole path, so a sibling that begins with its text does not match it.
        let sibling = staged.deletingLastPathComponent().appendingPathComponent("other").path
        let record = ProvenanceEnvelope(
            workflowName: "lungfish fetch ncbi", toolName: "lungfish-cli", argv: ["lungfish-cli", sibling])
        XCTAssertEqual(record.relocated(from: staged, to: final).argv, ["lungfish-cli", sibling])
    }
}

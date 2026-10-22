// StagedPlaceSpellingTests.swift - A record moves off a staged folder whatever spelling the record and the caller use
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane C2-PROVPATH, review fix 2. Foundation resolves a path only while it exists, and it drops `/private` only then.
// A run that publishes a bundle removes its staging folder, so a record that spells the folder `/tmp/x/stage/f` meets a
// caller that gives the folder as `/private/tmp/x/stage` after the folder is gone. `ProvenanceEnvelope.relocated`
// took `/private` + the given path, which covers only the other direction, and the record kept the staging folder.
// The same fault sat in `naoMgsPathCandidates`, which maps `/var` both ways and `/tmp` in neither.

import XCTest
import LungfishIO
@testable import LungfishWorkflow

final class StagedPlaceSpellingTests: XCTestCase {
    private func descriptor(_ path: String, role: FileRole) -> ProvenanceFileDescriptor {
        ProvenanceFileDescriptor(
            path: path, checksumSHA256: String(repeating: "d", count: 64), fileSize: 99, format: .fasta,
            role: role, originPath: nil, sourceProvenancePath: nil)
    }

    /// A record whose every field that can hold a place names `stage`.
    private func record(naming stage: String) -> ProvenanceEnvelope {
        let environment = ProvenanceStepObservation.Environment(
            base: .inherited, changed: ["TMPDIR"], values: ["TMPDIR": stage + "/tmp"], unset: [],
            pathPrefix: [stage + "/bin"])
        let observation = ProvenanceStepObservation(
            termination: .exited(code: 0), stop: nil, outputComplete: true, environment: environment,
            stage: .init(index: 0, count: 1))
        let step = ProvenanceStep(
            toolName: "bgzip", toolVersion: "1.22",
            argv: ["bgzip", "-c", stage + "/sources/record.fa"],
            durableReplayArgv: ["bgzip", "-c", stage + "/sources/record.fa"],
            reproducibleCommand: "bgzip -c \(stage)/sources/record.fa",
            resolvedOptions: ["input": .file(URL(fileURLWithPath: stage + "/sources/record.fa"))],
            inputs: [descriptor(stage + "/sources/record.fa", role: .input)],
            outputs: [descriptor(stage + "/genome.fa.gz", role: .output)],
            exitStatus: 0, stderr: "wrote \(stage)/genome.fa.gz", observation: observation)
        return ProvenanceEnvelope(
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            workflowName: "lungfish fetch ncbi",
            toolName: "lungfish-cli",
            toolVersion: "2026.10.22",
            argv: ["lungfish-cli", "fetch", "ncbi", "--output-dir", stage],
            durableReplayArgv: ["lungfish-cli", "fetch", "ncbi", "--output-dir", stage],
            reproducibleCommand: "lungfish-cli fetch ncbi --output-dir \(stage)",
            options: ProvenanceOptions(
                explicit: ["outputDir": .file(URL(fileURLWithPath: stage))],
                defaults: ["places": .array([.string(stage)])],
                resolvedDefaults: [:]),
            files: [descriptor(stage + "/genome.fa.gz", role: .output)],
            output: descriptor(stage + "/manifest.json", role: .output),
            outputs: [descriptor(stage + "/genome.fa.gz.fai", role: .output)],
            steps: [step],
            exitStatus: 0,
            stderr: "built in \(stage)",
            status: .completed)
    }

    private func text(_ envelope: ProvenanceEnvelope) throws -> String {
        String(decoding: try ProvenanceJSON.encoder.encode(envelope), as: UTF8.self)
    }

    /// The stage is given in one spelling and the record holds the other, for the `/tmp` link and for the system temp
    /// folder under `/var`. The stage is removed before the call, as a publish removes it.
    func testARecordIsRelocatedFromAStageGivenInAnotherSpellingOfItsFolder() throws {
        let fm = FileManager.default
        let id = "lge-spelling-\(UUID().uuidString)"
        let systemTemp = fm.temporaryDirectory.path
        let realTemp = systemTemp.hasPrefix("/var/") ? "/private" + systemTemp : systemTemp
        let pairs: [(given: String, recorded: String)] = [
            ("/private/tmp/\(id)", "/tmp/\(id)"),
            ("\(realTemp)/\(id)", "\(systemTemp)/\(id)"),
        ]
        for pair in pairs {
            let parent = URL(fileURLWithPath: pair.given, isDirectory: true)
            let stage = parent.appendingPathComponent("lge-stage-folder", isDirectory: true)
            try fm.createDirectory(at: stage, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
            try fm.removeItem(at: stage)
            let final = parent.appendingPathComponent("published/genome.lungfishref", isDirectory: true)

            let staged = record(naming: pair.recorded + "/lge-stage-folder")
            XCTAssertTrue(try text(staged).contains("lge-stage-folder"), "the fixture names the stage as \(pair.recorded)")
            let relocated = try text(staged.relocated(from: stage, to: final))
            XCTAssertFalse(
                relocated.contains("lge-stage-folder"),
                "a record spelled \(pair.recorded) keeps the stage after it is relocated from the stage given as \(stage.path)")
            XCTAssertTrue(relocated.contains(final.path + "/genome.fa.gz"), "the record names the files where they now are")
        }
    }

    /// The NAO-MGS import matches a path by every spelling it knows, `/var` and `/private/var` both ways. `/tmp` is
    /// the same link and needs the same pair.
    func testTheNaoMgsCandidatesNameTheLinkedFoldersBothWays() {
        let pairs = [
            ("/tmp/lge-x/a/f.tsv", "/private/tmp/lge-x/a/f.tsv"),
            ("/var/folders/lge-x/f.tsv", "/private/var/folders/lge-x/f.tsv"),
        ]
        for (short, real) in pairs {
            XCTAssertTrue(naoMgsPathCandidates(for: URL(fileURLWithPath: short)).contains(real), "\(short) is also \(real)")
            XCTAssertTrue(naoMgsPathCandidates(for: URL(fileURLWithPath: real)).contains(short), "\(real) is also \(short)")
        }
    }
}

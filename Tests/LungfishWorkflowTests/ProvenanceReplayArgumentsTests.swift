// ProvenanceReplayArgumentsTests.swift - The argv a provenance export replays, one case for each rule and each move
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
@testable import LungfishWorkflow

/// Phase 2.13 lane 13.45 (SW2 R-REPLAY), ARCH-13.45 C2 to C5. The rule is pure, so none of these cases touches the file
/// system.
struct ProvenanceReplayArgumentsTests {
    private static let project = "/Volumes/Lab/Runs.lungfish"
    private let token = ProvenanceReplayArguments.freshFolder

    private func rule(
        from old: String? = nil, to folder: String, inputs: [String: String?], outputs: [String]
    ) -> ProvenanceReplayArguments {
        let p = Self.project
        return ProvenanceReplayArguments(
            relocation: old.map { [ProvenanceFolderRename(oldPath: "\(p)/\($0)", newPath: "\(p)/\(folder)")] } ?? [],
            inputs: Dictionary(uniqueKeysWithValues: inputs.map { ("\(p)/\($0.key)", $0.value) }),
            outputs: Set(outputs.map { "\(p)/\($0)" }),
            recordFolder: URL(fileURLWithPath: "\(p)/\(folder)"),
            projectURL: URL(fileURLWithPath: p)
        )
    }

    private var p: String { Self.project }

    /// Rule 1, an output descriptor and a file under the record's folder become the fresh folder. Rename case.
    @Test func aRenamedRecordsOutputsGoToTheFreshFolderAndItsInputStays() {
        let replay = rule(from: "Analyses/trim", to: "Analyses/trim renamed", inputs: ["Inputs/r.fq": "abc"],
                          outputs: ["Analyses/trim renamed/out.fq"])
        let argv = ["fastp", "-i", "\(p)/Inputs/r.fq", "-o", "\(p)/Analyses/trim/out.fq", "--log=\(p)/Analyses/trim/run.log"]
        #expect(replay.arguments(argv) == [
            "fastp", "-i", "\(p)/Inputs/r.fq", "-o", "\(token)/out.fq", "--log=\(token)/run.log",
        ])
        #expect(replay.checkedInputs(argv).map(\.path) == ["\(p)/Inputs/r.fq"])
        #expect(replay.checkedInputs(argv).map(\.sha256) == ["abc"])
    }

    /// Rule 1 before rule 2, a word that an output descriptor names is an output even when an input descriptor names it.
    @Test func aWordBothDescriptorsNameIsAnOutput() {
        let replay = rule(to: "Analyses/sort", inputs: ["Analyses/sort/a.bam": "1"], outputs: ["Analyses/sort/a.bam"])
        #expect(replay.arguments(["samtools", "index", "@/Analyses/sort/a.bam"]) == ["samtools", "index", "\(token)/a.bam"])
    }

    /// Rule 2 after a Duplicate. The copy's input is read from the copy, its output goes to the fresh folder, so the
    /// replay never names the source folder.
    @Test func aDuplicatesReplayReadsTheCopyAndNeverNamesTheSource() {
        let replay = rule(from: "Analyses/trim", to: "Analyses/trim copy",
                          inputs: ["Analyses/trim copy/in.fq": nil], outputs: ["Analyses/trim copy/out.fq"])
        let argv = ["tool", "\(p)/Analyses/trim/in.fq", "\(p)/Analyses/trim/out.fq"]
        let replayed = replay.arguments(argv)
        #expect(replayed == ["tool", "\(p)/Analyses/trim copy/in.fq", "\(token)/out.fq"])
        #expect(!replayed.contains { $0.contains("\(p)/Analyses/trim/") })
        #expect(replay.checkedInputs(argv).map(\.sha256) == [nil])
    }

    /// Rule 3, a reference outside the project, a managed tool and a project file no descriptor names go out as
    /// recorded.
    @Test func wordsNoDescriptorNamesGoOutAsRecorded() {
        let replay = rule(from: "Analyses/k", to: "Analyses/k renamed", inputs: [:], outputs: [])
        let argv = ["/Users/a/.lungfish/conda/envs/kraken2/bin/kraken2", "--db", "/Volumes/Ref/db", "\(p)/Inputs/other.fq", "-t"]
        #expect(replay.arguments(argv) == argv)
        #expect(replay.checkedInputs(argv).isEmpty)
    }

    /// A Move takes the same rule, the old folder at another depth.
    @Test func aMovedRecordsOutputGoesToTheFreshFolder() {
        let replay = rule(from: "Analyses/trim", to: "Analyses/Group/trim", inputs: ["Inputs/r.fq": "abc"],
                          outputs: ["Analyses/Group/trim/out.fq"])
        #expect(replay.arguments(["fastp", "@/Inputs/r.fq", "@/Analyses/trim/out.fq"])
            == ["fastp", "\(p)/Inputs/r.fq", "\(token)/out.fq"])
    }

    /// A copied file's record was rebound already, so its relocation is empty and its outputs still go to the fresh
    /// folder, and a path outside the record's folder keeps its place below the project.
    @Test func aCopiedFilesRecordWithNoRelocationStillWritesOnlyTheFreshFolder() {
        let replay = rule(to: "Analyses/copy", inputs: ["Inputs/r.fq": "abc"], outputs: ["Analyses/copy/out.fq", "Reports/sum.txt"])
        #expect(replay.arguments(["tool", "\(p)/Inputs/r.fq", "\(p)/Analyses/copy/out.fq", "\(p)/Reports/sum.txt"])
            == ["tool", "\(p)/Inputs/r.fq", "\(token)/out.fq", "\(token)/Reports/sum.txt"])
    }

    /// Review 13.45-M2 Fix 1 (SWIFT 5, C3). The Python input check hashes an input in 1 MiB chunks and once, so a replay of
    /// a large run is not read whole into memory before its first tool, and a mismatch names the digest it computed.
    @Test func thePythonInputCheckStreamsEachInputInChunksAndHashesItOnce() {
        let replay = rule(to: "Analyses/trim", inputs: ["Inputs/r.fq": "abc"], outputs: [])
        let step = StepExecution(toolName: "fastp", toolVersion: "1", command: ["fastp", "\(p)/Inputs/r.fq"], inputs: [])
        let check = replay.pythonInputCheck([step])
        #expect(!check.contains("read_bytes"), Comment(rawValue: check))
        #expect(check.contains("for chunk in iter(lambda: handle.read(1 << 20), b\"\"):"), Comment(rawValue: check))
        #expect(check.components(separatedBy: "lge_sha256(").count - 1 == 2, Comment(rawValue: check))
        #expect(check.contains("if lge_actual != \"abc\":"), Comment(rawValue: check))
    }
}

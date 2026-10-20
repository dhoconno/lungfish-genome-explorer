// NaoMgsMarkdupProvenanceStepsTests.swift - The NAO-MGS markdup stages in the import's provenance
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishIO
@testable import LungfishWorkflow

/// BIO-13.09-M2 item 7c. It sits beside `MetagenomicsImportServiceTests`, whose file would pass 800 lines with it.
struct NaoMgsMarkdupProvenanceStepsTests {
    @Test
    func naoMgsMarkdupStagesKeepTheirParentAndPipesAndTakeNoSourceInputs() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("nao-mgs-markdup-steps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("virus_hits.tsv")
        try "sample\tread\n".write(to: source, atomically: true, encoding: .utf8)
        let bam = folder.appendingPathComponent("S1.bam")
        try Data("BAM\u{1}".utf8).write(to: bam)

        let call = NaoMgsBamMaterializationStep(
            sample: "S1", toolName: "lungfish nao-mgs markdup",
            argv: ["lungfish-internal", "nao-mgs-markdup", "--bam", bam.path], inputURLs: [bam]
        )
        let sortByName = NaoMgsBamMaterializationStep(
            sample: "S1", toolName: "samtools", argv: ["samtools", "sort", "-n", "-@", "4", bam.path],
            inputURLs: [bam], parentStepID: call.id, stdoutPipe: "pipe:stdout:samtools-sort-n"
        )
        let fixmate = NaoMgsBamMaterializationStep(
            sample: "S1", toolName: "samtools", argv: ["samtools", "fixmate", "-m", "-", "-"],
            parentStepID: call.id, stdinPipe: "pipe:stdout:samtools-sort-n"
        )
        let unparented = NaoMgsBamMaterializationStep(sample: "S1", toolName: "samtools", argv: ["samtools", "--version"])

        let steps = try naoMgsMaterializationProvenanceSteps(
            from: [call, sortByName, fixmate, unparented],
            sourceURLs: [source],
            relocatedArtifacts: [:],
            materializationReplayArgv: ["lungfish-cli", "import", "nao-mgs", source.path]
        )

        #expect(steps.map(\.id) == [call.id, sortByName.id, fixmate.id, unparented.id])
        #expect(steps[0].parentStepID == nil)
        #expect(steps[0].inputs.map(\.path) == [bam.path])
        #expect(steps[1].parentStepID == call.id)
        #expect(steps[1].inputs.map(\.path) == [bam.path])
        #expect(steps[1].outputs.map(\.path) == ["pipe:stdout:samtools-sort-n"])
        #expect(steps[1].outputs.map(\.role) == [.output])
        #expect(steps[2].parentStepID == call.id)
        #expect(steps[2].inputs.map(\.path) == ["pipe:stdout:samtools-sort-n"])
        #expect(steps[2].inputs.map(\.role) == [.input])
        #expect(steps[2].outputs.isEmpty)
        // A step with no parent, no inputs and no pipe takes the source file as before.
        #expect(steps[3].parentStepID == nil)
        #expect(steps[3].inputs.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["virus_hits.tsv"])
    }
}

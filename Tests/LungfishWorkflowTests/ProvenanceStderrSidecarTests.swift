// ProvenanceStderrSidecarTests.swift - A cut stderr leaves no folder name in a project's sidecar
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishCore
@testable import LungfishWorkflow

/// The writer rewrites the absolute paths inside a project to project-relative
/// ones, but it recognises only a path that is whole. A stderr that
/// `ProvenanceStderr` cut inside a path used to leave the end of that path in the
/// record, so the machine and project folder names stayed in a file that people
/// share. Project and sample names can be patient identifiers (Phase 2.7,
/// ruling 2, found in the EsViritu parity run).
@Suite("Provenance stderr in a project sidecar")
struct ProvenanceStderrSidecarTests {
    /// A temporary project whose root and scratch folders carry unique names, so a
    /// leaked name can be found in the raw bytes of the sidecar.
    private struct Layout {
        let root: URL
        let rootName = UUID().uuidString
        let scratchName = UUID().uuidString
        let analysis: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(rootName, isDirectory: true)
            analysis = root
                .appendingPathComponent(scratchName, isDirectory: true)
                .appendingPathComponent("Study.lungfish", isDirectory: true)
                .appendingPathComponent("Analyses/classify-1", isDirectory: true)
            try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        }
    }

    private static let banner = "mytool 1.2.3 starting with 8 threads"
    private static let lastLine = "ERROR: out of memory in stage 7, exiting"

    private static func stderr(in layout: Layout, endPad: Int) -> String {
        var lines = [banner]
        lines += (1...160).map {
            "[bam_sort] writing to \(layout.analysis.path)/part-\(String(format: "%04d", $0)).sorted.bam"
        }
        lines += ["[pad] " + String(repeating: ".", count: endPad), lastLine]
        return lines.joined(separator: "\n") + "\n"
    }

    /// A stderr that the old cut would have left with a tail that starts inside a path,
    /// before both folder names. Such a tail has no leading slash, so the writer cannot
    /// recognise the path in it, and the names stay in the record. The first word of the
    /// old tail is that path fragment, and a fragment that begins with a slash would
    /// still read as a path, so the search skips those.
    private static func stderrWithAPathCutByTheTail(in layout: Layout) throws -> String {
        for endPad in 0..<400 {
            let text = stderr(in: layout, endPad: endPad)
            let firstWord = text.suffix(ProvenanceStderr.tailLength).prefix { !$0.isWhitespace }
            if firstWord.first != "/", firstWord.contains(layout.rootName), firstWord.contains(layout.scratchName) {
                return text
            }
        }
        throw SetupError.noCutInsideAPath
    }

    private enum SetupError: Error {
        case noCutInsideAPath
    }

    @Test("a long stderr that names project paths leaves neither folder name in the saved sidecar")
    func longStderrLeavesNoFolderNameInTheSidecar() async throws {
        let layout = try Layout()
        defer { try? FileManager.default.removeItem(at: layout.root) }
        let log = try Self.stderrWithAPathCutByTheTail(in: layout)
        #expect(log.count > ProvenanceStderr.maxLength)

        let recorder = ProvenanceRecorder(signingProvider: nil)
        let runID = await recorder.beginRun(name: "Classify")
        await recorder.recordStep(
            runID: runID,
            toolName: "mytool",
            toolVersion: "1.2.3",
            command: ["mytool", "--out", layout.analysis.appendingPathComponent("out.bam").path],
            inputs: [],
            outputs: [],
            exitCode: 0,
            wallTime: 1,
            stderr: log
        )
        await recorder.completeRun(runID, status: .completed)
        try await recorder.save(runID: runID, to: layout.analysis)

        let sidecar = layout.analysis.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
        let raw = String(decoding: try Data(contentsOf: sidecar), as: UTF8.self)

        #expect(!raw.contains(layout.rootName), "the root folder name is in the sidecar")
        #expect(!raw.contains(layout.scratchName), "the scratch folder name is in the sidecar")
        #expect(raw.contains("... [truncated] ..."), "the stderr was cut")
        #expect(raw.contains("@/Analyses/classify-1/part-0160.sorted.bam"), "the kept paths are project-relative")

        // Read back, every kept line is a whole line of the stderr.
        let envelope = try #require(try ProvenanceEnvelopeReader.load(from: layout.analysis))
        for stderr in [envelope.stderr, envelope.steps.first?.stderr] {
            let kept = try #require(stderr)
            #expect(kept.hasPrefix(Self.banner + "\n"))
            #expect(kept.hasSuffix(Self.lastLine + "\n"))
            for line in kept.split(separator: "\n") {
                let whole = line == Self.banner[...] || line == Self.lastLine[...]
                    || line == "... [truncated] ..." || line.hasPrefix("[pad]")
                    || (line.hasPrefix("[bam_sort] writing to ") && line.hasSuffix(".sorted.bam"))
                #expect(whole, "a fragment is in the record: \(line.prefix(80))")
            }
        }
    }
}

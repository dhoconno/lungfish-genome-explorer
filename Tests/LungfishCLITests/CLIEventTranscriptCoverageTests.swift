// CLIEventTranscriptCoverageTests.swift - The transcripts of every leaf command that emits events
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
import XCTest
@testable import LungfishCLI

/// Check A3 of the contract table (plan decision S18, QA correction 8).
///
/// Each leaf that emits events has a folder under `Tests/Fixtures/cli-events/commands`. Most were
/// captured in process, and the leaves in `toolLeaves`, which run an external tool or the FASTQ
/// import, were captured from real runs of the built `lungfish-cli`. The checks decode every line under version 2, expect one terminal event last,
/// read each run with the frozen version 1 reader to the same outcome and outputs, and pin the order
/// of `outputs` for `variants call` and `bam primer-trim`. The capture tests run the in-process leaves
/// again and fail when a line differs from its transcript, so a transcript cannot go stale while the
/// emitters change.
///
/// The in-process captures run each command on a small fixture. A command with a test seam hands its
/// lines to a capturing sink, as the two ONT split commands do with `execute(emit:)`. `fastq platform`
/// and the four import commands have none, because they write through the flushing standard output
/// helper, so their standard output is redirected for the length of the run, and `ImportStreamCapture`
/// builds the fixtures of the import commands. The scratch
/// folder of each run is rewritten to `/work`, in its plain and its slash-escaped spelling, and nothing
/// else is edited. Set `LUNGFISH_RECAPTURE_CLI_EVENTS=1` to write the transcripts instead of comparing
/// them, and review the diff. `Tests/Fixtures/cli-events/README.md` describes the real runs.
final class CLIEventTranscriptCoverageTests: XCTestCase {
    // MARK: Transcript locations

    /// The `.events` leaves that run an external tool. A unit test cannot run them, so their
    /// transcripts come from real runs of the built `lungfish-cli`, which the fixtures README describes.
    static let toolLeaves: Set<String> = [
        "tree infer iqtree", "align mafft", "assemble", "variants call", "bam primer-trim", "esviritu detect",
        "kraken2 classify", "conda classify",
        // `bam consensus` runs samtools. Its transcripts are runs of the built CLI on the sarscov2 BAM
        // (lane A51 of Phase 2.10).
        "bam consensus",
        // `primers design primer3`, `primalscheme3` and `varvamp` run their engines. Each transcript pair is a run of the
        // built CLI with `--format json`, a saved design and a refused existing `--output` (lane 12.17 M2 of Phase 2.12).
        "primers design primer3", "primers design primalscheme3", "primers design varvamp",
        // `extract reads` runs samtools. Its transcripts are runs of the built CLI on the sarscov2 BAM,
        // `--by-region` to a FASTQ and a refused missing BAM (lane A51 of Phase 2.10).
        "extract reads",
        // `extract sequence --bundle` runs bgzip and samtools faidx. Its transcripts hold the words of the
        // leaf and of the extraction bundle builder (lane A48 M2 of Phase 2.11).
        "extract sequence",
        // `import fasta` runs bgzip and samtools faidx through ReferenceBundleImportService. Its transcripts
        // hold the words of the service and its builder (lane A48 M3 of Phase 2.11).
        "import fasta",
        // `bundle merge` builds with bgzip and samtools faidx. Its transcripts are runs of the built CLI on two
        // plain FASTA bundles (lane A49 M2 of Phase 2.11).
        "bundle merge",
        // `import bam` runs samtools sort and index through BAMImportService. Its transcripts are runs of the
        // built CLI on the sarscov2 BAM and a reference bundle (lane A63 M1 of Phase 2.11).
        "import bam",
        // `blast submit` reaches NCBI. Its transcripts are runs of the built CLI on a loopback BLAST stand-in,
        // recaptured with LUNGFISH_RECAPTURE_CLI_EVENTS=1 (BlastSubmitStandInTests, lane A65 of Phase 2.11).
        "blast submit",
        // `extract taxa-collection` runs seqkit grep through TaxonomyExtractionPipeline. Its transcripts are runs of
        // the built CLI on the argv of the taxa collections drawer's Extract button, recaptured with
        // LUNGFISH_RECAPTURE_CLI_EVENTS=1 (TaxaCollectionEventTranscriptReplayTests, lane A66 of Phase 2.11).
        "extract taxa-collection",
        // `taxtriage run` and `workflow run` run Nextflow. Their transcripts are runs on stand-ins, recaptured with
        // LUNGFISH_RECAPTURE_CLI_EVENTS=1 (TaxTriageRunCommandReplayTests, lane A2, and WorkflowRunEventsTests, A30).
        "taxtriage run", "workflow run",
        // The two spellings of the FASTQ import share the folder `import-fastq` (lane Q4 of Phase 2.7).
        "import fastq", "import-fastq",
        // `fetch genome` runs bgzip and samtools faidx on files from NCBI. Its transcripts are runs of
        // the built CLI on the loopback NCBI stand-in (FetchGenomeEventTranscriptReplayTests with
        // LUNGFISH_RECAPTURE_CLI_EVENTS=1, lane A44 of Phase 2.10).
        "fetch genome",
        // `map` runs minimap2 and samtools from the golden storage (lane A46 of Phase 2.10).
        "map",
        // `fastq ingest` runs clumpify from the managed bbtools environment, so a unit test cannot
        // capture its transcripts in process (lane A47 of Phase 2.10).
        "fastq ingest",
        // `fetch ncbi --bundle` builds with the same tools, and its transcripts are runs of the built
        // CLI on the same stand-in (FetchNCBIEventTranscriptReplayTests, lane A45 of Phase 2.10).
        "fetch ncbi",
        // `fetch pathoplexus` builds with the same tools on the loopback Pathoplexus and NCBI stand-ins
        // (FetchPathoplexusEventTranscriptReplayTests, lane A45 of Phase 2.10).
        "fetch pathoplexus",
        // `fetch sra download` runs the SRA Toolkit through its debug stand-in scripts and imports with the
        // managed bgzip. Its transcripts are runs of the built CLI (FetchSRAEventTranscriptReplayTests, lane
        // A45 of Phase 2.10).
        "fetch sra download",
        // `demo fetch` downloads, unpacks and installs a project archive. Its transcripts are runs of the built CLI
        // on a loopback stand-in that serves a small archive (DemoFetchEventTranscriptReplayTests, lane A45 of
        // Phase 2.10).
        "demo fetch",
    ]

    static var transcriptsFolder: URL {
        CLIEventContractCoverageTests.repositoryRoot.appendingPathComponent("Tests/Fixtures/cli-events/commands", isDirectory: true)
    }

    /// `Tests/Fixtures/cli-events/commands/<path with hyphens>`, one folder for each `.events` leaf.
    static func transcriptFolder(forLeaf leaf: String) -> URL {
        transcriptsFolder.appendingPathComponent(leaf.split(separator: " ").joined(separator: "-"), isDirectory: true)
    }

    /// One transcript, a run of the leaf that ends one way, such as `complete` or `failed`.
    static func transcriptURL(leaf: String, name: String) -> URL {
        transcriptFolder(forLeaf: leaf).appendingPathComponent("\(name).ndjson")
    }

    // MARK: A3 transcripts

    /// One checked-in run of one `.events` leaf, as the lines it printed.
    private struct Transcript {
        let leaf: String
        let name: String
        let lines: [String]

        var label: String { "\(leaf)/\(name)" }
    }

    private func transcripts() throws -> [Transcript] {
        var found: [Transcript] = []
        for (leaf, contract) in CLIEventContractTable.entries.sorted(by: { $0.key < $1.key }) {
            guard case .events = contract else { continue }
            let files = (try? FileManager.default.contentsOfDirectory(
                at: Self.transcriptFolder(forLeaf: leaf), includingPropertiesForKeys: nil
            )) ?? []
            for file in files.filter({ $0.pathExtension == "ndjson" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let text = try String(contentsOf: file, encoding: .utf8)
                found.append(Transcript(
                    leaf: leaf,
                    name: file.deletingPathExtension().lastPathComponent,
                    lines: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                ))
            }
        }
        return found
    }

    func testEveryEventsLeafHasATranscriptThatCompletes() throws {
        let all = try transcripts()
        let withTranscript = Set(all.map(\.leaf))
        let eventsLeaves = Set(CLIEventContractTable.entries.compactMap { path, contract -> String? in
            if case .events = contract { return path }
            return nil
        })
        XCTAssertEqual(
            eventsLeaves.subtracting(withTranscript).sorted(),
            [],
            "Every leaf that emits events has a checked-in transcript. The tool leaves get theirs from a real run of the built CLI"
        )
        XCTAssertTrue(Self.toolLeaves.isSubset(of: eventsLeaves))
        for leaf in withTranscript {
            XCTAssertTrue(
                all.contains { $0.leaf == leaf && $0.name.hasPrefix("complete") },
                "\(leaf) has no transcript of a run that completes"
            )
        }
    }

    func testNoTranscriptFolderBelongsToAnyOtherLeaf() throws {
        let folders = try FileManager.default.contentsOfDirectory(
            at: Self.transcriptsFolder, includingPropertiesForKeys: [.isDirectoryKey]
        )
        let expected = Set(CLIEventContractTable.entries.compactMap { path, contract -> String? in
            if case .events = contract { return path.split(separator: " ").joined(separator: "-") }
            return nil
        })
        for folder in folders where folder.lastPathComponent != ".DS_Store" {
            XCTAssertTrue(expected.contains(folder.lastPathComponent), "\(folder.lastPathComponent) is not the folder of an .events leaf")
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            for file in files where file != ".DS_Store" {
                XCTAssertTrue(file.hasSuffix(".ndjson"), "\(folder.lastPathComponent)/\(file) is not a transcript")
            }
        }
    }

    func testEveryTranscriptLineDecodesUnderVersion2WithNoIgnoredEvent() throws {
        let decoder = CLIEventLineDecoder()
        for transcript in try transcripts() {
            XCTAssertFalse(transcript.lines.isEmpty, "\(transcript.label) is empty")
            for line in transcript.lines {
                XCTAssertTrue(line.hasPrefix("{"), "\(transcript.label) holds a line a reader skips as chatter: \(line)")
                let envelope = try XCTUnwrap(try decoder.decodeLine(line), "\(transcript.label): \(line)")
                XCTAssertNotNil(envelope.event, "\(transcript.label) holds an event this reader ignores: \(line)")
                XCTAssertEqual(envelope.schemaVersion, CLIEventLine.currentSchemaVersion, "\(transcript.label): \(line)")
            }
        }
    }

    func testEveryTranscriptEndsInExactlyOneTerminalEvent() throws {
        let decoder = CLIEventLineDecoder()
        for transcript in try transcripts() {
            let events = try transcript.lines.map { try XCTUnwrap(try decoder.decode(line: $0), "\(transcript.label): \($0)") }
            guard case .start = events.first else {
                XCTFail("\(transcript.label) does not begin with a start event")
                continue
            }
            let terminal = events.filter {
                switch $0 {
                case .complete, .failed: return true
                case .start, .progress, .log, .output: return false
                }
            }
            XCTAssertEqual(terminal.count, 1, "\(transcript.label) holds \(terminal.count) terminal events")
            switch events.last {
            case .complete where transcript.name.hasPrefix("complete"):
                break
            case .failed where transcript.name.hasPrefix("failed"):
                break
            default:
                XCTFail("\(transcript.label) does not end in the terminal event its name promises")
            }
        }
    }

    func testTheFrozenVersion1ReaderReadsEveryTranscriptToTheSameOutcomeAndOutputs() throws {
        let current = CLIEventLineDecoder()
        let frozen = FrozenCLIEventV1LineDecoder()
        for transcript in try transcripts() {
            var currentOutcome: CLIEvent?
            var frozenOutcome: FrozenCLIEventV1?
            for line in transcript.lines {
                let event = try XCTUnwrap(try current.decode(line: line), "\(transcript.label): \(line)")
                let old = try XCTUnwrap(try frozen.decode(line: line), "The version 1 reader skips \(transcript.label): \(line)")
                XCTAssertEqual(old.asCLIEvent, event, "The two readers disagree on \(transcript.label): \(line)")
                if old.isTerminal {
                    currentOutcome = event
                    frozenOutcome = old
                }
            }
            switch (currentOutcome, frozenOutcome) {
            case let (.complete(outputs, _)?, .complete(oldOutputs, _)?):
                XCTAssertEqual(oldOutputs, outputs, "The outputs a version 1 app imports from \(transcript.label)")
                XCTAssertFalse(outputs.isEmpty, "A complete line names at least one path, or the transport fails the run: \(transcript.label)")
            case let (.failed(message, _)?, .failed(oldMessage, _)?):
                XCTAssertEqual(oldMessage, message, "The failure a version 1 app shows for \(transcript.label)")
            default:
                XCTFail("The two readers end \(transcript.label) in different ways")
            }
        }
    }

    /// Review of lane C1, ruling 5. The app runners of these two leaves find each path by its
    /// place in `outputs`, so the real runs pin the order. A writer that adds typed artifacts
    /// keeps the order, and every artifact it adds names a path that `outputs` holds.
    func testOutputsOfVariantsCallAndPrimerTrimKeepTheOrderTheirRunnersRead() throws {
        let order: [String: [String]] = [
            "variants call": [".db", ".vcf.gz", ".vcf.gz.tbi"],
            "bam primer-trim": [".bam", ".bam.bai", ".primer-trim-provenance.json"],
        ]
        let all = try transcripts()
        let decoder = CLIEventLineDecoder()
        for (leaf, suffixes) in order {
            let transcript = try XCTUnwrap(all.first { $0.leaf == leaf && $0.name == "complete" }, "No completing transcript of \(leaf)")
            let last = try XCTUnwrap(transcript.lines.last)
            let envelope = try XCTUnwrap(try decoder.decodeLine(last))
            guard case let .complete(outputs, _)? = envelope.event else {
                XCTFail("\(leaf) does not end in complete")
                continue
            }
            XCTAssertEqual(outputs.count, suffixes.count, "\(leaf) names \(outputs)")
            for (path, suffix) in zip(outputs, suffixes) {
                XCTAssertTrue(path.hasSuffix(suffix), "\(leaf) outputs '\(path)' where its runner reads a path ending '\(suffix)'")
            }
            for artifact in envelope.artifacts {
                XCTAssertTrue(outputs.contains(artifact.path), "\(leaf) types an artifact that outputs does not hold: \(artifact.path)")
            }
        }
        let primerTrim = try XCTUnwrap(all.first { $0.leaf == "bam primer-trim" && $0.name == "complete" })
        let envelope = try XCTUnwrap(try decoder.decodeLine(XCTUnwrap(primerTrim.lines.last)))
        XCTAssertEqual(
            envelope.artifacts.map(\.role),
            ["alignment", "alignment-index", "provenance"],
            "The version 2 primer trim run types its three outputs"
        )

        // Phase 2.6 lane C6. `variants call` types its three files in the order of `outputs` and each
        // names the one record of the run, and `align mafft` types its bundle, its one output.
        let variants = try XCTUnwrap(all.first { $0.leaf == "variants call" && $0.name == "complete" })
        let variantsEnvelope = try XCTUnwrap(try decoder.decodeLine(XCTUnwrap(variants.lines.last)))
        XCTAssertEqual(
            variantsEnvelope.artifacts.map(\.role),
            ["variants-database", "variants", "variants-index"],
            "The real run of variants call types its three files"
        )
        XCTAssertEqual(variantsEnvelope.artifacts.map(\.kind), ["variant-database", "vcf", "tbi"])
        let records = Set(variantsEnvelope.artifacts.compactMap(\.provenancePath))
        XCTAssertEqual(records.count, 1, "The three files name one record")
        XCTAssertTrue(try XCTUnwrap(records.first).hasSuffix(".lungfish-provenance.json"))

        let align = try XCTUnwrap(all.first { $0.leaf == "align mafft" && $0.name == "complete" })
        let alignEnvelope = try XCTUnwrap(try decoder.decodeLine(XCTUnwrap(align.lines.last)))
        guard case let .complete(alignOutputs, _)? = alignEnvelope.event else {
            return XCTFail("align mafft does not end in complete")
        }
        XCTAssertEqual(alignOutputs.count, 1, "The bundle is the one output, which a version 1 runner reads by place")
        XCTAssertTrue(try XCTUnwrap(alignOutputs.first).hasSuffix(".lungfishmsa"))
        XCTAssertEqual(alignEnvelope.artifacts.map(\.role), ["alignment"])
        XCTAssertEqual(alignEnvelope.artifacts.map(\.kind), ["multiple-sequence-alignment"])
        XCTAssertEqual(alignEnvelope.artifacts.map(\.path), alignOutputs)
        XCTAssertEqual(alignEnvelope.artifacts.first?.bundleKind, .multipleSequenceAlignment)
    }

    func testNoTranscriptNamesAPathOutsideTheScratchFolder() throws {
        // A transcript is shared, so no line may name a person's folder or a build folder.
        let markers = ["/Users/", "/private/", "/var/", "/Volumes/", "/tmp/", ".build"]
        for transcript in try transcripts() {
            for line in transcript.lines {
                let unescaped = line.replacingOccurrences(of: "\\/", with: "/")
                for marker in markers {
                    XCTAssertFalse(unescaped.contains(marker), "\(transcript.label) names a path outside /work ('\(marker)'): \(line)")
                }
            }
        }
    }

    func testNoTranscriptCarriesTheTextOfAFoundationError() throws {
        // A system message changes with the language and the macOS release, and a transcript that
        // holds one would go red on a machine that did not capture it.
        let markers = ["couldn’t", "couldn't", "isn’t", "The operation", "ArgumentParser.", "NSCocoaErrorDomain"]
        for transcript in try transcripts() {
            for line in transcript.lines {
                for marker in markers {
                    XCTAssertFalse(line.contains(marker), "\(transcript.label) carries system text ('\(marker)'): \(line)")
                }
            }
        }
    }

    // MARK: Fixtures

    /// Three rows over six columns, with a gap inside `seq1` so that an annotation across it splits.
    private static let threeRows = """
    >seq1
    A-CG-T
    >seq2
    ATCGGT
    >seq3
    AT-GGT

    """

    private static let gappedRows = """
    >seq1
    A-CGT
    >seq2
    A-C-T
    >seq3
    A-G-T

    """

    /// Two targets and two exclusions that differ at columns 1 and 5.
    private static let panel = """
    >t1
    ACGTACGT
    >t2
    ACGTACGT
    >x1
    GCGTGCGT
    >x2
    GCGTGCGT

    """

    private static let cladeTree = "((A:0.1,B:0.2)Clade:0.3,C:0.4);"
    private static let flatTree = "(A:0.1,B:0.2,C:0.3);"

    // MARK: What is captured

    /// One run of one leaf. `body` returns the event lines the run printed, in order.
    struct Capture {
        let leaf: String
        let name: String
        let body: (Scratch) async throws -> [String]
    }

    /// Every capture, with the leaf and the case it records.
    private static func captures() -> [Capture] {
        annotationCaptures() + exportCaptures() + derivedCaptures() + treeCaptures() + platformCaptures()
            + importCaptures() + ontSplitCaptures() + sequenceCaptures() + variantsCaptures() + importONTCaptures()
            + managedToolCaptures() + classifierImportCaptures() + naoMgsNvdImportCaptures() + importVCFCaptures()
            + projectCopyItemCaptures()
    }

    /// The four import commands and the three `build-db` leaves (`BuildDbStreamCapture`), run by `ImportStreamCapture`,
    /// which gives each run a scratch folder of its own and returns the standard output already rewritten to `/work`.
    private static func importCaptures() -> [Capture] {
        (ImportStreamCapture.cases() + BuildDbStreamCapture.cases() + AlignmentActionStreamCapture.cases()
            + CzIdImportStreamCapture.cases() + ViewerExportStreamCapture.cases() + PrimerExportStreamCapture.cases() + FastqExportStreamCapture.cases()
            + AnnotationGFF3ExportStreamCapture.cases() + AnnotationTableExportStreamCapture.cases()
            + FastqExportReadsStreamCapture.cases() + BundleExportGraphicStreamCapture.cases()).map { testCase in
            Capture(leaf: testCase.leaf, name: testCase.name) { _ in
                let scratch = try ImportStreamCapture.Scratch()
                defer { scratch.remove() }
                return try await testCase.run(scratch).standardOutput
            }
        }
    }

    private static func annotationCaptures() -> [Capture] {
        func annotated(_ scratch: Scratch) throws -> (bundle: URL, annotationID: String) {
            let bundle = try scratch.msaBundle("aln", threeRows)
            try MSACommand.AddSubcommand.parse([
                bundle.path, "--row", "seq1", "--columns", "3-6",
                "--name", "selection-feature", "--type", "gene", "--strand", "+", "--format", "json",
            ]).executeForTesting { _ in }
            let store = try MultipleSequenceAlignmentBundle.load(from: bundle).loadAnnotationStore()
            return (bundle, try XCTUnwrap(store.sourceAnnotations.first).id)
        }
        func projected(_ scratch: Scratch) throws -> (bundle: URL, annotationID: String, projectedID: String) {
            let (bundle, annotationID) = try annotated(scratch)
            try MSACommand.ProjectSubcommand.parse([
                bundle.path, "--source-annotation", annotationID, "--target-rows", "seq2",
                "--conflict-policy", "append", "--format", "json",
            ]).executeForTesting { _ in }
            let store = try MultipleSequenceAlignmentBundle.load(from: bundle).loadAnnotationStore()
            return (bundle, annotationID, try XCTUnwrap(store.projectedAnnotations.first).id)
        }
        return [
            Capture(leaf: "msa annotate add", name: "complete") { scratch in
                let bundle = try scratch.msaBundle("aln", threeRows)
                let command = try MSACommand.AddSubcommand.parse([
                    bundle.path, "--row", "seq1", "--columns", "3-6",
                    "--name", "selection-feature", "--type", "gene", "--strand", "+", "--format", "json",
                ])
                return try Self.lines { try command.executeForTesting(emit: $0) }
            },
            Capture(leaf: "msa annotate edit", name: "complete") { scratch in
                let (bundle, annotationID) = try annotated(scratch)
                let command = try MSACommand.EditSubcommand.parse([
                    bundle.path, "--annotation", annotationID,
                    "--name", "curated-feature", "--type", "CDS", "--format", "json",
                ])
                return try Self.lines { try command.executeForTesting(emit: $0) }
            },
            Capture(leaf: "msa annotate edit", name: "complete-with-warning") { scratch in
                let (bundle, _, projectedID) = try projected(scratch)
                let command = try MSACommand.EditSubcommand.parse([
                    bundle.path, "--annotation", projectedID, "--name", "curated-projection", "--format", "json",
                ])
                return try Self.lines { try command.executeForTesting(emit: $0) }
            },
            Capture(leaf: "msa annotate project", name: "complete-with-warning") { scratch in
                let (bundle, annotationID) = try annotated(scratch)
                let command = try MSACommand.ProjectSubcommand.parse([
                    bundle.path, "--source-annotation", annotationID, "--target-rows", "seq2",
                    "--conflict-policy", "append", "--format", "json",
                ])
                return try Self.lines { try command.executeForTesting(emit: $0) }
            },
            Capture(leaf: "msa annotate delete", name: "complete") { scratch in
                let (bundle, annotationID) = try annotated(scratch)
                let command = try MSACommand.DeleteSubcommand.parse([
                    bundle.path, "--annotation", annotationID, "--format", "json",
                ])
                return try Self.lines { try command.executeForTesting(emit: $0) }
            },
        ]
    }

    private static func exportCaptures() -> [Capture] {
        [
            Capture(leaf: "msa export", name: "complete") { scratch in
                let bundle = try scratch.msaBundle("aln", threeRows)
                let command = try MSACommand.ExportSubcommand.parse([
                    bundle.path, "--output-format", "aligned-fasta",
                    "--output", scratch.root.appendingPathComponent("selected.fa").path,
                    "--rows", "seq1", "--columns", "2-4", "--format", "json",
                ])
                return try Self.lines { try command.executeForTesting(emit: $0) }
            },
            Capture(leaf: "msa export", name: "complete-with-warning") { scratch in
                let bundle = try scratch.msaBundle("aln", threeRows)
                try MSACommand.AddSubcommand.parse([
                    bundle.path, "--row", "seq1", "--columns", "2-3",
                    "--name", "feature", "--type", "gene", "--format", "json",
                ]).executeForTesting { _ in }
                let command = try MSACommand.ExportSubcommand.parse([
                    bundle.path, "--output-format", "phylip",
                    "--output", scratch.root.appendingPathComponent("annotated.phy").path,
                    "--format", "json",
                ])
                return try Self.lines { try command.executeForTesting(emit: $0) }
            },
        ]
    }

    private static func derivedCaptures() -> [Capture] {
        [
            Capture(leaf: "msa consensus", name: "complete") { scratch in
                let bundle = try scratch.msaBundle("aln", threeRows)
                let command = try MSACommand.ConsensusSubcommand.parse([
                    bundle.path, "--output", scratch.root.appendingPathComponent("consensus.fa").path,
                    "--name", "fixture-consensus", "--threshold", "0.6", "--gap-policy", "omit", "--format", "json",
                ])
                return try Self.lines { try command.executeForTesting(emit: $0) }
            },
            Capture(leaf: "msa extract", name: "complete") { scratch in
                let bundle = try scratch.msaBundle("aln", threeRows)
                let command = try MSACommand.ExtractSubcommand.parse([
                    bundle.path, "--output-kind", "msa",
                    "--output", scratch.root.appendingPathComponent("selected.lungfishmsa").path,
                    "--rows", "seq1,seq2", "--columns", "2-4", "--name", "selected-region", "--format", "json",
                ])
                return try Self.lines { try command.executeForTesting(emit: $0) }
            },
            Capture(leaf: "msa mask columns", name: "complete") { scratch in
                let bundle = try scratch.msaBundle("aln", threeRows)
                let command = try MSACommand.MaskColumnsSubcommand.parse([
                    bundle.path, "--ranges", "2-3,6",
                    "--output", scratch.root.appendingPathComponent("masked.lungfishmsa").path,
                    "--name", "masked-region", "--reason", "low-confidence region", "--format", "json",
                ])
                return try Self.lines { try command.executeForTesting(emit: $0) }
            },
            Capture(leaf: "msa trim columns", name: "complete") { scratch in
                let bundle = try scratch.msaBundle("aln", gappedRows)
                let command = try MSACommand.TrimColumnsSubcommand.parse([
                    bundle.path, "--gap-only",
                    "--output", scratch.root.appendingPathComponent("trimmed.lungfishmsa").path,
                    "--name", "gap-only-trimmed", "--format", "json",
                ])
                return try Self.lines { try command.executeForTesting(emit: $0) }
            },
            Capture(leaf: "msa distance", name: "complete") { scratch in
                let bundle = try scratch.msaBundle("aln", threeRows)
                let command = try MSACommand.DistanceSubcommand.parse([
                    bundle.path, "--model", "identity",
                    "--output", scratch.root.appendingPathComponent("identity.tsv").path, "--format", "json",
                ])
                return try Self.lines { try command.executeForTesting(emit: $0) }
            },
            Capture(leaf: "msa discriminating-sites", name: "complete") { scratch in
                let bundle = try scratch.msaBundle("panel", panel)
                let command = try MSACommand.DiscriminatingSitesSubcommand.parse([
                    bundle.path, "--exclusions", "x1,x2", "--window-length", "8",
                    "--output", scratch.root.appendingPathComponent("sites.tsv").path, "--format", "json",
                ])
                return try Self.lines { try command.executeForTesting(emit: $0) }
            },
        ]
    }

    private static func treeCaptures() -> [Capture] {
        [
            Capture(leaf: "tree export subtree", name: "complete") { scratch in
                let bundle = try scratch.treeBundle("tree", newick: cladeTree)
                let command = try TreeCommand.ExportSubcommand.SubtreeSubcommand.parse([
                    bundle.path, "--label", "Clade",
                    "--output", scratch.root.appendingPathComponent("clade.nwk").path, "--format", "json",
                ])
                return try Self.lines { try command.executeForTesting(emit: $0) }
            },
            Capture(leaf: "tree reroot", name: "complete") { scratch in
                let bundle = try scratch.treeBundle("tree", newick: cladeTree)
                let command = try TreeCommand.RerootSubcommand.parse([
                    "--bundle", bundle.path, "--on", "C",
                    "--output", scratch.root.appendingPathComponent("rerooted.lungfishtree").path, "--format", "json",
                ])
                return try Self.lines { try command.executeForTesting(emit: $0) }
            },
            Capture(leaf: "tree reroot", name: "failed") { scratch in
                let bundle = try scratch.treeBundle("tree", newick: cladeTree)
                let command = try TreeCommand.RerootSubcommand.parse([
                    "--bundle", bundle.path, "--on", "Missing",
                    "--output", scratch.root.appendingPathComponent("never.lungfishtree").path, "--format", "json",
                ])
                return try Self.lines(expectingFailure: true) { try command.executeForTesting(emit: $0) }
            },
            Capture(leaf: "tree extract-subtree", name: "complete") { scratch in
                let bundle = try scratch.treeBundle("tree", newick: cladeTree)
                let command = try TreeCommand.ExtractSubtreeSubcommand.parse([
                    "--bundle", bundle.path, "--node", "Clade",
                    "--output", scratch.root.appendingPathComponent("extracted.lungfishtree").path, "--format", "json",
                ])
                return try Self.lines { try command.executeForTesting(emit: $0) }
            },
            Capture(leaf: "tree extract-subtree", name: "failed") { scratch in
                let bundle = try scratch.treeBundle("tree", newick: cladeTree)
                let command = try TreeCommand.ExtractSubtreeSubcommand.parse([
                    "--bundle", bundle.path, "--node", "Missing",
                    "--output", scratch.root.appendingPathComponent("never.lungfishtree").path, "--format", "json",
                ])
                return try Self.lines(expectingFailure: true) { try command.executeForTesting(emit: $0) }
            },
            Capture(leaf: "tree relabel", name: "complete") { scratch in
                let bundle = try scratch.treeBundle(
                    "tree", newick: flatTree, metadata: "id\tlineage\nA\tBA.1\nB\tBA.2\nC\tBA.5\n"
                )
                let command = try TreeCommand.RelabelSubcommand.parse([
                    "--bundle", bundle.path, "--column", "lineage",
                    "--output", scratch.root.appendingPathComponent("relabeled.lungfishtree").path, "--format", "json",
                ])
                return try Self.lines { try command.executeForTesting(emit: $0) }
            },
        ]
    }

    private static func platformCaptures() -> [Capture] {
        /// A bundle as an import before platform inference left it, with dorado reads recorded as Illumina.
        func mislabelledBundle(_ scratch: Scratch) throws -> URL {
            let bundle = scratch.root.appendingPathComponent("Project.lungfish/Imports/Legacy.lungfishfastq", isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let fastq = try PlatformHeaderFixtures.copy("ont-dorado-samtags-tab.fastq", to: bundle, as: "Legacy.fastq")
            FASTQMetadataStore.save(
                PersistedFASTQMetadata(sequencingPlatform: .illumina, assemblyReadType: .illuminaShortReads),
                for: fastq
            )
            return bundle
        }
        return [
            Capture(leaf: "fastq platform", name: "complete") { scratch in
                let bundle = try mislabelledBundle(scratch)
                let command = try FastqPlatformSubcommand.parse([bundle.path, "--set", "ont", "--format", "json"])
                return try await Self.standardOutputLines(in: scratch) { try await command.run() }
            },
            // A folder that is not a bundle throws after the start line. The message is the command's own.
            Capture(leaf: "fastq platform", name: "failed") { scratch in
                let folder = scratch.root.appendingPathComponent("Plain", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let command = try FastqPlatformSubcommand.parse([folder.path, "--set", "ont", "--format", "json"])
                return try await Self.standardOutputLines(in: scratch, expectingFailure: true) { try await command.run() }
            },
        ]
    }

    /// The two ONT split commands on one tiny fixture each. Their events go through the `execute(emit:)`
    /// seam, and a run into an output folder that already exists, without `--force`, ends in the
    /// `failed` line that the materializer's own message makes.
    private static func ontSplitCaptures() -> [Capture] {
        func fastq(_ scratch: Scratch, _ name: String, read: String) throws -> URL {
            let url = scratch.root.appendingPathComponent(name)
            let record = "@read-1\n\(read)\n+\n\(String(repeating: "I", count: read.count))\n"
            try (record + record.replacingOccurrences(of: "read-1", with: "read-2")).write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        func fluidigm(_ scratch: Scratch, precreatingOutput: Bool) throws -> FastqONTFluidigmSamplesSubcommand {
            let read = ONTFluidigmAmpliconMaterializer.defaultForwardPrimer + "ACGTACGTACGTACGT"
                + reverseComplement(ONTFluidigmAmpliconMaterializer.defaultReversePrimer) + "CC" + "AAAACCCCGG"
            let input = try fastq(scratch, "reads.fastq", read: read)
            let barcodes = scratch.root.appendingPathComponent("samples.csv")
            try "sample,barcode\nLF2871,AAAACCCCGG\n".write(to: barcodes, atomically: true, encoding: .utf8)
            let output = scratch.root.appendingPathComponent("fluidigm", isDirectory: true)
            if precreatingOutput { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
            return try FastqONTFluidigmSamplesSubcommand.parse(
                [input.path, "--barcodes", barcodes.path, "--output", output.path,
                 "--primer-mismatches", "0", "--minimum-insert-length", "8"] + (precreatingOutput ? [] : ["--force"])
            )
        }
        func pacBio(_ scratch: Scratch, precreatingOutput: Bool) throws -> FastqONTPacBioBarcodeDemuxSubcommand {
            let read = String(repeating: "T", count: 60) + "CACATATCAGAGTGCG" + String(repeating: "ACGT", count: 510)
                + reverseComplement("CTATACATAGTGATGT") + String(repeating: "A", count: 60)
            let input = try fastq(scratch, "reads.fastq", read: read)
            let barcodes = scratch.root.appendingPathComponent("plate.barcodes.csv")
            try "32286-001_DL46,BC1001,BC1021\n".write(to: barcodes, atomically: true, encoding: .utf8)
            let output = scratch.root.appendingPathComponent("pacbio", isDirectory: true)
            if precreatingOutput { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
            return try FastqONTPacBioBarcodeDemuxSubcommand.parse(
                [input.path, "--barcodes", barcodes.path, "--output", output.path,
                 "--chunk-jobs", "1", "--max-reads-per-slice", "0"] + (precreatingOutput ? [] : ["--force"])
            )
        }
        return [
            Capture(leaf: "fastq ont-fluidigm-samples", name: "complete") { scratch in
                let command = try fluidigm(scratch, precreatingOutput: false)
                return try await Self.eventLines { try await command.execute(emit: $0) }
            },
            Capture(leaf: "fastq ont-fluidigm-samples", name: "failed") { scratch in
                let command = try fluidigm(scratch, precreatingOutput: true)
                return try await Self.eventLines(expectingFailure: true) { try await command.execute(emit: $0) }
            },
            Capture(leaf: "fastq ont-pacbio-barcode-demux", name: "complete") { scratch in
                let command = try pacBio(scratch, precreatingOutput: false)
                return try await Self.eventLines { try await command.execute(emit: $0) }
            },
            Capture(leaf: "fastq ont-pacbio-barcode-demux", name: "failed") { scratch in
                let command = try pacBio(scratch, precreatingOutput: true)
                return try await Self.eventLines(expectingFailure: true) { try await command.execute(emit: $0) }
            },
        ]
    }

    private static func reverseComplement(_ sequence: String) -> String {
        String(sequence.reversed().map { base -> Character in
            switch base {
            case "A": return "T"
            case "C": return "G"
            case "G": return "C"
            case "T": return "A"
            default: return "N"
            }
        })
    }

    // MARK: Running a capture

    private struct NoFailure: Error, CustomStringConvertible {
        var description: String { "The run was expected to fail and did not" }
    }

    /// The lines a command with a test seam hands to its sink. A run that throws after it has
    /// printed its `failed` line is a failure case when `expectingFailure` is set.
    private static func lines(
        expectingFailure: Bool = false,
        _ run: (@escaping (String) -> Void) throws -> Void
    ) throws -> [String] {
        var captured: [String] = []
        do {
            try run { captured.append($0) }
            if expectingFailure { throw NoFailure() }
        } catch is NoFailure {
            throw NoFailure()
        } catch {
            if !expectingFailure { throw error }
        }
        return captured
    }

    /// `lines` for a command whose seam is async. The sink collects under a lock, because a
    /// materializer reports progress from its own tasks.
    static func eventLines(
        expectingFailure: Bool = false,
        _ run: (@escaping (String) -> Void) async throws -> Void
    ) async throws -> [String] {
        let sink = LineSink()
        do {
            try await run { sink.append($0) }
            if expectingFailure { throw NoFailure() }
        } catch is NoFailure {
            throw NoFailure()
        } catch {
            if !expectingFailure { throw error }
        }
        return sink.all
    }

    private final class LineSink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    /// The standard output of a run that has no sink, redirected to a file for its length.
    static func standardOutputLines(
        in scratch: Scratch,
        expectingFailure: Bool = false,
        _ run: () async throws -> Void
    ) async throws -> [String] {
        let file = scratch.root.appendingPathComponent("standard-output.capture")
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard saved >= 0, descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        dup2(descriptor, STDOUT_FILENO)
        close(descriptor)
        var failure: Error?
        do {
            try await run()
        } catch {
            failure = error
        }
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
        if expectingFailure {
            if failure == nil { throw NoFailure() }
        } else if let failure {
            throw failure
        }
        let text = try String(contentsOf: file, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: Scratch folder

    final class Scratch {
        let root: URL

        init() throws {
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".build/test-artifacts/CLIEventTranscripts-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        /// The scratch folder becomes `/work`, in the plain and the slash-escaped spelling a line can hold.
        func normalized(_ line: String) -> String {
            let escaped = root.path.replacingOccurrences(of: "/", with: "\\/")
            return line
                .replacingOccurrences(of: escaped, with: "\\/work")
                .replacingOccurrences(of: root.path, with: "/work")
        }

        func msaBundle(_ name: String, _ fasta: String) throws -> URL {
            let source = root.appendingPathComponent("\(name).fasta")
            try fasta.write(to: source, atomically: true, encoding: .utf8)
            let bundle = root.appendingPathComponent("\(name).lungfishmsa", isDirectory: true)
            _ = try MultipleSequenceAlignmentBundle.importAlignment(from: source, to: bundle, options: .init(name: name))
            return bundle
        }

        func treeBundle(_ name: String, newick: String, metadata: String? = nil) throws -> URL {
            let source = root.appendingPathComponent("\(name).nwk")
            try newick.write(to: source, atomically: true, encoding: .utf8)
            let bundle = root.appendingPathComponent("\(name).lungfishtree", isDirectory: true)
            _ = try PhylogeneticTreeBundleImporter.importTree(from: source, to: bundle)
            if let metadata {
                try metadata.write(to: bundle.appendingPathComponent("metadata.tsv"), atomically: true, encoding: .utf8)
            }
            return bundle
        }
    }

    // MARK: Tests

    func testTheCapturesCoverEveryEventsLeafThatNeedsNoTool() {
        let inProcess = Set(CLIEventContractTable.entries.compactMap { path, contract -> String? in
            if case .events = contract, !Self.toolLeaves.contains(path) { return path }
            return nil
        })
        let captured = Set(Self.captures().map(\.leaf))
        XCTAssertEqual(captured, inProcess, "Each events leaf that needs no tool has captures, and no other leaf does")
        for leaf in inProcess {
            XCTAssertTrue(
                Self.captures().contains { $0.leaf == leaf && $0.name.hasPrefix("complete") },
                "\(leaf) has no capture that completes"
            )
        }
    }

    func testEveryInProcessTranscriptIsWhatTheCommandPrintsToday() async throws {
        let recapture = ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_CLI_EVENTS"] == "1"
        for capture in Self.captures() {
            let scratch = try Scratch()
            defer { scratch.remove() }
            let lines = try await capture.body(scratch).map(scratch.normalized)
            let text = lines.joined(separator: "\n") + "\n"
            let url = Self.transcriptURL(leaf: capture.leaf, name: capture.name)

            if recapture {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
                continue
            }
            guard let checkedIn = try? String(contentsOf: url, encoding: .utf8) else {
                XCTFail("No transcript for '\(capture.leaf)' case '\(capture.name)'. Run with LUNGFISH_RECAPTURE_CLI_EVENTS=1 and review the new file")
                continue
            }
            XCTAssertEqual(
                lines,
                checkedIn.split(separator: "\n", omittingEmptySubsequences: true).map(String.init),
                "'\(capture.leaf)' case '\(capture.name)' no longer prints its checked-in transcript. If the change is deliberate, run with LUNGFISH_RECAPTURE_CLI_EVENTS=1 and review the diff"
            )
        }
    }
}

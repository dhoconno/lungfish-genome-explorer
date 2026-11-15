// RNASeqQuantCommandTests.swift - The leaf `lungfish-cli rnaseq quant` (Phase 5.1 lane RS-QUANT, milestone 2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// salmon and Trim Galore are stand-ins under the storage root `<home>/.lungfish`, which `--storage-root` names. The salmon
// stand-in writes the `salmon-c1` fixture's folder of SRR896663 at `-o`, or, when `capture/hold` exists, writes its process
// ID and sleeps until it is ended. The set and its index are built in this process by their owners.

import ArgumentParser
import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

/// One transcript record a transcript id of the GTF's exon lines, as gffread writes.
private struct QuantCommandTranscripts: ReferenceSetTranscriptDeriving {
    func toolVersion() async throws -> String { "0.12.9" }

    func writeTranscripts(genome: URL, annotation: URL, to output: URL) async throws {
        var ids: [String] = []
        for line in try String(contentsOf: annotation, encoding: .utf8).split(separator: "\n") {
            guard let start = line.range(of: "transcript_id \"") else { continue }
            let id = String(line[start.upperBound...].prefix { $0 != "\"" })
            if !ids.contains(id) { ids.append(id) }
        }
        try Data(ids.map { ">\($0)\nACGTACGTAC\n" }.joined().utf8).write(to: output)
    }
}

final class RNASeqQuantCommandTests: XCTestCase {
    var base: URL!
    var capture: URL!
    var stand: ManagedTestStandIn!
    var fixtures: ReadSetFixtures!
    var savedStorageRoot: String?
    var root: URL { stand.home.appendingPathComponent(".lungfish", isDirectory: true) }

    static let roomy = RunFitHostFacts(physicalMemoryBytes: 68_719_476_736)

    var salmonScript: String {
        let c = capture.path, fixture = RNASeqFixtures.salmonRun("SRR896663").path
        return """
        #!/bin/sh
        echo "$*" >> "\(c)/log"
        case "$1" in
          index) shift
            d=""; i=""; k=""
            while [ $# -gt 0 ]; do
              case "$1" in -d) d="$2"; shift 2 ;; -i) i="$2"; shift 2 ;; -k) k="$2"; shift 2 ;; *) shift ;; esac
            done
            /bin/mkdir -p "$i"; n=$(/usr/bin/grep -c . "$d")
            printf '{"k": %s, "salmon_version": "2.11.0", "num_decoys": %s, "seq_hash": "seq1", "name_hash": "name1", "decoy_seq_hash": "dseq1", "decoy_name_hash": "dname1"}\\n' "$k" "$n" > "$i/info.json"
            echo x > "$i/refseq.bin"; exit 0 ;;
          quant) shift ;;
          *) exit 2 ;;
        esac
        if [ -f "\(c)/hold" ]; then echo $$ > "\(c)/salmon.pid"; exec /bin/sleep 600; fi
        o=""
        while [ $# -gt 0 ]; do
          case "$1" in -o) o="$2"; shift 2 ;; *) shift ;; esac
        done
        /bin/mkdir -p "$o"
        /bin/cp -R "\(fixture)/" "$o/"
        exit 0
        """
    }

    var trimScript: String {
        """
        #!/bin/sh
        echo "$*" >> "\(capture.path)/trimlog"
        o=""; paired=0; files=""
        while [ $# -gt 0 ]; do
          case "$1" in -o) o="$2"; shift 2 ;; --paired) paired=1; shift ;; -*) shift ;; *) files="$files $1"; shift ;; esac
        done
        /bin/mkdir -p "$o"; n=0
        for f in $files; do
          n=$((n + 1)); stem=$(/usr/bin/basename "$f"); stem=${stem%.fastq}; stem=${stem%.fq}
          if [ $paired = 1 ]; then /bin/cp "$f" "$o/${stem}_val_${n}.fq"; else /bin/cp "$f" "$o/${stem}_trimmed.fq"; fi
        done
        exit 0
        """
    }

    override func setUp() async throws {
        base = try TestTempDirectory.make(prefix: "rnaseq-quant-cli")
        capture = base.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        fixtures = try ReadSetFixtures(in: base)
        stand = try ManagedTestStandIn(prefix: "rnaseq-quant-cli-home")
        savedStorageRoot = ProcessInfo.processInfo.environment["LUNGFISH_STORAGE_ROOT"]
        await NativeToolRunner.shared.clearCache()
        try stand.install("salmon", script: salmonScript)
        try stand.install("trim_galore", script: trimScript)
        try condaMeta(environment: "salmon", name: "salmon", version: "2.11.0")
        try condaMeta(environment: "trim_galore", name: "trim-galore", version: "2.3.0")
    }

    override func tearDown() async throws {
        if let savedStorageRoot { setenv("LUNGFISH_STORAGE_ROOT", savedStorageRoot, 1) } else { unsetenv("LUNGFISH_STORAGE_ROOT") }
        await NativeToolRunner.shared.clearCache()
        stand?.remove()
        TestTempDirectory.cleanup(base)
    }

    func condaMeta(environment: String, name: String, version: String) throws {
        let meta = root.appendingPathComponent("conda/envs/\(environment)/conda-meta", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try Data(#"{"name":"\#(name)","version":"\#(version)","build":"h0_0"}"#.utf8)
            .write(to: meta.appendingPathComponent("\(name)-\(version)-h0_0.json"))
    }

    /// A set of the fixture's transcripts, three a gene on chr1 and ERCC92 as a spike-in, and its index, built by their
    /// owners. The stand-in's log is emptied after, so it holds only quant's calls.
    func makeSetAndIndex() async throws -> String {
        let inputs = base.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let text = try String(contentsOf: RNASeqFixtures.salmonRun("SRR896663").appendingPathComponent("quant.sf"), encoding: .utf8)
        let ids = text.split(separator: "\n").dropFirst().map { String($0.prefix { $0 != "\t" }) }
        let host = ids.filter { !$0.hasPrefix("ERCC-") }
        let gtf = host.enumerated().map { index, id in
            "chr1\tt\texon\t\(index * 10 + 1)\t\(index * 10 + 10)\t.\t+\t.\tgene_id \"G\(index / 3)\"; transcript_id \"\(id)\";\n"
        }.joined()
        try Data(gtf.utf8).write(to: inputs.appendingPathComponent("genes.gtf"))
        try Data((">chr1 test\n" + String(repeating: "ACGTACGTAC", count: host.count + 1) + "\n").utf8)
            .write(to: inputs.appendingPathComponent("genome.fa"))
        try Data(ids.filter { $0.hasPrefix("ERCC-") }.map { ">\($0)\nACGTACGT\n" }.joined().utf8)
            .write(to: inputs.appendingPathComponent("ercc.fa"))
        let request = ReferenceSetRequest(
            name: "Test set", species: "Testus examplus", assemblyName: "T1", annotationSource: "TestDB",
            annotationRelease: "7", genome: inputs.appendingPathComponent("genome.fa"),
            annotation: inputs.appendingPathComponent("genes.gtf"),
            extras: [ReferenceSetExtraInput(name: "ERCC92", kind: .spikeIn, fasta: inputs.appendingPathComponent("ercc.fa"))],
            layout: .lge)
        let set = try await ReferenceSetOwner(
            storageRoot: root, deriver: QuantCommandTranscripts(), provenanceWriter: ProvenanceWriter(signingProvider: nil)
        ).build(request)
        let cache = SalmonIndexCache(
            storageRoot: root, runner: NativeToolRunner(toolsDirectory: nil, homeDirectory: stand.home, appIdentity: .preview),
            provenanceWriter: ProvenanceWriter(signingProvider: nil), host: Self.roomy, freeSpace: { _ in 1_000_000_000_000 })
        _ = try await cache.ensure(SalmonIndexRequest(setID: set.manifest.id), linuxRoute: "Linux")
        try? FileManager.default.removeItem(at: capture.appendingPathComponent("log"))
        return set.manifest.id
    }

    /// A copy of the interleaved pair bundle under `name` in the project's imports.
    func pairBundle(_ name: String) throws -> URL {
        let url = fixtures.importsURL.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.copyItem(at: fixtures.interleavedRoot, to: url)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: .interleaved, pairingSource: .detected)),
            for: url.appendingPathComponent("reads.fastq"))
        return url
    }

    func arguments(_ bundles: [URL], set: String, project: URL, name: String, extra: [String] = []) -> [String] {
        ["rnaseq", "quant"] + bundles.map(\.path)
            + ["--project", project.path, "--name", name, "--set", set, "--storage-root", root.path, "--quiet"] + extra
    }

    /// Parses `arguments` as the leaf and runs it with `lungfish-cli` and them as its argv, then returns the result.
    @discardableResult
    func run(_ arguments: [String], project: URL, name: String) async throws -> URL {
        let parsed = try LungfishCLI.parseAsRoot(arguments)
        let command = try XCTUnwrap(parsed as? RNASeqCommand.QuantSubcommand, "\(type(of: parsed))")
        try await command.execute(argv: ["lungfish-cli"] + arguments)
        return try XCTUnwrap(results(in: project).first { $0.lastPathComponent.hasPrefix(name) }, "no result \(name)")
    }

    func results(in project: URL) -> [URL] {
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: analyses.path)) ?? []
        return names.sorted().map { analyses.appendingPathComponent($0, isDirectory: true) }
    }

    func record(_ result: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: result), "the result has a record")
    }

    func text(_ step: ProvenanceStep?, _ key: String) -> String? {
        if case .string(let value)? = step?.resolvedOptions[key] { return value }
        return nil
    }

    func sha256(_ url: URL) throws -> String { try ProvenanceFileHasher.sha256(of: url) }

    // MARK: - The trim call's argv (prog plan :192)

    func testTheTrimCallRecordsItsPolyGFlagAndAQuantWithNoTrimReadsNotTrimmed() async throws {
        let set = try await makeSetAndIndex()
        let bundle = try pairBundle("A"), project = fixtures.projectURL
        let none = try await run(arguments([bundle], set: set, project: project, name: "None"), project: project, name: "None")
        let off = try await run(
            arguments([bundle], set: set, project: project, name: "Off", extra: ["--trim"]), project: project, name: "Off")
        let on = try await run(
            arguments([bundle], set: set, project: project, name: "On", extra: ["--trim", "--poly-g-trimming", "on"]),
            project: project, name: "On")
        let salmon = { (url: URL) throws -> ProvenanceStep? in try self.record(url).steps.first { $0.toolName == "salmon" } }
        let trim = { (url: URL) throws -> ProvenanceStep? in try self.record(url).steps.first { $0.toolName == "trim_galore" } }
        XCTAssertNil(try trim(none), "no trim call without --trim")
        XCTAssertEqual(text(try salmon(none), "trimming"), "Reads not trimmed")
        XCTAssertEqual(try trim(off)?.argv.dropFirst().first, "--no_poly_g")
        XCTAssertFalse(try trim(off)?.argv.contains("--poly_g") ?? true)
        XCTAssertEqual(text(try salmon(off), "trimming"), "Poly-G trimming: off (LGE default)")
        XCTAssertEqual(try trim(on)?.argv.dropFirst().first, "--poly_g")
        XCTAssertFalse(try trim(on)?.argv.contains("--no_poly_g") ?? true)
        XCTAssertEqual(text(try salmon(on), "trimming"), "Poly-G trimming: on (chosen), Trim Galore 2.3.0 --poly_g")
        // BIO-POLYG item 4: no poly-G key a person sees reads false or no.
        for url in [none, off, on] {
            let envelope = try record(url)
            let maps = [envelope.options.explicit, envelope.options.resolvedDefaults] + envelope.steps.map(\.resolvedOptions)
            for map in maps {
                for (key, value) in map where key.lowercased().contains("poly") || key == "trim" || key == "trimming" {
                    XCTAssertNotEqual(value, .boolean(false), key)
                    XCTAssertNotEqual(value, .string("false"), key)
                    XCTAssertNotEqual(value, .string("no"), key)
                }
            }
        }
    }

    // MARK: - The family's cases (SAD :95)

    func testTheRecordedArgvParsesToTheSameOptions() async throws {
        let set = try await makeSetAndIndex()
        let bundles = [try pairBundle("A"), try pairBundle("B")], project = fixtures.projectURL
        let given = arguments(bundles, set: set, project: project, name: "Counts", extra: [
            "--k", "31", "--decoys", "genome", "--trim", "--poly-g-trimming", "on", "--threads", "3",
        ])
        let recorded = try record(try await run(given, project: project, name: "Counts")).argv
        XCTAssertEqual(recorded, ["lungfish-cli"] + given, "the record holds the argv as run")
        let leaf = { (argv: [String]) throws -> SalmonQuantRequest in
            let parsed = try XCTUnwrap(try LungfishCLI.parseAsRoot(argv) as? RNASeqCommand.QuantSubcommand)
            return parsed.makeRequest(argv: [])
        }
        let first = try leaf(given), again = try leaf(Array(recorded.dropFirst()))
        XCTAssertEqual(again.bundles, first.bundles)
        XCTAssertEqual(again.projectURL, first.projectURL)
        XCTAssertEqual(again.name, first.name)
        XCTAssertEqual(again.setID, first.setID)
        XCTAssertEqual(again.k, first.k)
        XCTAssertEqual(again.decoys, first.decoys)
        XCTAssertEqual(again.threads, 3)
        XCTAssertEqual(again.threads, first.threads)
        XCTAssertEqual(again.trim, .trimGalore(polyG: true))
    }

    /// The recorded command, run again into a second project at another thread count, gives count tables of equal sha256.
    func testAReplayIntoASecondProjectGivesCountTablesOfEqualSHA256() async throws {
        let set = try await makeSetAndIndex()
        let bundles = [try pairBundle("A"), try pairBundle("B")], project = fixtures.projectURL
        let first = try await run(
            arguments(bundles, set: set, project: project, name: "Counts", extra: ["--threads", "3"]), project: project,
            name: "Counts")
        var argv = try record(first).argv
        let second = base.appendingPathComponent("Second.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let p = try XCTUnwrap(argv.firstIndex(of: "--project")), t = try XCTUnwrap(argv.firstIndex(of: "--threads"))
        argv[p + 1] = second.path
        argv[t + 1] = "1"
        let replay = try await run(Array(argv.dropFirst()), project: second, name: "Counts")
        for table in ["counts/genes.counts.tsv", "counts/transcripts.counts.tsv"] {
            XCTAssertEqual(try sha256(first.appendingPathComponent(table)), try sha256(replay.appendingPathComponent(table)), table)
        }
        XCTAssertEqual(try record(first).options.explicit["threads"], .integer(3), "threads is recorded")
        XCTAssertEqual(try record(replay).options.explicit["threads"], .integer(1))
    }

    /// The app's Cancel, modelled on `ImportCommandsSIGTERMTests`: one SIGTERM while salmon runs ends salmon, the command
    /// exits 125, and it publishes nothing and leaves no stage, no working folder and no `uses/` file.
    func testSIGTERMEndsSalmonPublishesNothingAndLeavesNoStageWorkFolderOrUse() async throws {
        let set = try await makeSetAndIndex()
        let bundle = try pairBundle("A"), project = fixtures.projectURL
        try Data().write(to: capture.appendingPathComponent("hold"))
        let run = try CLISIGTERMHarness.launchCLI(
            arguments([bundle], set: set, project: project, name: "Counts"), workingDirectory: base, testClass: Self.self)
        defer { run.stop() }
        let pid = await CLISIGTERMHarness.waitForProcessID(in: capture.appendingPathComponent("salmon.pid"))
        XCTAssertNotNil(pid, "the command never reached salmon")
        let stop = await CLISIGTERMHarness.cancel(run)
        CLISIGTERMHarness.assertCancelledExit(stop)
        CLISIGTERMHarness.assertNoProcessLeft(stop)
        if let pid { XCTAssertNotEqual(kill(pid, 0), 0, "salmon was ended") }
        XCTAssertEqual(results(in: project), [], "a cancelled quant publishes nothing and leaves no stage in Analyses")
        let scratch = ProjectTempDirectory.tempRoot(for: project)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        XCTAssertFalse(left.contains { $0.hasPrefix(SalmonQuantRoute.workFolderPrefix) }, "no working folder is left: \(left)")
        let files = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []
        XCTAssertEqual(files.filter { $0.contains("/uses/") }, [], "no use of the set or the index is written")
        XCTAssertEqual(files.filter { $0.contains(".creating-") }, [], "no stage is left under the storage root")
    }
}

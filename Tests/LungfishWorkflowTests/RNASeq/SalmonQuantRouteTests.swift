// SalmonQuantRouteTests.swift - salmon quant on a project's FASTQ bundles (Phase 5.1 lane RS-QUANT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class SalmonQuantRouteTests: XCTestCase {
    var base: URL!
    var root: URL!
    var capture: URL!
    var stand: ManagedTestStandIn!
    var fixtures: ReadSetFixtures!

    static let linuxRoute = "run salmon on Linux and bring its salmon folders into a project with lungfish-cli import rnaseq"
    static let roomy = RunFitHostFacts(physicalMemoryBytes: 68_719_476_736)

    /// A stand-in for salmon 2.11.0. `index` writes `info.json` with four hashes, as `SalmonIndexCacheTests` does. `quant`
    /// logs its arguments and writes the `salmon-c1` fixture's folder of SRR896663 at `-o`, then SRR896743 on the next call.
    static func salmonScript(capture: URL) -> String {
        let c = capture.path, fixture = RNASeqFixtures.salmonRun("SRR896663").deletingLastPathComponent().path
        return """
        #!/bin/sh
        echo "$*" >> "\(c)/log"
        case "$1" in
          index) shift
            t=""; d=""; i=""; k=""
            while [ $# -gt 0 ]; do
              case "$1" in -t) t="$2"; shift 2 ;; -d) d="$2"; shift 2 ;; -i) i="$2"; shift 2 ;; -k) k="$2"; shift 2 ;; *) shift ;; esac
            done
            /bin/mkdir -p "$i"; n=$(/usr/bin/grep -c . "$d")
            printf '{"k": %s, "salmon_version": "2.11.0", "num_decoys": %s, "seq_hash": "seq1", "name_hash": "name1", "decoy_seq_hash": "dseq1", "decoy_name_hash": "dname1"}\\n' "$k" "$n" > "$i/info.json"
            echo x > "$i/refseq.bin"; exit 0 ;;
          quant) shift ;;
          *) exit 2 ;;
        esac
        o=""
        while [ $# -gt 0 ]; do
          case "$1" in -o) o="$2"; shift 2 ;; *) shift ;; esac
        done
        run=SRR896663
        [ -f "\(c)/second" ] && run=SRR896743
        /usr/bin/touch "\(c)/second"
        /bin/mkdir -p "$o"
        /bin/cp -R "\(fixture)/$run/" "$o/"
        echo "quant log" > "$o/logs.txt"
        exit 0
        """
    }

    /// A stand-in for Trim Galore 2.3.0: logs its arguments and copies each input to the name Trim Galore gives it.
    static func trimGaloreScript(capture: URL) -> String {
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

    override func setUpWithError() throws {
        base = try TestTempDirectory.make(prefix: "salmon-quant")
        root = base.appendingPathComponent("root", isDirectory: true)
        capture = base.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        fixtures = try ReadSetFixtures(in: base)
        stand = try ManagedTestStandIn(prefix: "salmon-quant-home")
        try stand.install("salmon", script: Self.salmonScript(capture: capture))
        try stand.install("trim_galore", script: Self.trimGaloreScript(capture: capture))
        try condaMeta(environment: "salmon", name: "salmon", version: "2.11.0")
        try condaMeta(environment: "trim_galore", name: "trim-galore", version: "2.3.0")
    }

    override func tearDownWithError() throws {
        stand?.remove()
        TestTempDirectory.cleanup(base)
    }

    func condaMeta(environment: String, name: String, version: String) throws {
        let meta = stand.home.appendingPathComponent(".lungfish/conda/envs/\(environment)/conda-meta", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try Data(#"{"name":"\#(name)","version":"\#(version)","build":"h0_0"}"#.utf8)
            .write(to: meta.appendingPathComponent("\(name)-\(version)-h0_0.json"))
    }

    var runner: NativeToolRunner { NativeToolRunner(toolsDirectory: nil, homeDirectory: stand.home, appIdentity: .preview) }

    /// The fixture's transcripts by gene: three transcripts of chr1 a gene, and each ERCC sequence its own gene.
    func fixtureGenes() throws -> (order: [String], gene: [String: String]) {
        let text = try String(contentsOf: RNASeqFixtures.salmonRun("SRR896663").appendingPathComponent("quant.sf"), encoding: .utf8)
        let ids = text.split(separator: "\n").dropFirst().map { String($0.prefix { $0 != "\t" }) }
        var gene: [String: String] = [:]
        for (index, id) in ids.filter({ !$0.hasPrefix("ERCC-") }).enumerated() { gene[id] = "G\(index / 3)" }
        for id in ids where id.hasPrefix("ERCC-") { gene[id] = id }
        return (ids, gene)
    }

    /// A set whose transcripts are the fixture's: chr1 holds one exon a transcript and ERCC92 is a spike-in, not host.
    func makeSet() async throws -> ReferenceSetOutcome {
        let inputs = base.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let (ids, gene) = try fixtureGenes()
        let host = ids.filter { !$0.hasPrefix("ERCC-") }
        let gtf = host.enumerated().map { index, id in
            "chr1\tt\texon\t\(index * 10 + 1)\t\(index * 10 + 10)\t.\t+\t.\tgene_id \"\(gene[id] ?? "")\"; transcript_id \"\(id)\";\n"
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
        let owner = ReferenceSetOwner(
            storageRoot: root, deriver: StandInTranscriptDeriver(), provenanceWriter: ProvenanceWriter(signingProvider: nil))
        return try await owner.build(request)
    }

    /// The set and its index, built by their owners. The stand-in's log is emptied after, so it holds only quant's calls.
    func makeSetAndIndex() async throws -> String {
        let set = try await makeSet()
        let cache = SalmonIndexCache(
            storageRoot: root, runner: runner, provenanceWriter: ProvenanceWriter(signingProvider: nil), host: Self.roomy,
            freeSpace: { _ in 1_000_000_000_000 })
        _ = try await cache.ensure(SalmonIndexRequest(setID: set.manifest.id), linuxRoute: Self.linuxRoute)
        try? FileManager.default.removeItem(at: capture.appendingPathComponent("log"))
        return set.manifest.id
    }

    /// A copy of the interleaved pair bundle under `name`, whose import record names `steps`.
    func pairBundle(_ name: String, importSteps steps: [RecipeStepResult] = [], report: String? = nil) throws -> URL {
        let url = fixtures.importsURL.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.copyItem(at: fixtures.interleavedRoot, to: url)
        let recipe = steps.isEmpty ? nil : RecipeAppliedInfo(recipeID: "import", recipeName: "Import", stepResults: steps)
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(ingestion: IngestionMetadata(pairingMode: .interleaved, pairingSource: .detected, recipeApplied: recipe)),
            for: url.appendingPathComponent("reads.fastq"))
        if let report { try Data(report.utf8).write(to: url.appendingPathComponent("reads_val_1.fq_trimming_report.json")) }
        return url
    }

    func route(host: RunFitHostFacts = SalmonQuantRouteTests.roomy) -> SalmonQuantRoute {
        SalmonQuantRoute(
            storageRoot: root, runner: runner, provenanceWriter: ProvenanceWriter(signingProvider: nil), host: host,
            freeSpace: { _ in 1_000_000_000_000 })
    }

    func quant(
        _ bundles: [URL], set: String, trim: SalmonQuantTrim = .none, host: RunFitHostFacts = SalmonQuantRouteTests.roomy
    ) async throws -> SalmonQuantOutcome {
        let request = SalmonQuantRequest(
            bundles: bundles, projectURL: fixtures.projectURL, name: "Counts", setID: set, threads: 2, trim: trim,
            argv: ["lungfish-cli", "rnaseq", "quant"])
        return try await route(host: host).run(request, linuxRoute: Self.linuxRoute)
    }

    func record(_ result: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceEnvelopeReader.loadCanonical(from: result), "the result has a record")
    }

    func text(_ step: ProvenanceStep, _ key: String) -> String? {
        if case .string(let value)? = step.resolvedOptions[key] { return value }
        return nil
    }

    func logLines(_ name: String = "log") -> [String] {
        let text = (try? String(contentsOf: capture.appendingPathComponent(name), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    func salmonLine(_ envelope: ProvenanceEnvelope, sample: String, _ key: String) -> String? {
        envelope.steps.first { $0.toolName == "salmon" && text($0, "sample") == sample }.flatMap { text($0, key) }
    }

    // MARK: - Row 1, the import's poly-G state

    func testEachImportCaseGivesItsLineAndNoneReadsTheLGEDefault() async throws {
        let set = try await makeSetAndIndex()
        let none = try pairBundle("NoTrimmer")
        let galore = try pairBundle("Galore", importSteps: [RecipeStepResult(
            stepName: "Optimize storage + Compress", tool: "trim_galore", toolVersion: "2.3.0",
            commandLine: "trim_galore --clumpify --compression 6 --cores 4 --memory 1G --output_dir /w --paired a b",
            durationSeconds: 1)],
            report: #"{"trim_galore_version": "2.3.0", "read_number": 1, "parameters": {"poly_g": true}, "#
                + #""read_processing": {"total_reads": 2, "reads_written": 2}}"#)
        let fastp = try pairBundle("Fastp", importSteps: [RecipeStepResult(
            stepName: "Adapter + quality trim", tool: "fastp", toolVersion: "1.0.1",
            commandArguments: ["fastp", "--in1", "a", "--out1", "b", "-q", "20"], durationSeconds: 1)])
        let envelope = try record(try await quant([none, galore, fastp], set: set).resultURL)
        let key = "importPolyG"
        XCTAssertEqual(salmonLine(envelope, sample: "NoTrimmer", key),
                       "Poly-G trimming at import: not enabled (no trimmer ran at import)")
        XCTAssertEqual(salmonLine(envelope, sample: "Galore", key),
                       "Poly-G trimming at import: left to Trim Galore 2.3.0 auto-detection (not set by LGE), enabled (auto-detected)")
        XCTAssertEqual(salmonLine(envelope, sample: "Fastp", key),
                       "Poly-G trimming at import: left to fastp 1.0.1 auto-detection (not set by LGE), outcome not recorded")
        let lines = envelope.steps.compactMap { text($0, key) }
        XCTAssertEqual(lines.count, 3)
        XCTAssertFalse(lines.contains { $0.contains("off (LGE default)") }, "\(lines)")
    }

    // MARK: - Row 2, the route's own trim call

    func testTheTrimCallPassesThePolyGFlagAndTheRecordLineFollowsIt() async throws {
        let set = try await makeSetAndIndex()
        let bundle = try pairBundle("A")
        let off = try record(try await quant([bundle], set: set, trim: .trimGalore(polyG: false)).resultURL)
        let offTrim = try XCTUnwrap(off.steps.first { $0.toolName == "trim_galore" }, "the trim call has a step")
        XCTAssertTrue(offTrim.argv.contains("--no_poly_g"), "\(offTrim.argv)")
        XCTAssertFalse(offTrim.argv.contains("--poly_g"), "\(offTrim.argv)")
        XCTAssertEqual(salmonLine(off, sample: "A", "trimming"), "Poly-G trimming: off (LGE default)")

        let on = try record(try await quant([bundle], set: set, trim: .trimGalore(polyG: true)).resultURL)
        let onTrim = try XCTUnwrap(on.steps.first { $0.toolName == "trim_galore" }, "the trim call has a step")
        XCTAssertTrue(onTrim.argv.contains("--poly_g"), "\(onTrim.argv)")
        XCTAssertFalse(onTrim.argv.contains("--no_poly_g"), "\(onTrim.argv)")
        XCTAssertEqual(salmonLine(on, sample: "A", "trimming"), "Poly-G trimming: on (chosen), Trim Galore 2.3.0 --poly_g")

        let untrimmed = try record(try await quant([bundle], set: set).resultURL)
        XCTAssertNil(untrimmed.steps.first { $0.toolName == "trim_galore" })
        XCTAssertEqual(salmonLine(untrimmed, sample: "A", "trimming"), "Reads not trimmed")
        XCTAssertEqual(logLines("trimlog").count, 2, "Trim Galore ran only when asked")
    }
}

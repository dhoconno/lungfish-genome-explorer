// AssembleCommandReadSetTests.swift - lungfish-cli assemble hands each assembler the pairs and the single reads of one sample in their roles
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow
import LungfishTestSupport

/// Owner decision 1 of 2026-10-03 (docs/contracts/READ-PAIRING.md): paired
/// reads that were not merged are used as pairs. A sample that holds pairs
/// and merged or single reads is assembled in one run with each file in its
/// role. The tests run a stand-in assembler that keeps a copy of every file
/// it is handed under the role of the flag it came with, so they count the
/// reads that reached each role.
final class AssembleCommandReadSetTests: XCTestCase {

    private var root: URL!
    private var fixtures: ReadSetFixtures!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "assemble-command-read-sets")
        fixtures = try ReadSetFixtures(in: root.appendingPathComponent("Fixtures", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Reads per role

    /// 77 merged reads then 23 pairs in one root file, the shape the Kraken2
    /// and mapping lanes use. Before the change SPAdes was handed one `-s`
    /// file of 123 reads, 46 of them mates assembled as unrelated reads.
    func testAMixedRootGivesEachAssemblerItsPairsAndItsMergedReads() async throws {
        let bundle = try mixedRootBundle(mergedCount: 77, pairCount: 23)
        let pairs = (1...23).map { "p\($0)" }
        let merged = (1...77).map { "m\($0)" }

        let spades = try await assemble(bundle, tool: .spades)
        XCTAssertEqual(spades.forward, pairs.map { "\($0)/1" })
        XCTAssertEqual(spades.reverse, pairs.map { "\($0)/2" })
        XCTAssertEqual(spades.merged, [merged])
        XCTAssertEqual(spades.single, [])

        // MEGAHIT and SKESA have no merged role, so merged reads are single reads beside the pairs.
        for tool in [AssemblyTool.megahit, .skesa] {
            let run = try await assemble(bundle, tool: tool)
            XCTAssertEqual(run.forward, pairs.map { "\($0)/1" }, tool.rawValue)
            XCTAssertEqual(run.reverse, pairs.map { "\($0)/2" }, tool.rawValue)
            XCTAssertEqual(run.merged, [], tool.rawValue)
            XCTAssertEqual(run.single, [merged], tool.rawValue)
        }
    }

    /// L5c. Before the change the merge derivative's three files were joined
    /// into one single-read file of 5 reads.
    func testAMergeDerivativeIsAssembledAsItsPairsPlusItsMergedReads() async throws {
        let spades = try await assemble(fixtures.mergeDerivative, tool: .spades)
        XCTAssertEqual(spades.forward, ["u1/1"])
        XCTAssertEqual(spades.reverse, ["u1/2"])
        XCTAssertEqual(spades.merged, [["x1", "x2", "x3"]])
        XCTAssertEqual(spades.single, [])
    }

    /// L5d. The repair derivative's orphan is a single read, never a merged one.
    func testARepairDerivativeIsAssembledAsItsPairsPlusItsOrphans() async throws {
        let spades = try await assemble(fixtures.repairDerivative, tool: .spades)
        XCTAssertEqual(spades.forward, ["r1/1", "r2/1"])
        XCTAssertEqual(spades.reverse, ["r1/2", "r2/2"])
        XCTAssertEqual(spades.merged, [])
        XCTAssertEqual(spades.single, [["o1"]])

        let megahit = try await assemble(fixtures.repairDerivative, tool: .megahit)
        XCTAssertEqual(megahit.single, [["o1"]])
        let skesa = try await assemble(fixtures.repairDerivative, tool: .skesa)
        XCTAssertEqual(skesa.single, [["o1"]])
    }

    // MARK: - Unchanged

    func testASampleOfOnlySingleReadsOrOnlyPairsIsHandedOverAsItAlwaysWas() async throws {
        let single = try await assemble(fixtures.singleRoot, tool: .spades)
        XCTAssertEqual(single.single, [["s1", "s2", "s3"]])
        XCTAssertEqual(single.forward, [])

        let chunked = try await assemble(fixtures.chunkedRoot, tool: .spades)
        XCTAssertEqual(chunked.single, [["c1", "c2", "c3"]], "the chunks of one root are still joined into one file")

        let paired = try await assemble(fixtures.pairedDerivative, tool: .spades)
        XCTAssertEqual(paired.forward, ["p1/1", "p2/1"])
        XCTAssertEqual(paired.reverse, ["p1/2", "p2/2"])
        XCTAssertEqual(paired.single, [])
    }

    // MARK: - Helpers

    /// What the stand-in assembler was handed, by role.
    private struct Seen {
        var forward: [String] = []
        var reverse: [String] = []
        /// The reads of each `--merged` file, in command order.
        var merged: [[String]] = []
        /// The reads of each single-read file, in command order.
        var single: [[String]] = []
    }

    /// Assembles `bundle` the way `lungfish-cli assemble` does, with a
    /// stand-in assembler: the shared input resolution, the request it
    /// builds, and `ManagedAssemblyPipeline`.
    private func assemble(_ bundle: URL, tool: AssemblyTool) async throws -> Seen {
        let runRoot = root.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
        let standIn = try StandInAssemblers(root: runRoot)
        let outputDirectory = runRoot.appendingPathComponent("assembly", isDirectory: true)
        let request = try await assemblyRequest(for: bundle, tool: tool, outputDirectory: outputDirectory)
        _ = try await ManagedAssemblyPipeline(condaManager: standIn.condaManager).run(request: request.normalizedForExecution())
        return try standIn.seen(for: tool)
    }

    /// The request `lungfish-cli assemble <bundle> --assembler <tool>` runs.
    private func assemblyRequest(for bundle: URL, tool: AssemblyTool, outputDirectory: URL) async throws -> AssemblyRunRequest {
        let resolved = try await ResolvedSequenceInputs.resolveForAssembly(
            inputURLs: [bundle],
            materializationDirectory: outputDirectory.appendingPathComponent(".lungfish-assembly-inputs", isDirectory: true),
            materializer: fixtures.materializer
        )
        let pairedEnd = resolved.resolvedAsMatePair
        let layout = AssemblyRunRequest.resolveInputLayout(
            tool: tool,
            readType: .illuminaShortReads,
            pairedEnd: pairedEnd,
            explicit: nil,
            originalInputURLs: resolved.originalInputURLs,
            executionInputURLs: resolved.executionInputURLs,
            pooled: resolved.pooledLayoutResolution
        )
        return AssemblyRunRequest(
            tool: tool,
            readType: .illuminaShortReads,
            inputURLs: resolved.executionInputURLs,
            projectName: "fixture",
            outputDirectory: outputDirectory,
            pairedEnd: pairedEnd,
            threads: 2,
            inputLayout: layout?.layout
        )
    }

    /// A root bundle whose one file holds `mergedCount` merged reads and then
    /// `pairCount` adjacent pairs, with the sidecar classification a merge
    /// recipe writes (every role names the file).
    private func mixedRootBundle(mergedCount: Int, pairCount: Int) throws -> URL {
        let bundle = fixtures.importsURL.appendingPathComponent("mixed-\(mergedCount)-\(pairCount).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let file = bundle.appendingPathComponent("reads.fastq")
        let names = (1...mergedCount).map { "m\($0)" } + (1...pairCount).flatMap { ["p\($0)/1", "p\($0)/2"] }
        try ReadSetFixtures.fastq(names).write(to: file, atomically: true, encoding: .utf8)
        let classification = ReadClassification(files: [
            .init(filename: "reads.fastq", role: .merged, readCount: mergedCount),
            .init(filename: "reads.fastq", role: .pairedR1, readCount: pairCount),
            .init(filename: "reads.fastq", role: .pairedR2, readCount: pairCount),
        ])
        FASTQMetadataStore.save(
            PersistedFASTQMetadata(
                ingestion: IngestionMetadata(pairingMode: .interleaved, pairingSource: .detected),
                readClassification: classification
            ),
            for: file
        )
        return bundle
    }

    /// A conda root whose stand-in micromamba runs a stand-in SPAdes, MEGAHIT
    /// or SKESA. Each keeps a copy of every read file it is handed under the
    /// flag it came with and writes one contig.
    private struct StandInAssemblers {
        let condaManager: CondaManager
        private let seenDirectory: URL

        init(root: URL) throws {
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            seenDirectory = root.appendingPathComponent("saw", isDirectory: true)
            let micromamba = root.appendingPathComponent("stand-in-micromamba")
            try Self.script(seenDirectory: seenDirectory).write(to: micromamba, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: micromamba.path)
            condaManager = CondaManager(
                rootPrefix: root.appendingPathComponent("conda", isDirectory: true),
                bundledMicromambaProvider: { micromamba },
                bundledMicromambaVersionProvider: { "2.0.0" }
            )
        }

        func seen(for tool: AssemblyTool) throws -> Seen {
            let directory = seenDirectory.appendingPathComponent(tool.rawValue == "spades" ? "spades.py" : tool.rawValue)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            func reads(_ name: String) throws -> [String] {
                try ReadSetFixtures.readNames(in: directory.appendingPathComponent(name))
            }
            func numbered(_ prefix: String) throws -> [[String]] {
                try names
                    .filter { $0.hasPrefix("\(prefix)-") }
                    .sorted { (Int($0.dropFirst(prefix.count + 1)) ?? 0) < (Int($1.dropFirst(prefix.count + 1)) ?? 0) }
                    .map(reads)
            }
            return Seen(
                forward: names.contains("forward") ? try reads("forward") : [],
                reverse: names.contains("reverse") ? try reads("reverse") : [],
                merged: try numbered("merged"),
                single: try numbered("single")
            )
        }

        private static func script(seenDirectory: URL) -> String {
            """
            #!/bin/sh
            if [ "$1" = "--version" ]; then
              echo "2.0.0"
              exit 0
            fi
            if [ "$1" != "run" ] || [ "$2" != "-n" ]; then
              echo "unexpected micromamba invocation: $*" >&2
              exit 64
            fi
            tool="$4"
            shift 4
            if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-v" ]; then
              echo "$tool 1.0.0"
              exit 0
            fi
            seen='\(seenDirectory.path)'/"$tool"
            mkdir -p "$seen"
            outdir=""
            contigs=""
            single=0
            merged=0
            while [ "$#" -gt 0 ]; do
              case "$1" in
                -o)
                  shift
                  outdir="$1"
                  ;;
                --contigs_out)
                  shift
                  contigs="$1"
                  ;;
                -s)
                  shift
                  single=$((single + 1))
                  cp "$1" "$seen/single-$single"
                  ;;
                --merged)
                  shift
                  merged=$((merged + 1))
                  cp "$1" "$seen/merged-$merged"
                  ;;
                -1)
                  shift
                  cp "$1" "$seen/forward"
                  ;;
                -2)
                  shift
                  cp "$1" "$seen/reverse"
                  ;;
                -r)
                  shift
                  old_ifs="$IFS"
                  IFS=,
                  for file in $1; do
                    single=$((single + 1))
                    cp "$file" "$seen/single-$single"
                  done
                  IFS="$old_ifs"
                  ;;
                --reads)
                  shift
                  case "$1" in
                    *,*)
                      cp "${1%%,*}" "$seen/forward"
                      cp "${1#*,}" "$seen/reverse"
                      ;;
                    *)
                      single=$((single + 1))
                      cp "$1" "$seen/single-$single"
                      ;;
                  esac
                  ;;
              esac
              shift
            done
            if [ "$tool" = "skesa" ]; then
              mkdir -p "$(dirname "$contigs")"
              printf '>contig1\\nACGTACGTACGTACGTACGT\\n' > "$contigs"
              exit 0
            fi
            if [ -z "$outdir" ]; then
              echo "missing -o argument" >&2
              exit 66
            fi
            mkdir -p "$outdir"
            if [ "$tool" = "megahit" ]; then
              printf '>contig1\\nACGTACGTACGTACGTACGT\\n' > "$outdir/final.contigs.fa"
            else
              printf '>contig1\\nACGTACGTACGTACGTACGT\\n' > "$outdir/contigs.fasta"
            fi
            exit 0
            """
        }
    }
}

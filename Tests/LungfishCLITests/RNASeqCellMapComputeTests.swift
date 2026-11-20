// RNASeqCellMapComputeTests.swift - `rnaseq cell-map compute` with a stand-in route (Phase 5.5 lane CM-COMPUTE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The halves that need no real tool: the argv and the environment of 5.5 C2 (rulings C2-PYFLAGS and HASH-SEED-FLAG),
// the record check (HASH-SEED-FLAG item 2, review CM-REPRO-SC SF-3), the memory prediction of 5.5 C6 on stubbed 16, 32
// and 64 GiB Macs (ruling ADJ-SC-EMBED items 4 to 6), and a run on the plain STARsolo layout with bare barcodes, a
// cancel, a failed script and a probe record, each through a stand-in launch that writes what `embed.py` writes.

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

/// What a stand-in launch saw.
final class ComputeLaunchSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(arguments: [String], environment: [String: String])] = []
    func add(_ arguments: [String], _ environment: [String: String]) { lock.withLock { calls.append((arguments, environment)) } }
    var all: [(arguments: [String], environment: [String: String])] { lock.withLock { calls } }
}

enum ComputeStandIn {
    static let pinFolder = RNASeqFixtures.root.appendingPathComponent("sc-embed-pin", isDirectory: true)
    static var pinRecord: Data { get throws { try Data(contentsOf: pinFolder.appendingPathComponent("record.json")) } }

    /// A launch that writes the three files `embed.py` writes for each barcode of each input, as plain text, with
    /// coordinates and clusters that depend only on the row. `record` is the record it writes.
    static func launch(record: Data, exitCode: Int32 = 0, stderr: String = "", seen: ComputeLaunchSeen) -> RNASeqCellMapCompute.Launch {
        { arguments, environment, _ in
            seen.add(arguments, environment)
            guard exitCode == 0 else { return ("", stderr, exitCode) }
            func values(_ flag: String) -> [String] { arguments.indices.filter { arguments[$0] == flag }.map { arguments[$0 + 1] } }
            let out = URL(fileURLWithPath: try XCTUnwrap(values("--out").first))
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let samples = arguments.filter { $0.hasPrefix("--sample=") }.map { String($0.dropFirst("--sample=".count)) }
            var table = "sample\tbarcode\tx\ty\tcluster\n"
            var row = 0
            for (sample, path) in zip(samples, values("--barcodes")) {
                for barcode in try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isNewline) {
                    table += "\(sample)\t\(barcode)\t\(Float(row) * 0.5 + 1)\t\(Float(row % 17) + 2.25)\t\(row % 3)\n"
                    row += 1
                }
            }
            try Data(table.utf8).write(to: out.appendingPathComponent("cells.tsv"))
            try record.write(to: out.appendingPathComponent("record.json"))
            try Data("channel\tname\tversion\tbuild\nconda-forge\tscanpy\t1.11.5\tpyhd8ed1ab_0\n".utf8).write(to: out.appendingPathComponent("packages.tsv"))
            return ("embed.py: wrote \(out.path)\n", "", 0)
        }
    }

    /// The pin's record with one field set, by a dotted path.
    static func record(setting path: String, to value: Any) throws -> Data {
        var record = try XCTUnwrap(try JSONSerialization.jsonObject(with: try pinRecord) as? [String: Any])
        func set(_ object: [String: Any], _ keys: ArraySlice<Substring>) -> [String: Any] {
            var object = object
            let key = String(keys.first!)
            if keys.count == 1 { object[key] = value } else { object[key] = set(object[key] as? [String: Any] ?? [:], keys.dropFirst()) }
            return object
        }
        record = set(record, path.split(separator: ".")[...])
        return try JSONSerialization.data(withJSONObject: record)
    }
}

final class RNASeqCellMapComputeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-cell-map-compute") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    private var temporaryRoot: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    private func output(_ name: String) -> URL { root.appendingPathComponent("Analyses/\(name).lungfishrnaseq", isDirectory: true) }
    private let gib: UInt64 = 1 << 30

    private func compute(_ parent: URL, output: URL, launch: @escaping RNASeqCellMapCompute.Launch, physicalMemory: UInt64 = 64 << 30,
                         seed: Int = 0) async throws -> RNASeqResultWriter.CellMapSummary {
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let writer = RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
        return try await RNASeqCellMapCompute.compute(
            .init(parent: parent, threads: 1, seed: seed), output: output, physicalMemory: physicalMemory, launch: launch, writer: writer,
            temporaryRoot: temporaryRoot
        ) { run, summary in
            var envelope = ProvenanceEnvelope(workflowName: "RNA-seq cell map compute", toolName: "lungfish-cli", toolVersion: "test")
            envelope.options = ProvenanceOptions(explicit: [:], defaults: [:], resolvedDefaults: RNASeqCellMapCompute.facts(run, summary: summary))
            return envelope
        }.summary
    }

    private func leftovers() throws -> [String] {
        let analyses = root.appendingPathComponent("Analyses")
        let staged = (try? FileManager.default.contentsOfDirectory(atPath: analyses.path))?.filter { $0.hasPrefix(".") } ?? []
        return staged + ((try? FileManager.default.contentsOfDirectory(atPath: temporaryRoot.path)) ?? [])
    }

    // MARK: - The bundled script and lock (5.5 C3)

    func testTheBundledScriptAndLockAreTheRouteFolderFilesByteForByte() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try RNASeqCellMapCompute.bundledScript()
        XCTAssertEqual(try Data(contentsOf: script), try Data(contentsOf: repository.appendingPathComponent("scripts/repro/rnaseq/sc-embed/route/embed.py")))
        XCTAssertEqual(try RNASeqResultBundle.sha256Hex(fileAt: script), RNASeqCellMapCompute.scriptSHA256)
        let lock = try RNASeqCellMapCompute.bundledLock()
        XCTAssertEqual(try Data(contentsOf: lock), try Data(contentsOf: repository.appendingPathComponent("scripts/repro/rnaseq/env/explicit-sc-embed-osx-arm64.txt")))
        XCTAssertEqual(try RNASeqResultBundle.sha256Hex(fileAt: lock), "f127cc050d5b1ff7e381ca8a56b703ced7e949c07a8f2badb59edd1029da97ea")
    }

    // MARK: - Argv and environment (HASH-SEED-FLAG items 1 and 5, C2-PYFLAGS item 2, review CM-REPRO-SC SF-3)

    func testTheArgvNeverEmitsAProbeFlagAndTheEnvironmentAlwaysHoldsSeedZero() {
        let input = RNASeqCellMapCompute.Input(
            sample: "--allow-hash-seed", matrix: URL(fileURLWithPath: "/r/source/m.mtx.gz"), features: URL(fileURLWithPath: "/r/source/f.tsv.gz"),
            barcodes: URL(fileURLWithPath: "/r/source/b.tsv.gz"), isGzip: true, cells: 10, entries: 100, matrixSHA256: "")
        for threads in [1, 4] {
            let argv = RNASeqCellMapCompute.arguments(script: URL(fileURLWithPath: "/b/embed.py"), inputs: [input], output: URL(fileURLWithPath: "/t/out"),
                                                      lock: URL(fileURLWithPath: "/t/explicit-sc-embed-osx-arm64.txt"), threads: threads, seed: 0)
            XCTAssertEqual(Array(argv.prefix(4)), ["-s", "-B", "-P", "/b/embed.py"])
            XCTAssertFalse(argv.contains { $0.hasPrefix("--allow-hash") }, "the argv holds a hash-seed probe token")
            XCTAssertFalse(argv.contains("scanpy-default"))
            XCTAssertFalse(argv.contains("-I") || argv.contains("-E"))
            XCTAssertTrue(argv.contains("--sample=--allow-hash-seed"), "a sample is passed as one --sample=<name> token")
            let knn = try? XCTUnwrap(argv.firstIndex(of: "--knn-transformer"))
            XCTAssertEqual(knn.map { argv[$0 + 1] }, "sklearn")
            XCTAssertEqual(argv.firstIndex(of: "--leiden-flavor").map { argv[$0 + 1] }, "leidenalg")
            XCTAssertEqual(argv.firstIndex(of: "--leiden-iterations").map { argv[$0 + 1] }, "-1")
            for flag in ["--pca-seed", "--neighbors-seed", "--leiden-seed", "--umap-seed"] {
                XCTAssertEqual(argv.firstIndex(of: flag).map { argv[$0 + 1] }, "0", flag)
            }
            let environment = RNASeqCellMapCompute.environment(threads: threads, temporary: URL(fileURLWithPath: "/t"))
            XCTAssertEqual(Set(environment.keys), ["PYTHONHASHSEED", "OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
                                                    "VECLIB_MAXIMUM_THREADS", "NUMBA_NUM_THREADS", "NUMBA_CACHE_DIR", "MPLCONFIGDIR", "XDG_CACHE_HOME"])
            XCTAssertEqual(environment["PYTHONHASHSEED"], "0")
            XCTAssertEqual(environment["OPENBLAS_NUM_THREADS"], String(threads))
            XCTAssertEqual(environment["MPLCONFIGDIR"], "/t/matplotlib")
            XCTAssertFalse(environment.keys.contains { $0.hasPrefix("SKLEARN_") })
        }
    }

    // MARK: - The record check (HASH-SEED-FLAG item 2, review CM-REPRO-SC SF-3)

    func testTheRecordCheckPassesThePinAndRefusesEveryProbeNamingTheField() throws {
        XCTAssertNoThrow(try RNASeqCellMapCompute.checkRecord(try ComputeStandIn.pinRecord))
        let cases: [(String, Any, String)] = [
            ("guard", "passed with --allow-hash-seed 1 (report-only hash-order probe, not the route)",
             "The route's record says guard is \"passed with --allow-hash-seed 1 (report-only hash-order probe, not the route)\", where a route run says \"passed\". No cell map was written."),
            ("interpreter.sys_flags.hash_randomization", 1,
             "The route's record says interpreter.sys_flags.hash_randomization is 1, where a route run says 0. No cell map was written."),
            ("environment.values.PYTHONHASHSEED", "1",
             "The route's record says environment.values.PYTHONHASHSEED is \"1\", where a route run says \"0\". No cell map was written."),
            ("knn", "kNN: scanpy default for 1222 cells",
             "The route's record says knn is \"kNN: scanpy default for 1222 cells\", where a route run says \"kNN: exact, brute, transformer=sklearn\". No cell map was written."),
            ("parameters.knn_transformer", "scanpy-default",
             "The route's record says parameters.knn_transformer is \"scanpy-default\", where a route run says \"sklearn\". No cell map was written."),
            ("seeds.umap", 1, "The route's record says seeds.umap is 1, where a route run says 0. No cell map was written."),
        ]
        for (field, value, words) in cases {
            XCTAssertThrowsError(try RNASeqCellMapCompute.checkRecord(try ComputeStandIn.record(setting: field, to: value)), field) { error in
                XCTAssertEqual(error.localizedDescription, words)
            }
        }
        XCTAssertThrowsError(try RNASeqCellMapCompute.checkRecord(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? RNASeqCellMapComputeRefusal, .record(field: "guard", found: "missing", expected: "\"passed\""))
        }
    }

    // MARK: - Memory (ADJ-SC-EMBED items 4 to 6, 5.5 C6)

    func testTheMemoryPredictionRefusesG3OnA16GBMacAndRunsTheDrawAndG2() throws {
        typealias Prediction = RNASeqCellMapCompute.MemoryPrediction
        let g3 = Prediction(cells: 152_425, entries: 164_171_876, physicalMemory: 16 * gib)
        XCTAssertEqual(g3.bound, 6_871_947_673)
        XCTAssertEqual(g3.peak, 8_667_356_260)
        XCTAssertFalse(g3.fits)
        XCTAssertThrowsError(try RNASeqCellMapCompute.checkMemory(g3)) { error in
            XCTAssertEqual(error.localizedDescription,
                           "Not started: this cell map is predicted to need about 8.1 GB of memory at its peak (152,425 cells, 164,171,876 stored entries), "
                           + "more than 40% of this Mac's 16.0 GB (6.4 GB). This Mac can compute about 118,076 cells of this depth. Choose fewer cells, "
                           + "use a Mac with more memory, or compute the embedding elsewhere and bring it in with Import Embedding.")
        }
        let draw = Prediction(cells: 100_000, entries: 164_171_876, physicalMemory: 16 * gib)
        XCTAssertEqual(draw.peak, 6_491_718_760)
        XCTAssertNoThrow(try RNASeqCellMapCompute.checkMemory(draw))
        let g2 = Prediction(cells: 1_222, entries: 2_498_225, physicalMemory: 16 * gib)
        XCTAssertEqual(g2.peak, 775_695_250)
        XCTAssertTrue(g2.fits)
        XCTAssertTrue(Prediction(cells: 152_425, entries: 164_171_876, physicalMemory: 32 * gib).fits)
        XCTAssertTrue(Prediction(cells: 152_425, entries: 164_171_876, physicalMemory: 64 * gib).fits)
        // The ruling's table of the most cells a Mac may compute, at G3's and G1's depth.
        for (depth, expected) in [(1_077, [118_078, 249_548, 512_488]), (2_779, [89_074, 188_250, 386_603])] {
            let cells = [16, 32, 64].map { Prediction(cells: 1_000, entries: 1_000 * depth, physicalMemory: UInt64($0) * gib).cellsAtThisDepth }
            XCTAssertEqual(cells, expected, "depth \(depth)")
        }
        let facts = g3.facts
        XCTAssertEqual(facts["predictedPeakBytes"], .integer(8_667_356_260))
        XCTAssertEqual(facts["physicalMemoryBytes"], .integer(17_179_869_184))
        XCTAssertEqual(facts["shareOfPhysicalMemory"], .number(0.40))
        XCTAssertEqual(facts["bytesPerCell"], .integer(41_500))
    }

    // MARK: - The table

    func testTheRouteTableBecomesLGEsTableWithTheValueBytesUnchanged() throws {
        let route = Data("sample\tbarcode\tx\ty\tcluster\np\tAAAC-1\t-6.6139255\t13.468839\t1\n".utf8)
        XCTAssertEqual(String(decoding: try RNASeqCellMapCompute.lgeTable(fromRouteCells: route), as: UTF8.self),
                       "sample\tbarcode\tumap_1\tumap_2\tleiden\np\tAAAC-1\t-6.6139255\t13.468839\t1\n")
        XCTAssertThrowsError(try RNASeqCellMapCompute.lgeTable(fromRouteCells: Data("barcode\tx\n".utf8))) { error in
            XCTAssertEqual(error as? RNASeqCellMapComputeRefusal, .tableForm)
        }
    }

    // MARK: - Runs through a stand-in launch

    /// The committed STARsolo cut is plain files with bare barcodes. The route reads them as the manifest names them,
    /// `--gzip false`, and the cell map keeps each barcode as given (ruling ARCH-X4-INPUT item 5). X4 does not cover it.
    func testAComputeRunOnThePlainSTARsoloLayoutKeepsTheBareBarcodes() async throws {
        let parent = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: root)
        let seen = ComputeLaunchSeen()
        let map = output("computed")
        let summary = try await compute(parent, output: map, launch: ComputeStandIn.launch(record: try ComputeStandIn.pinRecord, seen: seen))

        let call = try XCTUnwrap(seen.all.first)
        XCTAssertEqual(seen.all.count, 1)
        XCTAssertEqual(call.arguments.firstIndex(of: "--gzip").map { call.arguments[$0 + 1] }, "false")
        let barcodes = try XCTUnwrap(call.arguments.firstIndex(of: "--barcodes").map { call.arguments[$0 + 1] })
        XCTAssertTrue(barcodes.hasPrefix(parent.path + "/source/"), barcodes)
        XCTAssertTrue(call.arguments.contains("--sample=\(CellMapImportFixture.starsolo)"))
        XCTAssertEqual(call.environment["PYTHONHASHSEED"], "0")

        XCTAssertEqual(summary.embeddings.map(\.name), ["umap"])
        XCTAssertEqual(summary.embeddings.first?.drawn, [200])
        XCTAssertEqual(summary.labelSets.map(\.name), ["leiden"])
        XCTAssertEqual(summary.labelSets.first?.labels, ["0", "1", "2"])
        let manifest = try RNASeqResultBundle.loadManifest(from: map)
        XCTAssertEqual(manifest.origin, .init(kind: .computed, tool: "scanpy", toolVersion: "1.11.5"))
        XCTAssertEqual(manifest.sourceFiles.map(\.path), ["source/compute/embedding.tsv"])
        XCTAssertEqual(manifest.sourceFiles.first?.tool, "scanpy")
        let table = try String(contentsOf: map.appendingPathComponent("source/compute/embedding.tsv"), encoding: .utf8)
        XCTAssertTrue(table.hasPrefix("sample\tbarcode\tumap_1\tumap_2\tleiden\n"))
        let labels = try String(contentsOf: map.appendingPathComponent("labels/leiden.tsv"), encoding: .utf8)
        XCTAssertFalse(labels.contains("-1\t"), "a bare barcode gained a suffix")
        let facts = try CellMapImportFixture.facts(map)
        XCTAssertEqual(facts["seed"], .integer(0))
        XCTAssertEqual(facts["threads"], .integer(1))
        XCTAssertEqual(facts["cells"], .string("Every cell kept"))
        guard case .dictionary(let route)? = facts["routeRecord"] else { return XCTFail("the record holds no route record") }
        XCTAssertEqual(route["knn"], .string("kNN: exact, brute, transformer=sklearn"))
        XCTAssertEqual(try leftovers(), [], "a stage or a temporary folder is left")
    }

    func testACancelledLaunchLeavesNoCellMapNoStageAndNoTemporaryFolder() async throws {
        let parent = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: root)
        let map = output("cancelled")
        let cancelled: RNASeqCellMapCompute.Launch = { _, _, _ in throw CancellationError() }
        do {
            _ = try await compute(parent, output: map, launch: cancelled)
            XCTFail("a cancelled run wrote a cell map")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: map.path))
        XCTAssertEqual(try leftovers(), [])
    }

    func testAFailedScriptAndAProbeRecordEachWriteNoCellMap() async throws {
        let parent = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: root)
        let map = output("failed")
        do {
            _ = try await compute(parent, output: map, launch: ComputeStandIn.launch(
                record: Data(), exitCode: 3, stderr: "step one\nembed.py: guard failed: hash_randomization == 0\n", seen: ComputeLaunchSeen()))
            XCTFail("a failed script wrote a cell map")
        } catch {
            XCTAssertEqual(error.localizedDescription,
                           "The route stopped with exit code 3 and wrote no cell map. Its last line was: embed.py: guard failed: hash_randomization == 0")
        }
        do {
            let probe = try ComputeStandIn.record(setting: "knn", to: "kNN: scanpy default for 200 cells")
            _ = try await compute(parent, output: map, launch: ComputeStandIn.launch(record: probe, seen: ComputeLaunchSeen()))
            XCTFail("a probe record wrote a cell map")
        } catch {
            XCTAssertEqual(error as? RNASeqCellMapComputeRefusal,
                           .record(field: "knn", found: "\"kNN: scanpy default for 200 cells\"", expected: "\"kNN: exact, brute, transformer=sklearn\""))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: map.path))
        XCTAssertEqual(try leftovers(), [])
    }

    func testARefusalBeforeTheLaunchStartsNothing() async throws {
        let parent = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: root)
        let seen = ComputeLaunchSeen()
        let launch = ComputeStandIn.launch(record: try ComputeStandIn.pinRecord, seen: seen)
        // 1 GiB: the bound is 429,496,729 B, under the base of 700,000,000 B, so even 200 cells are refused.
        for (memory, seed, expected) in [(gib, 0, "Not started"), (64 * gib, 1, "The seed 1 is not offered.")] {
            do {
                _ = try await compute(parent, output: output("refused"), launch: launch, physicalMemory: memory, seed: seed)
                XCTFail("refused run wrote a cell map")
            } catch {
                XCTAssertTrue(error.localizedDescription.hasPrefix(expected), error.localizedDescription)
            }
        }
        XCTAssertEqual(seen.all.count, 0, "a refused run launched the route")
        XCTAssertEqual(try leftovers(), [])
    }
}

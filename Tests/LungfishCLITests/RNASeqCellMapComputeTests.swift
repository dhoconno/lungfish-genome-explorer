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

/// A seeded synthetic single-cell result in the plain STARsolo layout: a copy of the committed cut whose
/// `Solo.out/Gene/filtered/` holds `cells` cells in six groups over 3,000 features instead. Each cell holds 60 of 300 shared
/// features and 90 of its group's 450, so every feature passes the route's `--min-cells 3` and the groups separate.
enum ComputeSynthetic {
    static let featureCount = 3_000

    static func folder(cells: Int, seed: UInt64, in root: URL) throws -> URL {
        let folder = root.appendingPathComponent("synthetic-\(cells)", isDirectory: true)
        try FileManager.default.copyItem(at: RNASeqFixtures.root.appendingPathComponent(CellMapImportFixture.starsolo, isDirectory: true), to: folder)
        let filtered = folder.appendingPathComponent("Solo.out/Gene/filtered", isDirectory: true)
        var state = seed
        func next() -> UInt64 {  // SplitMix64
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        var entries: [String] = []
        entries.reserveCapacity(cells * 150)
        for cell in 0..<cells {
            var genes = Set<Int>()
            while genes.count < 60 { genes.insert(Int(next() % 300)) }
            while genes.count < 150 { genes.insert(300 + (cell % 6) * 450 + Int(next() % 450)) }
            for gene in genes.sorted() { entries.append("\(gene + 1) \(cell + 1) \(1 + next() % (gene < 300 ? 4 : 8))") }
        }
        let letters = Array("ACGT")
        let barcodes = (0..<cells).map { i in String((0..<16).map { letters[(i >> (2 * (15 - $0))) & 3] }) }
        let features = (1...featureCount).map { String(format: "SYN%05d\tSYN%05d\tGene Expression", $0, $0) }
        try Data((features.joined(separator: "\n") + "\n").utf8).write(to: filtered.appendingPathComponent("features.tsv"))
        try Data((barcodes.joined(separator: "\n") + "\n").utf8).write(to: filtered.appendingPathComponent("barcodes.tsv"))
        let header = "%%MatrixMarket matrix coordinate integer general\n%\n\(featureCount) \(cells) \(entries.count)\n"
        try Data((header + entries.joined(separator: "\n") + "\n").utf8).write(to: filtered.appendingPathComponent("matrix.mtx"))
        return folder
    }

    /// The folder read and written as a single-cell result by the one writer, as `CellMapImportFixture.result` does.
    static func result(cells: Int, seed: UInt64, in root: URL) throws -> URL {
        let read = try SingleCellFolderReader.read(folder: try folder(cells: cells, seed: seed, in: root))
        let analyses = root.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let samples = [RNASeqSampleRecord(id: read.sample, animal: "A1", species: "Homo sapiens", runs: [read.sample])]
        let request = try SingleCellFolderReader.request([read], name: "synthetic", samples: samples, genomes: [])
        let url = analyses.appendingPathComponent("synthetic.lungfishrnaseq", isDirectory: true)
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test")
        return try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(request, to: url, envelope: envelope)
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
                         seed: Int = 0, step: (String) -> Void = { _ in }) async throws -> RNASeqResultWriter.CellMapSummary {
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let writer = RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
        return try await RNASeqCellMapCompute.compute(
            .init(parent: parent, threads: 1, seed: seed), output: output, physicalMemory: physicalMemory, launch: launch, writer: writer,
            temporaryRoot: temporaryRoot, step: step
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
        // The rulings' table of the most cells a Mac may compute, at G3's and G1's depth (ADJ-SC-EMBED-2 item 3).
        for (depth, expected) in [(1_077, [118_078, 249_548, 512_488]), (2_779, [77_446, 157_214, 316_751])] {
            let cells = [16, 32, 64].map { Prediction(cells: 1_000, entries: 1_000 * depth, physicalMemory: UInt64($0) * gib).cellsAtThisDepth }
            XCTAssertEqual(cells, expected, "depth \(depth)")
        }
        let facts = g3.facts
        XCTAssertEqual(facts["predictedPeakBytes"], .integer(8_667_356_260))
        XCTAssertEqual(facts["physicalMemoryBytes"], .integer(17_179_869_184))
        XCTAssertEqual(facts["shareOfPhysicalMemory"], .number(0.40))
        XCTAssertEqual(facts["bytesPerCell"], .integer(41_500))
        XCTAssertEqual(facts["readBytesPerStoredEntry"], .integer(31))
    }

    /// The route's own peaks at deep inputs sat above the old read line of 21 B a stored entry: 7,624,415,928 B for 50,000 cells
    /// and 264,115,061 entries in one matrix, 7,655,040,744 B for 263,750,195 entries in five, 3,906,736,088 B for 25,000 cells
    /// and 131,662,491 entries. The read line is 31 B a stored entry (ruling ADJ-SC-EMBED-2 items 1 and 4), so the 16 GB Mac
    /// refuses the two deep inputs, runs the half-size one, and the refusal words stay as ADJ-SC-EMBED item 6 gave them.
    func testTheMemoryPredictionCoversTheRoutePeaksAtDeepInputsWithThirtyOneBytesAStoredEntry() throws {
        typealias Prediction = RNASeqCellMapCompute.MemoryPrediction
        let cases: [(cells: Int, entries: Int, peak: UInt64, runs: Bool)] = [
            (50_000, 264_115_061, 8_387_566_891, false),
            (50_000, 263_750_195, 8_376_256_045, false),
            (25_000, 131_662_491, 4_281_537_221, true),
        ]
        for input in cases {
            let sixteen = Prediction(cells: input.cells, entries: input.entries, physicalMemory: 16 * gib)
            XCTAssertEqual(sixteen.bound, 6_871_947_673)
            XCTAssertEqual(sixteen.peak, input.peak, "\(input.cells) cells, \(input.entries) entries")
            XCTAssertEqual(sixteen.fits, input.runs, "\(input.cells) cells, \(input.entries) entries")
            if input.runs {
                XCTAssertNoThrow(try RNASeqCellMapCompute.checkMemory(sixteen))
            } else {
                XCTAssertThrowsError(try RNASeqCellMapCompute.checkMemory(sixteen)) { error in
                    XCTAssertEqual(error as? RNASeqCellMapComputeRefusal, .memory(sixteen))
                }
            }
            XCTAssertEqual(sixteen.facts["readBytesPerStoredEntry"], .integer(31))
        }
        let deep = Prediction(cells: 50_000, entries: 264_115_061, physicalMemory: 16 * gib)
        XCTAssertEqual(deep.cellsAtThisDepth, 40_744)
        XCTAssertThrowsError(try RNASeqCellMapCompute.checkMemory(deep)) { error in
            XCTAssertEqual(error.localizedDescription,
                           "Not started: this cell map is predicted to need about 7.8 GB of memory at its peak (50,000 cells, 264,115,061 stored entries), "
                           + "more than 40% of this Mac's 16.0 GB (6.4 GB). This Mac can compute about 40,744 cells of this depth. Choose fewer cells, "
                           + "use a Mac with more memory, or compute the embedding elsewhere and bring it in with Import Embedding.")
        }
        let roomy = Prediction(cells: 50_000, entries: 264_115_061, physicalMemory: 32 * gib)
        XCTAssertEqual(roomy.bound, 13_743_895_347)
        XCTAssertEqual(roomy.peak, 8_387_566_891)
        XCTAssertTrue(roomy.fits)
        XCTAssertNoThrow(try RNASeqCellMapCompute.checkMemory(roomy))
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
        XCTAssertEqual(manifest.origin, .init(kind: .computed, tool: "scanpy", toolVersion: "1.11.5", settings: ["seed": "0", "threads": "1"]))
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
        XCTAssertEqual(facts["pythonCall"], .string("micromamba run -n sc-embed python -s -B -P embed.py with its inputs as argv"),
                       "the record does not name the launcher (ruling TIERB-ENV item 5)")
        guard case .dictionary(let route)? = facts["routeRecord"] else { return XCTFail("the record holds no route record") }
        XCTAssertEqual(route["knn"], .string("kNN: exact, brute, transformer=sklearn"))
        XCTAssertEqual(try leftovers(), [], "a stage or a temporary folder is left")
    }

    /// Vote S-2: a run of 8,192 cells, the old bar of 5.5 C11, passes with exact neighbours and is never refused. The test
    /// writes a seeded synthetic matrix, and the stand-in covers the Swift path. The route's run is the conformance case.
    func testAn8192CellRunComputesWithExactNeighboursAndIsNeverRefused() async throws {
        let parent = try ComputeSynthetic.result(cells: 8_192, seed: 8_192, in: root)
        let seen = ComputeLaunchSeen()
        var steps: [String] = []
        let summary = try await compute(parent, output: output("synthetic-map"),
                                        launch: ComputeStandIn.launch(record: try ComputeStandIn.pinRecord, seen: seen)) { steps.append($0) }
        let call = try XCTUnwrap(seen.all.first)
        XCTAssertEqual(seen.all.count, 1)
        XCTAssertEqual(call.arguments.firstIndex(of: "--knn-transformer").map { call.arguments[$0 + 1] }, "sklearn")
        XCTAssertFalse(call.arguments.contains { $0.contains("pynndescent") || $0 == "scanpy-default" })
        XCTAssertEqual(steps.first, "Computing a cell map of 8,192 cells with exact nearest neighbours at 1 thread.")
        XCTAssertEqual(summary.embeddings.first?.drawn, [8_192])
        XCTAssertEqual(try leftovers(), [], "a stage or a temporary folder is left")
    }

    /// Ruling TIERB-ENV items 1 and 2. With the 13 launch names removed from both lists, the CLI form's 23 names equal the
    /// pin's 13 as a set, and any other name on one side only fails with the name given.
    func testTierBComparesEnvironmentNamesAsASetWithoutTheLaunchNames() throws {
        let pin = RNASeqCellMapCompute.parameterValue(try XCTUnwrap(try JSONSerialization.jsonObject(with: try ComputeStandIn.pinRecord)))
        let pinNames = RNASeqCellMapTierB.names(pin)
        XCTAssertEqual(pinNames.count, 13)
        let added = ["CONDA_DEFAULT_ENV", "CONDA_PREFIX", "CONDA_PROMPT_MODIFIER", "CONDA_SHLVL", "LC_ALL", "MAMBA_EXE",
                     "MAMBA_ROOT_PREFIX", "PWD", "SHLVL", "XML_CATALOG_FILES", "__CF_USER_TEXT_ENCODING"]
        func run(_ names: [String]) throws -> ParameterValue {
            RNASeqCellMapCompute.parameterValue(try XCTUnwrap(try JSONSerialization.jsonObject(
                with: try ComputeStandIn.record(setting: "environment.names", to: names.sorted()))))
        }
        let cli = pinNames.filter { $0 != "LC_CTYPE" } + added
        XCTAssertEqual(cli.count, 23)
        XCTAssertEqual(RNASeqCellMapTierB.recordDifferences(try run(cli), pin), [])
        XCTAssertEqual(RNASeqCellMapTierB.recordDifferences(try run(cli + ["OPENBLAS_CORETYPE"]), pin),
                       ["environment.names (+OPENBLAS_CORETYPE on the run)"])
        XCTAssertEqual(RNASeqCellMapTierB.recordDifferences(try run(cli.filter { $0 != "HOME" } + ["CONDA_EXE"]), pin),
                       ["environment.names (+CONDA_EXE on the run, -HOME missing from the run)"])
        XCTAssertEqual(RNASeqCellMapTierB.launchNamesLeftOut(try run(cli)).count, 12, "the 11 micromamba adds and TMPDIR")
        XCTAssertEqual(RNASeqCellMapTierB.launchNamesLeftOut(pin), ["LC_CTYPE", "TMPDIR"])
    }

    /// Ruling TIERB-BIO item 2, review CM-COMPUTE BIO B1. A run whose clusters moved changes `counts.clusters` and the keys
    /// under `counts.cluster_sizes`, an object that `flatten` opens into `counts.cluster_sizes.0` and so on. A left-out name
    /// covers the keys below it, so the run still reaches ARI, and a key outside the nine, `counts.genes_kept`, still fails.
    func testTierBLeavesOutTheClusterCountAndSizesOfAMovedRun() throws {
        let pin = RNASeqCellMapCompute.parameterValue(try XCTUnwrap(try JSONSerialization.jsonObject(with: try ComputeStandIn.pinRecord)))
        func run(_ change: (inout [String: Any]) -> Void) throws -> ParameterValue {
            var json = try XCTUnwrap(try JSONSerialization.jsonObject(with: try ComputeStandIn.pinRecord) as? [String: Any])
            var counts = try XCTUnwrap(json["counts"] as? [String: Any])
            change(&counts)
            json["counts"] = counts
            return RNASeqCellMapCompute.parameterValue(
                try XCTUnwrap(try JSONSerialization.jsonObject(with: try JSONSerialization.data(withJSONObject: json))))
        }
        let moved = try run { counts in
            counts["cluster_sizes"] = ["0": 232, "1": 228, "2": 139]
            counts["clusters"] = 14
        }
        XCTAssertEqual(RNASeqCellMapTierB.recordDifferences(moved, pin), [])
        let strict = try run { counts in
            counts["cluster_sizes"] = ["0": 232, "1": 228, "2": 139]
            counts["clusters"] = 14
            counts["genes_kept"] = 15_246
        }
        XCTAssertEqual(RNASeqCellMapTierB.recordDifferences(strict, pin), ["counts.genes_kept"])
    }

    /// The view's Source fact (manager's decision of 2026-11-20 04:50). A computed cell map's manifest holds the seed and
    /// threads under `origin.settings`, the parent's `route` is copied whole with no key added, and the manifest reads back
    /// equal. `settings` is a schema 2 key written only for `computed`, so a manifest that holds it at schema 1 or with
    /// another kind reads as unreadable.
    func testAComputedCellMapNamesItsSeedAndThreadsInTheOriginAndReadsBackEqual() async throws {
        let parent = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: root)
        let map = output("settings")
        let launch = ComputeStandIn.launch(record: try ComputeStandIn.pinRecord, seen: ComputeLaunchSeen())
        _ = try await compute(parent, output: map, launch: launch)

        let data = try Data(contentsOf: map.appendingPathComponent(RNASeqResultManifest.filename))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let origin = try XCTUnwrap(json["origin"] as? [String: Any])
        XCTAssertEqual(origin["settings"] as? [String: String], ["seed": "0", "threads": "1"])
        let manifest = try RNASeqResultBundle.loadManifest(from: map)
        XCTAssertEqual(manifest.route, try RNASeqResultBundle.loadManifest(from: parent).route, "the parent's route gained a key")
        XCTAssertTrue(manifest.keysMatchSchema)
        let again = try JSONDecoder().decode(RNASeqResultManifest.self, from: try JSONEncoder().encode(manifest))
        XCTAssertEqual(again, manifest)
        XCTAssertEqual(again.origin.settings, ["seed": "0", "threads": "1"])

        var imported = manifest
        imported.origin.kind = .imported
        XCTAssertFalse(imported.keysMatchSchema, "settings with the kind imported read as a cell map")
        imported.origin.settings = nil
        XCTAssertTrue(imported.keysMatchSchema)
        var parentManifest = try RNASeqResultBundle.loadManifest(from: parent)
        XCTAssertNil(parentManifest.origin.settings)
        let parentJSON = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try Data(contentsOf: parent.appendingPathComponent(RNASeqResultManifest.filename))) as? [String: Any])
        XCTAssertNil((parentJSON["origin"] as? [String: Any])?["settings"], "a schema 1 origin holds settings")
        parentManifest.origin.settings = ["seed": "0"]
        XCTAssertFalse(parentManifest.keysMatchSchema, "a schema 1 manifest with origin settings read as readable")
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

    /// Review CM-COMPUTE SWIFT SF3. macOS ends a process that runs the Mac out of memory with SIGKILL, and `micromamba run`
    /// reports its killed child as exit 137. `ToolProcessMemoryStop` is the one route that words it, so a route killed after
    /// a passing prediction reads as a memory stop with a next step and writes no cell map. The middle sentence names this
    /// Mac's memory, so the test holds the first sentence and the end, never the whole.
    func testARouteKilledForMemoryIsWordedByToolProcessMemoryStopAndWritesNoCellMap() async throws {
        let parent = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: root)
        let map = output("killed")
        do {
            _ = try await compute(parent, output: map, launch: ComputeStandIn.launch(
                record: Data(), exitCode: 137, stderr: "", seen: ComputeLaunchSeen()))
            XCTFail("a killed route wrote a cell map")
        } catch {
            let words = error.localizedDescription
            XCTAssertTrue(words.hasPrefix("The cell-map route stopped before it finished, most likely because the Mac ran out of memory."), words)
            XCTAssertTrue(words.hasSuffix("bring it in with Import Embedding."), words)
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

    /// TIERB-BIO item 5: each form of the verdict, built from the pin's own table, genes and record.
    func testTierBVerdictTakesEachOfTheRulingsFourForms() throws {
        let pin = ComputeStandIn.pinFolder
        func value(_ data: Data) throws -> ParameterValue {
            RNASeqCellMapCompute.parameterValue(try XCTUnwrap(try JSONSerialization.jsonObject(with: data)))
        }
        let pinRecord = try value(try ComputeStandIn.pinRecord)
        let genes = root.appendingPathComponent("genes", isDirectory: true)
        try FileManager.default.createDirectory(at: genes, withIntermediateDirectories: true)
        for name in ["variable_genes.tsv", "pca_variance_ratio.tsv"] {
            try FileManager.default.copyItem(at: pin.appendingPathComponent(name), to: genes.appendingPathComponent(name))
        }
        let rows = try String(contentsOf: pin.appendingPathComponent("cells.tsv"), encoding: .utf8).split(separator: "\n").dropFirst()
        func table(_ name: String, _ edit: (inout [String]) -> Void) throws -> URL {
            let url = root.appendingPathComponent(name)
            let body = rows.map { row -> String in
                var fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                edit(&fields)
                return fields.joined(separator: "\t")
            }
            try Data((((["sample\tbarcode\tumap_1\tumap_2\tleiden"] + body).joined(separator: "\n")) + "\n").utf8).write(to: url)
            return url
        }
        func verdict(_ run: URL, record: ParameterValue? = nil) throws -> String {
            try RNASeqCellMapTierB.verdict(run: run, pin: pin.appendingPathComponent("cells.tsv"), record: record ?? pinRecord,
                                           pinRecord: pinRecord, runFolder: genes, pinFolder: pin)
        }
        XCTAssertEqual(try verdict(try table("same.tsv") { _ in }), "equal by bytes")
        XCTAssertEqual(try verdict(try table("mirrored.tsv") { $0[2] = String(-(Float($0[2]) ?? 0)) }),
                       "same meaning (labels equal, variable genes equal, neighbours kept 1.0000)")
        let merged = try value(try ComputeStandIn.record(setting: "counts.cluster_sizes", to: ["0": 459, "2": 139]))
        XCTAssertEqual(try verdict(try table("merged.tsv") { if $0[4] == "1" { $0[4] = "0" } }, record: merged),
                       "passes by meaning, moved: clusters 15 against 14, 228 cells (18.7%) in another cluster, "
                       + "0 variable genes in and 0 out; ARI 0.7271, neighbours kept 1.0000")
        var row = 0
        XCTAssertTrue(try verdict(try table("shuffled.tsv") { $0[4] = String((row * 7) % 15); row += 1 }).hasPrefix("fail: ARI "))
        XCTAssertEqual(try verdict(try table("ids.tsv") { $0[1] = "X" + $0[1] }), "fail: cell ids are not the pin's by bytes and in order")
        XCTAssertEqual(try verdict(try table("record.tsv") { _ in }, record: try value(try ComputeStandIn.record(setting: "counts.genes_kept", to: 1))),
                       "fail: record keys counts.genes_kept")
    }
}

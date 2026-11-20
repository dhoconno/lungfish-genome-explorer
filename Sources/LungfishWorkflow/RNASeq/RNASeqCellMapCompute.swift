// RNASeqCellMapCompute.swift - What rnaseq cell-map compute decides before it launches (Phase 5.5 lane CM-COMPUTE)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `lungfish-cli rnaseq cell-map compute` runs the pinned Scanpy route, the bundled `embed.py` (5.5 C1 to C11), on a
// single-cell result's matrices and hands its table to the import's checker and the one writer. This file holds what is
// settled before the launch: the inputs from the parent's matrix entries (ruling ARCH-X4-INPUT item 5), the argv and
// the environment of 5.5 C2 (ruling C2-PYFLAGS), the memory prediction of 5.5 C6 (ruling ADJ-SC-EMBED items 4 to 6) and
// the check of the route's own record (ruling HASH-SEED-FLAG item 2, review CM-REPRO-SC SF-3).

import Foundation
import LungfishCore
import LungfishIO

public enum RNASeqCellMapCompute {
    /// The managed environment of the Single-Cell Analysis pack, built from the explicit lock below.
    public static let environmentName = "sc-embed"
    public static let scriptName = "embed.py"
    /// CM-REPRO's script, byte for byte (5.5 C3). Every record of the pin names this sha256.
    public static let scriptSHA256 = "493f9c5a0fe658d19f5581086a70726df10c9e979607d1f5bedb32a16482fa2c"
    /// The bundled explicit lock, named as `ManagedCondaExplicitLockSpec` requires.
    public static let lockResource = "sc-embed-osx-arm64-explicit.txt"
    /// The name the route's record gives the lock. The pin's record holds it (review CM-REPRO-BIO, section 4 item 1), so
    /// the run reads a copy of the bundled lock under this name.
    public static let lockName = "explicit-sc-embed-osx-arm64.txt"
    public static let knnWords = "kNN: exact, brute, transformer=sklearn"
    /// The origin of a computed cell map (`docs/formats/rnaseq-cell-map.md`, The manifest, 5.5 C10).
    public static let tool = "scanpy"
    public static let toolVersion = "1.11.5"
    public static let embeddingName = "umap"
    public static let embeddingMethod = "UMAP"
    public static let labelSetName = "leiden"
    /// `python -s -B -P`, never `-I` or `-E`, which drop `PYTHONHASHSEED` (ruling C2-PYFLAGS (b)).
    public static let pythonFlags = ["-s", "-B", "-P"]
    public static let threadVariables = ["OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "NUMBA_NUM_THREADS"]
    /// Each cache variable and its folder in the run's temporary folder. The hermetic environment sets `HOME` to the
    /// person's home, where numba and matplotlib would otherwise write.
    public static let cacheVariables = [("NUMBA_CACHE_DIR", "numba"), ("MPLCONFIGDIR", "matplotlib"), ("XDG_CACHE_HOME", "xdg")]

    /// One matrix entry of the parent, as the route reads it. Barcodes stay as given, 10x's `-1` or STARsolo's bare
    /// form (ruling ARCH-X4-INPUT item 5).
    public struct Input: Equatable, Sendable {
        public var sample: String
        public var matrix: URL
        public var features: URL
        public var barcodes: URL
        public var isGzip: Bool
        public var cells: Int
        public var entries: Int
        public var matrixSHA256: String

        public init(sample: String, matrix: URL, features: URL, barcodes: URL, isGzip: Bool, cells: Int, entries: Int, matrixSHA256: String) {
            (self.sample, self.matrix, self.features, self.barcodes) = (sample, matrix, features, barcodes)
            (self.isGzip, self.cells, self.entries, self.matrixSHA256) = (isGzip, cells, entries, matrixSHA256)
        }
    }

    /// The parent's matrix entries with their paths resolved, each file checked against the sha256 its manifest names
    /// before the launch, as the route's own `prep.py` does.
    public static func inputs(of parent: URL, manifest: RNASeqResultManifest) throws -> [Input] {
        guard let matrices = manifest.matrices, !matrices.isEmpty else { throw RNASeqPseudobulkRefusal.noCells(name: manifest.name) }
        return try matrices.map { entry in
            guard entry.format == "matrix-market" else {
                throw RNASeqCellMapComputeRefusal.notMatrixMarket(sample: entry.sample, format: entry.format)
            }
            var urls: [URL] = []
            for file in [entry.matrix, entry.features, entry.barcodes] {
                let url = try RNASeqResultBundle.resolve(file.path, in: parent)
                guard try RNASeqResultBundle.sha256Hex(fileAt: url) == file.sha256 else {
                    throw RNASeqCellMapComputeRefusal.inputChanged(file: file.path, name: manifest.name)
                }
                urls.append(url)
            }
            return Input(sample: entry.sample, matrix: urls[0], features: urls[1], barcodes: urls[2], isGzip: entry.isGzip,
                         cells: entry.cellCount, entries: entry.entryCount, matrixSHA256: entry.matrix.sha256)
        }
    }

    /// The route's parameters (5.5 C2), each named even at its value, in the order of the route's `run.sh`. The kNN
    /// transformer is always `sklearn`, exact and brute at every size (vote S-2), and the Leiden flavor is always named
    /// (ruling ADJ-SC-EMBED item 1).
    public static func routeArguments(seed: Int) -> [String] {
        let seed = String(seed)
        return ["--cells", "all", "--feature-type", "Gene Expression", "--min-cells", "3", "--target-sum", "10000",
                "--n-top-genes", "2000", "--hvg-flavor", "seurat", "--scale-max", "10", "--n-comps", "50", "--svd-solver", "arpack",
                "--pca-seed", seed, "--n-neighbors", "15", "--n-pcs", "30", "--knn-metric", "euclidean", "--knn-transformer", "sklearn",
                "--neighbors-seed", seed, "--leiden-flavor", "leidenalg", "--leiden-iterations", "-1", "--leiden-directed", "true",
                "--leiden-use-weights", "true", "--resolution", "1.0", "--leiden-seed", seed, "--umap-min-dist", "0.5",
                "--umap-spread", "1.0", "--umap-init", "spectral", "--umap-maxiter", "umap-default", "--umap-seed", seed]
    }

    /// The arguments after `python`: the flags, the script, each input with its sample as `--sample=<name>` so a name
    /// that starts with `-` is never read as an option (ruling HASH-SEED-FLAG item 5), and the route's parameters. It
    /// never emits a token that starts with `--allow-hash` or the `scanpy-default` transformer.
    public static func arguments(script: URL, inputs: [Input], output: URL, lock: URL, threads: Int, seed: Int) -> [String] {
        var argv = pythonFlags + [script.path]
        for input in inputs {
            argv += ["--sample=\(input.sample)", "--matrix", input.matrix.path, "--features", input.features.path,
                     "--barcodes", input.barcodes.path, "--gzip", input.isGzip ? "true" : "false"]
        }
        argv += ["--out", output.path, "--lock", lock.path, "--threads", String(threads)]
        return argv + routeArguments(seed: seed)
    }

    /// The variables the CLI adds to `CondaManager`'s hermetic environment, which holds only `MAMBA_ROOT_PREFIX`, `PATH`,
    /// `HOME` and `TMPDIR`. These are the variables of 5.5 C2 and no other, so the child inherits no `SKLEARN_*` or
    /// `PYTHON*` variable from the caller's shell, and `PYTHONHASHSEED` is always 0.
    public static func environment(threads: Int, temporary: URL) -> [String: String] {
        var environment = ["PYTHONHASHSEED": "0"]
        for name in threadVariables { environment[name] = String(threads) }
        for (name, folder) in cacheVariables { environment[name] = temporary.appendingPathComponent(folder, isDirectory: true).path }
        return environment
    }

    /// The predicted peak footprint of a run, P = max(700,000,000 + 41,500 B a cell + 10 B a stored entry, 200,000,000 +
    /// 21 B a stored entry), against 40% of the Mac's memory (ruling ADJ-SC-EMBED item 4). Cells are the cells the run
    /// keeps and entries the stored entries of every matrix it reads, both from the parent's manifest.
    public struct MemoryPrediction: Equatable, Sendable {
        public static let base: UInt64 = 700_000_000
        public static let perCell: UInt64 = 41_500
        public static let perEntry: UInt64 = 10
        public static let readBase: UInt64 = 200_000_000
        public static let readPerEntry: UInt64 = 21
        public static let share = 0.40

        public var cells: Int
        public var entries: Int
        public var physicalMemory: UInt64

        public init(cells: Int, entries: Int, physicalMemory: UInt64) {
            (self.cells, self.entries, self.physicalMemory) = (cells, entries, physicalMemory)
        }

        public var peak: UInt64 {
            let (cells, entries) = (UInt64(max(cells, 0)), UInt64(max(entries, 0)))
            return max(Self.base + Self.perCell * cells + Self.perEntry * entries, Self.readBase + Self.readPerEntry * entries)
        }

        /// 40% of the Mac's memory, rounded down to a whole byte.
        public var bound: UInt64 { UInt64((Double(physicalMemory) * Self.share).rounded(.down)) }
        public var fits: Bool { peak <= bound }

        /// The most cells this Mac may compute at this input's stored entries a cell.
        public var cellsAtThisDepth: Int {
            guard cells > 0 else { return 0 }
            let depth = Double(entries) / Double(cells)
            let bound = Double(self.bound)
            let byCells = (bound - Double(Self.base)) / (Double(Self.perCell) + Double(Self.perEntry) * depth)
            let byRead = depth > 0 ? (bound - Double(Self.readBase)) / (Double(Self.readPerEntry) * depth) : byCells
            return max(0, Int(min(byCells, byRead).rounded(.down)))
        }

        /// The record's memory facts: the five terms, the share, the Mac's memory and the predicted peak (5.5 C6).
        public var facts: [String: ParameterValue] {
            [
                "baseBytes": .integer(Int(Self.base)), "bytesPerCell": .integer(Int(Self.perCell)),
                "bytesPerStoredEntry": .integer(Int(Self.perEntry)), "readBaseBytes": .integer(Int(Self.readBase)),
                "readBytesPerStoredEntry": .integer(Int(Self.readPerEntry)), "shareOfPhysicalMemory": .number(Self.share),
                "physicalMemoryBytes": .integer(Int(physicalMemory)), "boundBytes": .integer(Int(bound)),
                "cells": .integer(cells), "storedEntries": .integer(entries), "predictedPeakBytes": .integer(Int(peak)),
                "measure": .string("peak memory footprint (phys_footprint)"),
            ]
        }
    }

    /// Refuses a prediction over the bound in words, before anything is launched (5.5 C6).
    public static func checkMemory(_ prediction: MemoryPrediction) throws {
        guard prediction.fits else { throw RNASeqCellMapComputeRefusal.memory(prediction) }
    }

    /// The fields a route run's record must hold, with the value each must have. A probe run of `embed.py` (its
    /// `--allow-hash-seed` or `--knn-transformer scanpy-default`) or a run at another seed fails one of them.
    static let recordRules: [(field: String, expected: String)] = [
        ("guard", "\"passed\""),
        ("interpreter.sys_flags.hash_randomization", "0"),
        ("environment.values.PYTHONHASHSEED", "\"0\""),
        ("knn", "\"\(knnWords)\""),
        ("parameters.knn_transformer", "\"sklearn\""),
        ("seeds.pca", "0"), ("seeds.neighbors", "0"), ("seeds.leiden", "0"), ("seeds.umap", "0"),
        ("script.sha256", "\"\(scriptSHA256)\""),
    ]

    /// Reads the route's `record.json` and refuses, naming the field, any record that is not a seed-0 route run of the
    /// bundled script (ruling HASH-SEED-FLAG item 2, review CM-REPRO-SC SF-3). The same check serves a replay.
    @discardableResult
    public static func checkRecord(_ data: Data) throws -> [String: Any] {
        guard let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw RNASeqCellMapComputeRefusal.recordUnreadable
        }
        for rule in recordRules {
            let value = rule.field.split(separator: ".").reduce(Optional<Any>.some(record)) { ($0 as? [String: Any])?[String($1)] }
            let found = value.map(describe) ?? "missing"
            guard found == rule.expected else {
                throw RNASeqCellMapComputeRefusal.record(field: rule.field, found: found, expected: rule.expected)
            }
        }
        return record
    }

    /// A JSON value as the refusal shows it: a string in quotes, a number or a boolean as JSON writes it.
    static func describe(_ value: Any) -> String {
        if let text = value as? String { return "\"\(text)\"" }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        }
        if value is NSNull { return "null" }
        return String(describing: value)
    }

    /// The route's `cells.tsv` (`sample`, `barcode`, `x`, `y`, `cluster`) as LGE's table (`sample`, `barcode`, `umap_1`,
    /// `umap_2`, `leiden`). Only the header changes, so every value keeps the bytes the script wrote.
    public static func lgeTable(fromRouteCells data: Data) throws -> Data {
        let header = Data("sample\tbarcode\tx\ty\tcluster\n".utf8)
        guard data.starts(with: header) else { throw RNASeqCellMapComputeRefusal.tableForm }
        return Data("sample\tbarcode\t\(embeddingName)_1\t\(embeddingName)_2\t\(labelSetName)\n".utf8) + data.dropFirst(header.count)
    }
}

// SalmonQuantRoute.swift - salmon quant on a project's FASTQ bundles against a reference set (Phase 5.1 lane RS-QUANT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Each FASTQ bundle is one sample, read through `ReadSetResolver`. The index comes from `SalmonIndexCache` by set id,
// salmon version, k and decoys, and quant never builds one. `RunFitPreflight` checks the Mac, then each sample gets one
// `salmon quant -i <index> -l A -1 -2 -p <threads> -o <dir>` (`scripts/repro/rnaseq/seqc-gse47774/quant.sh:10-12`) in a
// working folder in the project's `.tmp/`. `SalmonQuantFolderReader` reads each folder and `RNASeqResultWriter` writes
// the result in the project's `Analyses/`, with one recorded step a sample and one a trim call.

import Foundation
import LungfishCore
import LungfishIO

/// Whether the route trims the reads before salmon. Trimming is off by default, as the scripts of gates GS and GC ran
/// (ADJ-ROUTE item 3). A trim call always passes the poly-G setting (ADJ-ROUTE item 1).
public enum SalmonQuantTrim: Sendable, Equatable {
    case none
    case trimGalore(polyG: Bool)
}

public struct SalmonQuantRequest: Sendable {
    public var bundles: [URL]
    public var projectURL: URL
    public var name: String
    public var setID: String
    public var k: Int
    public var decoys: SalmonIndexDecoys
    public var threads: Int
    public var trim: SalmonQuantTrim
    /// The command as the person ran it, recorded as the run's argv.
    public var argv: [String]

    public init(
        bundles: [URL], projectURL: URL, name: String, setID: String, k: Int = 31, decoys: SalmonIndexDecoys = .genome,
        threads: Int = 6, trim: SalmonQuantTrim = .none, argv: [String] = []
    ) {
        self.bundles = bundles
        self.projectURL = projectURL
        self.name = name
        self.setID = setID
        self.k = k
        self.decoys = decoys
        self.threads = threads
        self.trim = trim
        self.argv = argv
    }
}

public struct SalmonQuantOutcome: Sendable {
    public var resultURL: URL
    public var index: SalmonIndexOutcome
    public var samples: [String]
}

public enum SalmonQuantError: Error, LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case noSet(id: String, folder: String)
    case noIndex(setID: String, key: String, k: Int, decoys: SalmonIndexDecoys)
    case layout(bundle: String, reason: String)
    case toolFailed(tool: String, sample: String, status: Int, stderr: String)
    case trimOutputMissing(sample: String, file: String)
    case versionUnknown(tool: String, environment: String)

    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let words):
            return words
        case .noSet(let id, let folder):
            return "No reference set \(id) is in \(folder). Build the set first with lungfish-cli rnaseq reference-set, then its index."
        case .noIndex(let setID, let key, let k, let decoys):
            let options = (k == 31 ? "" : " --k \(k)") + (decoys == .none ? " --decoys none" : "")
            return "Set \(setID) has no salmon index \(key), and quant never builds one. Build it with "
                + "lungfish-cli rnaseq index --set \(setID)\(options), then run quant again."
        case .layout(let bundle, let reason):
            return "\(bundle) \(reason), so nothing ran."
        case .toolFailed(let tool, let sample, let status, let stderr):
            return "\(tool) stopped with exit status \(status) on sample \(sample): \(stderr)"
        case .trimOutputMissing(let sample, let file):
            return "Trim Galore wrote no \(file) for sample \(sample), so nothing was counted."
        case .versionUnknown(let tool, let environment):
            return "Lungfish could not read the version of \(tool) from its environment at \(environment). "
                + "Install the RNA-seq pack in the Plugin Manager again."
        }
    }
}

/// The one route that quantifies a project's bulk reads with salmon on LGE's own index.
public struct SalmonQuantRoute: Sendable {
    /// The prefix of the working folder in the project's `.tmp/`, which the project's scratch sweep knows by its marker.
    public static let workFolderPrefix = "rnaseq-quant-"
    public static let routeID = "salmon-selective-alignment-reads"

    let storageRoot: URL
    let runner: NativeToolRunner
    let provenanceWriter: ProvenanceWriter
    let host: RunFitHostFacts
    let freeSpace: RunFitPreflight.FreeSpaceReader

    /// `host` is the caller's reading, `Int64(clamping: ProcessInfo.processInfo.physicalMemory)`.
    package init(
        storageRoot: URL, runner: NativeToolRunner = .shared, provenanceWriter: ProvenanceWriter = ProvenanceWriter(),
        host: RunFitHostFacts, freeSpace: @escaping RunFitPreflight.FreeSpaceReader = RunFitPreflight.volumeFreeSpace
    ) {
        self.storageRoot = storageRoot
        self.runner = runner
        self.provenanceWriter = provenanceWriter
        self.host = host
        self.freeSpace = freeSpace
    }

    /// Quantifies each bundle as one sample and publishes one result. Every refusal comes before any process starts.
    ///
    /// - Throws: ``SalmonQuantError``, ``RunFitError``, ``SalmonIndexError``, a reader's or the writer's error.
    package func run(_ request: SalmonQuantRequest, linuxRoute: String) async throws -> SalmonQuantOutcome {
        let started = Date()
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SalmonQuantError.invalidRequest("The result needs a name.") }
        guard !request.bundles.isEmpty else { throw SalmonQuantError.invalidRequest("Name at least one FASTQ bundle.") }
        guard request.threads > 0 else { throw SalmonQuantError.invalidRequest("Threads is a number from 1 up.") }

        let owner = ReferenceSetOwner(storageRoot: storageRoot)
        let setURL = owner.setsFolder.appendingPathComponent(
            "\(request.setID).\(ReferenceSetManifest.folderExtension)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: setURL.path) else {
            throw SalmonQuantError.noSet(id: request.setID, folder: owner.setsFolder.path)
        }
        let set = try owner.settled(setURL, id: request.setID)
        let cache = SalmonIndexCache(
            storageRoot: storageRoot, runner: runner, provenanceWriter: provenanceWriter, host: host, freeSpace: freeSpace)
        let salmon = try await cache.salmonVersion()
        let key = SalmonIndexKey(setID: request.setID, salmonVersion: salmon.version, k: request.k, decoys: request.decoys)
        guard let index = try cache.published(key) else {
            throw SalmonQuantError.noIndex(setID: request.setID, key: key.folderName, k: request.k, decoys: request.decoys)
        }
        let trimVersion = request.trim == .none ? nil : try await condaVersion(.trimGalore, id: "trim_galore")

        let work = try ProjectTempDirectory.create(prefix: Self.workFolderPrefix, in: request.projectURL)
        defer { try? FileManager.default.removeItem(at: work) }
        let resolver = ReadSetResolver(materializationDirectory: work.appendingPathComponent("reads", isDirectory: true))
        var samples: [SampleReads] = []
        for bundle in request.bundles {
            try Task.checkCancellation()
            samples.append(try await reads(of: bundle.standardizedFileURL, resolver: resolver))
        }
        try RunFitPreflight.require(
            need: SalmonQuantNeed.need(splitBytes: samples.map(\.splitBytes).max() ?? 0, diskFolder: work),
            host: host, linuxRoute: linuxRoute, freeSpace: freeSpace)

        var folders: [SalmonQuantFolder] = []
        var steps: [ProvenanceStep] = []
        for (number, sample) in samples.enumerated() {
            let run = try await quantify(
                sample, number: number, request: request, index: index, salmonVersion: salmon.version,
                trimVersion: trimVersion, work: work)
            folders.append(run.folder)
            steps += run.steps
        }

        let analyses = request.projectURL.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let resultURL = AnalysesFolder.batchSampleFileURL(named: name, extension: "lungfishrnaseq", in: analyses)
        let made = try writerRequest(
            name: name, folders: folders, set: set, index: index, trim: request.trim, trimVersion: trimVersion, samples: samples)
        let envelope = try envelope(
            request, samples: samples, steps: steps, index: index, salmonBuild: salmon.build, result: resultURL,
            counts: made.counts, started: started)
        try RNASeqResultWriter(provenanceWriter: provenanceWriter).write(made, to: resultURL, envelope: envelope)
        try cache.recordUse(of: index, resultFolder: resultURL)
        try owner.recordUse(of: setURL, resultFolder: resultURL)
        return SalmonQuantOutcome(resultURL: resultURL, index: index, samples: samples.map(\.id))
    }

    /// The version of a managed tool from the `conda-meta` of its environment, which starts no process. `id` is the
    /// tool's entry in the lock, such as `trim_galore` for the package `trim-galore`.
    func condaVersion(_ tool: NativeTool, id: String) async throws -> String {
        let executable = try await runner.findTool(tool)
        let environment = executable.deletingLastPathComponent().deletingLastPathComponent()
        if case .observed(let version, _) = ToolVersionEvidence.condaMeta(id: ManagedToolID(rawValue: id), environment: environment) {
            return version
        }
        throw SalmonQuantError.versionUnknown(tool: id, environment: environment.path)
    }
}

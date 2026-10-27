// ClassificationConfig+ReadFileIdentity.swift - The size and digest of each read file, recorded when a run ends
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishIO

extension ClassificationPipeline {

    /// ``runPipelineInDigestScope(config:profileRequest:progress:)`` with one digest cache bound for the whole run,
    /// so a read file that the provenance records and the read-file identities both describe is read once
    /// (BIO-READ-IDENTITY 4.2). A caller that bound a cache already keeps it.
    func runPipeline(
        config: ClassificationConfig,
        profileRequest: BrackenProfileRequest?,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> ClassificationResult {
        // `scoped` takes a nonisolated operation, so the actor binds the task-local itself, as `scoped` does.
        try await ProvenanceDigestCache.$current.withValue(ProvenanceDigestCache.current ?? ProvenanceDigestCache()) {
            try await runPipelineInDigestScope(config: config, profileRequest: profileRequest, progress: progress)
        }
    }
}

extension ClassificationConfig {

    /// This config with ``readFileIdentities``, the size and SHA-256 of every durable file Extract and BLAST will
    /// read for the result (BIO-READ-IDENTITY 4.2). The digests come from the run's digest cache, so a file the
    /// provenance records hashed is not read again. Nil when the run named no durable read file.
    func recordingReadFileIdentities() async -> ClassificationConfig {
        var config = self
        let identities = await KrakenResultReadSources.durableReadFiles(of: self).compactMap { url -> ReadFileIdentity? in
            guard let size = try? ProvenanceFileHasher.fileSize(of: url) else { return nil }
            return ReadFileIdentity(url: url, sizeBytes: size, sha256: try? ProvenanceDigestCache.digest(of: url))
        }
        config.readFileIdentities = identities.isEmpty ? nil : identities
        return config
    }
}

extension KrakenResultReadSources {

    /// The words Extract adds to its completion message when the files at `place` changed after the result was made
    /// and every read it names is still there with the length kraken2 saw (BIO-READ-IDENTITY 4.3).
    public static func changedReadsNote(place: String) -> String {
        "The reads at \(place) changed after this result was made. Every read it names is there with the length "
            + "kraken2 saw, so Lungfish extracted them."
    }

    /// Whether a read file the run recorded has another size now, or is gone: one `stat` per file (4.2). False for a
    /// result that recorded none, whose read check alone decides.
    public static func readFilesChanged(since config: ClassificationConfig) -> Bool {
        (config.readFileIdentities ?? []).contains { identity in
            let size = (try? FileManager.default.attributesOfItem(atPath: identity.url.path)[.size] as? NSNumber)?.uint64Value
            return size != identity.sizeBytes
        }
    }

    /// Every durable file ``resolve(result:materializationDirectory:)`` reads for a result of `config`, without
    /// materializing anything: a loose file itself, a bundle's files by role, and for a virtual derivative the files
    /// of the bundle its reads come from plus its trim-positions and orientation files. A scratch input and the
    /// materialization folder are never among them.
    static func durableReadFiles(of config: ClassificationConfig) async -> [URL] {
        guard let inputs = try? recordedInputs(ofConfig: config) else { return [] }
        var files: [URL] = []
        for input in inputs {
            for url in await durableFiles(of: input.standardizedFileURL) where !files.contains(url) {
                files.append(url)
            }
        }
        return files
    }

    private static func durableFiles(of input: URL) async -> [URL] {
        guard FASTQBundle.isBundleURL(input) else { return [input] }
        if let manifest = FASTQBundle.loadDerivedManifest(in: input) {
            switch manifest.payload {
            case .subset, .trim, .demuxedVirtual, .orientMap:
                let root = FASTQBundle.resolveBundle(relativePath: manifest.rootBundleRelativePath, from: input)
                let source = FASTQDerivedPayloadRoot.pairedOrMixedSource(of: input, recordedRoot: root) ?? root
                let maps = selectsRecordsUnchanged(input, payload: manifest.payload)
                    ? [] : recordMapFiles(of: input, payload: manifest.payload)
                return await durableFiles(of: source.standardizedFileURL) + maps
            case .full, .fullFASTA, .fullPaired, .fullMixed, .demuxGroup:
                break
            }
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("lungfish-read-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        return ((try? await files(of: input, materializationDirectory: scratch)) ?? []).map(\.url)
    }

    /// The trim-positions and orientation files of a virtual derivative that change its records.
    private static func recordMapFiles(of bundle: URL, payload: FASTQDerivativePayload) -> [URL] {
        let names: [String]
        switch payload {
        case .trim(let trimPositions): names = [trimPositions]
        case .orientMap(let orientMap, _): names = [orientMap]
        case .demuxedVirtual(_, _, _, let trimPositions, let orientMap): names = [trimPositions, orientMap].compactMap { $0 }
        default: names = [FASTQBundle.trimPositionFilename, "orient-map.tsv"]
        }
        return names.map { bundle.appendingPathComponent($0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

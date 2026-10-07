// TwelveSAmpliconMatchingWorkflow+Inputs.swift - The inputs a 12S matching run reads, one sample each
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A bundle is planned whole through the read-set resolver. A file named
// inside a bundle is that file alone, as the FASTQ subcommands and TaxTriage
// read it, except the preview of a virtual bundle, which holds a few reads
// of the sample and not the sample (Phase 2.1 round F4, review A S1).

import Foundation
import LungfishCore
import LungfishIO

/// How a path named as a 12S input is planned.
enum TwelveSNamedInput: Equatable, Sendable {
    /// A bundle, or a path outside every bundle, planned as it is named.
    case asNamed(URL)
    /// A file inside a bundle, planned as that file alone.
    case fileAlone(URL)
    /// The preview of a virtual bundle, for which its bundle is planned.
    case previewOf(bundle: URL, preview: URL)

    init(_ inputURL: URL) {
        let input = inputURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard !FASTQBundle.isBundleURL(input),
              SequenceInputResolver.enclosingFASTQBundleURL(for: input) != nil,
              FileManager.default.fileExists(atPath: input.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            self = .asNamed(input)
            return
        }
        if FASTQBundle.isFASTQFileURL(input),
           let bundleURL = SequenceInputResolver.unmaterializedDerivedBundleURL(for: input) {
            self = .previewOf(bundle: bundleURL, preview: input)
        } else {
            self = .fileAlone(input)
        }
    }
}

extension TwelveSAmpliconMatchingWorkflow {

    /// Plans each input through the read-set resolver, one input one sample.
    /// Pairs reach the count as pairs and a mixed stream is split by name
    /// into the scratch folder (docs/contracts/READ-PAIRING.md).
    func resolveInputs(
        _ inputURLs: [URL],
        scratchDirectory: URL,
        progressHandler: ProgressHandler?
    ) async throws -> [ResolvedInput] {
        let resolver = ReadSetResolver(
            materializationDirectory: scratchDirectory.appendingPathComponent("read-sets", isDirectory: true)
        )
        var resolved: [ResolvedInput] = []
        for inputURL in inputURLs {
            do {
                let plan = try await Self.plan(
                    TwelveSNamedInput(inputURL),
                    resolver: resolver,
                    progressHandler: progressHandler
                )
                resolved.append(ResolvedInput(sourceURL: inputURL, plan: plan))
            } catch ReadSetResolverError.noReads(let path) {
                throw TwelveSAmpliconMatchingError.noReadsInInput(path)
            }
        }
        return resolved
    }

    static func plan(
        _ input: TwelveSNamedInput,
        resolver: ReadSetResolver,
        progressHandler: ProgressHandler?
    ) async throws -> ReadSetPlan {
        switch input {
        case let .asNamed(url):
            return try await resolver.plan(for: url, capability: readPairingCapability)
        case let .previewOf(bundleURL, preview):
            progressHandler?(
                0.25,
                "\(preview.lastPathComponent) is the preview of the virtual bundle \(bundleURL.lastPathComponent), "
                    + "not its reads. Reading the bundle instead."
            )
            return try await resolver.plan(for: bundleURL, capability: readPairingCapability)
        case let .fileAlone(file):
            return try await planFileAlone(file, resolver: resolver)
        }
    }

    /// The plan of a file inside a bundle, read as that file alone. The
    /// resolver reads any path inside a bundle as the whole bundle, so the
    /// plan is made for a link to the file outside every bundle, beside a
    /// link to the file's own sidecar, and is then pointed back at the file.
    /// The bundle's manifest, lineage and platform describe the bundle and
    /// not one of its files read alone. The links go when the plan is made.
    private static func planFileAlone(_ file: URL, resolver: ReadSetResolver) async throws -> ReadSetPlan {
        let fileManager = FileManager.default
        let linkDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "lungfish-12s-named-input-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: linkDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: linkDirectory) }
        let link = linkDirectory.appendingPathComponent(file.lastPathComponent)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: file)
        let sidecar = FASTQMetadataStore.metadataURL(for: file)
        if fileManager.fileExists(atPath: sidecar.path) {
            try fileManager.createSymbolicLink(
                at: FASTQMetadataStore.metadataURL(for: link),
                withDestinationURL: sidecar
            )
        }
        let plan = try await resolver.plan(for: link, capability: readPairingCapability)
        return plan.naming(file, insteadOf: link)
    }

    /// Refuses two inputs that would be one sample, before anything is
    /// written. A result holds each sample once and its tables are keyed by
    /// the sample, so two such inputs used to stop the run on a trap after
    /// `--force` had removed the earlier output (review A, N1).
    static func refuseDuplicateSampleIDs(_ inputURLs: [URL]) throws {
        var firstInputs: [String: URL] = [:]
        for inputURL in inputURLs {
            let sampleID = Self.sampleID(for: inputURL)
            if let earlier = firstInputs[sampleID] {
                throw TwelveSAmpliconMatchingError.duplicateSampleID(
                    sampleID: sampleID,
                    first: earlier.path,
                    second: inputURL.path
                )
            }
            firstInputs[sampleID] = inputURL
        }
    }
}

private extension ReadSetPlan {
    /// The same plan with `file` in every place that names `alias`, for a
    /// plan made through a link to `file`.
    func naming(_ file: URL, insteadOf alias: URL) -> ReadSetPlan {
        let aliasPath = alias.standardizedFileURL.path
        func swap(_ url: URL) -> URL {
            url.standardizedFileURL.path == aliasPath ? file : url
        }
        func swap(_ pair: ReadSetMatePair) -> ReadSetMatePair {
            switch pair.files {
            case let .separate(r1, r2):
                return ReadSetMatePair(files: .separate(r1: swap(r1), r2: swap(r2)), pairCount: pair.pairCount)
            case let .interleaved(url):
                return ReadSetMatePair(files: .interleaved(swap(url)), pairCount: pair.pairCount)
            }
        }
        return ReadSetPlan(
            inputURL: swap(inputURL),
            capability: capability,
            sourceLayout: sourceLayout,
            layoutReason: layoutReason,
            sequencingPlatform: sequencingPlatform,
            wasMaterialized: wasMaterialized,
            sampleHoldsPairsAndSingleReads: sampleHoldsPairsAndSingleReads,
            runs: runs.map { run in
                ReadSetRun(
                    matePairs: run.matePairs.map(swap),
                    singleReads: run.singleReads.map {
                        ReadSetSingleReads(url: swap($0.url), role: $0.role, readCount: $0.readCount)
                    },
                    mixedStreams: run.mixedStreams.map {
                        ReadSetMixedStream(
                            url: swap($0.url),
                            pairCount: $0.pairCount,
                            singleReadCount: $0.singleReadCount,
                            singleReadRole: $0.singleReadRole
                        )
                    }
                )
            },
            steps: steps.map {
                ReadSetStep(
                    kind: $0.kind,
                    inputURLs: $0.inputURLs.map(swap),
                    outputURLs: $0.outputURLs,
                    pairCount: $0.pairCount,
                    singleReadCount: $0.singleReadCount,
                    startedAt: $0.startedAt,
                    endedAt: $0.endedAt
                )
            },
            singleReadReason: singleReadReason,
            composition: composition
        )
    }
}

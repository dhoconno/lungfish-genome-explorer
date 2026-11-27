// ReferenceSetInstall.swift - Download, build and index one catalog reference set (2026-11-26)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `lungfish-cli rnaseq install-reference` runs this, and the Plugin Manager runs that command (ARCH ruling 2026-11-26).
// It only combines what `rnaseq reference-set --default` and `rnaseq index` already do: the set is written only by
// `ReferenceSetOwner` and the index only by `SalmonIndexCache`. This file writes only its download folder.

import Foundation
import LungfishCore

package enum ReferenceSetInstallError: Error, LocalizedError, Equatable {
    case notInCatalog(String, offered: [String])
    case unpinned(String)
    case download(file: String, reason: String)
    case checksumMismatch(file: String, expected: String, found: String)
    case toolsMissing

    package var errorDescription: String? {
        switch self {
        case .notInCatalog(let id, let offered):
            return "\(id) is not a reference set Lungfish installs. The sets are \(offered.joined(separator: ", "))."
        case .unpinned(let id):
            return "The set \(id) pins no sha256 for its genome or its GTF, so Lungfish will not download it."
        case .download(let file, let reason):
            return "Downloading \(file) failed: \(reason) Try Download again."
        case .toolsMissing:
            return "Install the RNA-Seq Analysis pack first, on the Packs tab of Plugin Manager. It holds salmon and gffread."
        case .checksumMismatch(let file, let expected, let found):
            return "The downloaded \(file) has sha256 \(found), not \(expected) as the set names. The file was deleted. "
                + "Try Download again."
        }
    }
}

package struct ReferenceSetInstallOutcome: Sendable, Equatable {
    package var setID: String
    package var setURL: URL
    package var indexURL: URL
}

/// What the install reports: a fraction while bytes download, and a stage line with no fraction for the set build and
/// the index build, which report no progress of their own (UX trap 2).
package enum ReferenceSetInstallProgress: Sendable, Equatable {
    case downloading(fraction: Double, message: String)
    case stage(String)
}

package struct ReferenceSetInstall: Sendable {
    /// The folder of the downloads under the storage root. They are kept, because the set's record names each input
    /// path as it was given (ARCH ruling item 7), and a second install finds them and downloads nothing.
    package static let downloadsFolderName = "rnaseq-reference-downloads"

    /// The sentence a refusal for memory or disk ends on (`RunFitPreflight.require`).
    package static let linuxRoute = "Build the set and its index on a Mac with more memory and disk, or count on Linux with "
        + "lungfish-cli rnaseq plan and bring the counts back with lungfish-cli import rnaseq"

    /// Builds the index of a published set. The default runs `SalmonIndexCache.ensure` at the catalog's k and decoys.
    package typealias Indexer = @Sendable (_ setID: String, _ argv: [String]) async throws -> URL
    /// Checks the tools, memory and disk for the index before any byte is downloaded (ARCH trap 2, BIO trap 2, UX trap 5).
    package typealias Preflight = @Sendable () async throws -> Void

    let storageRoot: URL
    let loader: any DemoProjectArchiveLoading
    let owner: ReferenceSetOwner
    let indexer: Indexer
    let preflight: Preflight

    package init(
        storageRoot: URL,
        loader: any DemoProjectArchiveLoading = URLSessionDemoProjectArchiveLoader(),
        owner: ReferenceSetOwner? = nil,
        indexer: Indexer? = nil,
        preflight: Preflight? = nil
    ) {
        self.storageRoot = storageRoot
        self.loader = loader
        self.owner = owner ?? ReferenceSetOwner(storageRoot: storageRoot)
        let host = RunFitHostFacts(physicalMemoryBytes: Int64(clamping: ProcessInfo.processInfo.physicalMemory))
        self.indexer = indexer ?? { setID, argv in
            let cache = SalmonIndexCache(storageRoot: storageRoot, host: host)
            let request = SalmonIndexRequest(setID: setID, k: ReferenceSetCatalog.indexK, decoys: ReferenceSetCatalog.indexDecoys)
            return try await cache.ensure(request, linuxRoute: Self.linuxRoute, argv: argv).indexURL
        }
        self.preflight = preflight ?? {
            for tool in [NativeTool.gffread, .salmon] where (try? await NativeToolRunner.shared.toolPath(for: tool)) == nil {
                throw ReferenceSetInstallError.toolsMissing
            }
            let cacheFolder = storageRoot.appendingPathComponent(SalmonIndexCache.folderName, isDirectory: true)
            try RunFitPreflight.require(need: SalmonIndexNeed.need(diskFolder: cacheFolder), host: host, linuxRoute: Self.linuxRoute)
        }
    }

    package func downloadFolder(for row: ReferenceSetDefault) -> URL {
        storageRoot.appendingPathComponent(Self.downloadsFolderName, isDirectory: true)
            .appendingPathComponent(row.id.replacingOccurrences(of: "/", with: "-"), isDirectory: true)
    }

    /// Installs the catalog entry `id`. A set and index already there are reused, and a download already checked is not
    /// fetched again.
    package func install(
        _ id: String, argv: [String] = [], progress: @escaping @Sendable (ReferenceSetInstallProgress) -> Void = { _ in }
    ) async throws -> ReferenceSetInstallOutcome {
        guard let entry = ReferenceSetCatalog.entry(id) else {
            throw ReferenceSetInstallError.notInCatalog(id, offered: ReferenceSetCatalog.entries.map(\.id))
        }
        return try await install(row: entry.row, argv: argv, progress: progress)
    }

    /// Installs `row`. Tests pass a row of file URLs.
    package func install(
        row: ReferenceSetDefault, argv: [String] = [],
        progress: @escaping @Sendable (ReferenceSetInstallProgress) -> Void = { _ in }
    ) async throws -> ReferenceSetInstallOutcome {
        guard let genomeSHA = row.genomeSHA256, let annotationSHA = row.annotationSHA256 else {
            throw ReferenceSetInstallError.unpinned(row.id)
        }
        try await preflight()
        let folder = downloadFolder(for: row)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let files = [(row.genomeURL, genomeSHA), (row.annotationURL, annotationSHA)]
        var local: [URL] = []
        for (index, (source, sha)) in files.enumerated() {
            guard let url = URL(string: source) else { throw ReferenceSetInstallError.download(file: source, reason: "The address is not a URL.") }
            let name = url.lastPathComponent
            let share = 1.0 / Double(files.count)
            local.append(try await fetch(url, sha256: sha, into: folder) { done, total in
                let part = total.map { $0 > 0 ? min(Double(done) / Double($0), 1) : 0 } ?? 0
                progress(.downloading(
                    fraction: (Double(index) + part) * share,
                    message: "Downloading \(name), \(Self.megabytes(done)) of \(total.map(Self.megabytes) ?? "unknown")"))
            })
        }

        progress(.stage("Building the reference set from the genome and the genes"))
        try Task.checkCancellation()
        let request = ReferenceSetRequest(
            name: "\(row.species) \(row.assemblyName) \(row.annotationSource) \(row.annotationRelease)", species: row.species,
            assemblyName: row.assemblyName, assemblyAccession: row.assemblyAccession, assemblySourceURL: row.genomeURL,
            annotationSource: row.annotationSource, annotationRelease: row.annotationRelease, genome: local[0],
            annotation: local[1], expected: row)
        let set = try await owner.build(request, argv: argv)

        progress(.stage("Building the salmon index, which takes about an hour"))
        try Task.checkCancellation()
        let index = try await indexer(set.manifest.id, argv)
        return ReferenceSetInstallOutcome(setID: set.manifest.id, setURL: set.url, indexURL: index)
    }

    /// The local copy of `url` in `folder`, named as the URL names it, since the set id hashes each input's file name
    /// (ARCH trap 1). A copy already there with the pinned sha256 is used as it is.
    func fetch(
        _ url: URL, sha256 expected: String, into folder: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> URL {
        let name = url.lastPathComponent
        let final = folder.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: final.path) {
            if (try? FileDigest.sha256(of: final)) == expected { return final }
            try FileManager.default.removeItem(at: final)
        }
        let partial = folder.appendingPathComponent(".\(name).partial-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: partial) }
        do {
            try await loader.download(from: url, to: partial, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ReferenceSetInstallError.download(file: name, reason: Self.words(error))
        }
        try Task.checkCancellation()
        let found = try FileDigest.sha256(of: partial) { try Task.checkCancellation() }
        guard found == expected else {
            throw ReferenceSetInstallError.checksumMismatch(file: name, expected: expected, found: found)
        }
        try PortableRename.exclusive(partial, to: final)
        return final
    }

    /// The loader's error in words that do not say "demo project" (ARCH trap 10).
    static func words(_ error: any Error) -> String {
        if let demo = error as? DemoProjectError {
            switch demo {
            case .cancelled: return "The download was cancelled."
            case .network(let reason): return "The network failed (\(reason))."
            case .offline: return "This Mac is not connected to the internet."
            case .notFound(let url): return "The server has no file at \(url.absoluteString)."
            case .httpStatus(let status, let url): return "The server answered \(status) for \(url.absoluteString)."
            default: break
            }
        }
        if let urlError = error as? URLError { return "The network failed (\(urlError.localizedDescription))." }
        return error.localizedDescription
    }

    static func megabytes(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }
}

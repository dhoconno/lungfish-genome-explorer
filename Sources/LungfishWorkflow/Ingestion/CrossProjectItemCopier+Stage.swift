// CrossProjectItemCopier+Stage.swift - The stage a copied item is built in before its one rename
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.18 (SWIFT inv 85, BIO 6). The copier builds the whole item
// in the target project's `.tmp` folder, rewrites its links and the stage's
// name in its records there, hashes the files as they will be published, and
// only then renames it into place, so a cancel or a failure leaves no part of
// it in the project and every recorded digest matches the file on disk.

import CryptoKit
import Foundation
import LungfishCore
import LungfishIO

extension CrossProjectItemCopier {

    // MARK: - Containment

    /// `url` with its deepest existing ancestor resolved, so a folder reached
    /// through a symlinked alias compares by its real path even when the last
    /// components do not exist yet.
    static func resolvedThroughExistingAncestor(_ url: URL, fileManager: FileManager = .default) -> URL {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !fileManager.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }

    // MARK: - Source files

    /// Every regular file the copy reads from the source item, with its path
    /// inside the item, its size and its SHA-256, sorted by the bytes of the
    /// path. A symlinked file is read through its target. `checkCancellation`
    /// runs before each file and between the chunks of its hash.
    static func readSourceFiles(
        of item: URL,
        checkCancellation: () throws -> Void
    ) throws -> [ProjectItemCopyRecord.SourceFile] {
        let root = item.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: item.path])
        }
        let rootComponents = root.pathComponents
        var files: [ProjectItemCopyRecord.SourceFile] = []
        while let url = enumerator.nextObject() as? URL {
            let target = url.resolvingSymlinksInPath()
            guard try target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            try checkCancellation()
            let components = url.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(url.lastPathComponent).standardizedFileURL.pathComponents
            guard components.starts(with: rootComponents), components.count > rootComponents.count else { continue }
            files.append(ProjectItemCopyRecord.SourceFile(
                path: components.dropFirst(rootComponents.count).joined(separator: "/"),
                size: try ProvenanceFileHasher.fileSize(of: target),
                sha256: try ProvenanceFileHasher.sha256(of: target, cancellationCheck: checkCancellation)
            ))
        }
        return files.sorted { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
    }

    /// The SHA-256 of the lines `<path>\t<size>\t<sha256>\n` of `files` in their order.
    static func sourceItemDigest(of files: [ProjectItemCopyRecord.SourceFile]) -> String {
        let text = files.map { "\($0.path)\t\($0.size)\t\($0.sha256)\n" }.joined()
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Stage paths

    /// Rewrites the stage's path to the final item's in every JSON file of the
    /// staged item, records included. Both are spelled from the target project's
    /// root, so one pair covers the absolute, `@/` and URL spellings, each also
    /// percent-encoded and with escaped slashes.
    static func rewriteStagePaths(in staged: URL, to destination: URL, targetProjectURL: URL) throws {
        let variants = ProjectItemLinkRewriter.pathVariants(of: targetProjectURL)
        guard let from = ProjectItemLinkRewriter.relative(path: staged.standardizedFileURL.path, toAny: variants),
              let to = ProjectItemLinkRewriter.relative(path: destination.standardizedFileURL.path, toAny: variants),
              !from.isEmpty, !to.isEmpty else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: staged.path])
        }
        var pairs = [(from, to)]
        if let encodedFrom = from.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let encodedTo = to.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           encodedFrom != from || encodedTo != to {
            pairs.append((encodedFrom, encodedTo))
        }
        pairs += pairs.map { ($0.0.replacingOccurrences(of: "/", with: "\\/"), $0.1.replacingOccurrences(of: "/", with: "\\/")) }
        for file in try jsonFiles(under: staged) {
            let text = try String(contentsOf: file, encoding: .utf8)
            let rewritten = pairs.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
            if rewritten != text {
                try rewritten.write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func jsonFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        return try enumerator.compactMap { $0 as? URL }.filter { url in
            guard url.pathExtension.lowercased() == "json" else { return false }
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
    }

    // MARK: - Digests

    /// Rehashes every output the staged item's record names whose file the
    /// link rewrite or the stage rewrite changed, so each recorded digest
    /// matches the file that is published. The record names the final paths,
    /// and the file is read at the same place inside the stage.
    static func refreshRecordedDigests(in staged: URL, publishedAs destination: URL) throws {
        let recordURL = staged.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        guard FileManager.default.fileExists(atPath: recordURL.path),
              var envelope = try ProvenanceEnvelopeReader.load(fromSidecar: recordURL) else { return }
        let finalRoot = destination.standardizedFileURL.path
        var changed = false
        // Only JSON files change in the stage, and several lists of the record name one file, so each
        // JSON file is hashed once.
        var digests: [String: String] = [:]
        func refreshed(_ descriptor: ProvenanceFileDescriptor) throws -> ProvenanceFileDescriptor {
            guard let recorded = descriptor.checksumSHA256, descriptor.path.hasPrefix(finalRoot + "/"), descriptor.path.lowercased().hasSuffix(".json") else { return descriptor }
            let stagedFile = staged.appendingPathComponent(String(descriptor.path.dropFirst(finalRoot.count + 1)))
            guard FileManager.default.fileExists(atPath: stagedFile.path) else { return descriptor }
            let digest: String
            if let known = digests[descriptor.path] {
                digest = known
            } else {
                digest = try ProvenanceFileHasher.sha256(of: stagedFile)
                digests[descriptor.path] = digest
            }
            guard digest != recorded else { return descriptor }
            changed = true
            return ProvenanceFileDescriptor(
                path: descriptor.path, checksumSHA256: digest, fileSize: try ProvenanceFileHasher.fileSize(of: stagedFile),
                format: descriptor.format, role: descriptor.role, originPath: descriptor.originPath,
                sourceProvenancePath: descriptor.sourceProvenancePath
            )
        }
        envelope.outputs = try envelope.outputs.map(refreshed)
        envelope.files = try envelope.files.map(refreshed)
        envelope.steps = try envelope.steps.map { step in
            var step = step
            step.outputs = try step.outputs.map(refreshed)
            return step
        }
        if let output = envelope.output { envelope.output = try refreshed(output) }
        if changed {
            try ProvenanceWriter(signingProvider: nil).write(envelope, to: staged)
        }
    }
}

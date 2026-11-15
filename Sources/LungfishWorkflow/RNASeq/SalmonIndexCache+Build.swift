// SalmonIndexCache+Build.swift - A build of one salmon index in a held stage (Phase 5.1 lane RS-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import LungfishCore
import LungfishIO

extension SalmonIndexCache {
    /// The published index of the request's key, or a new one. A reuse starts no process and runs no check. A build checks
    /// the Mac first and refuses with `linuxRoute` at the end of its words (ADJ-SPIKE-ARCH items 4 and 7).
    ///
    /// - Throws: ``SalmonIndexError``, ``RunFitError`` or the error of a write.
    package func ensure(_ request: SalmonIndexRequest, linuxRoute: String, argv: [String] = []) async throws -> SalmonIndexOutcome {
        let started = Date()
        guard (1...31).contains(request.k), request.k % 2 == 1 else {
            throw SalmonIndexError.invalidRequest("k is an odd number from 1 to 31, not \(request.k).")
        }
        let owner = ReferenceSetOwner(storageRoot: storageRoot)
        let setURL = owner.setsFolder.appendingPathComponent(
            "\(request.setID).\(ReferenceSetManifest.folderExtension)", isDirectory: true)
        guard FileManager.default.fileExists(atPath: setURL.path) else {
            throw SalmonIndexError.noSet(id: request.setID, folder: owner.setsFolder.path)
        }
        let set = try owner.settled(setURL, id: request.setID)
        let salmon = try await salmonVersion()
        let key = SalmonIndexKey(setID: request.setID, salmonVersion: salmon.version, k: request.k, decoys: request.decoys)
        if let found = try published(key) { return found }

        removeAbandonedStages()
        try RunFitPreflight.require(
            need: SalmonIndexNeed.need(diskFolder: cacheFolder), host: host, linuxRoute: linuxRoute, freeSpace: freeSpace)
        let setFolder = cacheFolder.appendingPathComponent(key.setID, isDirectory: true)
        try FileManager.default.createDirectory(at: setFolder, withIntermediateDirectories: true)
        let hold = try SalmonIndexStageHold.make(in: setFolder, name: key.folderName)
        defer { hold.release() }
        let finalURL = folder(for: key)
        var renaming = false
        do {
            let file = try await build(in: hold.url, key: key, set: set, salmonBuild: salmon.build, linuxRoute: linuxRoute)
            let envelope = try makeEnvelope(file, set: set, finalURL: finalURL, stage: hold.url, argv: argv, started: started)
            try provenanceWriter.write(envelope, to: hold.url, bundleLayoutRoot: finalURL)
            // The key folder has no `lungfish*` extension, so the writer above writes no `provenance/` by itself.
            try provenanceWriter.writeBundleProvenanceLayout(envelope, toBundleRoot: hold.url, descriptorBundleRoot: finalURL)
            try FileManager.default.createDirectory(
                at: hold.url.appendingPathComponent(Self.usesFolderName, isDirectory: true), withIntermediateDirectories: false)
            renaming = true
            try PortableRename.exclusive(hold.url, to: finalURL)
            return SalmonIndexOutcome(url: finalURL, key: key, hashes: file.hashes, reused: false)
        } catch {
            try? FileManager.default.removeItem(at: hold.url)
            // Another build of the same key won the rename, so its index is used after its key file is checked.
            if renaming, FileManager.default.fileExists(atPath: finalURL.path) { return try settled(finalURL, key: key) }
            throw error
        }
    }

    /// salmon's version and package line from the `conda-meta` of its environment, which starts no process.
    func salmonVersion() async throws -> (version: String, build: String) {
        let executable = try await runner.findTool(.salmon)
        let environment = executable.deletingLastPathComponent().deletingLastPathComponent()
        let evidence = ToolVersionEvidence.condaMeta(id: ManagedToolID(rawValue: "salmon"), environment: environment)
        if case .observed(let version, let line?) = evidence { return (version, line) }
        throw SalmonIndexError.versionUnknown(environment: environment.path)
    }

    /// The arguments of `salmon index`. Every build passes the same options and no other (`SalmonIndexNeed`).
    static func salmonArguments(gentrome: String, decoys: String?, k: Int, index: String) -> [String] {
        var arguments = ["index", "-t", gentrome]
        if let decoys { arguments += ["-d", decoys] }
        return arguments + [
            "-k", String(k), "-p", String(SalmonIndexNeed.threads), "--ramLimit", String(SalmonIndexNeed.ramLimitGiB), "-i", index,
        ]
    }

    /// Writes the gentrome and the decoy names in `.work`, checks a large gentrome again, runs salmon, checks its
    /// `info.json` against the key, removes `.work` and writes `index-key.json`.
    func build(
        in stage: URL, key: SalmonIndexKey, set: ReferenceSetOutcome, salmonBuild: String, linuxRoute: String
    ) async throws -> SalmonIndexKeyFile {
        let work = stage.appendingPathComponent(Self.workFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
        let decoyNames = try writeGentrome(set, decoys: key.decoys, into: work)
        let gentrome = work.appendingPathComponent(Self.gentromeName)
        if let scaled = SalmonIndexNeed.scaledNeed(gentromeBytes: gentrome.fileSizeBytes, diskFolder: cacheFolder) {
            try RunFitPreflight.require(need: scaled, host: host, linuxRoute: linuxRoute, freeSpace: freeSpace)
        }
        let index = stage.appendingPathComponent(Self.indexFolderName, isDirectory: true)
        let decoys = key.decoys == .genome ? work.appendingPathComponent(Self.decoysName) : nil
        let result = try await runner.run(
            .salmon, arguments: Self.salmonArguments(gentrome: gentrome.path, decoys: decoys?.path, k: key.k, index: index.path))
        guard result.isSuccess else { throw SalmonIndexError.salmonFailed(status: Int(result.exitCode), stderr: result.stderr) }
        let hashes = try readInfo(of: index, key: key, decoys: decoyNames.count)
        try FileManager.default.removeItem(at: work)
        let file = SalmonIndexKeyFile(
            schemaVersion: SalmonIndexKeyFile.currentSchemaVersion, setID: key.setID, salmonVersion: key.salmonVersion,
            k: key.k, decoys: key.decoys,
            referenceSetSHA256: try ProvenanceFileHasher.sha256(of: set.url.appendingPathComponent(ReferenceSetManifest.filename)),
            salmonBuild: salmonBuild,
            argv: ["salmon"] + Self.salmonArguments(
                gentrome: Self.gentromeName, decoys: decoys == nil ? nil : Self.decoysName, k: key.k, index: Self.indexFolderName),
            indexSeqHash: hashes.seqHash, indexNameHash: hashes.nameHash,
            indexDecoySeqHash: hashes.decoySeqHash, indexDecoyNameHash: hashes.decoyNameHash)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try DurableReplace.replace(try encoder.encode(file), named: SalmonIndexKeyFile.filename, in: stage)
        return file
    }

    /// The set's transcript FASTA as it is, then for genome decoys the genome after a newline when the FASTA lacks a last
    /// one, as `seqc-gse47774/ref.sh:28-31` writes it. Each decoy name is a genome header up to its first space or tab.
    func writeGentrome(_ set: ReferenceSetOutcome, decoys: SalmonIndexDecoys, into work: URL) throws -> [String] {
        let gentrome = work.appendingPathComponent(Self.gentromeName)
        guard FileManager.default.createFile(atPath: gentrome.path, contents: nil) else {
            throw SalmonIndexError.invalidRequest("Lungfish could not write \(gentrome.path).")
        }
        let handle = try FileHandle(forWritingTo: gentrome)
        defer { try? handle.close() }
        var last: UInt8?
        try set.url.appendingPathComponent(set.manifest.derived.transcripts.path).forEachChunkAutoDecompressing { chunk in
            try Task.checkCancellation()
            try handle.write(contentsOf: chunk)
            if let byte = chunk.last { last = byte }
        }
        var names = FASTAHeaderNames()
        if decoys == .genome {
            if let last, last != 0x0A { try handle.write(contentsOf: Data([0x0A])) }
            try set.url.appendingPathComponent(set.manifest.genome.path).forEachChunkAutoDecompressing { chunk in
                try Task.checkCancellation()
                try handle.write(contentsOf: chunk)
                names.feed(chunk)
            }
        }
        try handle.synchronize()
        guard decoys == .genome else { return [] }
        let list = names.finish()
        try DurableReplace.replace(Data(list.map { $0 + "\n" }.joined().utf8), named: Self.decoysName, in: work)
        return list
    }

    /// salmon's `info.json`: `k`, `salmon_version` and `num_decoys` must equal what was asked, and the four hashes are read.
    /// A disagreement publishes nothing.
    func readInfo(of index: URL, key: SalmonIndexKey, decoys: Int) throws -> SalmonIndexHashes {
        let url = index.appendingPathComponent("info.json")
        guard let data = try? Data(contentsOf: url),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SalmonIndexError.indexDisagrees(field: "info.json", expected: "a JSON object", found: "none")
        }
        func number(_ name: String) -> String { (info[name] as? NSNumber)?.stringValue ?? "none" }
        func text(_ name: String) -> String? { (info[name] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        let checks = [
            ("k", String(key.k), number("k")),
            ("salmon_version", key.salmonVersion, text("salmon_version") ?? "none"),
            ("num_decoys", String(decoys), number("num_decoys")),
        ]
        for (field, expected, found) in checks where expected != found {
            throw SalmonIndexError.indexDisagrees(field: field, expected: expected, found: found)
        }
        let decoyFields = key.decoys == .genome ? ["decoy_seq_hash", "decoy_name_hash"] : []
        for field in ["seq_hash", "name_hash"] + decoyFields where text(field) == nil {
            throw SalmonIndexError.indexDisagrees(field: field, expected: "a hash", found: "none")
        }
        return SalmonIndexHashes(
            seqHash: text("seq_hash") ?? "", nameHash: text("name_hash") ?? "",
            decoySeqHash: key.decoys == .genome ? text("decoy_seq_hash") : nil,
            decoyNameHash: key.decoys == .genome ? text("decoy_name_hash") : nil)
    }

    /// The root record: the set's manifest as the input, one salmon step, each file of `index/` and `index-key.json` with
    /// its sha256 as outputs, and the four hashes, so a reader names the index without opening it.
    func makeEnvelope(
        _ file: SalmonIndexKeyFile, set: ReferenceSetOutcome, finalURL: URL, stage: URL, argv: [String], started: Date
    ) throws -> ProvenanceEnvelope {
        var outputs: [ProvenanceFileDescriptor] = []
        let index = stage.appendingPathComponent(Self.indexFolderName, isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: index.path).sorted()
        for relative in names.map({ "\(Self.indexFolderName)/\($0)" }) + [SalmonIndexKeyFile.filename] {
            let url = stage.appendingPathComponent(relative)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), !isFolder.boolValue else { continue }
            outputs.append(ProvenanceFileDescriptor(
                path: finalURL.appendingPathComponent(relative).path, checksumSHA256: try ProvenanceFileHasher.sha256(of: url),
                fileSize: UInt64(max(url.fileSizeBytes, 0)), role: .output))
        }
        let manifest = set.url.appendingPathComponent(ReferenceSetManifest.filename)
        let inputs = [ProvenanceFileDescriptor(path: manifest.path, checksumSHA256: file.referenceSetSHA256, role: .input)]
        var hashes: [String: ParameterValue] = [
            "index_seq_hash": .string(file.indexSeqHash), "index_name_hash": .string(file.indexNameHash),
        ]
        if let hash = file.indexDecoySeqHash { hashes["index_decoy_seq_hash"] = .string(hash) }
        if let hash = file.indexDecoyNameHash { hashes["index_decoy_name_hash"] = .string(hash) }
        let options = ProvenanceOptions(
            explicit: ["set": .string(file.setID), "k": .integer(file.k), "decoys": .string(file.decoys.rawValue)],
            defaults: ["threads": .integer(SalmonIndexNeed.threads), "ramLimit": .integer(SalmonIndexNeed.ramLimitGiB)],
            resolvedDefaults: hashes)
        let step = ProvenanceStep(
            toolName: "salmon", toolVersion: file.salmonVersion, argv: file.argv, exitStatus: 0,
            managedToolID: ManagedToolID(rawValue: "salmon"))
        return ProvenanceEnvelope(
            workflowName: "RNA-seq salmon index", toolName: "lungfish-cli", toolVersion: WorkflowRun.currentAppVersion,
            argv: argv, options: options, files: inputs, outputs: outputs, steps: [step],
            wallTimeSeconds: Date().timeIntervalSince(started), exitStatus: 0, status: .completed)
    }
}

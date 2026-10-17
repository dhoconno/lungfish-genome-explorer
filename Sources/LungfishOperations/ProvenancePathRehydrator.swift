// ProvenancePathRehydrator.swift - Rewrites copied/moved provenance paths
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishWorkflow

package enum ProvenancePathRehydrator {
    /// Rewrites the paths of the records at `destinationURL`, which came from `sourceURL`. A record that verified
    /// before and that the rewrite changed is signed again with `signingProvider`, or reads unsigned with none
    /// (2.11 A68, SW1 (a), plan decision S5).
    package static func rehydrate(
        from sourceURL: URL,
        to destinationURL: URL,
        signingProvider: (any ProvenanceSigningProvider)? = ProvenanceSigningConfiguration.defaultProvider(),
        logFailure: ((String) -> Void)? = nil
    ) {
        let sourcePath = sourceURL.standardizedFileURL.path
        let destinationPath = destinationURL.standardizedFileURL.path
        guard sourcePath != destinationPath else { return }

        let fm = FileManager.default
        let sourceSidecar = URL(fileURLWithPath: sourcePath + ".lungfish-provenance.json")
        let destinationSidecar = URL(fileURLWithPath: destinationPath + ".lungfish-provenance.json")
        if fm.fileExists(atPath: sourceSidecar.path),
           !fm.fileExists(atPath: destinationSidecar.path) {
            do {
                try fm.copyItem(at: sourceSidecar, to: destinationSidecar)
            } catch {
                logFailure?("Failed to copy source provenance sidecar \(sourceSidecar.path): \(error)")
            }
        }
        if let internalBundleProvenance = internalBundleProvenanceURL(for: destinationURL, fileManager: fm),
           fm.fileExists(atPath: sourceSidecar.path),
           !fm.fileExists(atPath: internalBundleProvenance.path) {
            do {
                try fm.copyItem(at: sourceSidecar, to: internalBundleProvenance)
            } catch {
                logFailure?("Failed to copy bundle provenance \(internalBundleProvenance.path): \(error)")
            }
        }

        for provenanceURL in provenanceURLs(for: destinationURL, adjacentSidecar: destinationSidecar, fileManager: fm) {
            do {
                // Records in a project hold project-relative paths; resolve
                // them where the item came from so the prefix rewrite below
                // sees real paths, then store portable paths for its new home.
                let stored = try Data(contentsOf: provenanceURL)
                let verifiedBefore = (try? ProvenanceSignatureVerifier.verify(provenanceURL: provenanceURL)) != nil
                let data = (try? PortablePath.resolveJSON(stored, context: .forFile(at: sourceURL))) ?? stored
                let json = try JSONSerialization.jsonObject(with: data)
                let rehydrated = rehydrateJSONValue(
                    json,
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    key: nil,
                    forcePathStringRewrite: false
                )
                guard JSONSerialization.isValidJSONObject(rehydrated) else { continue }
                let output = try JSONSerialization.data(
                    withJSONObject: rehydrated,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try PortablePath.sanitizeJSON(output, forFileAt: provenanceURL).write(to: provenanceURL, options: .atomic)
                if verifiedBefore, (try? ProvenanceSignatureVerifier.verify(provenanceURL: provenanceURL)) == nil {
                    try rebindSignature(of: provenanceURL, rewritten: output, signingProvider: signingProvider, logFailure: logFailure)
                }
            } catch {
                logFailure?("Failed to rehydrate provenance \(provenanceURL.path): \(error)")
            }
        }
    }

    /// A record that verified before the rewrite and does not after it never keeps the signature that no longer
    /// matches it. With a signer it is signed again through `ProvenanceWriter`, so `provenance verify` passes. With
    /// none, or when signing fails, it is written through the writer with no signature, which removes its signature
    /// file and public key, so it reads unsigned and never tampered (plan decision S5). Only an envelope can be signed
    /// again, so a signed record of another shape loses its pair. A record whose signature failed before the rewrite
    /// is left as it was, since a rename vouches for nothing.
    private static func rebindSignature(
        of provenanceURL: URL,
        rewritten: Data,
        signingProvider: (any ProvenanceSigningProvider)?,
        logFailure: ((String) -> Void)?
    ) throws {
        guard var envelope = try? ProvenanceJSON.decoder.decode(ProvenanceEnvelope.self, from: rewritten) else {
            for artifact in [
                ProvenanceSigningConfiguration.signatureURL(for: provenanceURL),
                ProvenanceSigningConfiguration.publicKeyURL(for: provenanceURL),
            ] where FileManager.default.fileExists(atPath: artifact.path) {
                try FileManager.default.removeItem(at: artifact)
            }
            return
        }
        if let signingProvider {
            do {
                try ProvenanceWriter(signingProvider: signingProvider).write(envelope, toSidecar: provenanceURL)
                return
            } catch {
                logFailure?("Failed to sign rehydrated provenance \(provenanceURL.path) again, so it reads unsigned: \(error)")
            }
        }
        envelope.signatures = []
        try ProvenanceWriter(signingProvider: nil).write(envelope, toSidecar: provenanceURL)
    }

    private static func provenanceURLs(
        for destinationURL: URL,
        adjacentSidecar: URL,
        fileManager fm: FileManager
    ) -> [URL] {
        var urls: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { return }
            urls.append(url)
        }

        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: destinationURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let enumerator = fm.enumerator(
                at: destinationURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            )
            if let enumerator {
                for case let url as URL in enumerator where isRecordFile(url) {
                    append(url)
                }
            }
        } else if isRecordFile(destinationURL) {
            append(destinationURL)
        }

        if fm.fileExists(atPath: adjacentSidecar.path) {
            append(adjacentSidecar)
        }
        if let internalBundleProvenance = internalBundleProvenanceURL(for: destinationURL, fileManager: fm),
           fm.fileExists(atPath: internalBundleProvenance.path) {
            append(internalBundleProvenance)
        }

        return urls
    }

    /// A JSON file whose name holds `provenance` is a record, and the signature file that signing writes beside one
    /// (`<record>.signature.json`, `ProvenanceSigningConfiguration.signatureURL(for:)`) is not (2.11 A68, SW1 (b)).
    private static func isRecordFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return url.pathExtension.lowercased() == "json"
            && name.contains("provenance")
            && !name.hasSuffix(".signature.json")
    }

    private static func internalBundleProvenanceURL(for url: URL, fileManager fm: FileManager) -> URL? {
        guard let bundleRoot = enclosingLungfishBundleRoot(for: url, fileManager: fm) else { return nil }
        return bundleRoot.appendingPathComponent(".lungfish-provenance.json")
    }

    private static func enclosingLungfishBundleRoot(for url: URL, fileManager fm: FileManager) -> URL? {
        var candidate = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            candidate = candidate.deletingLastPathComponent()
        }

        var seenPaths = Set<String>()
        while true {
            let candidatePath = candidate.standardizedFileURL.path
            guard !candidatePath.isEmpty, seenPaths.insert(candidatePath).inserted else { return nil }
            if isLungfishBundleURL(candidate) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent().standardizedFileURL
            let parentPath = parent.path
            guard !parentPath.isEmpty, parentPath != candidatePath else { return nil }
            candidate = parent
        }
    }

    private static func isLungfishBundleURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext.hasPrefix("lungfish") && ext.count > "lungfish".count
    }

    private static func rehydrateJSONValue(
        _ value: Any,
        sourcePath: String,
        destinationPath: String,
        key: String?,
        forcePathStringRewrite: Bool
    ) -> Any {
        if let string = value as? String {
            guard forcePathStringRewrite || key.map(shouldRewritePathValue(forKey:)) == true else { return string }
            return rehydratePathString(string, sourcePath: sourcePath, destinationPath: destinationPath)
        }
        if let dictionary = value as? [String: Any] {
            var rewritten: [String: Any] = [:]
            let typedValueKind = typedParameterValueKind(in: dictionary)
            for (childKey, childValue) in dictionary {
                if preservesExactInvocationValue(forKey: childKey) {
                    rewritten[childKey] = childValue
                    continue
                }
                let childForcePathRewrite = forcePathStringRewrite
                    || (typedValueKind == "file" && normalizeKey(childKey) == "value")
                rewritten[childKey] = rehydrateJSONValue(
                    childValue,
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    key: childKey,
                    forcePathStringRewrite: childForcePathRewrite
                )
            }
            return rewritten
        }
        if let array = value as? [Any] {
            let childForcePathRewrite = forcePathStringRewrite || key.map(shouldRewritePathCollection(forKey:)) == true
            return array.map {
                rehydrateJSONValue(
                    $0,
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    key: nil,
                    forcePathStringRewrite: childForcePathRewrite
                )
            }
        }
        return value
    }

    /// Rewrites a value that is the source path or lies under it. Any other value stays as it was, one that only holds
    /// the source path inside it among them, so a sibling whose name extends the source's, `S-2/x` beside `S`, keeps
    /// its name (2.11 A68, SW1 (c)).
    private static func rehydratePathString(
        _ string: String,
        sourcePath: String,
        destinationPath: String
    ) -> String {
        if string == sourcePath {
            return destinationPath
        }
        let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
        if string.hasPrefix(sourcePrefix) {
            return destinationPath + "/" + string.dropFirst(sourcePrefix.count)
        }
        return string
    }

    private static func preservesExactInvocationValue(forKey key: String) -> Bool {
        let normalized = normalizeKey(key)
        return [
            "argv",
            "args",
            "arguments",
            "command",
            "commandline",
            "executedcommand",
            "reproduciblecommand",
            "shellcommand",
        ].contains(normalized)
    }

    private static func shouldRewritePathValue(forKey key: String) -> Bool {
        let normalized = normalizeKey(key)
        if preservesExactInvocationValue(forKey: key) {
            return false
        }
        if normalized.contains("path") || normalized.contains("url") {
            return true
        }
        return [
            "bundle",
            "destination",
            "dir",
            "directory",
            "file",
            "input",
            "output",
            "payload",
            "source",
        ].contains(normalized)
    }

    private static func shouldRewritePathCollection(forKey key: String) -> Bool {
        let normalized = normalizeKey(key)
        if preservesExactInvocationValue(forKey: key) {
            return false
        }
        if normalized.contains("paths") || normalized.contains("urls") || normalized.contains("files") {
            return true
        }
        return [
            "bundles",
            "directories",
            "inputs",
            "outputs",
            "payloads",
            "sources",
        ].contains(normalized)
    }

    private static func normalizeKey(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func typedParameterValueKind(in dictionary: [String: Any]) -> String? {
        guard let typeValue = dictionary.first(where: { normalizeKey($0.key) == "type" })?.value as? String else {
            return nil
        }
        return normalizeKey(typeValue)
    }
}

// ProvenancePathRehydrator.swift - Rewrites copied/moved provenance paths
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

enum ProvenancePathRehydrator {
    static func rehydrate(
        from sourceURL: URL,
        to destinationURL: URL,
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
                let data = try Data(contentsOf: provenanceURL)
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
                try output.write(to: provenanceURL, options: .atomic)
            } catch {
                logFailure?("Failed to rehydrate provenance \(provenanceURL.path): \(error)")
            }
        }
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
                for case let url as URL in enumerator {
                    guard url.pathExtension.lowercased() == "json",
                          url.lastPathComponent.lowercased().contains("provenance") else {
                        continue
                    }
                    append(url)
                }
            }
        } else if destinationURL.pathExtension.lowercased() == "json",
                  destinationURL.lastPathComponent.lowercased().contains("provenance") {
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
        if string.contains(sourcePath) {
            return string.replacingOccurrences(of: sourcePath, with: destinationPath)
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

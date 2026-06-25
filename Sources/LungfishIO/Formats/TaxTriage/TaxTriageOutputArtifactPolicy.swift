// TaxTriageOutputArtifactPolicy.swift - durable TaxTriage output filtering
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

public enum TaxTriageOutputArtifactPolicy {
    public static let prunableDirectoryNames: Set<String> = [
        "work",
        "download",
        "workflow-source",
    ]

    public static func filterRetainedOutputFiles(
        _ urls: [URL],
        outputDirectory: URL? = nil
    ) -> [URL] {
        urls.filter { isRetainedOutputFile($0, outputDirectory: outputDirectory) }
    }

    public static func isRetainedOutputFile(
        _ url: URL,
        outputDirectory: URL? = nil
    ) -> Bool {
        !isPrunedIntermediatePath(url.path, outputDirectory: outputDirectory)
    }

    public static func isPrunedIntermediatePath(
        _ path: String,
        outputDirectory: URL? = nil
    ) -> Bool {
        let components = pathComponents(for: path, relativeTo: outputDirectory)
        return components.contains { prunableDirectoryNames.contains($0) }
    }

    public static func containsPrunedIntermediatePath(in text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: "\\", with: "/")
        let delimiters = CharacterSet(charactersIn: "/ \n\r\t,:;\"'[]{}()")
        let components = normalized
            .components(separatedBy: delimiters)
            .filter { !$0.isEmpty }
        return components.contains { component in
            prunableDirectoryNames.contains(component)
        }
    }

    private static func pathComponents(for path: String, relativeTo outputDirectory: URL?) -> [String] {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        if let outputDirectory {
            let rootPath = outputDirectory.standardizedFileURL.path
            let normalizedRoot = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if standardizedPath == rootPath {
                return []
            }
            if standardizedPath.hasPrefix(normalizedRoot) {
                let relative = String(standardizedPath.dropFirst(normalizedRoot.count))
                return relative.split(separator: "/").map(String.init)
            }
        }
        return URL(fileURLWithPath: standardizedPath).pathComponents
    }
}

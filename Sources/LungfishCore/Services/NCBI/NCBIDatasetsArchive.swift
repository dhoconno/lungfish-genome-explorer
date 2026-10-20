// NCBIDatasetsArchive.swift - Unpacks the ZIP the NCBI Datasets API returns
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

/// Unpacks a Datasets download with `/usr/bin/unzip` on ``ToolProcess``, so
/// one primitive drains, bounds and cancels the tool.
enum NCBIDatasetsArchive {
    static func extract(
        _ zipURL: URL,
        to directory: URL,
        unzipURL: URL = URL(fileURLWithPath: "/usr/bin/unzip")
    ) async throws {
        let spec = ToolProcessSpec(
            executableURL: unzipURL,
            arguments: ["-q", "-o", zipURL.path, "-d", directory.path],
            environment: ToolProcessSpec.inheritedEnvironment(),
            stdout: .discard,
            stderr: .discard,
            label: "unzip"
        )
        let result: ToolProcessResult
        do {
            result = try await ToolProcess.run(spec)
        } catch ToolProcessError.cancelled {
            throw DatabaseServiceError.cancelled
        }
        guard result.isSuccess else {
            throw DatabaseServiceError.parseError(message: "Failed to extract Datasets ZIP (exit \(result.status))")
        }
        do {
            try verifySymbolicLinksStayInside(directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Refuses any symbolic link under `root` whose target is absolute or
    /// resolves outside `root`, as `SafeZipExtractor` does for a demo project.
    /// unzip already neutralizes `..` and absolute names and refuses a write
    /// through a link, so the links are what an archive can still use to leave.
    static func verifySymbolicLinksStayInside(_ root: URL) throws {
        let fileManager = FileManager.default
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return }
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true else { continue }
            let target = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            if target.hasPrefix("/") || target.hasPrefix("~") {
                throw DatabaseServiceError.parseError(
                    message: "The Datasets download was refused because it holds the symbolic link “\(url.lastPathComponent)” to the absolute path \(target)"
                )
            }
            let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            let resolved = parent.appendingPathComponent(target).standardizedFileURL.path
            guard resolved == canonicalRoot || resolved.hasPrefix(canonicalRoot + "/") else {
                throw DatabaseServiceError.parseError(
                    message: "The Datasets download was refused because it holds the symbolic link “\(url.lastPathComponent)” that points outside its folder (\(target))"
                )
            }
        }
    }
}

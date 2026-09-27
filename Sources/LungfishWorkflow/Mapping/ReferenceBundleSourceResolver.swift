import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

enum ReferenceBundleSourceResolver {
    static func canonicalSourceBundleURL(
        for url: URL?,
        projectURL: URL?
    ) -> URL? {
        guard let url else { return nil }
        guard let bundleURL = enclosingReferenceBundleURL(for: url) else {
            return url.standardizedFileURL
        }
        return canonicalSourceBundleURL(
            for: bundleURL.standardizedFileURL,
            projectURL: projectURL,
            visitedPaths: []
        )
    }

    private static func canonicalSourceBundleURL(
        for bundleURL: URL,
        projectURL: URL?,
        visitedPaths: Set<String>
    ) -> URL {
        let normalized = bundleURL.standardizedFileURL
        guard !visitedPaths.contains(normalized.path) else {
            return normalized
        }

        let updatedVisited = visitedPaths.union([normalized.path])

        if let manifestOriginURL = manifestOriginBundleURL(
            for: normalized,
            projectURL: projectURL
        ),
           manifestOriginURL.standardizedFileURL != normalized {
            return canonicalSourceBundleURL(
                for: manifestOriginURL.standardizedFileURL,
                projectURL: projectURL,
                visitedPaths: updatedVisited
            )
        }

        if let analysisSourceURL = analysisSourceBundleURL(
            for: normalized,
            projectURL: projectURL
        ),
           analysisSourceURL.standardizedFileURL != normalized {
            return canonicalSourceBundleURL(
                for: analysisSourceURL.standardizedFileURL,
                projectURL: projectURL,
                visitedPaths: updatedVisited
            )
        }

        return normalized
    }

    private static func manifestOriginBundleURL(
        for bundleURL: URL,
        projectURL: URL?
    ) -> URL? {
        guard let manifest = try? BundleManifest.load(from: bundleURL),
              let originBundlePath = manifest.originBundlePath,
              !originBundlePath.isEmpty else {
            return nil
        }

        let resolved: URL
        if originBundlePath.hasPrefix("@/"), let projectURL {
            let innerPath = String(originBundlePath.dropFirst(2))
            resolved = projectURL
                .appendingPathComponent(innerPath, isDirectory: true)
                .standardizedFileURL
        } else {
            resolved = FASTQBundle.resolveBundle(
                relativePath: originBundlePath,
                from: bundleURL
            ).standardizedFileURL
        }
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return nil
        }
        return resolved
    }

    private static func analysisSourceBundleURL(
        for bundleURL: URL,
        projectURL: URL?
    ) -> URL? {
        guard let analysisURL = enclosingAnalysisDirectory(
            for: bundleURL,
            projectURL: projectURL
        ) else {
            return nil
        }

        if let provenance = MappingProvenance.load(from: analysisURL),
           let sourceReferenceBundlePath = provenance.sourceReferenceBundlePath,
           !sourceReferenceBundlePath.isEmpty {
            let sourceURL = URL(fileURLWithPath: sourceReferenceBundlePath).standardizedFileURL
            if sourceURL != bundleURL {
                return sourceURL
            }
        }

        if let result = try? MappingResult.load(from: analysisURL),
           let sourceURL = result.sourceReferenceBundleURL?.standardizedFileURL,
           sourceURL != bundleURL {
            return sourceURL
        }

        return nil
    }

    private static func enclosingAnalysisDirectory(
        for url: URL,
        projectURL: URL?
    ) -> URL? {
        guard let projectURL else { return nil }
        return AnalysesFolder.enclosingAnalysisDirectory(for: url, projectURL: projectURL)
    }

    private static func enclosingReferenceBundleURL(for url: URL) -> URL? {
        let normalized = url.standardizedFileURL
        if normalized.pathExtension.lowercased() == "lungfishref" {
            return normalized
        }

        var current = normalized
        while current.pathComponents.count > 1 {
            current = current.deletingLastPathComponent().standardizedFileURL
            if current.pathExtension.lowercased() == "lungfishref" {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    return current
                }
            }
        }

        return nil
    }
}

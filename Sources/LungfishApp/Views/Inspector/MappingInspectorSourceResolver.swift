import Foundation
import LungfishIO

enum MappingInspectorSourceResolver {
    static func resolve(
        name: String,
        path: String?,
        projectURL: URL?
    ) -> MappingDocumentSourceRow {
        guard let path, !path.isEmpty else {
            return .missing(name: name, originalPath: nil)
        }

        let fileManager = FileManager.default
        let candidateURL = URL(fileURLWithPath: path).standardizedFileURL
        guard fileManager.fileExists(atPath: candidateURL.path) else {
            return .missing(name: name, originalPath: path)
        }

        let navigableURL = resolveNavigableURL(for: candidateURL, projectURL: projectURL) ?? candidateURL

        if let projectURL, isURL(navigableURL, inside: projectURL) {
            return .projectLink(name: name, targetURL: navigableURL)
        }
        return .filesystemLink(name: name, fileURL: navigableURL)
    }

    private static func resolveNavigableURL(for url: URL, projectURL: URL?) -> URL? {
        let normalized = url.standardizedFileURL
        if let enclosingReferenceBundleURL = resolveEnclosingReferenceBundleURL(for: normalized),
           let canonicalBundleURL = ReferenceBundleSourceResolver.canonicalSourceBundleURL(
               for: normalized,
               projectURL: projectURL
           ),
           canonicalBundleURL.standardizedFileURL != enclosingReferenceBundleURL,
           FileManager.default.fileExists(atPath: canonicalBundleURL.path) {
            return canonicalBundleURL
        }

        if let projectURL, let analysisURL = resolveAnalysisRowURL(for: normalized, projectURL: projectURL) {
            return analysisURL
        }

        if supportedBundleExtensions.contains(normalized.pathExtension.lowercased()) {
            return normalized
        }

        var current = normalized
        while current.pathComponents.count > 1 {
            current = current.deletingLastPathComponent().standardizedFileURL
            if supportedBundleExtensions.contains(current.pathExtension.lowercased()) {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    return current
                }
            }
        }

        return nil
    }

    private static func resolveEnclosingReferenceBundleURL(for url: URL) -> URL? {
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

    private static func resolveAnalysisRowURL(for url: URL, projectURL: URL) -> URL? {
        AnalysesFolder.enclosingAnalysisDirectory(for: url, projectURL: projectURL)
    }

    private static func isURL(_ url: URL, inside directory: URL) -> Bool {
        let child = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return child.count >= parent.count && child.starts(with: parent)
    }

    private static let supportedBundleExtensions: Set<String> = ["lungfishfastq", "lungfishref"]
}

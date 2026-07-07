import Foundation
import LungfishIO

enum CLIClassificationFolderResolver {
    static func expandInputArguments(_ paths: [String], recursive: Bool) throws -> [URL] {
        var resolved: [URL] = []
        var seen = Set<String>()

        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw CLIError.inputFileNotFound(path: url.path)
            }

            let candidates: [URL]
            if isDirectory.boolValue, !FASTQBundle.isBundleURL(url) {
                candidates = try eligibleReadURLs(in: url, recursive: recursive)
            } else {
                candidates = [url]
            }

            for candidate in candidates {
                let standardized = candidate.standardizedFileURL
                if seen.insert(standardized.path).inserted {
                    resolved.append(standardized)
                }
            }
        }

        return resolved
    }

    private static func eligibleReadURLs(in directory: URL, recursive: Bool) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isPackageKey]
        let options: FileManager.DirectoryEnumerationOptions = recursive
            ? [.skipsHiddenFiles]
            : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: options
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let candidate as URL in enumerator {
            let values = try candidate.resourceValues(forKeys: keys)
            if values.isDirectory == true {
                if FASTQBundle.isBundleURL(candidate) {
                    urls.append(candidate.standardizedFileURL)
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true,
                  SequenceInputResolver.inputSequenceFormat(for: candidate) != nil else {
                continue
            }
            urls.append(candidate.standardizedFileURL)
        }

        return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

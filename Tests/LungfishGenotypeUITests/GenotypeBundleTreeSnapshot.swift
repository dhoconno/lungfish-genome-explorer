import Foundation

/// Everything under a folder, so a test can prove that a read left it as it
/// was. A file rewritten with the same bytes still shows through its
/// modification date, a hidden file such as a lock file or a record shows like
/// any other, and so does a folder that appeared or vanished.
enum GenotypeBundleTreeSnapshot {
    struct Entry: Equatable {
        let bytes: Data
        let modified: Date
        let mode: Int
    }

    /// The entries by path relative to `root`.
    static func entries(of root: URL) throws -> [String: Entry] {
        let resolvedRoot = root.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path
        var found: [String: Entry] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: resolvedRoot,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return found
        }
        for case let url as URL in enumerator {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(rootPath.count))
            switch attributes[.type] as? FileAttributeType {
            case .typeDirectory:
                found[relative] = Entry(bytes: Data(), modified: .distantPast, mode: mode)
            case .typeRegular:
                found[relative] = Entry(
                    bytes: try Data(contentsOf: url),
                    modified: attributes[.modificationDate] as? Date ?? .distantPast,
                    mode: mode
                )
            default:
                break
            }
        }
        return found
    }
}

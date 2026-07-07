import Foundation
import LungfishIO

struct WorkflowSidebarInputSelection: Equatable {
    struct DetailRow: Equatable {
        let url: URL
        let displayPath: String
    }

    let directReadURLs: [URL]
    let recursiveReadURLs: [URL]
    let detailRows: [DetailRow]
    let recursiveDetailRows: [DetailRow]
    let folderSelectionCount: Int
    let explicitBundleCount: Int
    let duplicateBundleCount: Int
    let recursiveDuplicateBundleCount: Int
    let skippedItemCount: Int
    let selectedFolderNames: [String]
    let emptyFolderNames: [String]
    let additionalDescendantBundleCount: Int

    init(
        directReadURLs: [URL],
        recursiveReadURLs: [URL],
        detailRows: [DetailRow],
        recursiveDetailRows: [DetailRow]? = nil,
        folderSelectionCount: Int,
        explicitBundleCount: Int,
        duplicateBundleCount: Int,
        recursiveDuplicateBundleCount: Int? = nil,
        skippedItemCount: Int,
        selectedFolderNames: [String],
        emptyFolderNames: [String],
        additionalDescendantBundleCount: Int
    ) {
        self.directReadURLs = directReadURLs
        self.recursiveReadURLs = recursiveReadURLs
        self.detailRows = detailRows
        self.recursiveDetailRows = recursiveDetailRows ?? detailRows
        self.folderSelectionCount = folderSelectionCount
        self.explicitBundleCount = explicitBundleCount
        self.duplicateBundleCount = duplicateBundleCount
        self.recursiveDuplicateBundleCount = recursiveDuplicateBundleCount ?? duplicateBundleCount
        self.skippedItemCount = skippedItemCount
        self.selectedFolderNames = selectedFolderNames
        self.emptyFolderNames = emptyFolderNames
        self.additionalDescendantBundleCount = additionalDescendantBundleCount
    }

    var hasAdditionalDescendantBundles: Bool {
        additionalDescendantBundleCount > 0
    }

    var duplicateSummaryText: String? {
        duplicateSummaryText(includeSubfolders: false)
    }

    var emptyFolderSummaryText: String? {
        guard let first = emptyFolderNames.first else { return nil }
        if emptyFolderNames.count == 1 {
            return "No eligible FASTQ bundles were found directly in \"\(first)\"."
        }
        return "No eligible FASTQ bundles were found directly in \(emptyFolderNames.count) selected folders."
    }

    var subfolderSummaryText: String? {
        guard additionalDescendantBundleCount > 0 else { return nil }
        let noun = additionalDescendantBundleCount == 1 ? "bundle" : "bundles"
        return "Subfolders contain \(additionalDescendantBundleCount) additional eligible FASTQ \(noun)."
    }

    func selectedReadURLs(includeSubfolders: Bool) -> [URL] {
        includeSubfolders ? recursiveReadURLs : directReadURLs
    }

    func detailRows(includeSubfolders: Bool) -> [DetailRow] {
        includeSubfolders ? recursiveDetailRows : detailRows
    }

    func duplicateSummaryText(includeSubfolders: Bool) -> String? {
        let count = includeSubfolders ? recursiveDuplicateBundleCount : duplicateBundleCount
        guard count > 0 else { return nil }
        let noun = count == 1 ? "bundle" : "bundles"
        return "Skipped \(count) duplicate \(noun) already included by another selected item."
    }

    func summaryText(includeSubfolders: Bool) -> String {
        let count = selectedReadURLs(includeSubfolders: includeSubfolders).count
        let bundleNoun = count == 1 ? "bundle" : "bundles"
        if folderSelectionCount == 1, explicitBundleCount == 0 {
            let selectedCount = includeSubfolders ? recursiveReadURLs.count : directReadURLs.count
            if selectedCount == 0, let emptyFolderSummaryText {
                return emptyFolderSummaryText
            }
            let folderLabel = selectedFolderNames.first ?? "selected folder"
            return "Folder \"\(folderLabel)\" expands to \(selectedCount) eligible FASTQ \(bundleNoun)."
        }
        if folderSelectionCount > 1, explicitBundleCount == 0 {
            return "\(folderSelectionCount) folders selected: \(count) eligible FASTQ \(bundleNoun). They will run as one batch."
        }
        if folderSelectionCount > 0 {
            let folderNoun = folderSelectionCount == 1 ? "folder" : "folders"
            let explicitNoun = explicitBundleCount == 1 ? "explicit bundle" : "explicit bundles"
            return "\(count) FASTQ \(bundleNoun) selected from \(folderSelectionCount) \(folderNoun) and \(explicitBundleCount) \(explicitNoun)."
        }
        return count == 0 ? "No read bundles selected" : "\(count) FASTQ \(bundleNoun) selected."
    }

    static func resolve(items: [SidebarItem], projectURL: URL?) -> WorkflowSidebarInputSelection {
        var directURLs: [URL] = []
        var recursiveURLs: [URL] = []
        var directDetailRows: [DetailRow] = []
        var recursiveDetailRows: [DetailRow] = []
        var directSeen = Set<String>()
        var recursiveSeen = Set<String>()
        var directDuplicateCount = 0
        var recursiveDuplicateCount = 0
        var skippedCount = 0
        var folderCount = 0
        var folderNames: [String] = []
        var explicitCount = 0
        var emptyFolders: [String] = []

        func appendDirect(_ url: URL) {
            let standardized = url.standardizedFileURL
            if directSeen.insert(standardized.path).inserted {
                directURLs.append(standardized)
                directDetailRows.append(
                    DetailRow(
                        url: standardized,
                        displayPath: WorkflowSidebarInputSelection.displayPath(for: standardized, relativeTo: projectURL)
                    )
                )
            } else {
                directDuplicateCount += 1
            }
        }

        func appendRecursive(_ url: URL) {
            let standardized = url.standardizedFileURL
            if recursiveSeen.insert(standardized.path).inserted {
                recursiveURLs.append(standardized)
                recursiveDetailRows.append(
                    DetailRow(
                        url: standardized,
                        displayPath: WorkflowSidebarInputSelection.displayPath(for: standardized, relativeTo: projectURL)
                    )
                )
            } else {
                recursiveDuplicateCount += 1
            }
        }

        for item in items {
            guard item.type != .group else {
                skippedCount += 1
                continue
            }

            if item.type == .fastqBundle {
                if let url = fastqBundleURL(for: item) {
                    explicitCount += 1
                    appendDirect(url)
                    appendRecursive(url)
                } else {
                    skippedCount += 1
                }
                continue
            }

            if item.type == .folder || item.type == .project {
                folderCount += 1
                folderNames.append(item.title)
                let directChildren = directReadChildren(of: item)
                if directChildren.isEmpty {
                    emptyFolders.append(item.title)
                }
                for child in directChildren {
                    if let url = readURL(for: child) {
                        appendDirect(url)
                        appendRecursive(url)
                    }
                }

                let recursiveChildren = recursiveReadChildren(of: item)
                let directPaths = Set(directChildren.compactMap { readURL(for: $0)?.standardizedFileURL.path })
                for child in recursiveChildren {
                    guard let url = readURL(for: child) else { continue }
                    if directPaths.contains(url.standardizedFileURL.path) {
                        continue
                    }
                    appendRecursive(url)
                }
                continue
            }

            skippedCount += 1
        }

        let additionalDescendantCount = recursiveURLs.filter { !directSeen.contains($0.path) }.count

        return WorkflowSidebarInputSelection(
            directReadURLs: directURLs,
            recursiveReadURLs: recursiveURLs,
            detailRows: directDetailRows,
            recursiveDetailRows: recursiveDetailRows,
            folderSelectionCount: folderCount,
            explicitBundleCount: explicitCount,
            duplicateBundleCount: directDuplicateCount,
            recursiveDuplicateBundleCount: recursiveDuplicateCount,
            skippedItemCount: skippedCount,
            selectedFolderNames: folderNames,
            emptyFolderNames: emptyFolders,
            additionalDescendantBundleCount: additionalDescendantCount
        )
    }

    private static func fastqBundleURL(for item: SidebarItem) -> URL? {
        guard item.type == .fastqBundle, let url = item.url else { return nil }
        return resolveReadBundleURL(from: url)
    }

    private static func readURL(for item: SidebarItem) -> URL? {
        if let bundleURL = fastqBundleURL(for: item) {
            return bundleURL
        }
        guard item.type == .sequence, let url = item.url else { return nil }
        let standardizedURL = url.standardizedFileURL
        if let bundleURL = SequenceInputResolver.enclosingFASTQBundleURL(for: standardizedURL) {
            return bundleURL
        }
        if SequenceInputResolver.inputSequenceFormat(for: standardizedURL) != nil {
            return standardizedURL
        }
        return nil
    }

    private static func resolveReadBundleURL(from url: URL) -> URL? {
        let standardizedURL = url.standardizedFileURL
        if standardizedURL.pathExtension.lowercased() == FASTQBundle.directoryExtension {
            return standardizedURL
        }
        return SequenceInputResolver.enclosingFASTQBundleURL(for: standardizedURL)
    }

    private static func directReadChildren(of item: SidebarItem) -> [SidebarItem] {
        item.children.filter { readURL(for: $0) != nil }
    }

    private static func recursiveReadChildren(of item: SidebarItem) -> [SidebarItem] {
        var result: [SidebarItem] = []
        func visit(_ current: SidebarItem) {
            for child in current.children {
                if readURL(for: child) != nil {
                    result.append(child)
                    continue
                }
                if child.type == .folder || child.type == .project {
                    visit(child)
                }
            }
        }
        visit(item)
        return result
    }

    private static func displayPath(for url: URL, relativeTo projectURL: URL?) -> String {
        guard let projectURL else { return url.lastPathComponent }
        let projectPath = projectURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == projectPath || path.hasPrefix(projectPath + "/") else {
            return url.lastPathComponent
        }
        let relative = String(path.dropFirst(projectPath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? url.lastPathComponent : relative
    }
}

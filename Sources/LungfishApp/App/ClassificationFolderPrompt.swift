import AppKit

struct ClassificationFolderInput: Equatable {
    let directReadURLs: [URL]
    let recursiveReadURLs: [URL]
    let additionalDescendantCount: Int
    let folderSelectionCount: Int

    var hasSubfolderBundles: Bool { additionalDescendantCount > 0 }
    var isEmpty: Bool { directReadURLs.isEmpty && recursiveReadURLs.isEmpty }
}

enum SubfolderInclusionChoice {
    case topLevelOnly
    case includeSubfolders
    case cancel
}

enum ClassificationFolderPrompt {
    static func readURLs(for choice: SubfolderInclusionChoice, from input: ClassificationFolderInput) -> [URL]? {
        switch choice {
        case .topLevelOnly:
            return input.directReadURLs
        case .includeSubfolders:
            return input.recursiveReadURLs
        case .cancel:
            return nil
        }
    }

    @MainActor
    static func present(
        for input: ClassificationFolderInput,
        in window: NSWindow,
        completion: @escaping (SubfolderInclusionChoice) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Include Subfolders?"
        let count = input.additionalDescendantCount
        let noun = count == 1 ? "sample" : "samples"
        alert.informativeText = "The selected folder's subfolders contain \(count) additional eligible FASTQ/FASTA \(noun). Process only the top-level samples, or include the subfolders?"
        alert.addButton(withTitle: "Include Subfolders")
        alert.addButton(withTitle: "Top Level Only")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                completion(.includeSubfolders)
            case .alertSecondButtonReturn:
                completion(.topLevelOnly)
            default:
                completion(.cancel)
            }
        }
    }
}

extension AppDelegate {
    nonisolated static func classificationFolderInput(items: [SidebarItem], projectURL: URL?) -> ClassificationFolderInput {
        let selection = WorkflowSidebarInputSelection.resolve(items: items, projectURL: projectURL)
        return ClassificationFolderInput(
            directReadURLs: selection.directReadURLs,
            recursiveReadURLs: selection.recursiveReadURLs,
            additionalDescendantCount: selection.additionalDescendantBundleCount,
            folderSelectionCount: selection.folderSelectionCount
        )
    }
}

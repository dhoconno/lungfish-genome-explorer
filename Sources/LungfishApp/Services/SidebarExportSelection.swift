import Foundation

/// Shared ordered partition for menu and sidebar export eligibility. Bundle
/// capabilities remain the authority for supported scientific formats.
struct SidebarExportSelection {
    enum Format { case sequences, fastq }
    let exportable: [SidebarItem]
    let skipped: [SidebarItem]
    var hasExportableItems: Bool { !exportable.isEmpty }
    var skippedDescriptions: [String] { skipped.map(\.title) }

    init(_ items: [SidebarItem], format: Format) {
        self.init(items, matching: { item in
            switch format {
            case .sequences: return item.type == .sequence || item.type.bundleCapabilities.canExportSequences
            case .fastq: return item.type == .fastqBundle && item.url != nil
            }
        })
    }

    private init(_ items: [SidebarItem], matching eligible: (SidebarItem) -> Bool) {
        var exportable: [SidebarItem] = []
        var skipped: [SidebarItem] = []
        for item in items {
            if eligible(item) { exportable.append(item) } else { skipped.append(item) }
        }
        self.exportable = exportable
        self.skipped = skipped
    }

    static func annotations(_ items: [SidebarItem], loadedDocumentURL: URL? = nil,
                            loadedDocumentID: UUID? = nil, loadedNativeSequenceID: UUID? = nil,
                            hasLoadedAnnotations: Bool = false) -> Self {
        Self(items, matching: { item in
            guard item.url != nil else { return false }
            return item.type.bundleCapabilities.canExportAnnotations
                || (hasLoadedAnnotations && matchesLoadedDocument(item, url: loadedDocumentURL,
                    id: loadedDocumentID, nativeSequenceID: loadedNativeSequenceID))
        })
    }

    /// Stored records and external documents can share a display path. An
    /// explicit row identity must never fall back to a different document URL.
    static func matchesLoadedDocument(_ item: SidebarItem, url: URL?, id: UUID?, nativeSequenceID: UUID? = nil) -> Bool {
        if let rowID = item.userInfo["documentID"] {
            guard let documentID = UUID(uuidString: rowID) else { return false }
            return documentID == id
        }
        guard nativeSequenceID == nil, let itemURL = item.url, let url else { return false }
        return itemURL.standardizedFileURL == url.standardizedFileURL
    }
}

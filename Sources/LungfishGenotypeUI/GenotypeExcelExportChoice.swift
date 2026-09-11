import Foundation

public enum GenotypeExcelExportRole: String, CaseIterable, Identifiable, Sendable {
    case filteredView
    case editableWorkbook

    public var id: Self { self }

    public var title: String {
        switch self {
        case .filteredView: "Filtered view"
        case .editableWorkbook: "Editable workbook — current.xlsx"
        }
    }

    public var explanation: String {
        switch self {
        case .filteredView:
            "Share what you see in LGE, with the current filters, haplotype calls, and annotations. Changes in this file do not return to LGE."
        case .editableWorkbook:
            "Work with all evidence in Excel, including reads hidden by LGE filters. Supported edits can be reviewed and imported back into LGE."
        }
    }
}

@MainActor
public final class GenotypeExcelExportChoiceModel {
    public var role: GenotypeExcelExportRole

    public init(role: GenotypeExcelExportRole = .filteredView) {
        self.role = role
    }

    public var primaryActionTitle: String {
        role == .filteredView ? "Export…" : "Open in Excel"
    }
}

public struct GenotypeFilteredExportPresentation: Equatable, Sendable {
    public let url: URL
    public let isAvailable: Bool
    public let unavailableReason: String?
}

public enum GenotypeFilteredExportEvent: Sendable {
    case started
    case succeeded(URL)
    case failed(String)
}

@MainActor
public final class GenotypeFilteredExportSessionState {
    private var latestURL: URL?
    public private(set) var statusText: String?
    public private(set) var isExporting = false
    private let fileExists: (URL) -> Bool

    public init(fileExists: @escaping (URL) -> Bool = {
        FileManager.default.fileExists(atPath: $0.path)
    }) {
        self.fileExists = fileExists
    }

    public var presentation: GenotypeFilteredExportPresentation? {
        guard let latestURL else { return nil }
        let available = fileExists(latestURL)
        return .init(
            url: latestURL,
            isAvailable: available,
            unavailableReason: available ? nil
                : "The last filtered export is no longer available at its saved location."
        )
    }

    public func recordSuccessfulExport(_ url: URL) {
        latestURL = url.standardizedFileURL
        isExporting = false
        statusText = "Filtered export completed."
    }

    public func recordCancelledOrFailedExport() {}

    public func beginExport() {
        isExporting = true
        statusText = "Exporting filtered workbook…"
    }

    public func recordFailedExport(_ message: String) {
        isExporting = false
        statusText = "Filtered export failed — \(message)"
    }

    public func clear() {
        latestURL = nil
        statusText = nil
        isExporting = false
    }
}

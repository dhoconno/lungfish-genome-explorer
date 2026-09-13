import Foundation

public struct GenotypeExcelExportPresentation: Equatable, Sendable {
    public let url: URL
    public let isAvailable: Bool
    public let unavailableReason: String?
}

public enum GenotypeExcelExportEvent: Sendable {
    case started
    case succeeded(URL)
    case failed(String)
}

@MainActor
public final class GenotypeExcelExportSessionState {
    public static let disclosure = "Includes all results and the current filtered view. This is a snapshot; make edits in LGE and export again. Filtering does not remove data from the All worksheet."
    private var latestURL: URL?
    public private(set) var statusText: String?
    public private(set) var isExporting = false
    private let fileExists: (URL) -> Bool

    public init(fileExists: @escaping (URL) -> Bool = {
        FileManager.default.fileExists(atPath: $0.path)
    }) {
        self.fileExists = fileExists
    }

    public var presentation: GenotypeExcelExportPresentation? {
        guard let latestURL else { return nil }
        let available = fileExists(latestURL)
        return .init(
            url: latestURL,
            isAvailable: available,
            unavailableReason: available ? nil
                : "The last Excel export is no longer available at its saved location."
        )
    }

    public func recordSuccessfulExport(_ url: URL) {
        latestURL = url.standardizedFileURL
        isExporting = false
        statusText = "Excel export completed."
    }

    public func recordCancelledOrFailedExport() {}

    public func beginExport() {
        isExporting = true
        statusText = "Exporting Excel workbook…"
    }

    public func recordFailedExport(_ message: String) {
        isExporting = false
        statusText = "Excel export failed — \(message)"
    }

    public func clear() {
        latestURL = nil
        statusText = nil
        isExporting = false
    }
}

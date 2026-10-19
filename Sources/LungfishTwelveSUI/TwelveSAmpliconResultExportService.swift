import Foundation
import LungfishKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import UniformTypeIdentifiers

public enum TwelveSAmpliconResultExportFormat: String, CaseIterable, Identifiable, Sendable {
    case csv
    case tsv
    case excel

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .csv: return "CSV"
        case .tsv: return "TSV"
        case .excel: return "Excel"
        }
    }

    /// The format sheet's button title, a verb phrase as the HIG asks.
    public var sheetButtonTitle: String {
        switch self {
        case .csv: return "Export CSV"
        case .tsv: return "Export TSV"
        case .excel: return "Export Excel Workbook"
        }
    }

    public var fileExtension: String {
        switch self {
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .excel: return "xlsx"
        }
    }

    public var cliValue: String {
        switch self {
        case .csv: return "csv"
        case .tsv: return "tsv"
        case .excel: return "xlsx"
        }
    }

    public var contentType: UTType {
        switch self {
        case .csv:
            return .commaSeparatedText
        case .tsv:
            return UTType(filenameExtension: "tsv") ?? .plainText
        case .excel:
            return UTType(filenameExtension: "xlsx") ?? .data
        }
    }
}

struct TwelveSAmpliconResultExportSnapshot: Equatable {
    let bundleURL: URL
    let analysisName: String
    let sampleNames: [String]
    let filters: TwelveSResultDisplayState
    let rows: [TwelveSScientificNameCountRow]
    let unresolvedRows: [TwelveSUnresolvedSequence]
}

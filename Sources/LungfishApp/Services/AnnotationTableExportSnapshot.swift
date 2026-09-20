import Foundation
import LungfishWorkflow

enum AnnotationTableExportScope: String, Codable, Sendable {
    case allMatching
    case selected
}

struct AnnotationTableExportSnapshot: Codable, Sendable, Equatable {
    let table: ScientificTableData
    let tab: String
    let scope: AnnotationTableExportScope
    let rowIdentities: [String]
    let sourceURLs: [URL]
    let queryDescription: [String: String]
    let coordinateConventions: [String: String]

    static func captureAnnotations(
        _ rows: [AnnotationSearchIndex.SearchResult],
        columns: [ScientificTableColumn],
        scope: AnnotationTableExportScope,
        sourceURLs: [URL],
        queryDescription: [String: String],
        resolvedText: [String: [String: String]] = [:]
    ) -> Self {
        let exportedColumns = columns.map { column -> ScientificTableColumn in
            switch column.id {
            case "StartColumn": return .init(id: column.id, title: "Start (0-based)")
            case "EndColumn": return .init(id: column.id, title: "End (0-based, exclusive)")
            case "SizeColumn": return .init(id: column.id, title: "Size (bp)")
            default: return column
            }
        }
        return Self(
            table: .init(name: "Annotations", columns: exportedColumns, rows: rows.map { row in
                columns.map { annotationCell(row, columnID: $0.id, resolvedText: resolvedText[annotationIdentity(row)] ?? [:]) }
            }),
            tab: "annotations",
            scope: scope,
            rowIdentities: rows.map(annotationIdentity),
            sourceURLs: sourceURLs,
            queryDescription: queryDescription,
            coordinateConventions: [
                "StartColumn": "0-based inclusive genomic start",
                "EndColumn": "0-based exclusive genomic end",
                "SizeColumn": "end minus start in base pairs",
            ]
        )
    }

    static func captureVariants(
        _ rows: [AnnotationSearchIndex.SearchResult],
        columns: [ScientificTableColumn],
        scope: AnnotationTableExportScope,
        numericInfoColumnIDs: Set<String>,
        integerInfoColumnIDs: Set<String> = [],
        sourceURLs: [URL],
        queryDescription: [String: String],
        resolvedText: [String: [String: String]] = [:]
    ) -> Self {
        let exportedColumns = columns.map {
            $0.id == "PositionColumn" ? .init(id: $0.id, title: "Position (1-based)") : $0
        }
        return Self(
            table: .init(name: "Variants", columns: exportedColumns, rows: rows.map { row in
                columns.map {
                    variantCell(
                        row,
                        columnID: $0.id,
                        numericInfoColumnIDs: numericInfoColumnIDs,
                        integerInfoColumnIDs: integerInfoColumnIDs,
                        resolvedText: resolvedText[variantIdentity(row)] ?? [:]
                    )
                }
            }),
            tab: "variants",
            scope: scope,
            rowIdentities: rows.map(variantIdentity),
            sourceURLs: sourceURLs,
            queryDescription: queryDescription,
            coordinateConventions: ["PositionColumn": "1-based genomic position"]
        )
    }

    static func captureSamples(
        _ rows: [AnnotationTableDrawerView.SampleDisplayRow],
        columns: [ScientificTableColumn],
        scope: AnnotationTableExportScope,
        sourceURLs: [URL],
        queryDescription: [String: String]
    ) -> Self {
        Self(
            table: .init(name: "Samples", columns: columns, rows: rows.map { row in
                columns.map { sampleCell(row, columnID: $0.id) }
            }),
            tab: "samples",
            scope: scope,
            rowIdentities: rows.map(\.rowKey),
            sourceURLs: sourceURLs,
            queryDescription: queryDescription,
            coordinateConventions: [:]
        )
    }

    static func captureGenotypes(
        _ rows: [AnnotationTableDrawerView.GenotypeDisplayRow],
        columns: [ScientificTableColumn],
        scope: AnnotationTableExportScope,
        numericInfoColumnIDs: Set<String>,
        integerInfoColumnIDs: Set<String> = [],
        sourceURLs: [URL],
        queryDescription: [String: String]
    ) -> Self {
        let exportedColumns = columns.map {
            $0.id == "GTPositionColumn" ? .init(id: $0.id, title: "Position (1-based)") : $0
        }
        return Self(
            table: .init(name: "Genotypes", columns: exportedColumns, rows: rows.map { row in
                columns.map { genotypeCell(
                    row, columnID: $0.id,
                    numericInfoColumnIDs: numericInfoColumnIDs,
                    integerInfoColumnIDs: integerInfoColumnIDs
                ) }
            }),
            tab: "genotypes",
            scope: scope,
            rowIdentities: rows.map { "\($0.trackId):\($0.variantRowId):\($0.sampleName)" },
            sourceURLs: sourceURLs,
            queryDescription: queryDescription,
            coordinateConventions: ["GTPositionColumn": "1-based genomic position"]
        )
    }

    private static func annotationIdentity(_ row: AnnotationSearchIndex.SearchResult) -> String {
        "\(row.trackId):\(row.annotationRowId.map(String.init) ?? row.id.uuidString)"
    }

    private static func variantIdentity(_ row: AnnotationSearchIndex.SearchResult) -> String {
        "\(row.trackId):\(row.variantRowId.map(String.init) ?? row.id.uuidString)"
    }

    private static func annotationCell(
        _ row: AnnotationSearchIndex.SearchResult,
        columnID: String,
        resolvedText: [String: String]
    ) -> ScientificTableCell {
        switch columnID {
        case "NameColumn": return text(row.name)
        case "TrackIdColumn": return text(row.trackId)
        case "TrackNameColumn": return text(row.trackName ?? row.trackId)
        case "TypeColumn": return text(row.type)
        case "ChromosomeColumn": return text(row.chromosome)
        case "StartColumn": return .integer(Int64(row.start))
        case "EndColumn": return .integer(Int64(row.end))
        case "SizeColumn": return .integer(Int64(row.end - row.start))
        case "StrandColumn": return text(row.strand)
        default:
            if columnID.hasPrefix("attr_") {
                return text(row.attributes?[String(columnID.dropFirst(5))])
            }
            return text(resolvedText[columnID])
        }
    }

    private static func variantCell(
        _ row: AnnotationSearchIndex.SearchResult,
        columnID: String,
        numericInfoColumnIDs: Set<String>,
        integerInfoColumnIDs: Set<String>,
        resolvedText: [String: String]
    ) -> ScientificTableCell {
        switch columnID {
        case "VariantIdColumn": return text(row.name)
        case "VariantTypeColumn": return text(row.type)
        case "VariantChromColumn": return text(row.chromosome)
        case "PositionColumn": return .integer(Int64(row.start + 1))
        case "RefColumn": return text(row.ref)
        case "AltColumn": return text(row.alt)
        case "QualityColumn": return row.quality.flatMap { $0 >= 0 ? .number($0) : nil } ?? .empty
        case "FilterColumn": return text(row.filter)
        case "SamplesColumn": return row.sampleCount.map { .integer(Int64($0)) } ?? .empty
        case "TrackIdColumn": return text(row.trackId)
        case "TrackNameColumn": return text(row.trackName ?? row.trackId)
        case "SourceColumn": return text(row.sourceFile)
        default:
            if columnID.hasPrefix("info_") {
                let value = row.infoDict?[String(columnID.dropFirst(5))]
                if integerInfoColumnIDs.contains(columnID), let value, !value.contains(","), let integer = Int64(value) {
                    return .integer(integer)
                }
                if numericInfoColumnIDs.contains(columnID), let value, !value.contains(","), let number = Double(value) {
                    return .number(number)
                }
                return text(value)
            }
            return text(resolvedText[columnID])
        }
    }

    private static func sampleCell(
        _ row: AnnotationTableDrawerView.SampleDisplayRow,
        columnID: String
    ) -> ScientificTableCell {
        switch columnID {
        case "SampleVisibleColumn": return .boolean(row.isVisible)
        case "SampleNameColumn": return text(row.name)
        case "SampleDisplayNameColumn": return text(row.displayName)
        case "SampleSourceColumn": return text(row.sourceFile)
        default:
            if columnID.hasPrefix("meta_") { return text(row.metadata[String(columnID.dropFirst(5))]) }
            return .empty
        }
    }

    private static func genotypeCell(
        _ row: AnnotationTableDrawerView.GenotypeDisplayRow,
        columnID: String,
        numericInfoColumnIDs: Set<String>,
        integerInfoColumnIDs: Set<String>
    ) -> ScientificTableCell {
        switch columnID {
        case "GTSampleColumn": return text(row.sampleName)
        case "GTTrackColumn": return text(row.trackName)
        case "GTVariantColumn": return text(row.variantID)
        case "GTChromColumn": return text(row.chromosome)
        case "GTPositionColumn": return .integer(Int64(row.position + 1))
        case "GTGenotypeColumn": return text(row.genotype)
        case "GTZygosityColumn": return text(row.zygosity)
        case "GTADColumn": return text(row.alleleDepths)
        case "GTDPColumn": return row.depth.map { .integer(Int64($0)) } ?? .empty
        case "GTGQColumn": return row.genotypeQuality.map { .integer(Int64($0)) } ?? .empty
        case "GTABColumn": return row.alleleBalance.map(ScientificTableCell.number) ?? .empty
        default:
            if columnID.hasPrefix("gtinfo_") {
                let value = row.infoDict[String(columnID.dropFirst(7))]
                if integerInfoColumnIDs.contains(columnID), let value, !value.contains(","), let integer = Int64(value) {
                    return .integer(integer)
                }
                if numericInfoColumnIDs.contains(columnID), let value, !value.contains(","), let number = Double(value) {
                    return .number(number)
                }
                return text(value)
            }
            return .empty
        }
    }

    private static func text(_ value: String?) -> ScientificTableCell {
        guard let value, !value.isEmpty, value != "." else { return .empty }
        return .text(value)
    }
}

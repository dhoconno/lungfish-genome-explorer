import Foundation
import LungfishCore
import LungfishIO

public struct MSAReferenceSequenceInput: Sendable, Equatable {
    public let rowID: String
    public let rowName: String
    public let sourceName: String
    public let outputName: String
    public let alignedSequence: String
    public let alignedColumns: [Int]
    public let coordinateMap: MultipleSequenceAlignmentBundle.RowCoordinateMap

    public init(
        rowID: String,
        rowName: String,
        sourceName: String,
        outputName: String,
        alignedSequence: String,
        alignedColumns: [Int],
        coordinateMap: MultipleSequenceAlignmentBundle.RowCoordinateMap
    ) {
        self.rowID = rowID
        self.rowName = rowName
        self.sourceName = sourceName
        self.outputName = outputName
        self.alignedSequence = alignedSequence
        self.alignedColumns = alignedColumns
        self.coordinateMap = coordinateMap
    }
}

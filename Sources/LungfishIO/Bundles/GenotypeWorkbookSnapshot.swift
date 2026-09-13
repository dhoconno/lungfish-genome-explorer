import Foundation

extension GenotypeWorkbookPresentation {
    public struct Matrix: Codable, Sendable {
        public let samples: [Sample]
        public let loci: [String]
        public let rows: [Row]

        public init(samples: [Sample], loci: [String], rows: [Row]) {
            self.samples = samples
            self.loci = loci
            self.rows = rows
        }
    }

    public struct Snapshot: Codable, Sendable {
        public let schemaVersion: Int
        public let generatedAt: String
        public let sourceRevision: [String: String]
        public let allMatrix: Matrix
        public let filteredMatrix: Matrix
        public let calls: [Call]
        public let colors: [Color]
        public let hasHaplotypeContent: Bool
        public let metadata: [[String]]

        public init(
            schemaVersion: Int = 3,
            generatedAt: String,
            sourceRevision: [String: String],
            allMatrix: Matrix,
            filteredMatrix: Matrix,
            calls: [Call],
            colors: [Color],
            hasHaplotypeContent: Bool,
            metadata: [[String]]
        ) {
            self.schemaVersion = schemaVersion
            self.generatedAt = generatedAt
            self.sourceRevision = sourceRevision
            self.allMatrix = allMatrix
            self.filteredMatrix = filteredMatrix
            self.calls = calls
            self.colors = colors
            self.hasHaplotypeContent = hasHaplotypeContent
            self.metadata = metadata
        }
    }
}

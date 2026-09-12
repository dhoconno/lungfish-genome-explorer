import Foundation

public enum GenotypeWorkbookPresentation {
    public struct Payload: Codable, Sendable {
        public let schemaVersion: Int
        public let role: String
        public let sourceRevision: [String: String]
        public let samples: [Sample]
        public let loci: [String]
        public let rows: [Row]
        public let calls: [Call]
        public let colors: [Color]
        public let metadata: [[String]]
        public let callEditingSupported: Bool

        public init(schemaVersion: Int, role: String, sourceRevision: [String: String], samples: [Sample], loci: [String], rows: [Row], calls: [Call], colors: [Color], metadata: [[String]], callEditingSupported: Bool) {
            self.schemaVersion = schemaVersion
            self.role = role
            self.sourceRevision = sourceRevision
            self.samples = samples
            self.loci = loci
            self.rows = rows
            self.calls = calls
            self.colors = colors
            self.metadata = metadata
            self.callEditingSupported = callEditingSupported
        }
    }

    public struct Sample: Codable, Sendable {
        public let id: String
        public let name: String
        public let comment: String?

        public init(id: String, name: String, comment: String?) {
            self.id = id
            self.name = name
            self.comment = comment
        }
    }

    public struct Target: Codable, Sendable {
        public let kind: String
        public let locus: String
        public let genotype: String
        public let stableClusterID: String?

        public init(kind: String, locus: String, genotype: String, stableClusterID: String?) {
            self.kind = kind
            self.locus = locus
            self.genotype = genotype
            self.stableClusterID = stableClusterID
        }
    }

    public struct Cell: Codable, Sendable {
        public let sampleID: String
        public let displayValue: Int?
        public let rawSupport: Int?
        public let reviewEligible: Bool
        public let fillHex: String?
        public let comment: String?
        public let review: String?

        public init(sampleID: String, displayValue: Int?, rawSupport: Int?, reviewEligible: Bool, fillHex: String?, comment: String?, review: String?) {
            self.sampleID = sampleID
            self.displayValue = displayValue
            self.rawSupport = rawSupport
            self.reviewEligible = reviewEligible
            self.fillHex = fillHex
            self.comment = comment
            self.review = review
        }
    }

    public struct Row: Codable, Sendable {
        public let id: String
        public let target: Target
        public let displayName: String
        public let comment: String?
        public let fillHex: String?
        public var cells: [Cell]

        public init(id: String, target: Target, displayName: String, comment: String?, fillHex: String?, cells: [Cell]) {
            self.id = id
            self.target = target
            self.displayName = displayName
            self.comment = comment
            self.fillHex = fillHex
            self.cells = cells
        }
    }

    public struct Slot: Codable, Sendable {
        public let effective: String
        public let pipeline: String?
        public let baselineAvailable: Bool
        public let status: String
        public let source: String

        public init(effective: String, pipeline: String?, baselineAvailable: Bool, status: String, source: String) {
            self.effective = effective
            self.pipeline = pipeline
            self.baselineAvailable = baselineAvailable
            self.status = status
            self.source = source
        }
    }

    public struct Call: Codable, Sendable {
        public let id: String
        public let sampleID: String
        public let locus: String
        public let h1: Slot
        public let h2: Slot
        public let comment: String?

        public init(id: String, sampleID: String, locus: String, h1: Slot, h2: Slot, comment: String?) {
            self.id = id
            self.sampleID = sampleID
            self.locus = locus
            self.h1 = h1
            self.h2 = h2
            self.comment = comment
        }
    }

    public struct Color: Codable, Sendable {
        public let locus: String
        public let call: String
        public let fillHex: String
        public let fontHex: String

        public init(locus: String, call: String, fillHex: String, fontHex: String) {
            self.locus = locus
            self.call = call
            self.fillHex = fillHex
            self.fontHex = fontHex
        }
    }
}

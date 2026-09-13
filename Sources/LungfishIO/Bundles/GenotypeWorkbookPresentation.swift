import Foundation

public enum GenotypeWorkbookPresentation {
    /// Fully resolved presentation. A present record with nil colors and false
    /// traits explicitly means no decoration, never an inheritance request.
    public struct Style: Codable, Sendable, Equatable {
        public let fillHex: String?
        public let textHex: String?
        public let borderHex: String?
        public let isBold: Bool
        public let isItalic: Bool
        public init(fillHex: String? = nil, textHex: String? = nil, borderHex: String? = nil, isBold: Bool = false, isItalic: Bool = false) {
            self.fillHex = fillHex; self.textHex = textHex; self.borderHex = borderHex
            self.isBold = isBold; self.isItalic = isItalic
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
        public let style: Style?
        public let sampleID: String
        public let displayValue: Int?
        public let rawSupport: Int?
        public let reviewEligible: Bool
        public let fillHex: String?
        public let comment: String?
        public let review: String?

        public init(sampleID: String, displayValue: Int?, rawSupport: Int?, reviewEligible: Bool, fillHex: String?, comment: String?, review: String?, style: Style? = nil) {
            self.style = style
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
        public let style: Style?
        public let id: String
        public let target: Target
        public let displayName: String
        public let comment: String?
        public let fillHex: String?
        public var cells: [Cell]

        public init(id: String, target: Target, displayName: String, comment: String?, fillHex: String?, cells: [Cell], style: Style? = nil) {
            self.style = style
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

    public struct Color: Codable, Sendable, Equatable {
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

import Foundation
import LungfishCore

public struct GenotypeAnnotationSidecar: Codable, Equatable, Sendable {
    public static let filename = "annotations.json"
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var generatedAt: String
    public var lastEditedAt: String?
    public var lastEditor: String?
    public var callOverrides: [CallOverride]
    public var cellHighlights: [CellHighlight]
    public var rowHighlights: [RowHighlight]
    public var sampleNotes: [SampleNote]
    public var cellComments: [CellComment]
    public var sampleStatusFlags: [SampleStatusFlag]
    public var callStatusFlags: [CallStatusFlag]
    public var smartCohorts: [GenotypeCohortSmartFilter]
    public var manualHaplotypeAssignments: [ManualHaplotypeAssignment]
    public var settings: Settings
    public var auditLog: [AuditEntry]

    public init(schemaVersion: Int, generatedAt: String,
                lastEditedAt: String?, lastEditor: String?,
                callOverrides: [CallOverride], cellHighlights: [CellHighlight],
                rowHighlights: [RowHighlight], sampleNotes: [SampleNote],
                cellComments: [CellComment],
                sampleStatusFlags: [SampleStatusFlag], callStatusFlags: [CallStatusFlag],
                smartCohorts: [GenotypeCohortSmartFilter],
                manualHaplotypeAssignments: [ManualHaplotypeAssignment],
                settings: Settings, auditLog: [AuditEntry]) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.lastEditedAt = lastEditedAt
        self.lastEditor = lastEditor
        self.callOverrides = callOverrides
        self.cellHighlights = cellHighlights
        self.rowHighlights = rowHighlights
        self.sampleNotes = sampleNotes
        self.cellComments = cellComments
        self.sampleStatusFlags = sampleStatusFlags
        self.callStatusFlags = callStatusFlags
        self.smartCohorts = smartCohorts
        self.manualHaplotypeAssignments = manualHaplotypeAssignments
        self.settings = settings
        self.auditLog = auditLog
    }

    public static func empty(generatedAt: String) -> GenotypeAnnotationSidecar {
        GenotypeAnnotationSidecar(
            schemaVersion: currentSchemaVersion, generatedAt: generatedAt,
            lastEditedAt: nil, lastEditor: nil,
            callOverrides: [], cellHighlights: [], rowHighlights: [],
            sampleNotes: [], cellComments: [],
            sampleStatusFlags: [], callStatusFlags: [],
            smartCohorts: [], manualHaplotypeAssignments: [],
            settings: .default, auditLog: []
        )
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> GenotypeAnnotationSidecar {
        let decoder = JSONDecoder()
        return try decoder.decode(GenotypeAnnotationSidecar.self, from: data)
    }

    public mutating func append(audit: AuditEntry) {
        auditLog.append(audit)
        lastEditedAt = audit.timestamp
        lastEditor = audit.author
    }
}

public extension GenotypeAnnotationSidecar {
    struct CallOverride: Codable, Equatable, Sendable {
        public let sample: String
        public let locus: String
        public let slot: HaplotypeSlot
        public let originalCall: String
        public let overrideCall: String
        public let reasonTag: OverrideReasonTag
        public let rationale: String
        public let author: String
        public let timestamp: String

        public init(sample: String, locus: String, slot: HaplotypeSlot,
                    originalCall: String, overrideCall: String,
                    reasonTag: OverrideReasonTag, rationale: String,
                    author: String, timestamp: String) {
            self.sample = sample
            self.locus = locus
            self.slot = slot
            self.originalCall = originalCall
            self.overrideCall = overrideCall
            self.reasonTag = reasonTag
            self.rationale = rationale
            self.author = author
            self.timestamp = timestamp
        }
    }

    enum OverrideReasonTag: String, Codable, Sendable, CaseIterable {
        case dropout
        case contamination
        case novel
        case misCall
        case confirmed
    }

    struct CellHighlight: Codable, Equatable, Sendable {
        public let sample: String
        public let locus: String
        public let slot: HaplotypeSlot
        public let fillColor: String?
        public let borderColor: String?
        public let author: String
        public let timestamp: String

        public init(sample: String, locus: String, slot: HaplotypeSlot,
                    fillColor: String?, borderColor: String?,
                    author: String, timestamp: String) {
            self.sample = sample
            self.locus = locus
            self.slot = slot
            self.fillColor = fillColor
            self.borderColor = borderColor
            self.author = author
            self.timestamp = timestamp
        }
    }

    struct RowHighlight: Codable, Equatable, Sendable {
        public let sample: String
        public let fillColor: String?
        public let borderColor: String?
        public let author: String
        public let timestamp: String

        public init(sample: String, fillColor: String?, borderColor: String?,
                    author: String, timestamp: String) {
            self.sample = sample
            self.fillColor = fillColor
            self.borderColor = borderColor
            self.author = author
            self.timestamp = timestamp
        }
    }

    struct SampleNote: Codable, Equatable, Sendable {
        public let sample: String
        public let body: String
        public let author: String
        public let timestamp: String

        public init(sample: String, body: String, author: String, timestamp: String) {
            self.sample = sample
            self.body = body
            self.author = author
            self.timestamp = timestamp
        }
    }

    struct CellComment: Codable, Equatable, Sendable {
        public let sample: String
        public let locus: String
        public let slot: HaplotypeSlot
        public let body: String
        public let author: String
        public let timestamp: String

        public init(sample: String, locus: String, slot: HaplotypeSlot,
                    body: String, author: String, timestamp: String) {
            self.sample = sample
            self.locus = locus
            self.slot = slot
            self.body = body
            self.author = author
            self.timestamp = timestamp
        }
    }

    enum StatusValue: String, Codable, Sendable, CaseIterable {
        case unflagged
        case needsReview
        case reviewed
        case confirmed
    }

    struct SampleStatusFlag: Codable, Equatable, Sendable {
        public let sample: String
        public let value: StatusValue
        public let author: String
        public let timestamp: String

        public init(sample: String, value: StatusValue, author: String, timestamp: String) {
            self.sample = sample
            self.value = value
            self.author = author
            self.timestamp = timestamp
        }
    }

    struct CallStatusFlag: Codable, Equatable, Sendable {
        public let sample: String
        public let locus: String
        public let slot: HaplotypeSlot
        public let value: StatusValue
        public let author: String
        public let timestamp: String

        public init(sample: String, locus: String, slot: HaplotypeSlot,
                    value: StatusValue, author: String, timestamp: String) {
            self.sample = sample
            self.locus = locus
            self.slot = slot
            self.value = value
            self.author = author
            self.timestamp = timestamp
        }
    }

    struct Settings: Codable, Equatable, Sendable {
        public var viewMode: String
        public var panelLayout: String
        public var cardDensity: String
        public var cardDensityThreshold: Int
        public var dropoutAbsolute: Int?
        public var dropoutSampleFraction: Double?
        public var dropoutLocusFraction: Double?
        /// Per-locus overrides for `dropoutLocusFraction`. When a locus name
        /// (e.g. "MHC-B") has a value here, that fraction replaces the global
        /// `dropoutLocusFraction` for diagnostic alleles in that locus. The
        /// "EQ slider grid": each locus gets its own knob.
        public var locusFractionOverrides: [String: Double]?

        public static let `default` = Settings(
            viewMode: "outline",
            panelLayout: "aLeading",
            cardDensity: "auto",
            cardDensityThreshold: 30,
            dropoutAbsolute: 50,
            dropoutSampleFraction: nil,
            dropoutLocusFraction: 0.01,
            locusFractionOverrides: nil
        )

        public init(viewMode: String, panelLayout: String, cardDensity: String,
                    cardDensityThreshold: Int, dropoutAbsolute: Int?,
                    dropoutSampleFraction: Double?, dropoutLocusFraction: Double?,
                    locusFractionOverrides: [String: Double]? = nil) {
            self.viewMode = viewMode
            self.panelLayout = panelLayout
            self.cardDensity = cardDensity
            self.cardDensityThreshold = cardDensityThreshold
            self.dropoutAbsolute = dropoutAbsolute
            self.dropoutSampleFraction = dropoutSampleFraction
            self.dropoutLocusFraction = dropoutLocusFraction
            self.locusFractionOverrides = locusFractionOverrides
        }
    }

    struct AuditEntry: Codable, Equatable, Sendable {
        public let action: String
        public let sample: String
        public let locus: String?
        public let slot: HaplotypeSlot?
        public let before: String?
        public let after: String?
        public let color: String?
        public let reason: String?
        public let rationale: String?
        public let author: String
        public let timestamp: String

        public init(action: String, sample: String, locus: String?, slot: HaplotypeSlot?,
                    before: String?, after: String?, color: String?,
                    reason: String?, rationale: String?,
                    author: String, timestamp: String) {
            self.action = action
            self.sample = sample
            self.locus = locus
            self.slot = slot
            self.before = before
            self.after = after
            self.color = color
            self.reason = reason
            self.rationale = rationale
            self.author = author
            self.timestamp = timestamp
        }
    }
}

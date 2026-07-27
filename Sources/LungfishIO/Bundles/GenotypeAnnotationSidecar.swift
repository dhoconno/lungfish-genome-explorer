import Foundation
import LungfishCore

public enum ONTMHCCandidateTintCategory: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case sharedNovel
    case singletonNovel
    case sharedExtension
    case singletonExtension
}

public struct ONTMHCCandidateDisplaySettings: Codable, Equatable, Sendable {
    public var showKnown: Bool
    public var showSharedCandidates: Bool
    public var showSingletonCandidates: Bool
    public var tints: [ONTMHCCandidateTintCategory: AnnotationColor]

    public static let defaultTints: [ONTMHCCandidateTintCategory: AnnotationColor] = [
        .sharedNovel: AnnotationColor(hex: "#F5D78E")!,
        .singletonNovel: AnnotationColor(hex: "#F5B97A")!,
        .sharedExtension: AnnotationColor(hex: "#A8D8D0")!,
        .singletonExtension: AnnotationColor(hex: "#AFCBF2")!,
    ]

    public static let `default` = ONTMHCCandidateDisplaySettings(
        showKnown: true,
        showSharedCandidates: true,
        showSingletonCandidates: true,
        tints: defaultTints
    )

    public init(
        showKnown: Bool = true,
        showSharedCandidates: Bool = true,
        showSingletonCandidates: Bool = true,
        tints: [ONTMHCCandidateTintCategory: AnnotationColor] = Self.defaultTints
    ) {
        self.showKnown = showKnown
        self.showSharedCandidates = showSharedCandidates
        self.showSingletonCandidates = showSingletonCandidates
        self.tints = Self.normalizedTints(tints)
    }

    private enum CodingKeys: String, CodingKey {
        case showKnown
        case showSharedCandidates
        case showSingletonCandidates
        case tints
    }

    private struct TintCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showKnown = try container.decodeIfPresent(Bool.self, forKey: .showKnown) ?? true
        showSharedCandidates = try container.decodeIfPresent(Bool.self, forKey: .showSharedCandidates) ?? true
        showSingletonCandidates = try container.decodeIfPresent(Bool.self, forKey: .showSingletonCandidates) ?? true

        var decodedTints: [ONTMHCCandidateTintCategory: AnnotationColor] = [:]
        if container.contains(.tints),
           let tintContainer = try? container.nestedContainer(keyedBy: TintCodingKey.self, forKey: .tints) {
            for key in tintContainer.allKeys {
                guard let category = ONTMHCCandidateTintCategory(rawValue: key.stringValue) else {
                    continue
                }
                if let color = try? tintContainer.decode(AnnotationColor.self, forKey: key) {
                    decodedTints[category] = color
                } else if let hex = try? tintContainer.decode(String.self, forKey: key),
                          let color = AnnotationColor(hex: hex) {
                    decodedTints[category] = color
                }
            }
        }
        tints = Self.normalizedTints(decodedTints)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showKnown, forKey: .showKnown)
        try container.encode(showSharedCandidates, forKey: .showSharedCandidates)
        try container.encode(showSingletonCandidates, forKey: .showSingletonCandidates)
        var tintContainer = container.nestedContainer(keyedBy: TintCodingKey.self, forKey: .tints)
        for category in ONTMHCCandidateTintCategory.allCases {
            let key = TintCodingKey(stringValue: category.rawValue)!
            try tintContainer.encode(tints[category] ?? Self.defaultTints[category]!, forKey: key)
        }
    }

    private static func normalizedTints(
        _ tints: [ONTMHCCandidateTintCategory: AnnotationColor]
    ) -> [ONTMHCCandidateTintCategory: AnnotationColor] {
        var normalized = defaultTints
        for category in ONTMHCCandidateTintCategory.allCases {
            if let tint = tints[category] {
                normalized[category] = AnnotationColor(
                    red: tint.red,
                    green: tint.green,
                    blue: tint.blue,
                    alpha: tint.alpha
                )
            }
        }
        return normalized
    }
}

public struct GenotypeAnnotationSidecar: Codable, Equatable, Sendable {
    public static let filename = "annotations.json"
    public static let oldestSupportedSchemaVersion = 1
    public static let currentSchemaVersion = 3

    public enum SchemaMutationError: Error, Equatable, LocalizedError, Sendable {
        case unsupportedFutureSchemaVersion(found: Int, current: Int)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFutureSchemaVersion(let found, let current):
                return "Cannot modify genotype annotation schema version \(found); this version of Lungfish supports mutations through version \(current)."
            }
        }
    }

    public var schemaVersion: Int
    public var generatedAt: String
    public var lastEditedAt: String?
    public var lastEditor: String?
    public var callOverrides: [CallOverride]
    public var cellHighlights: [CellHighlight]
    public var rowHighlights: [RowHighlight]
    public var sampleNotes: [SampleNote]
    public var cellComments: [CellComment]
    public var matrixStyles: [MatrixStyleAnnotation]
    public var matrixComments: [MatrixComment]
    public var matrixReviews: [MatrixReviewAnnotation]
    public var sampleStatusFlags: [SampleStatusFlag]
    public var callStatusFlags: [CallStatusFlag]
    public var smartCohorts: [GenotypeCohortSmartFilter]
    public var manualHaplotypeAssignments: [ManualHaplotypeAssignment]
    public var aiHaplotypeReviews: [AIHaplotypeReviewEntry]
    public var activeAIHaplotypeReviewID: String?
    public var settings: Settings
    public var auditLog: [AuditEntry]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, lastEditedAt, lastEditor
        case callOverrides, cellHighlights, rowHighlights, sampleNotes, cellComments
        case matrixStyles, matrixComments, matrixReviews
        case sampleStatusFlags, callStatusFlags, smartCohorts, manualHaplotypeAssignments
        case aiHaplotypeReviews, activeAIHaplotypeReviewID, settings, auditLog
    }

    public init(schemaVersion: Int, generatedAt: String,
                lastEditedAt: String?, lastEditor: String?,
                callOverrides: [CallOverride], cellHighlights: [CellHighlight],
                rowHighlights: [RowHighlight], sampleNotes: [SampleNote],
                cellComments: [CellComment],
                matrixStyles: [MatrixStyleAnnotation] = [],
                matrixComments: [MatrixComment] = [],
                matrixReviews: [MatrixReviewAnnotation] = [],
                sampleStatusFlags: [SampleStatusFlag], callStatusFlags: [CallStatusFlag],
                smartCohorts: [GenotypeCohortSmartFilter],
                manualHaplotypeAssignments: [ManualHaplotypeAssignment],
                aiHaplotypeReviews: [AIHaplotypeReviewEntry] = [],
                activeAIHaplotypeReviewID: String? = nil,
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
        self.matrixStyles = matrixStyles
        self.matrixComments = matrixComments
        self.matrixReviews = matrixReviews
        self.sampleStatusFlags = sampleStatusFlags
        self.callStatusFlags = callStatusFlags
        self.smartCohorts = smartCohorts
        self.manualHaplotypeAssignments = manualHaplotypeAssignments
        self.aiHaplotypeReviews = aiHaplotypeReviews
        self.activeAIHaplotypeReviewID = activeAIHaplotypeReviewID
        self.settings = settings
        self.auditLog = auditLog
    }

    public init(schemaVersion: Int, generatedAt: String,
                lastEditedAt: String?, lastEditor: String?,
                callOverrides: [CallOverride], cellHighlights: [CellHighlight],
                rowHighlights: [RowHighlight], sampleNotes: [SampleNote],
                cellComments: [CellComment],
                sampleStatusFlags: [SampleStatusFlag], callStatusFlags: [CallStatusFlag],
                smartCohorts: [GenotypeCohortSmartFilter],
                manualHaplotypeAssignments: [ManualHaplotypeAssignment],
                aiHaplotypeReviews: [AIHaplotypeReviewEntry] = [],
                activeAIHaplotypeReviewID: String? = nil,
                settings: Settings, auditLog: [AuditEntry]) {
        self.init(
            schemaVersion: schemaVersion,
            generatedAt: generatedAt,
            lastEditedAt: lastEditedAt,
            lastEditor: lastEditor,
            callOverrides: callOverrides,
            cellHighlights: cellHighlights,
            rowHighlights: rowHighlights,
            sampleNotes: sampleNotes,
            cellComments: cellComments,
            matrixStyles: [],
            matrixComments: [],
            matrixReviews: [],
            sampleStatusFlags: sampleStatusFlags,
            callStatusFlags: callStatusFlags,
            smartCohorts: smartCohorts,
            manualHaplotypeAssignments: manualHaplotypeAssignments,
            aiHaplotypeReviews: aiHaplotypeReviews,
            activeAIHaplotypeReviewID: activeAIHaplotypeReviewID,
            settings: settings,
            auditLog: auditLog
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .schemaVersion
        ) ?? Self.oldestSupportedSchemaVersion
        self.generatedAt = try container.decode(String.self, forKey: .generatedAt)
        self.lastEditedAt = try container.decodeIfPresent(String.self, forKey: .lastEditedAt)
        self.lastEditor = try container.decodeIfPresent(String.self, forKey: .lastEditor)
        self.callOverrides = try container.decodeIfPresent([CallOverride].self, forKey: .callOverrides) ?? []
        self.cellHighlights = try container.decodeIfPresent([CellHighlight].self, forKey: .cellHighlights) ?? []
        self.rowHighlights = try container.decodeIfPresent([RowHighlight].self, forKey: .rowHighlights) ?? []
        self.sampleNotes = try container.decodeIfPresent([SampleNote].self, forKey: .sampleNotes) ?? []
        self.cellComments = try container.decodeIfPresent([CellComment].self, forKey: .cellComments) ?? []
        self.matrixStyles = try container.decodeIfPresent([MatrixStyleAnnotation].self, forKey: .matrixStyles) ?? []
        self.matrixComments = try container.decodeIfPresent([MatrixComment].self, forKey: .matrixComments) ?? []
        self.matrixReviews = try container.decodeIfPresent([MatrixReviewAnnotation].self, forKey: .matrixReviews) ?? []
        self.sampleStatusFlags = try container.decodeIfPresent([SampleStatusFlag].self, forKey: .sampleStatusFlags) ?? []
        self.callStatusFlags = try container.decodeIfPresent([CallStatusFlag].self, forKey: .callStatusFlags) ?? []
        self.smartCohorts = try container.decodeIfPresent([GenotypeCohortSmartFilter].self, forKey: .smartCohorts) ?? []
        self.manualHaplotypeAssignments = try container.decodeIfPresent(
            [ManualHaplotypeAssignment].self,
            forKey: .manualHaplotypeAssignments
        ) ?? []
        self.aiHaplotypeReviews = try container.decodeIfPresent(
            [AIHaplotypeReviewEntry].self,
            forKey: .aiHaplotypeReviews
        ) ?? []
        self.activeAIHaplotypeReviewID = try container.decodeIfPresent(
            String.self,
            forKey: .activeAIHaplotypeReviewID
        )
        self.settings = try container.decodeIfPresent(Settings.self, forKey: .settings) ?? .default
        self.auditLog = try container.decodeIfPresent([AuditEntry].self, forKey: .auditLog) ?? []
    }

    public static func empty(generatedAt: String) -> GenotypeAnnotationSidecar {
        GenotypeAnnotationSidecar(
            schemaVersion: currentSchemaVersion, generatedAt: generatedAt,
            lastEditedAt: nil, lastEditor: nil,
            callOverrides: [], cellHighlights: [], rowHighlights: [],
            sampleNotes: [], cellComments: [],
            matrixStyles: [], matrixComments: [], matrixReviews: [],
            sampleStatusFlags: [], callStatusFlags: [],
            smartCohorts: [], manualHaplotypeAssignments: [],
            aiHaplotypeReviews: [], activeAIHaplotypeReviewID: nil,
            settings: .default, auditLog: []
        )
    }

    public mutating func promoteToCurrentSchema() throws {
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw SchemaMutationError.unsupportedFutureSchemaVersion(
                found: schemaVersion,
                current: Self.currentSchemaVersion
            )
        }
        if schemaVersion < Self.currentSchemaVersion {
            schemaVersion = Self.currentSchemaVersion
        }
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

    public var resolvedMatrixComments: [MatrixTarget: MatrixComment] {
        var resolved: [MatrixTarget: MatrixComment] = [:]
        for comment in matrixComments {
            guard let existing = resolved[comment.target] else {
                resolved[comment.target] = comment
                continue
            }
            if Self.shouldReplaceMatrixComment(existing: existing, with: comment) {
                resolved[comment.target] = comment
            }
        }
        return resolved
    }

    private static func shouldReplaceMatrixComment(
        existing: MatrixComment,
        with candidate: MatrixComment
    ) -> Bool {
        guard let existingDate = parseISO8601Date(existing.timestamp),
              let candidateDate = parseISO8601Date(candidate.timestamp) else {
            return true
        }
        return candidateDate >= existingDate
    }

    private static func parseISO8601Date(_ timestamp: String) -> Date? {
        let fractionalSecondsFormatter = ISO8601DateFormatter()
        fractionalSecondsFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalSecondsFormatter.date(from: timestamp)
            ?? ISO8601DateFormatter().date(from: timestamp)
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
        case misCall = "mis-call"
        case dropoutSuspected = "dropout-suspected"
        case crossContamination = "cross-contamination"
        case novel
        case pedigreeConflict = "pedigree-conflict"
        case analystJudgment = "analyst-judgment"
        case confirmed
        case other

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let rawValue = try container.decode(String.self)
            switch rawValue {
            case Self.misCall.rawValue, "misCall":
                self = .misCall
            case Self.dropoutSuspected.rawValue, "dropout":
                self = .dropoutSuspected
            case Self.crossContamination.rawValue, "contamination":
                self = .crossContamination
            case Self.novel.rawValue:
                self = .novel
            case Self.pedigreeConflict.rawValue:
                self = .pedigreeConflict
            case Self.analystJudgment.rawValue:
                self = .analystJudgment
            case Self.confirmed.rawValue:
                self = .confirmed
            case Self.other.rawValue:
                self = .other
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown genotype override reason tag '\(rawValue)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
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

    enum MatrixTarget: Codable, Equatable, Hashable, Sendable {
        case row(locus: String, genotype: String, stableClusterID: String? = nil)
        case column(sample: String)
        case cell(locus: String, genotype: String, sample: String, stableClusterID: String? = nil)

        private enum CodingKeys: String, CodingKey {
            case kind, locus, genotype, sample, stableClusterID
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try container.decode(String.self, forKey: .kind)
            switch kind {
            case "row":
                self = .row(
                    locus: try container.decode(String.self, forKey: .locus),
                    genotype: try container.decode(String.self, forKey: .genotype),
                    stableClusterID: try container.decodeIfPresent(String.self, forKey: .stableClusterID)
                )
            case "column":
                self = .column(sample: try container.decode(String.self, forKey: .sample))
            case "cell":
                self = .cell(
                    locus: try container.decode(String.self, forKey: .locus),
                    genotype: try container.decode(String.self, forKey: .genotype),
                    sample: try container.decode(String.self, forKey: .sample),
                    stableClusterID: try container.decodeIfPresent(String.self, forKey: .stableClusterID)
                )
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .kind,
                    in: container,
                    debugDescription: "Unknown genotype matrix target kind '\(kind)'"
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case let .row(locus, genotype, stableClusterID):
                try container.encode("row", forKey: .kind)
                try container.encode(locus, forKey: .locus)
                try container.encode(genotype, forKey: .genotype)
                try container.encodeIfPresent(stableClusterID, forKey: .stableClusterID)
            case let .column(sample):
                try container.encode("column", forKey: .kind)
                try container.encode(sample, forKey: .sample)
            case let .cell(locus, genotype, sample, stableClusterID):
                try container.encode("cell", forKey: .kind)
                try container.encode(locus, forKey: .locus)
                try container.encode(genotype, forKey: .genotype)
                try container.encode(sample, forKey: .sample)
                try container.encodeIfPresent(stableClusterID, forKey: .stableClusterID)
            }
        }

        public var sample: String? {
            switch self {
            case .row:
                return nil
            case let .column(sample), let .cell(_, _, sample, _):
                return sample
            }
        }

        public var locus: String? {
            switch self {
            case let .row(locus, _, _), let .cell(locus, _, _, _):
                return locus
            case .column:
                return nil
            }
        }

        public var genotype: String? {
            switch self {
            case let .row(_, genotype, _), let .cell(_, genotype, _, _):
                return genotype
            case .column:
                return nil
            }
        }

        public var auditSample: String {
            sample ?? "matrix"
        }

        public var stableClusterID: String? {
            switch self {
            case let .row(_, _, stableClusterID), let .cell(_, _, _, stableClusterID):
                return stableClusterID
            case .column:
                return nil
            }
        }

        public var auditDescription: String {
            switch self {
            case let .row(locus, genotype, stableClusterID):
                return "row \(locus) \(genotype)" + (stableClusterID.map { " [\($0)]" } ?? "")
            case let .column(sample):
                return "column \(sample)"
            case let .cell(locus, genotype, sample, stableClusterID):
                return "cell \(sample) \(locus) \(genotype)" + (stableClusterID.map { " [\($0)]" } ?? "")
            }
        }

        public var stableAuditDescription: String {
            auditDescription
        }
    }

    struct MatrixStyle: Codable, Equatable, Sendable {
        public var fillColor: String?
        public var textColor: String?
        public var borderColor: String?
        public var isBold: Bool
        public var isItalic: Bool
        public var boldOverride: Bool?
        public var italicOverride: Bool?

        public init(
            fillColor: String? = nil,
            textColor: String? = nil,
            borderColor: String? = nil,
            isBold: Bool = false,
            isItalic: Bool = false,
            boldOverride: Bool? = nil,
            italicOverride: Bool? = nil
        ) {
            self.fillColor = fillColor
            self.textColor = textColor
            self.borderColor = borderColor
            self.isBold = isBold
            self.isItalic = isItalic
            self.boldOverride = boldOverride
            self.italicOverride = italicOverride
        }

        public var isEmpty: Bool {
            fillColor == nil && textColor == nil && borderColor == nil && !isBold && !isItalic
                && boldOverride == nil && italicOverride == nil
        }
    }

    struct MatrixStyleAnnotation: Codable, Equatable, Sendable {
        public let target: MatrixTarget
        public let style: MatrixStyle
        public let author: String
        public let timestamp: String

        public init(target: MatrixTarget, style: MatrixStyle, author: String, timestamp: String) {
            self.target = target
            self.style = style
            self.author = author
            self.timestamp = timestamp
        }
    }

    struct MatrixComment: Codable, Equatable, Sendable {
        public let target: MatrixTarget
        public let body: String
        public let author: String
        public let timestamp: String

        public init(target: MatrixTarget, body: String, author: String, timestamp: String) {
            self.target = target
            self.body = body
            self.author = author
            self.timestamp = timestamp
        }
    }

    enum MatrixReviewDisposition: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
        case falsePositive
        case falseNegative
    }

    struct MatrixReviewAnnotation: Codable, Equatable, Sendable {
        public var target: MatrixTarget
        public var disposition: MatrixReviewDisposition
        public var author: String
        public var timestamp: String

        public init(
            target: MatrixTarget,
            disposition: MatrixReviewDisposition,
            author: String,
            timestamp: String
        ) {
            self.target = target
            self.disposition = disposition
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

    enum AIHaplotypeReviewSource: String, Codable, Equatable, Sendable {
        case ai
    }

    enum AIHaplotypeReviewerDecision: String, Codable, Equatable, Sendable, CaseIterable {
        case needsReview
        case reviewed
        case confirmed
        case rejected
        case editedManually = "edited-manually"
    }

    struct AIHaplotypeCallReview: Codable, Equatable, Sendable {
        public let sample: String
        public let locus: String
        public let slot: HaplotypeSlot
        public let callState: GenotypeHaplotypeAICallState
        public let confidenceTier: GenotypeHaplotypeAIConfidenceTier
        public let supportEvidenceRefs: [String]
        public let counterevidenceRefs: [String]
        public let reviewerDecision: AIHaplotypeReviewerDecision
        public let reviewer: String?
        public let reviewedAt: String?
        public let provenancePath: String

        public init(
            sample: String,
            locus: String,
            slot: HaplotypeSlot,
            callState: GenotypeHaplotypeAICallState,
            confidenceTier: GenotypeHaplotypeAIConfidenceTier,
            supportEvidenceRefs: [String],
            counterevidenceRefs: [String],
            reviewerDecision: AIHaplotypeReviewerDecision,
            reviewer: String?,
            reviewedAt: String?,
            provenancePath: String
        ) {
            self.sample = sample
            self.locus = locus
            self.slot = slot
            self.callState = callState
            self.confidenceTier = confidenceTier
            self.supportEvidenceRefs = supportEvidenceRefs
            self.counterevidenceRefs = counterevidenceRefs
            self.reviewerDecision = reviewerDecision
            self.reviewer = reviewer
            self.reviewedAt = reviewedAt
            self.provenancePath = provenancePath
        }
    }

    struct AIHaplotypeReviewEntry: Codable, Equatable, Sendable {
        public let id: String
        public let analysisRevisionID: String
        public let createdAt: String
        public let source: AIHaplotypeReviewSource
        public let reviewState: ONTGenotypeHaplotypeAnalysisReviewState
        public let callReviews: [AIHaplotypeCallReview]
        public let evidenceSnapshotPath: String
        public let callsPath: String
        public let validationReportPath: String
        public let provenancePath: String

        public init(
            id: String,
            analysisRevisionID: String,
            createdAt: String,
            source: AIHaplotypeReviewSource,
            reviewState: ONTGenotypeHaplotypeAnalysisReviewState,
            callReviews: [AIHaplotypeCallReview],
            evidenceSnapshotPath: String,
            callsPath: String,
            validationReportPath: String,
            provenancePath: String
        ) {
            self.id = id
            self.analysisRevisionID = analysisRevisionID
            self.createdAt = createdAt
            self.source = source
            self.reviewState = reviewState
            self.callReviews = callReviews
            self.evidenceSnapshotPath = evidenceSnapshotPath
            self.callsPath = callsPath
            self.validationReportPath = validationReportPath
            self.provenancePath = provenancePath
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
        /// Optional analyst-selected definition set for this bundle. When
        /// present, the UI re-analyzes haplotypes against this definition
        /// instead of the pipeline/manifest default.
        public var activeHaplotypeDefinitionSetID: String?
        /// Assay scope for `activeHaplotypeDefinitionSetID`. nil preserves
        /// legacy sidecars and falls back to unique definition IDs.
        public var activeHaplotypeAssayID: String?
        /// Optional per-bundle preference for the Summary viewport mode.
        /// nil means use the result-specific default.
        public var preferredSummaryViewMode: String?
        /// Candidate-row visibility and tint preferences scoped to this result bundle.
        /// Legacy sidecars synthesize the defaults when this section is absent.
        public var mhcCandidateDisplay: ONTMHCCandidateDisplaySettings

        public static let `default` = Settings(
            viewMode: "outline",
            panelLayout: "aLeading",
            cardDensity: "auto",
            cardDensityThreshold: 30,
            dropoutAbsolute: 50,
            dropoutSampleFraction: nil,
            dropoutLocusFraction: 0.01,
            locusFractionOverrides: nil,
            activeHaplotypeDefinitionSetID: nil,
            activeHaplotypeAssayID: nil,
            preferredSummaryViewMode: nil,
            mhcCandidateDisplay: .default
        )

        public init(viewMode: String, panelLayout: String, cardDensity: String,
                    cardDensityThreshold: Int, dropoutAbsolute: Int?,
                    dropoutSampleFraction: Double?, dropoutLocusFraction: Double?,
                    locusFractionOverrides: [String: Double]? = nil,
                    activeHaplotypeDefinitionSetID: String? = nil,
                    activeHaplotypeAssayID: String? = nil,
                    preferredSummaryViewMode: String? = nil,
                    mhcCandidateDisplay: ONTMHCCandidateDisplaySettings = .default) {
            self.viewMode = viewMode
            self.panelLayout = panelLayout
            self.cardDensity = cardDensity
            self.cardDensityThreshold = cardDensityThreshold
            self.dropoutAbsolute = dropoutAbsolute
            self.dropoutSampleFraction = dropoutSampleFraction
            self.dropoutLocusFraction = dropoutLocusFraction
            self.locusFractionOverrides = locusFractionOverrides
            self.activeHaplotypeDefinitionSetID = activeHaplotypeDefinitionSetID
            self.activeHaplotypeAssayID = activeHaplotypeAssayID
            self.preferredSummaryViewMode = preferredSummaryViewMode
            self.mhcCandidateDisplay = mhcCandidateDisplay
        }

        private enum CodingKeys: String, CodingKey {
            case viewMode
            case panelLayout
            case cardDensity
            case cardDensityThreshold
            case dropoutAbsolute
            case dropoutSampleFraction
            case dropoutLocusFraction
            case locusFractionOverrides
            case activeHaplotypeDefinitionSetID
            case activeHaplotypeAssayID
            case preferredSummaryViewMode
            case mhcCandidateDisplay
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            viewMode = try container.decodeIfPresent(String.self, forKey: .viewMode) ?? Self.default.viewMode
            panelLayout = try container.decodeIfPresent(String.self, forKey: .panelLayout) ?? Self.default.panelLayout
            cardDensity = try container.decodeIfPresent(String.self, forKey: .cardDensity) ?? Self.default.cardDensity
            cardDensityThreshold = try container.decodeIfPresent(Int.self, forKey: .cardDensityThreshold)
                ?? Self.default.cardDensityThreshold
            dropoutAbsolute = try container.decodeIfPresent(Int.self, forKey: .dropoutAbsolute)
            dropoutSampleFraction = try container.decodeIfPresent(Double.self, forKey: .dropoutSampleFraction)
            dropoutLocusFraction = try container.decodeIfPresent(Double.self, forKey: .dropoutLocusFraction)
            locusFractionOverrides = try container.decodeIfPresent(
                [String: Double].self,
                forKey: .locusFractionOverrides
            )
            activeHaplotypeDefinitionSetID = try container.decodeIfPresent(
                String.self,
                forKey: .activeHaplotypeDefinitionSetID
            )
            activeHaplotypeAssayID = try container.decodeIfPresent(String.self, forKey: .activeHaplotypeAssayID)
            preferredSummaryViewMode = try container.decodeIfPresent(String.self, forKey: .preferredSummaryViewMode)
            mhcCandidateDisplay = try container.decodeIfPresent(
                ONTMHCCandidateDisplaySettings.self,
                forKey: .mhcCandidateDisplay
            ) ?? .default
        }
    }

    struct ManualHaplotypeAssignmentAuditPayload: Codable, Equatable, Sendable {
        public let operationID: String
        public let priorSidecarSHA256: String?
        public let before: ManualHaplotypeAssignment?
        public let after: ManualHaplotypeAssignment?
        public let copySourceSample: String?

        public init(
            operationID: String,
            priorSidecarSHA256: String?,
            before: ManualHaplotypeAssignment?,
            after: ManualHaplotypeAssignment?,
            copySourceSample: String?
        ) {
            self.operationID = operationID
            self.priorSidecarSHA256 = priorSidecarSHA256
            self.before = before
            self.after = after
            self.copySourceSample = copySourceSample
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
        public let manualHaplotypeAssignment: ManualHaplotypeAssignmentAuditPayload?

        public init(action: String, sample: String, locus: String?, slot: HaplotypeSlot?,
                    before: String?, after: String?, color: String?,
                    reason: String?, rationale: String?,
                    author: String, timestamp: String) {
            self.init(
                action: action,
                sample: sample,
                locus: locus,
                slot: slot,
                before: before,
                after: after,
                color: color,
                reason: reason,
                rationale: rationale,
                author: author,
                timestamp: timestamp,
                manualHaplotypeAssignment: nil
            )
        }

        public init(action: String, sample: String, locus: String?, slot: HaplotypeSlot?,
                    before: String?, after: String?, color: String?,
                    reason: String?, rationale: String?,
                    author: String, timestamp: String,
                    manualHaplotypeAssignment: ManualHaplotypeAssignmentAuditPayload?) {
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
            self.manualHaplotypeAssignment = manualHaplotypeAssignment
        }
    }
}

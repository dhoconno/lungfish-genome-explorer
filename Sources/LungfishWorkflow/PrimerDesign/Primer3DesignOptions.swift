import Foundation

public struct Primer3DesignOptions: Codable, Equatable, Sendable {
    public let productSizeMin: Int
    public let productSizeMax: Int
    public let targetStart: Int?
    public let targetEnd: Int?
    public let pairCount: Int
    public let primerMinSize: Int
    public let primerOptSize: Int
    public let primerMaxSize: Int
    public let primerMinTm: Double
    public let primerOptTm: Double
    public let primerMaxTm: Double
    public let primerMinGC: Double
    public let primerMaxGC: Double
    public let pickInternalOligo: Bool

    public init(
        productSizeMin: Int,
        productSizeMax: Int,
        targetStart: Int?,
        targetEnd: Int?,
        pairCount: Int,
        primerMinSize: Int,
        primerOptSize: Int,
        primerMaxSize: Int,
        primerMinTm: Double,
        primerOptTm: Double,
        primerMaxTm: Double,
        primerMinGC: Double,
        primerMaxGC: Double,
        pickInternalOligo: Bool
    ) {
        self.productSizeMin = productSizeMin
        self.productSizeMax = productSizeMax
        self.targetStart = targetStart
        self.targetEnd = targetEnd
        self.pairCount = pairCount
        self.primerMinSize = primerMinSize
        self.primerOptSize = primerOptSize
        self.primerMaxSize = primerMaxSize
        self.primerMinTm = primerMinTm
        self.primerOptTm = primerOptTm
        self.primerMaxTm = primerMaxTm
        self.primerMinGC = primerMinGC
        self.primerMaxGC = primerMaxGC
        self.pickInternalOligo = pickInternalOligo
    }
}

public enum Primer3BindingSitePolicy: String, Codable, Equatable, Sendable {
    case templateOnly
    case excludeVariableAndGappedColumns
}

public enum Primer3TemplateSelection: Sendable {
    case fastaRecord(inputURL: URL, recordIndex: Int)
    case msaTemplate(inputURL: URL, rowIndex: Int, bindingSitePolicy: Primer3BindingSitePolicy)

    public var inputURL: URL {
        switch self {
        case .fastaRecord(let inputURL, _), .msaTemplate(let inputURL, _, _): inputURL
        }
    }
}

public struct Primer3DesignRequest: Sendable {
    public let inputURLs: [URL]
    public let selections: [Primer3TemplateSelection]
    public let destinationURL: URL
    public let options: Primer3DesignOptions
    public let invocation: PrimerAnalysisWrapperInvocation
    public let executableURL: URL?
    public let expectedInputChecksums: [URL: String]

    public init(
        inputURLs: [URL],
        selections: [Primer3TemplateSelection],
        destinationURL: URL,
        options: Primer3DesignOptions,
        invocation: PrimerAnalysisWrapperInvocation,
        executableURL: URL? = nil,
        expectedInputChecksums: [URL: String] = [:]
    ) {
        self.inputURLs = inputURLs
        self.selections = selections
        self.destinationURL = destinationURL
        self.options = options
        self.invocation = invocation
        self.executableURL = executableURL
        self.expectedInputChecksums = expectedInputChecksums
    }
}

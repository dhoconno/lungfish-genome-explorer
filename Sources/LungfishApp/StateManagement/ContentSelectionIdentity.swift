import Foundation

public struct ContentSelectionIdentity: Hashable, Sendable {
    public let standardizedURLPath: String?
    public let kind: String
    public let sampleID: String?
    public let resultID: String?
    public let trackID: String?
    public let windowID: UUID?

    public init(
        url: URL?,
        kind: String,
        sampleID: String? = nil,
        resultID: String? = nil,
        trackID: String? = nil,
        windowID: UUID? = nil
    ) {
        self.standardizedURLPath = url?.standardizedFileURL.path
        self.kind = kind
        self.sampleID = sampleID
        self.resultID = resultID
        self.trackID = trackID
        self.windowID = windowID
    }
}

import Foundation
import LungfishCore
import LungfishIO

public struct MSAReferenceColumnInterval: Codable, Sendable, Equatable {
    public let start: Int
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

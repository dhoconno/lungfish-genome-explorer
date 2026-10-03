import Foundation
import LungfishCore
import LungfishIO

public enum AIHaplotypingProgressEvent: Equatable, Sendable {
    case runStarted(chunkCount: Int, observationCount: Int)
    case chunkStarted(chunkID: String, chunkIndex: Int, chunkCount: Int, observationCount: Int)
    case providerRetry(chunkID: String, retryIndex: Int, maxRetries: Int, errorCategory: String)
    case chunkFinished(chunkID: String, chunkIndex: Int, chunkCount: Int, callCount: Int, definitionCount: Int)
    case runFinished(chunkCount: Int, callCount: Int, definitionCount: Int)
}

import CryptoKit
import Darwin
import Foundation
import LungfishCore

public struct ONTGenotypeWorkbookLegacyReceiptFact:
    Equatable, Sendable
{
    public let transactionID: String
    public let action: String
    public let exitStatus: Int
    public let finalBundlePath: String
    public let oldCurrentWorkbook:
        ONTGenotypeWorkbookUpdateFileDescriptor
    public let newCurrentWorkbook:
        ONTGenotypeWorkbookUpdateFileDescriptor

    public init(
        transactionID: String,
        action: String,
        exitStatus: Int,
        finalBundlePath: String,
        oldCurrentWorkbook:
            ONTGenotypeWorkbookUpdateFileDescriptor,
        newCurrentWorkbook:
            ONTGenotypeWorkbookUpdateFileDescriptor
    ) {
        self.transactionID = transactionID
        self.action = action
        self.exitStatus = exitStatus
        self.finalBundlePath = finalBundlePath
        self.oldCurrentWorkbook = oldCurrentWorkbook
        self.newCurrentWorkbook = newCurrentWorkbook
    }
}

import CryptoKit
import Darwin
import Foundation

public struct ONTGenotypeWorkbookCleanupState: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let transactionID: String
    public let finalBundlePath: String
    public let sourceRootPath: String
    public let quarantinePath: String
    public let parentIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity
    public let sourceIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity
    public let quarantineIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity
    public let survivorIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity
    public let survivorManifest: ONTGenotypeWorkbookUpdateFileDescriptor
    public let survivorCurrentWorkbook: ONTGenotypeWorkbookUpdateFileDescriptor
    public let transaction: ONTGenotypeWorkbookUpdateTransaction
    public let terminalReceiptAction: String
    public let terminalReceiptDetail: String
    public let decision: ONTGenotypeWorkbookCleanupDecision
    public let retryState: String
    public let createdAt: Date

    public init(
        schemaVersion: Int = 3,
        transactionID: String,
        finalBundlePath: String,
        sourceRootPath: String,
        quarantinePath: String,
        parentIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        sourceIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        quarantineIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        survivorIdentity: ONTGenotypeWorkbookUpdateDirectoryIdentity,
        survivorManifest: ONTGenotypeWorkbookUpdateFileDescriptor,
        survivorCurrentWorkbook: ONTGenotypeWorkbookUpdateFileDescriptor,
        transaction: ONTGenotypeWorkbookUpdateTransaction,
        terminalReceiptAction: String,
        terminalReceiptDetail: String,
        decision: ONTGenotypeWorkbookCleanupDecision,
        retryState: String = "cleanup-pending",
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.transactionID = transactionID
        self.finalBundlePath = finalBundlePath
        self.sourceRootPath = sourceRootPath
        self.quarantinePath = quarantinePath
        self.parentIdentity = parentIdentity
        self.sourceIdentity = sourceIdentity
        self.quarantineIdentity = quarantineIdentity
        self.survivorIdentity = survivorIdentity
        self.survivorManifest = survivorManifest
        self.survivorCurrentWorkbook = survivorCurrentWorkbook
        self.transaction = transaction
        self.terminalReceiptAction = terminalReceiptAction
        self.terminalReceiptDetail = terminalReceiptDetail
        self.decision = decision
        self.retryState = retryState
        self.createdAt = createdAt
    }
}

import CryptoKit
import Darwin
import Foundation
import LungfishCore

public enum ONTGenotypeWorkbookLegacyAuthorityInspection:
    Equatable, Sendable
{
    case clear(receipts: [ONTGenotypeWorkbookLegacyReceiptFact])
    case blocked(reason: String)

    public var blockReason: String? {
        guard case .blocked(let reason) = self else { return nil }
        return reason
    }
}

import CryptoKit
import Darwin
import Foundation
import LungfishCore

public enum ONTGenotypeBundlePublicationLockProbe:
    String, Equatable, Sendable
{
    case missing
    case unlocked
    case held
}

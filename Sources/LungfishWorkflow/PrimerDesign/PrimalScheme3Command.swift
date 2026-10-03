import CryptoKit
import Darwin
import Foundation
import LungfishIO

struct PrimalScheme3Command: Sendable {
    let executableOverride: URL?
    let arguments: [String]
    let workingDirectory: URL
    let selectionAlgorithm: PrimalScheme3SelectionAlgorithm
    let terminalGapPolicy: PrimalScheme3TerminalGapPolicy
    var managedEnvironmentURL: URL? = nil
}

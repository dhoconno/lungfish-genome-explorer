// Public-key-only verification. This helper never opens a Keychain or private key.
import CryptoKit
import Foundation
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3,
      let publicBytes = Data(base64Encoded: arguments[0]), publicBytes.count == 32,
      let signature = Data(base64Encoded: arguments[1]), signature.count == 64 else {
    exit(2)
}
do {
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
    let payload = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    exit(key.isValidSignature(signature, for: payload) ? 0 : 1)
} catch {
    exit(2)
}

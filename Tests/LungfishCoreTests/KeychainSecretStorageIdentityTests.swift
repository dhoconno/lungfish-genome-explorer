import XCTest
@testable import LungfishCore

final class KeychainSecretStorageIdentityTests: XCTestCase {
    func testDebugUsesAnIsolatedKeychainService() {
        let stable = KeychainSecretStorage(appIdentity: .stable)
        let preview = KeychainSecretStorage(appIdentity: .preview)
        let debug = KeychainSecretStorage(appIdentity: .debug)

        XCTAssertEqual(stable.serviceIdentifier, "com.lungfish.secrets")
        XCTAssertEqual(preview.serviceIdentifier, "com.lungfish.secrets")
        XCTAssertEqual(debug.serviceIdentifier, "com.lungfish.secrets.debug")
    }

    func testExplicitKeychainServiceOverrideRemainsAuthoritative() {
        let storage = KeychainSecretStorage(
            service: "com.example.lungfish.tests",
            appIdentity: .debug
        )

        XCTAssertEqual(storage.serviceIdentifier, "com.example.lungfish.tests")
    }
}

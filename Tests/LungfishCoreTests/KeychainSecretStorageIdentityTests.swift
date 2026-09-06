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

extension KeychainSecretStorageIdentityTests {
    func testForkKeychainSelectorsAreIsolatedWithoutAccessingKeychain() throws {
        var services = Set<String>()
        for namespace in ["org.example.first", "org.example.second"] {
            for channel in ["stable", "preview", "debug"] {
                let identity = try LungfishAppIdentity.from(infoDictionary: [
                    "CFBundleDisplayName": "Example", "CFBundleName": "Example",
                    "CFBundleIdentifier": namespace + "." + channel, "LungfishReleaseChannel": channel,
                    "LungfishIdentitySchemaVersion": 1, "LungfishRuntimeNamespace": namespace,
                ])
                let service = KeychainSecretStorage(appIdentity: identity).serviceIdentifier
                XCTAssertEqual(service, namespace + "." + channel + ".secrets")
                XCTAssertNotEqual(service, KeychainSecretStorage(appIdentity: .stable).serviceIdentifier)
                services.insert(service)
            }
        }
        XCTAssertEqual(services.count, 6)
    }
}

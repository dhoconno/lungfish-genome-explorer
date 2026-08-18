// ProvenanceDependencySetTests.swift - dependencySet on ProvenanceRuntimeIdentity
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class ProvenanceDependencySetTests: XCTestCase {
    func testRuntimeIdentityCarriesDependencySet() throws {
        // ProvenanceRuntimeIdentity() is the real factory used at every construction
        // site (its memberwise init supplies defaults for every parameter); there is
        // no separate `.current()` static.
        let identity = ProvenanceRuntimeIdentity()
        XCTAssertEqual(identity.dependencySet, ManagedToolLock.bundled.resolvedDependencySet)
    }

    func testLegacyEnvelopeDecodesWithNilDependencySet() throws {
        let json = #"{"appVersion":"0.5.0-beta29","executablePath":"/x","processIdentifier":1,"operatingSystemVersion":"26.0","architecture":"arm64"}"#
        let identity = try JSONDecoder().decode(ProvenanceRuntimeIdentity.self, from: Data(json.utf8))
        XCTAssertNil(identity.dependencySet)
    }
}

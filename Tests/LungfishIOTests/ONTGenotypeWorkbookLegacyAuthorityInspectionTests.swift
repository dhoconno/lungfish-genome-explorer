import Darwin
import Foundation
@testable import LungfishIO
import XCTest

final class ONTGenotypeWorkbookLegacyAuthorityInspectionTests:
    XCTestCase
{
    func testAttestationRootReplacementDuringInspectionFailsClosed()
        throws
    {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LegacyAuthorityRootSwap-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let bundle = parent.appendingPathComponent(
            "sample.lungfishgenotype",
            isDirectory: true
        )
        let attestationRoot = parent.appendingPathComponent(
            "attestations",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundle,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: attestationRoot,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(Darwin.chmod(attestationRoot.path, 0o700), 0)
        let displaced = parent.appendingPathComponent(
            "attestations-displaced",
            isDirectory: true
        )

        let inspection =
            ONTGenotypeWorkbookUpdateRecovery
            .inspectLegacyArchiveAuthority(
                transactionID:
                    "2026-07-27T120000Z-update-current-workbook-deadbeef",
                liveBundleURL: bundle,
                attestationRootURL: attestationRoot,
                attestationEnumerationObserver: {
                    try FileManager.default.moveItem(
                        at: attestationRoot,
                        to: displaced
                    )
                    try FileManager.default.createDirectory(
                        at: attestationRoot,
                        withIntermediateDirectories: false
                    )
                }
            )

        guard case .blocked(let reason) = inspection else {
            return XCTFail("A replaced authority root must fail closed.")
        }
        XCTAssertTrue(reason.contains("changed"), reason)
    }

    func testAttestationRootWithUnsafePermissionsFailsClosed() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LegacyAuthorityPermissions-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: parent) }
        let bundle = parent.appendingPathComponent(
            "sample.lungfishgenotype",
            isDirectory: true
        )
        let attestationRoot = parent.appendingPathComponent(
            "attestations",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: bundle,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: attestationRoot,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(Darwin.chmod(attestationRoot.path, 0o777), 0)

        let inspection =
            ONTGenotypeWorkbookUpdateRecovery
            .inspectLegacyArchiveAuthority(
                transactionID:
                    "2026-07-27T120000Z-update-current-workbook-deadbeef",
                liveBundleURL: bundle,
                attestationRootURL: attestationRoot
            )

        guard case .blocked(let reason) = inspection else {
            return XCTFail("An unsafe authority root must fail closed.")
        }
        XCTAssertTrue(reason.contains("unsafe"), reason)
    }
}

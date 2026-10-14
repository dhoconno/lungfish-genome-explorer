// RouteParityHarness+Signing.swift - A flip loses no signature, the shared assertion of every family's signing case
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane Q-SIGN, the ruling of the A52 whole-lane review (Q6) and BIO 4. Every parity class runs
// with no signing key, so a record that side A signs and side C leaves unsigned is invisible to it. A
// flip moves a launch from one writer to another, and the writers that build
// `ProvenanceWriter(signingProvider: nil)` never sign when a key is set. One completing case in each
// family therefore runs again with a throwaway key.
//
//     let runs = try await harness.runSigned(
//         in: caseRoot, fixture: { try Fixture.make(in: $0) },
//         sideA: { await Self.sideA($0) }, sideC: { await self.sideC($0) }
//     )
//     RouteParityHarness.assertNoSignatureLost(runs, opening: { Self.bundle(in: $0).appendingPathComponent(".lungfish-provenance.json") })
//     await harness.assertSignaturesVerify(runs, opening: { ... })
//
// - `runSigned` writes the key to `signing-key.txt` in the case root, beside the side roots and never inside
//   one, so no fixture, golden or argument vector holds it, and points `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE`
//   at it for the three sides. The in-process side A reads it from this process, and the built CLI inherits it
//   through the app's subprocess environment, as it does in the field. The sides are not compared against a
//   declared list, since a signed record adds two files to each root and the declared counts are for runs
//   with no key.
// - `assertNoSignatureLost` fails for a record new in the run that side A signed and side C or C' holds
//   unsigned, and for a side C or C' whose opening record (the one the result's bundle or folder opens
//   first) is unsigned. An inner record whose digest a signed record states may stay unsigned, and a case
//   lists it by name with its reason.
// - `assertSignaturesVerify` runs `lungfish-cli provenance verify` on every signed new record of sides C and
//   C', which must exit 0 with "Signature valid", and on one copy of side C's opening record with one digit
//   changed, which must not.

import CryptoKit
import Foundation
import LungfishWorkflow
import XCTest

extension RouteParityHarness {
    // MARK: - The key

    /// The file name of a case's throwaway key, in the case root and outside every side root.
    public static let signingKeyFileName = "signing-key.txt"

    /// Where a case's throwaway key is written.
    public static func signingKeyURL(in caseRoot: URL) -> URL {
        caseRoot.appendingPathComponent(signingKeyFileName)
    }

    /// Writes a fresh throwaway key to `signing-key.txt` in `caseRoot`, which must exist, and returns the file.
    /// A case that runs its own sides calls it after it clears and builds its roots.
    public static func writeSigningKey(in caseRoot: URL) throws -> URL {
        let keyFile = signingKeyURL(in: caseRoot)
        try "lane-q-sign-throwaway-\(UUID().uuidString)\n".write(to: keyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        return keyFile
    }

    /// The signing variables of this process, put back by `restore`. The in-process side reads them from this
    /// process, and the built CLI inherits them through the app's subprocess environment.
    public struct SigningEnvironment {
        private let previous: [String: String?]

        /// Points `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` at `keyFile` and clears `LUNGFISH_PROVENANCE_SIGNING_KEY`.
        public init(keyFile: URL) {
            let keyName = ProvenanceSigningConfiguration.signingKeyEnvironmentKey
            let fileName = ProvenanceSigningConfiguration.signingKeyFileEnvironmentKey
            var previous: [String: String?] = [:]
            for name in [keyName, fileName] { previous[name] = ProcessInfo.processInfo.environment[name] }
            self.previous = previous
            unsetenv(keyName)
            setenv(fileName, keyFile.path, 1)
        }

        public func restore() {
            for (name, value) in previous {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
    }

    /// Runs `run` with `LUNGFISH_PROVENANCE_SIGNING_KEY_FILE` naming a key written under `caseRoot` after
    /// the root is cleared, and puts the variables back afterwards. A class that calls it runs in the
    /// integration tier, never the parallel unit tier, since the variables belong to the whole process.
    @MainActor
    public func runSigned(
        in caseRoot: URL,
        fixture: (URL) throws -> Void,
        sideA: (URL) async throws -> RouteParitySideOutcome,
        sideC: (URL) async throws -> RouteParitySideOutcome
    ) async throws -> RouteParityRuns {
        let keyFile = Self.signingKeyURL(in: caseRoot)
        let saved = SigningEnvironment(keyFile: keyFile)
        defer { saved.restore() }
        return try await run(
            in: caseRoot,
            fixture: { root in
                try fixture(root)
                _ = try Self.writeSigningKey(in: caseRoot)
            },
            sideA: sideA,
            sideC: sideC
        )
    }

    // MARK: - The records of a run

    /// Whether the relative name `name` is a provenance record, which is a JSON file whose own name
    /// contains `provenance`, and not the signature artifact of one.
    static func isRecordName(_ name: String) -> Bool {
        isProvenanceEnvelope(name) && !name.hasSuffix(".signature.json")
    }

    /// Whether `record` has both files a signed record adds, `<record>.signature.json` and `<record>.pub`.
    public static func isSigned(_ record: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: ProvenanceSigningConfiguration.signatureURL(for: record).path)
            && fileManager.fileExists(atPath: ProvenanceSigningConfiguration.publicKeyURL(for: record).path)
    }

    /// The records the run of `run` wrote or rewrote, by relative name with the ids that change from run
    /// to run masked. A record the fixture held as it is does not count.
    static func newRecords(in run: RouteParitySideRun, fixture: [String: String]) -> [String: [URL]] {
        var found: [String: [URL]] = [:]
        for name in relativeFiles(under: run.root) where isRecordName(name) {
            let url = run.root.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if fixture[name] == digest { continue }
            found[maskedID(name), default: []].append(url)
        }
        return found
    }

    /// `url` relative to `root`, for a message.
    static func relativeName(of url: URL, in root: URL) -> String {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }

    // MARK: - The assertion

    /// Every line that tells a flip lost a signature, empty when none did.
    ///
    /// - A record new in the run (not in the fixture) that side A signed must not be unsigned on side C or
    ///   C' when that side holds a record of the same masked name. A record one side lacks is a difference
    ///   of files, which the parity comparison reports.
    /// - The record `opening` names for side C and for side C' must exist and be signed.
    ///
    /// `inner` holds the masked names of records that may stay unsigned because a signed record states
    /// their digest.
    public static func signatureLosses(
        in runs: RouteParityRuns,
        opening: (URL) -> URL,
        inner: Set<String> = []
    ) -> [String] {
        var losses: [String] = []
        let recordsA = newRecords(in: runs.a, fixture: runs.fixture)
        for side in [runs.c, runs.cPrime] {
            let recordsSide = newRecords(in: side, fixture: runs.fixture)
            for (name, urlsA) in recordsA.sorted(by: { $0.key < $1.key }) where !inner.contains(name) {
                let signedA = urlsA.filter(isSigned).count
                guard signedA > 0, let urlsSide = recordsSide[name] else { continue }
                let signedSide = urlsSide.filter(isSigned).count
                if signedSide < min(signedA, urlsSide.count) {
                    losses.append("side \(side.side): \(name) is signed on side A and unsigned here (\(signedSide) of \(urlsSide.count) signed)")
                }
            }
            let record = opening(side.root)
            let shown = relativeName(of: record, in: side.root)
            if !FileManager.default.fileExists(atPath: record.path) {
                losses.append("side \(side.side): the record the result opens first, \(shown), does not exist")
            } else if !isSigned(record) {
                losses.append("side \(side.side): the record the result opens first, \(shown), is unsigned though a key is set")
            }
        }
        return losses
    }

    /// Fails the test once, listing every signature a flip lost, when any.
    public static func assertNoSignatureLost(
        _ runs: RouteParityRuns,
        opening: (URL) -> URL,
        inner: Set<String> = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertNoFailures(
            signatureLosses(in: runs, opening: opening, inner: inner),
            in: "a flip lost a signature", file: file, line: line
        )
    }

    // MARK: - Verifying

    /// `text` with its first digit raised by one, so the record differs by one digit. Nil when it holds none.
    public static func editingOneDigit(of text: String) -> String? {
        guard let index = text.firstIndex(where: { $0.isASCII && $0.isNumber }) else { return nil }
        var edited = text
        edited.replaceSubrange(index...index, with: String(((text[index].wholeNumberValue ?? 0) + 1) % 10))
        return edited
    }

    /// BIO check 4. `lungfish-cli provenance verify` exits 0 with "Signature valid" on every signed record
    /// new on side C and on side C', and exits nonzero on a copy of side C's opening record with one digit
    /// edited, checked against the signature and public key the record holds.
    public func assertSignaturesVerify(
        _ runs: RouteParityRuns,
        opening: @Sendable (URL) -> URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for side in [runs.c, runs.cPrime] {
            var verified = 0
            for (name, urls) in Self.newRecords(in: side, fixture: runs.fixture).sorted(by: { $0.key < $1.key }) {
                for record in urls where Self.isSigned(record) {
                    let verify = await Self.runCLI(cliBinary, arguments: ["provenance", "verify", record.path], timeout: .seconds(60))
                    XCTAssertEqual(verify.status, 0, "side \(side.side): \(name): \(verify.detail)", file: file, line: line)
                    XCTAssertTrue(
                        verify.stdout.contains("Signature valid"), "side \(side.side): \(name): \(verify.stdout)", file: file, line: line
                    )
                    verified += 1
                }
            }
            XCTAssertGreaterThan(verified, 0, "side \(side.side): no signed record to verify", file: file, line: line)
        }

        let record = opening(runs.c.root)
        let folder = runs.caseRoot.appendingPathComponent("tampered", isDirectory: true)
        guard let text = try? String(contentsOf: record, encoding: .utf8), let edited = Self.editingOneDigit(of: text) else {
            return XCTFail("side C: the opening record \(record.path) cannot be read or holds no digit", file: file, line: line)
        }
        let copy = folder.appendingPathComponent(record.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try edited.write(to: copy, atomically: true, encoding: .utf8)
        } catch {
            return XCTFail("side C: the edited copy was not written: \(error)", file: file, line: line)
        }
        let verify = await Self.runCLI(
            cliBinary,
            arguments: [
                "provenance", "verify", copy.path,
                "--signature", ProvenanceSigningConfiguration.signatureURL(for: record).path,
                "--public-key", ProvenanceSigningConfiguration.publicKeyURL(for: record).path,
            ],
            timeout: .seconds(60)
        )
        XCTAssertNotEqual(verify.status, 0, "side C: a one-digit edit of \(record.lastPathComponent) still verifies", file: file, line: line)
        XCTAssertFalse(verify.stdout.contains("Signature valid"), "side C: \(verify.stdout)", file: file, line: line)
    }
}

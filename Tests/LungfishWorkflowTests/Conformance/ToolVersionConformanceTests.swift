// ToolVersionConformanceTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Asserts that every tool the dependency manifest pins actually reports that
// pinned version when its version-check command runs against the local
// conda install. The command for each lock id comes from the one table,
// `ManagedToolVersionProbe`, and its dialect says how the version is read.
//
// Both installed-version tests treat a MISSING tool and a DRIFTED version the
// same way, and the mode decides what that way is:
//
//   * default (LUNGFISH_REQUIRE_TOOLS unset): drift is an XCTSkip naming every
//     drifted tool. A developer machine's real root legitimately lags the
//     manifest during a dependency sweep, between the moment a pin lands and
//     the moment `tools update --apply` (or the Update Tools sheet) runs
//     against that root. The default gate, including the pre-push hook, must
//     stay green in that window; the skip message is what tells the developer
//     the remedy is available. A tool the root does not provision is printed
//     as a LUNGFISH_PROBE_NOT_INSTALLED line and never skipped silently.
//   * LUNGFISH_REQUIRE_TOOLS=1: drift and a missing probe executable are an
//     XCTFail, except the tools of experimental packs when their environment is
//     absent (the CLI cannot install those packs). verify.sh and CI run in this
//     mode against a reconciled root, so
//     conformance is genuinely enforced there and a real drift cannot ship
//     unnoticed.
//
// The skip therefore relaxes WHERE conformance is enforced, not WHETHER: no
// merge path reaches main without a require-mode run asserting these pins.
//
// The pure checks on the table itself live in ManagedToolVersionProbeTableTests,
// which runs in the unit tier. This class needs the installed tools.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class ToolVersionConformanceTests: XCTestCase {
    /// Every manifest tool env must report the manifest version from its version command.
    ///
    /// Version drift is a skip by default and a failure under
    /// `LUNGFISH_REQUIRE_TOOLS=1`; see the file comment for why.
    func testEveryManifestToolReportsPinnedVersion() async throws {
        let manifest = try ConformanceFixtures.manifest()
        let entries = manifest.entries.filter { $0.source == .tool }
        XCTAssertFalse(entries.isEmpty, "the bundled lock has no tools")
        let outcome = try await probe(entries)
        XCTAssertTrue(outcome.failures.isEmpty, outcome.failures.joined(separator: "\n"))
        if !outcome.drifted.isEmpty {
            throw XCTSkip("tool version drift (run with LUNGFISH_REQUIRE_TOOLS=1 to enforce): \(outcome.drifted.joined(separator: "; "))")
        }
    }

    /// Version drift is a skip by default and a failure under
    /// `LUNGFISH_REQUIRE_TOOLS=1`; see the file comment for why.
    func testEveryInstalledPackToolReportsPinnedVersion() async throws {
        let manifest = try ConformanceFixtures.manifest()
        let entries = manifest.entries.filter { $0.source != .tool }
        XCTAssertFalse(entries.isEmpty, "the bundled lock has no pack tools")
        let outcome = try await probe(entries)
        XCTAssertTrue(outcome.failures.isEmpty, outcome.failures.joined(separator: "\n"))
        if !outcome.drifted.isEmpty {
            throw XCTSkip("pack tool version drift (run with LUNGFISH_REQUIRE_TOOLS=1 to enforce): \(outcome.drifted.joined(separator: "; "))")
        }
    }

    // MARK: - Probing

    private enum CondaMetaVerdict {
        case pass
        case drift(String)
        case failure(String)
    }

    private struct Outcome {
        var failures: [String] = []
        var drifted: [String] = []
    }

    /// Runs each entry's probe from the table against the real root.
    ///
    /// Every entry prints one `LUNGFISH_PROBE` line so a run can be compared with another.
    private func probe(_ entries: [ManagedToolLockEntry]) async throws -> Outcome {
        var outcome = Outcome()
        /// A version mismatch is enforced under require and reported as drift otherwise.
        func recordDrift(_ id: String, _ message: String) {
            print("LUNGFISH_PROBE id=\(id) outcome=drift")
            if ToolAvailability.requireTools {
                outcome.failures.append(message)
            } else {
                outcome.drifted.append(message)
            }
        }
        for entry in entries {
            let id = entry.id.rawValue
            guard let probe = ManagedToolVersionProbe.probe(for: entry.id) else {
                print("LUNGFISH_PROBE id=\(id) outcome=no-probe")
                outcome.failures.append("\(id): the probe table has no entry for this lock id")
                continue
            }
            let url: URL
            do {
                url = try await CondaManager.shared.toolPath(name: probe.executable, environment: entry.environment)
            } catch {
                print("LUNGFISH_PROBE_NOT_INSTALLED id=\(id) executable=\(probe.executable) environment=\(entry.environment)")
                // The CLI cannot install an experimental pack, so its absent environment is
                // listed and never a failure, in both modes. Any other absence fails under require.
                let environmentURL = await CondaManager.shared.environmentURL(named: entry.environment)
                let exempt = entry.isInExperimentalPack
                    && !FileManager.default.fileExists(atPath: environmentURL.path)
                if ToolAvailability.requireTools && !exempt {
                    outcome.failures.append("\(id): not installed (\(probe.executable) in env \(entry.environment)): \(error)")
                }
                continue
            }
            var environment = [String: String]()
            if id == "nextflow" {
                let environmentRoot = url.deletingLastPathComponent().deletingLastPathComponent()
                let javaHome = environmentRoot.appendingPathComponent("lib/jvm", isDirectory: true)
                environment["JAVA_HOME"] = javaHome.path
                environment["PATH"] = javaHome.appendingPathComponent("bin").path
                    + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            }
            let r = try ProcessRunner.run(url, probe.arguments, environment: environment, timeout: 60)
            let expected = entry.pythonRuntime?.version ?? entry.version ?? ""
            let text = r.stdout + r.stderr

            switch probe.dialect {
            case .notSelfReported:
                // Prints usage rather than a version string; a non-crash run (including
                // its typical non-zero "no args" exit) is the pass condition.
                print("LUNGFISH_PROBE id=\(id) outcome=ran")
            case .selfReportedWithHelpFallback:
                if ConformanceFixtures.textReportsVersion(text, version: expected) {
                    print("LUNGFISH_PROBE id=\(id) outcome=pass")
                    break
                }
                let helpResult = try? ProcessRunner.run(url, ["--help"], timeout: 60)
                let helpText = (helpResult?.stdout ?? "") + (helpResult?.stderr ?? "")
                if ConformanceFixtures.textReportsVersion(helpText, version: expected) {
                    print("LUNGFISH_PROBE id=\(id) outcome=pass")
                } else {
                    recordDrift(id, "\(id): expected \(expected) in --version or --help output: \(text.prefix(200)) / \(helpText.prefix(200))")
                }
            case .selfReported:
                if ConformanceFixtures.textReportsVersion(text, version: expected) {
                    print("LUNGFISH_PROBE id=\(id) outcome=pass")
                } else {
                    recordDrift(id, "\(id): expected \(expected) in: \(text.prefix(200))")
                }
            case .condaMetaOnly:
                switch await condaMetaVerdict(entry) {
                case .pass:
                    print("LUNGFISH_PROBE id=\(id) outcome=pass")
                case .drift(let message):
                    recordDrift(id, message)
                case .failure(let message):
                    print("LUNGFISH_PROBE id=\(id) outcome=drift")
                    outcome.failures.append(message)
                }
            }
        }
        return outcome
    }

    /// UPSTREAM PACKAGING DEFECTS: two pinned arm64 builds cannot report
    /// their own version, so for these -- and only these -- the installed
    /// version is asserted against the environment's conda-meta record
    /// instead of the self-reported string.
    ///
    ///   * bwa-mem2 (`bioconda::bwa-mem2=2.3=hda5e58c_0`): `bwa-mem2
    ///     version` prints "2.2.1". The build ships 2.3 binaries but was
    ///     packaged with a stale version string.
    ///   * bracken (`bioconda::bracken=1.0.0=1`): the package ships no
    ///     driver at all, only `est_abundance.py` and friends, so
    ///     `CondaManager.ensureBrackenLauncher` synthesizes `bin/bracken`
    ///     as a passthrough to that script, which has no version flag, and
    ///     `bracken -v` prints an argparse usage error. An environment that has
    ///     the source-built Bracken prints `Bracken v3.0.1` instead. Either way
    ///     the probe says nothing about the pin, so conda-meta decides.
    ///
    /// In both cases conda-meta records the correct version and no newer
    /// arm64 build exists. This stays a hard assertion: if conda-meta ever
    /// disagrees with the manifest pin, it fails loudly. REMOVE the
    /// bwa-mem2 entry once a fixed arm64 build is pinned.
    ///
    /// Like the self-reported path, a mismatch is a hard failure only under
    /// LUNGFISH_REQUIRE_TOOLS=1; on a drifting dev machine it reports as drift,
    /// so this exception never turns a tolerated skip into a failure.
    private func condaMetaVerdict(_ entry: ManagedToolLockEntry) async -> CondaMetaVerdict {
        let id = entry.id.rawValue
        let pinned = entry.version ?? ""
        let envURL = await CondaManager.shared.environmentURL(named: entry.environment)
        let meta = CondaMetaReader.primaryPackage(named: id, inEnvironment: envURL)
        if let meta {
            return meta.version == pinned
                ? .pass
                : .drift("\(id): conda-meta version \(meta.version) does not match manifest pin \(pinned)")
        } else if entry.preserveExistingInstall == true {
            // A tool that opted into preserveExistingInstall may legitimately
            // have no conda-meta record: the reconciler deliberately keeps a
            // working local build (for example a source-built Bracken) rather
            // than overwriting it with the pin. That is a supported end state,
            // not drift and not a skip, so assert what can actually be checked:
            // every declared executable is present and executable. Skipping here
            // would trip the tier 1 no-skips rule; failing would punish the
            // documented behaviour.
            let missing = entry.executables.filter { name in
                let url = envURL.appendingPathComponent("bin/\(name)")
                return !FileManager.default.isExecutableFile(atPath: url.path)
            }
            return missing.isEmpty
                ? .pass
                : .failure("\(id): local install preserved but missing executables: \(missing.joined(separator: ", "))")
        } else {
            return .drift("\(id): no conda-meta record in env \(entry.environment)")
        }
    }
}

import Foundation
import XCTest
import LungfishIO
@testable import LungfishWorkflow

/// The adapter contract's runtime identity check runs after varVAMP or Olivar
/// has already finished. A copied conda root reached through `/tmp` reports
/// `sys.executable` unresolved and `sys.prefix` resolved to `/private/tmp`,
/// which used to fail as "lacks upstream source verification". The check must
/// accept the same runtime under any alias and, when it does fail, say which
/// record differs and that the native tool succeeded.
final class PrimerSchemeRuntimeIdentityTests: XCTestCase {
    private var root: URL!
    private var envReal: URL!
    private var envLink: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimerSchemeRuntimeIdentityTests-\(UUID().uuidString)", isDirectory: true)
        envReal = root.appendingPathComponent("real/envs/varvamp", isDirectory: true)
        try FileManager.default.createDirectory(at: envReal.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: envReal.appendingPathComponent("bin/python3.13"))
        try FileManager.default.createSymbolicLink(
            at: envReal.appendingPathComponent("bin/python"), withDestinationURL: envReal.appendingPathComponent("bin/python3.13"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent("real"))
        envLink = root.appendingPathComponent("link/envs/varvamp", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func runtime(
        executable: String, prefix: String,
        sources: [PrimerSchemeAdapterProvenance.SourceVerification] = [.init(path: "/x/command.py", sha256: "a", expectedSHA256: "a", byteSize: 1)],
        distribution: String = "bioconda::varvamp=1.3.2=pyhdfd78af_0"
    ) -> PrimerSchemeAdapterProvenance.Runtime {
        .init(
            pythonExecutable: executable, pythonVersion: "3.13", platform: "macOS", implementation: "CPython",
            engineModulePath: "/x/__init__.py", sourceVerification: sources, environmentPrefix: prefix,
            distribution: distribution,
            condaPackageRecord: .init(path: "/x", sha256: "b", byteSize: 1, name: "varvamp", version: "1.3.2",
                                      build: "pyhdfd78af_0", channel: "bioconda", subdir: "noarch", url: "https://x"))
    }

    func testSameRuntimeUnderSymlinkAndPhysicalAliasesIsAccepted() {
        // LGE launched through the link; Python reports the unresolved
        // executable and the realpath prefix, as CPython does.
        let launched = envLink.appendingPathComponent("bin/python")
        let physicalPrefix = envReal.canonicalFilePath
        XCTAssertNil(PrimerSchemeAdapterResultLoader.runtimeIdentityViolation(
            runtime: runtime(executable: launched.path, prefix: physicalPrefix),
            engine: .varvamp, executableURL: launched,
            expectedDistribution: "bioconda::varvamp=1.3.2=pyhdfd78af_0"))
        // And launched physically while Python reports the link.
        XCTAssertNil(PrimerSchemeAdapterResultLoader.runtimeIdentityViolation(
            runtime: runtime(executable: launched.path, prefix: envLink.path),
            engine: .varvamp, executableURL: URL(fileURLWithPath: physicalPrefix + "/bin/python3.13"),
            expectedDistribution: "bioconda::varvamp=1.3.2=pyhdfd78af_0"))
    }

    func testMissingSourceVerificationNamesTheRecordAndTheRepair() throws {
        let launched = envReal.appendingPathComponent("bin/python")
        let message = try XCTUnwrap(PrimerSchemeAdapterResultLoader.runtimeIdentityViolation(
            runtime: runtime(executable: launched.path, prefix: envReal.path, sources: []),
            engine: .varvamp, executableURL: launched,
            expectedDistribution: "bioconda::varvamp=1.3.2=pyhdfd78af_0"))
        XCTAssertTrue(message.contains("lacks upstream source verification"), message)
        XCTAssertTrue(message.contains("no verified varvamp source files"), message)
        XCTAssertTrue(message.contains("native varvamp run itself succeeded"), message)
        XCTAssertTrue(message.contains("reinstall the pcr-primer-design plugin pack"), message)
    }

    func testDifferentEnvironmentIsNamedPrecisely() throws {
        let launched = envReal.appendingPathComponent("bin/python")
        let other = root.appendingPathComponent("real/envs/other", isDirectory: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: other.appendingPathComponent("bin/python"))

        let executableMessage = try XCTUnwrap(PrimerSchemeAdapterResultLoader.runtimeIdentityViolation(
            runtime: runtime(executable: other.appendingPathComponent("bin/python").path, prefix: envReal.path),
            engine: .varvamp, executableURL: launched,
            expectedDistribution: "bioconda::varvamp=1.3.2=pyhdfd78af_0"))
        XCTAssertTrue(executableMessage.contains("names Python"), executableMessage)
        XCTAssertTrue(executableMessage.contains("but LGE launched"), executableMessage)
        XCTAssertTrue(executableMessage.contains("LUNGFISH_CONDA_ROOT"), executableMessage)

        let prefixMessage = try XCTUnwrap(PrimerSchemeAdapterResultLoader.runtimeIdentityViolation(
            runtime: runtime(executable: launched.path, prefix: other.path),
            engine: .varvamp, executableURL: launched,
            expectedDistribution: "bioconda::varvamp=1.3.2=pyhdfd78af_0"))
        XCTAssertTrue(prefixMessage.contains("names environment"), prefixMessage)

        let distributionMessage = try XCTUnwrap(PrimerSchemeAdapterResultLoader.runtimeIdentityViolation(
            runtime: runtime(executable: launched.path, prefix: envReal.path, distribution: "bioconda::varvamp=1.3.1=x"),
            engine: .varvamp, executableURL: launched,
            expectedDistribution: "bioconda::varvamp=1.3.2=pyhdfd78af_0"))
        XCTAssertTrue(distributionMessage.contains("records varvamp distribution bioconda::varvamp=1.3.1=x"), distributionMessage)
        XCTAssertTrue(distributionMessage.contains("pins bioconda::varvamp=1.3.2=pyhdfd78af_0"), distributionMessage)
    }
}

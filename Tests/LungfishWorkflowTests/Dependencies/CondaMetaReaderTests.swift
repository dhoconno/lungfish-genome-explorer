import XCTest
@testable import LungfishWorkflow

final class CondaMetaReaderTests: XCTestCase {
    private func makeEnv(_ files: [String: String]) throws -> URL {
        let env = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let meta = env.appendingPathComponent("conda-meta")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        for (name, body) in files { try body.write(to: meta.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return env
    }

    func testReadsNameVersionBuildSubdir() throws {
        let env = try makeEnv(["samtools-1.23.1-hc612e98_0.json":
            #"{"name":"samtools","version":"1.23.1","build":"hc612e98_0","subdir":"osx-arm64","channel":"https://conda.anaconda.org/bioconda/osx-arm64"}"#])
        let pkgs = CondaMetaReader.packages(inEnvironment: env)
        XCTAssertEqual(pkgs.count, 1)
        XCTAssertEqual(pkgs[0].name, "samtools")
        XCTAssertEqual(pkgs[0].build, "hc612e98_0")
    }

    func testSpecParsingAndMatching() throws {
        let spec = try XCTUnwrap(CondaSpec(spec: "bioconda::samtools=1.23.1=hc612e98_0"))
        XCTAssertEqual(spec.channel, "bioconda"); XCTAssertEqual(spec.name, "samtools")
        XCTAssertEqual(spec.version, "1.23.1"); XCTAssertEqual(spec.build, "hc612e98_0")
        XCTAssertTrue(spec.matches(CondaMetaPackage(name: "samtools", version: "1.23.1", build: "hc612e98_0", subdir: "osx-arm64", channel: nil)))
        XCTAssertFalse(spec.matches(CondaMetaPackage(name: "samtools", version: "1.23.1", build: "hc612e98_1", subdir: "osx-arm64", channel: nil)))
        XCTAssertNil(CondaSpec(spec: "samtools"))               // no version -> not a pin
        XCTAssertNotNil(CondaSpec(spec: "bioconda::samtools=1.23.1")) // build optional in parser
    }
}

import XCTest
@testable import LungfishWorkflow

final class CondaLockfileServiceTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CondaLockfileServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try super.tearDownWithError()
    }

    func testLockfilePinsPluginPackRequirementsAndIsCondaLockCompatible() throws {
        let pack = PluginPack(
            id: "read-mapping",
            name: "Read Mapping",
            description: "Mapping",
            sfSymbol: "map",
            packages: ["minimap2", "bwa-mem2"],
            category: "Mapping",
            requirements: [
                PackToolRequirement(
                    id: "minimap2",
                    displayName: "minimap2",
                    environment: "minimap2",
                    installPackages: ["bioconda::minimap2=2.30"],
                    executables: ["minimap2"],
                    version: "2.30"
                ),
                PackToolRequirement(
                    id: "bwa-mem2",
                    displayName: "BWA-MEM2",
                    environment: "bwa-mem2",
                    installPackages: ["bioconda::bwa-mem2=2.3"],
                    executables: ["bwa-mem2"],
                    version: "2.3"
                ),
            ]
        )
        let output = tempRoot.appendingPathComponent("read-mapping-lock.yml")

        let result = try CondaLockfileService().writeLockfile(
            for: pack,
            to: output,
            commandLine: ["lungfish", "conda", "lock", "--pack", "read-mapping", "--output", output.path]
        )

        XCTAssertEqual(result.lockfileURL, output)
        let yaml = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(yaml.contains("metadata:"))
        XCTAssertTrue(yaml.contains("content_hash:"))
        XCTAssertTrue(yaml.contains("package:"))
        XCTAssertTrue(yaml.contains("name: minimap2"))
        XCTAssertTrue(yaml.contains("version: \"2.30\""))
        XCTAssertTrue(yaml.contains("manager: conda"))
        XCTAssertTrue(yaml.contains("name: bwa-mem2"))
        XCTAssertTrue(yaml.contains("version: \"2.3\""))
        XCTAssertTrue(yaml.contains("category: main"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.provenanceURL.path))
    }

    func testInstallFromLockfilePlansExactEnvironmentCreatesAndWritesProvenance() async throws {
        let customCondaRoot = tempRoot.appendingPathComponent("conda", isDirectory: true)
        let lockfile = customCondaRoot
            .appendingPathComponent("locks", isDirectory: true)
            .appendingPathComponent("lock.yml")
        try FileManager.default.createDirectory(
            at: lockfile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        version: 1
        metadata:
          pack: read-mapping
          platforms:
            - osx-arm64
        package:
          - name: minimap2
            version: "2.30"
            manager: conda
            platform: osx-arm64
            dependencies: {}
          - name: bwa-mem2
            version: "2.3"
            manager: conda
            platform: osx-arm64
            dependencies: {}

        """.write(to: lockfile, atomically: true, encoding: .utf8)

        let recorder = RecordingCondaLockInstaller()
        let result = try await CondaLockfileService().install(
            fromLockfile: lockfile,
            condaRoot: customCondaRoot,
            installer: recorder,
            commandLine: ["lungfish", "conda", "install", "--from-lockfile", lockfile.path]
        )

        let calls = await recorder.calls
        XCTAssertEqual(calls, [
            .init(environment: "minimap2", packageSpecs: ["minimap2=2.30"], condaRoot: customCondaRoot),
            .init(environment: "bwa-mem2", packageSpecs: ["bwa-mem2=2.3"], condaRoot: customCondaRoot),
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.provenanceURL.path))
        XCTAssertTrue(result.provenanceURL.path.hasPrefix(customCondaRoot.standardizedFileURL.path))

        let minimap2Env = customCondaRoot.appendingPathComponent("envs/minimap2", isDirectory: true)
        let bwaEnv = customCondaRoot.appendingPathComponent("envs/bwa-mem2", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: minimap2Env.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bwaEnv.path))

        let provenance = try JSONDecoder.lungfishProvenance.decode(
            WorkflowRun.self,
            from: Data(contentsOf: result.provenanceURL)
        )
        XCTAssertEqual(provenance.parameters["lockfilePath"]?.stringValue, lockfile.standardizedFileURL.path)
        XCTAssertTrue(provenance.parameters["lockfilePath"]?.stringValue?.hasPrefix(customCondaRoot.standardizedFileURL.path) == true)
        XCTAssertEqual(provenance.parameters["destinationCondaRoot"]?.stringValue, customCondaRoot.standardizedFileURL.path)
        XCTAssertEqual(
            provenance.steps.first?.outputs.map(\.path).sorted(),
            [bwaEnv.path, minimap2Env.path].sorted()
        )
    }
}

private actor RecordingCondaLockInstaller: CondaLockInstalling {
    struct Call: Equatable {
        let environment: String
        let packageSpecs: [String]
        let condaRoot: URL
    }

    private(set) var calls: [Call] = []

    func install(environment: String, packageSpecs: [String], condaRoot: URL) async throws {
        try FileManager.default.createDirectory(
            at: condaRoot.appendingPathComponent("envs/\(environment)", isDirectory: true),
            withIntermediateDirectories: true
        )
        calls.append(.init(environment: environment, packageSpecs: packageSpecs, condaRoot: condaRoot))
    }
}

private extension JSONDecoder {
    static var lungfishProvenance: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

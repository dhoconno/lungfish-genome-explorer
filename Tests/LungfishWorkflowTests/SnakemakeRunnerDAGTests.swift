import XCTest
@testable import LungfishWorkflow

final class SnakemakeRunnerDAGTests: XCTestCase {

    func testDAGConversionUsesUniqueTemporaryDirectoryAndCleansItUp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnakemakeRunnerDAGTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dotExecutable = root.appendingPathComponent("dot")
        try Data().write(to: dotExecutable)

        let observations = SnakemakeDAGConversionObservations()

        let converter = SnakemakeDAGConverter(
            temporaryDirectoryProvider: { root },
            dotExecutableProvider: { dotExecutable },
            runGraphviz: { _, arguments, workingDirectory in
                guard let outputIndex = arguments.firstIndex(of: "-o") else {
                    return (1, "", "missing output")
                }
                let outputFile = URL(fileURLWithPath: arguments[outputIndex + 1])
                let inputFile = URL(fileURLWithPath: arguments.last ?? "")
                await observations.append(
                    workingDirectory: workingDirectory,
                    inputFile: inputFile,
                    outputFile: outputFile
                )

                XCTAssertTrue(FileManager.default.fileExists(atPath: inputFile.path))
                try "<svg/>".data(using: .utf8)!.write(to: outputFile)
                return (0, "", "")
            }
        )

        let first = try await converter.convert(dotData: Data("digraph { a }".utf8), format: .svg)
        let second = try await converter.convert(dotData: Data("digraph { b }".utf8), format: .svg)

        XCTAssertEqual(String(data: first, encoding: .utf8), "<svg/>")
        XCTAssertEqual(String(data: second, encoding: .utf8), "<svg/>")
        let observedWorkingDirectories = await observations.workingDirectories
        let observedInputFiles = await observations.inputFiles
        let observedOutputFiles = await observations.outputFiles
        XCTAssertEqual(observedWorkingDirectories.count, 2)
        XCTAssertEqual(Set(observedWorkingDirectories.map(\.path)).count, 2)
        XCTAssertTrue(observedInputFiles.allSatisfy { $0.lastPathComponent == "dag.dot" })
        XCTAssertTrue(observedOutputFiles.allSatisfy { $0.lastPathComponent == "dag.svg" })
        XCTAssertTrue(observedWorkingDirectories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("dag.dot").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("dag.svg").path))
    }

    func testDAGConversionReturnsRawDOTWhenGraphvizIsUnavailable() async throws {
        let rawDOT = Data("digraph { raw }".utf8)
        let converter = SnakemakeDAGConverter(
            dotExecutableProvider: { nil },
            runGraphviz: { _, _, _ in
                XCTFail("Graphviz must not run when the executable is unavailable")
                return (0, "", "")
            }
        )

        let converted = try await converter.convert(dotData: rawDOT, format: .svg)

        XCTAssertEqual(converted, rawDOT)
    }

    func testDAGConversionReturnsRawDOTAndCleansTemporaryDirectoryWhenGraphvizFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnakemakeRunnerDAGTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dotExecutable = root.appendingPathComponent("dot")
        try Data().write(to: dotExecutable)
        let observations = SnakemakeDAGConversionObservations()
        let rawDOT = Data("digraph { failed }".utf8)
        let converter = SnakemakeDAGConverter(
            temporaryDirectoryProvider: { root },
            dotExecutableProvider: { dotExecutable },
            runGraphviz: { _, _, workingDirectory in
                await observations.append(
                    workingDirectory: workingDirectory,
                    inputFile: workingDirectory.appendingPathComponent("dag.dot"),
                    outputFile: workingDirectory.appendingPathComponent("dag.svg")
                )
                return (1, "", "conversion failed")
            }
        )

        let converted = try await converter.convert(dotData: rawDOT, format: .svg)

        XCTAssertEqual(converted, rawDOT)
        let observedWorkingDirectories = await observations.workingDirectories
        XCTAssertEqual(observedWorkingDirectories.count, 1)
        XCTAssertTrue(observedWorkingDirectories.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testPNGConversionUsesPNGOutputPath() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnakemakeRunnerDAGTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dotExecutable = root.appendingPathComponent("dot")
        try Data().write(to: dotExecutable)
        let observations = SnakemakeDAGConversionObservations()
        let converter = SnakemakeDAGConverter(
            temporaryDirectoryProvider: { root },
            dotExecutableProvider: { dotExecutable },
            runGraphviz: { _, arguments, workingDirectory in
                guard let outputIndex = arguments.firstIndex(of: "-o") else {
                    return (1, "", "missing output")
                }
                let outputFile = URL(fileURLWithPath: arguments[outputIndex + 1])
                await observations.append(
                    workingDirectory: workingDirectory,
                    inputFile: URL(fileURLWithPath: arguments.last ?? ""),
                    outputFile: outputFile
                )
                try Data([0x89, 0x50, 0x4e, 0x47]).write(to: outputFile)
                return (0, "", "")
            }
        )

        let converted = try await converter.convert(dotData: Data("digraph { png }".utf8), format: .png)

        XCTAssertEqual(converted, Data([0x89, 0x50, 0x4e, 0x47]))
        let observedOutputFiles = await observations.outputFiles
        XCTAssertEqual(observedOutputFiles.map(\.lastPathComponent), ["dag.png"])
    }
}

private actor SnakemakeDAGConversionObservations {
    private(set) var workingDirectories: [URL] = []
    private(set) var inputFiles: [URL] = []
    private(set) var outputFiles: [URL] = []

    func append(workingDirectory: URL, inputFile: URL, outputFile: URL) {
        workingDirectories.append(workingDirectory)
        inputFiles.append(inputFile)
        outputFiles.append(outputFile)
    }
}

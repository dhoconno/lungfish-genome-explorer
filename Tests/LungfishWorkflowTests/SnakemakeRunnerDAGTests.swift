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

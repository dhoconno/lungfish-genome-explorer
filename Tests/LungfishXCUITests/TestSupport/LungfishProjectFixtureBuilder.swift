import Foundation

enum LungfishProjectFixtureBuilder {
    private struct ProjectMetadataFixture: Encodable {
        let author: String?
        let createdAt: Date
        let customMetadata: [String: String]
        let description: String?
        let formatVersion: String
        let modifiedAt: Date
        let name: String
        let version: String
    }

    private struct AnalysisMetadataFixture: Encodable {
        let created: Date
        let isBatch: Bool
        let tool: String
    }

    private enum FixtureCopyTarget {
        case projectRoot
        case directory(name: String)
    }

    static func makeAnalysesProject(named name: String = "FixtureProject") throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "lungfish-xcui-project-\(UUID().uuidString)",
            isDirectory: true
        )
        let projectURL = root.appendingPathComponent("\(name).lungfish", isDirectory: true)
        let analysesDirectory = projectURL.appendingPathComponent("Analyses", isDirectory: true)
        let source = LungfishFixtureCatalog.analyses.appendingPathComponent(
            "spades-2026-01-15T13-00-00",
            isDirectory: true
        )
        let destination = analysesDirectory.appendingPathComponent(
            "spades-2026-01-15T13-00-00",
            isDirectory: true
        )

        try fileManager.createDirectory(at: analysesDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
        try writeProjectMetadata(to: projectURL, name: name)
        try writeAnalysisMetadata(to: destination, tool: "spades")
        return projectURL
    }

    static func makeIlluminaAssemblyProject(named name: String = "IlluminaAssemblyFixture") throws -> URL {
        try makeProject(
            named: name,
            fixtures: [
                (LungfishFixtureCatalog.sarscov2.appendingPathComponent("test_1.fastq.gz"), .projectRoot),
                (LungfishFixtureCatalog.sarscov2.appendingPathComponent("test_2.fastq.gz"), .projectRoot),
            ]
        )
    }

    static func makeOntAssemblyProject(named name: String = "OntAssemblyFixture") throws -> URL {
        try makeProject(
            named: name,
            fixtures: [
                (LungfishFixtureCatalog.assemblyUI.appendingPathComponent("ont/reads.fastq"), .projectRoot),
            ]
        )
    }

    static func makePacBioHiFiAssemblyProject(named name: String = "HiFiAssemblyFixture") throws -> URL {
        try makeProject(
            named: name,
            fixtures: [
                (LungfishFixtureCatalog.assemblyUI.appendingPathComponent("pacbio-hifi/reads.fastq"), .projectRoot),
            ]
        )
    }

    private static func makeProject(
        named name: String,
        fixtures: [(source: URL, target: FixtureCopyTarget)]
    ) throws -> URL {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "lungfish-xcui-project-\(UUID().uuidString)",
            isDirectory: true
        )
        let projectURL = root.appendingPathComponent("\(name).lungfish", isDirectory: true)
        try fileManager.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try writeProjectMetadata(to: projectURL, name: name)

        for fixture in fixtures {
            let destinationDirectory: URL
            switch fixture.target {
            case .projectRoot:
                destinationDirectory = projectURL
            case .directory(let name):
                destinationDirectory = projectURL.appendingPathComponent(name, isDirectory: true)
                try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            }

            try fileManager.copyItem(
                at: fixture.source,
                to: destinationDirectory.appendingPathComponent(fixture.source.lastPathComponent)
            )
        }

        return projectURL
    }

    private static func writeProjectMetadata(to projectURL: URL, name: String) throws {
        let timestamp = Date()
        let metadata = ProjectMetadataFixture(
            author: nil,
            createdAt: timestamp,
            customMetadata: [:],
            description: nil,
            formatVersion: "1.0",
            modifiedAt: timestamp,
            name: name,
            version: "1.0"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadataURL = projectURL.appendingPathComponent("metadata.json")
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
    }

    private static func writeAnalysisMetadata(to analysisURL: URL, tool: String) throws {
        let metadata = AnalysisMetadataFixture(
            created: Date(),
            isBatch: false,
            tool: tool
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadataURL = analysisURL.appendingPathComponent("analysis-metadata.json")
        try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
    }
}

import Foundation

public struct PBAAContainerImagePin: Sendable, Codable, Equatable {
    public let id: String
    public let reference: String
    public let expectedDigest: String
    public let toolVersion: String

    public var pinnedReference: String {
        "\(reference)@\(expectedDigest)"
    }

    public init(id: String, reference: String, expectedDigest: String, toolVersion: String) {
        self.id = id
        self.reference = reference
        self.expectedDigest = expectedDigest
        self.toolVersion = toolVersion
    }
}

public struct PBAAContainerPins: Sendable, Codable, Equatable {
    public static let workflowSchemaVersion = "pbaa-cluster/1"

    public static let pbaa = PBAAContainerImagePin(
        id: "pbaa",
        reference: "quay.io/biocontainers/pbaa:1.2.0--h9ee0642_0",
        expectedDigest: "sha256:fa48bd65b2e429af09eaf06541030e812e5bb0de440059b9b34a6e49c87edd04",
        toolVersion: "1.2.0"
    )

    public static let samtools = PBAAContainerImagePin(
        id: "samtools",
        reference: "quay.io/biocontainers/samtools:1.23.1--ha83d96e_0",
        expectedDigest: "sha256:23cda33a3a42125872766df9aaf1d2db67cdb8c85314b793465188435af31ba6",
        toolVersion: "1.23.1"
    )

    public static let current = PBAAContainerPins(pbaa: pbaa, samtools: samtools)

    public let pbaa: PBAAContainerImagePin
    public let samtools: PBAAContainerImagePin

    public init(pbaa: PBAAContainerImagePin, samtools: PBAAContainerImagePin) {
        self.pbaa = pbaa
        self.samtools = samtools
    }
}

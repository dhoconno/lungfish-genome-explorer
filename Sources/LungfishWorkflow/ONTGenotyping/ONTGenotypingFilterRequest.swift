import Foundation
import LungfishCore
import LungfishIO

public struct ONTGenotypingFilterRequest: Sendable, Codable, Equatable {
    public let sampleName: String
    public let inputBAMURL: URL
    public let referenceFASTAURL: URL
    public let outputBAMURL: URL
    public let scriptURL: URL
    public let extraArguments: [String]

    public init(
        sampleName: String,
        inputBAMURL: URL,
        referenceFASTAURL: URL,
        outputBAMURL: URL,
        scriptURL: URL,
        extraArguments: [String] = []
    ) {
        self.sampleName = sampleName
        self.inputBAMURL = inputBAMURL.standardizedFileURL
        self.referenceFASTAURL = referenceFASTAURL.standardizedFileURL
        self.outputBAMURL = outputBAMURL.standardizedFileURL
        self.scriptURL = scriptURL.standardizedFileURL
        self.extraArguments = extraArguments
    }

    public var outputBAIURL: URL {
        outputBAMURL.appendingPathExtension("bai")
    }

    public var pythonArguments: [String] {
        [
            scriptURL.path,
            "--sample-name", sampleName,
            "--input-bam", inputBAMURL.path,
            "--reference-fasta", referenceFASTAURL.path,
            "--output-bam", outputBAMURL.path,
            "--require-both-end-softclips",
            "--require-full-reference-span",
            "--allow-indels",
            "--max-mismatches", "0",
        ] + extraArguments
    }
}

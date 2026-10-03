import Foundation
import LungfishCore
import LungfishIO
import os.log

public struct ViralVariantCallingExecutionPlan: Sendable, Equatable {
    public let caller: ViralVariantCaller
    public let workingDirectory: URL
    public let alignmentURL: URL
    public let alignmentIndexURL: URL
    public let referenceURL: URL
    public let referenceIndexURL: URL
    public let medakaFASTQURL: URL?
    public let rawVCFURL: URL
    public let normalizedVCFURL: URL
    public let stagedVCFGZURL: URL
    public let stagedTabixURL: URL
    public let commandLine: String
    /// Medaka and Clair3 only: the platform the caller is told to expect.
    public let platform: VariantCallingPlatform?
    /// Clair3 only: the resolved `--model_path` directory.
    public let clair3ModelPath: URL?

    public init(
        caller: ViralVariantCaller,
        workingDirectory: URL,
        alignmentURL: URL,
        alignmentIndexURL: URL,
        referenceURL: URL,
        referenceIndexURL: URL,
        medakaFASTQURL: URL?,
        rawVCFURL: URL,
        normalizedVCFURL: URL,
        stagedVCFGZURL: URL,
        stagedTabixURL: URL,
        commandLine: String,
        platform: VariantCallingPlatform? = nil,
        clair3ModelPath: URL? = nil
    ) {
        self.caller = caller
        self.workingDirectory = workingDirectory
        self.alignmentURL = alignmentURL
        self.alignmentIndexURL = alignmentIndexURL
        self.referenceURL = referenceURL
        self.referenceIndexURL = referenceIndexURL
        self.medakaFASTQURL = medakaFASTQURL
        self.rawVCFURL = rawVCFURL
        self.normalizedVCFURL = normalizedVCFURL
        self.stagedVCFGZURL = stagedVCFGZURL
        self.stagedTabixURL = stagedTabixURL
        self.commandLine = commandLine
        self.platform = platform
        self.clair3ModelPath = clair3ModelPath
    }

    /// The folder `medaka_variant -o` writes into (`medaka.annotated.vcf`
    /// is the final, depth-annotated call set).
    public var medakaOutputDirectory: URL {
        rawVCFURL.deletingLastPathComponent().appendingPathComponent("medaka", isDirectory: true)
    }

    /// The folder `run_clair3.sh --output` writes into (`merge_output.vcf.gz`
    /// is the final call set).
    public var clair3OutputDirectory: URL {
        rawVCFURL.deletingLastPathComponent().appendingPathComponent("clair3", isDirectory: true)
    }
}

// ViralReconSharedSampleName.swift - Two inputs of a Viral Recon run that go by one sample name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation

extension ViralReconSamplesheetBuilder {
    /// Two inputs of a Viral Recon run go by one sample name once letter case is ignored.
    ///
    /// viralrecon joins the rows of one `sample` into one sample, so two LGE samples of one name ran as one sample
    /// whose reads were both, and each result showed the joined reads with no words (trust session VR-SAME-NAME,
    /// BIO-PROBES-F Q1). Names that differ only in letter case are two samples to viralrecon, but its result files
    /// are named `<sample>.*`, and a disk that ignores case keeps one file for the two. The inputs are named by
    /// ``describingInputs(_:_:)``, the first input first.
    public struct SharedSampleNameError: Error, LocalizedError, Sendable, Equatable {
        public let name: String
        public let input: URL
        public let otherName: String
        public let otherInput: URL

        public var errorDescription: String? {
            let (first, second) = ViralReconSamplesheetBuilder.describingInputs(input, otherInput)
            let rename = "Rename the sample of one of them in its metadata, and run again."
            if name == otherName {
                return "The inputs “\(first)” and “\(second)” both have the sample name “\(name)”, "
                    + "and viralrecon would join their reads into one sample. " + rename
            }
            return "The inputs “\(first)” and “\(second)” have the sample names “\(name)” and “\(otherName)”, "
                + "which differ only in letter case, and viralrecon's result files for the two would replace "
                + "each other on a disk that ignores case. " + rename
        }
    }

    /// Refuses the first input whose sample name repeats an earlier one once letter case is ignored. The name is
    /// refused, never renamed, because a renamed sample would differ from the name viralrecon writes into its
    /// files. The wizard, the app's Run and `workflow run` with bundle inputs reach this through
    /// ``ViralReconInputResolver/makeSamples(from:)``, so the run stops before any read is split or staged. A
    /// samplesheet that a caller wrote by hand is not read for names (viralrecon's own runs of one sample stay
    /// possible).
    public static func refuseInputsThatShareASampleName(_ inputs: [(name: String, url: URL)]) throws {
        var firstOfName: [String: (name: String, url: URL)] = [:]
        for input in inputs {
            let key = input.name.lowercased()
            if let earlier = firstOfName[key] {
                throw SharedSampleNameError(
                    name: earlier.name, input: earlier.url, otherName: input.name, otherInput: input.url
                )
            }
            firstOfName[key] = input
        }
    }

    /// Each of two inputs by the shortest trailing part of its path that tells it from the other, one folder at a
    /// time from the file name up. Letter case is ignored in the comparison, because two parts that differ only in
    /// case look alike to a person.
    static func describingInputs(_ first: URL, _ second: URL) -> (String, String) {
        let firstParts = first.standardizedFileURL.pathComponents.filter { $0 != "/" }
        let secondParts = second.standardizedFileURL.pathComponents.filter { $0 != "/" }
        var length = 1
        while length < min(firstParts.count, secondParts.count),
              firstParts.suffix(length).map({ $0.lowercased() }) == secondParts.suffix(length).map({ $0.lowercased() }) {
            length += 1
        }
        return (firstParts.suffix(length).joined(separator: "/"), secondParts.suffix(length).joined(separator: "/"))
    }
}

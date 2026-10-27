// BBToolsPairArguments.swift - The reformat.sh argv that joins two mate files and splits one file back
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

/// The `reformat.sh` argv of a pair conversion, shared by every site that interleaves two mate files or splits an
/// interleaved file (row BBTOOLS-QIN). One builder gives every site the same flags, and a test reaches it without the
/// app. The layout is always stated, so BBTools' own name detection cannot pair a file by position.
package enum BBToolsPairArguments {
    /// R1 and R2 files into one interleaved file.
    package static func interleave(r1: String, r2: String, output: String) -> [String] {
        [
            "in1=\(r1)",
            "in2=\(r2)",
            "out=\(output)",
            "interleaved=t",
        ] + BBToolsQualityArguments.keepEveryScore
    }

    /// One interleaved file into R1 and R2 files.
    package static func deinterleave(input: String, out1: String, out2: String) -> [String] {
        [
            "in=\(input)",
            "out1=\(out1)",
            "out2=\(out2)",
            "interleaved=t",
        ] + BBToolsQualityArguments.keepEveryScore
    }
}

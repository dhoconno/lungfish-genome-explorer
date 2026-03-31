import UniformTypeIdentifiers

enum FASTAFileTypes {
    static let readableExtensions = ["fa", "fasta", "fna", "fsa"]

    /// Content types for FASTA files, including gzip-compressed variants.
    ///
    /// Includes both plain FASTA extensions and `.gz` / `.gzip` so that
    /// NSOpenPanel accepts `sequence.fa.gz` files used by genome bundles.
    static let readableContentTypes: [UTType] = {
        var types = readableExtensions.compactMap { UTType(filenameExtension: $0) }
        // Add gzip so .fa.gz, .fasta.gz are selectable
        types.append(.gzip)
        if let gz = UTType(filenameExtension: "gz") {
            types.append(gz)
        }
        return types
    }()
}

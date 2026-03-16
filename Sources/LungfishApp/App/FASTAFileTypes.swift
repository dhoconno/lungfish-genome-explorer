import UniformTypeIdentifiers

enum FASTAFileTypes {
    static let readableExtensions = ["fa", "fasta", "fna", "fsa"]
    static let readableContentTypes: [UTType] = readableExtensions.compactMap {
        UTType(filenameExtension: $0)
    }
}

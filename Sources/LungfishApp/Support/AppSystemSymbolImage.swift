import AppKit

enum AppSystemSymbolImage {
    static func named(
        _ symbolName: String,
        accessibilityDescription: String?,
        fallbackSize: NSSize = NSSize(width: 16, height: 16)
    ) -> NSImage {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)
            ?? NSImage(size: fallbackSize)
    }
}

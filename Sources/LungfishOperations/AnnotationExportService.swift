import Foundation
import LungfishCore
import LungfishIO
import LungfishWorkflow

/// Value-captured export inputs shared by document and sidebar entry points.
package enum AnnotationExportService {
    package struct Source: Codable, Sendable {
        package enum Kind: String, Codable, Sendable { case openDocument, sidebarBundle }
        package let kind: Kind
        package let urls: [URL]
        package let name: String

        package init(kind: Kind, urls: [URL], name: String) {
            self.kind = kind
            self.urls = urls
            self.name = name
        }
    }
}
